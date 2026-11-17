import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'subs_srt.dart';
import 'tr_bus.dart';
import 'translator.dart';

/// 听队列里的「整片翻译」引擎。
///
/// 以前翻译只能在查看页里跑（点「翻译」= 进界面 + 弹语言 + 页内进度条）。
/// 现在队列卡片上就地跑：蓝条压在转写绿条上显示进度，按钮 蓝(翻译中)
/// →红(暂停)→绿(完成)，结果照样落到同一份缓存，查看页打开就是双语。
///
/// 缓存与查看页共用：`<systemTemp 的上一级>/files/subs_tr/<jobId>_<lang>.json`，
/// 是一份与句序对齐的字符串数组。
/// 全局翻译器表：翻译挂在应用层，**离开听队列页面也继续跑**。
///
/// 以前翻译器是页面的 State 字段，`dispose()` 里 `cancel()` —— 一退出就断，
/// 而且断在批次之间，最后一跳不落盘，等于白翻。
final Map<String, SubTranslator> _registry = {};

SubTranslator translatorFor(String jobId, {Api? api}) =>
    _registry.putIfAbsent(jobId, () => SubTranslator(jobId: jobId, api: api));

/// 页面要显示的全部翻译器（给「有任务在翻」的提示用）
Iterable<SubTranslator> get activeTranslators =>
    _registry.values.where((t) => t.active);

bool get anyTranslating => activeTranslators.isNotEmpty;

/// 任务被删掉时回收
void forgetTranslator(String jobId) {
  final t = _registry.remove(jobId);
  t?.cancel();
  // 同生共死：任务被删，这份译文缓存也一起删，不留孤儿文件
  unawaited(t?.dropCache() ?? Future<void>.value());
}

class SubTranslator extends ChangeNotifier {
  SubTranslator({
    this.api,
    required this.jobId,
    this.loadSrtFn,
    this.trFn,
    this.dirOverride,
  });

  final Api? api;
  final String jobId;

  /// 测试注入：不碰网络、不写用户目录
  final Future<String> Function()? loadSrtFn;
  final Future<List<String>> Function(List<String> lines, String to)? trFn;
  final Directory? dirOverride;

  /// srt 里的全部句子（顺序必须和查看页一致，译文才不错位）
  List<Cue> cues = const [];

  String lang = '';
  List<String> out = const [];

  bool loading = false;
  bool busy = false; // 正在翻（不是暂停）
  bool paused = false;
  bool done = false;
  String err = '';
  int doneCount = 0;

  bool get active => busy || paused;
  double get progress =>
      cues.isEmpty ? 0 : (doneCount / cues.length).clamp(0.0, 1.0);
  int get pct => (progress * 100).round();

  bool _stop = false;
  Completer<void>? _gate;
  DateTime _savedAt = DateTime.fromMillisecondsSinceEpoch(0);

  static Directory dir() =>
      Directory('${Directory.systemTemp.parent.path}/files/subs_tr');

  Directory _dir() => dirOverride ?? dir();

  static File file(String jobId, String lang) =>
      File('${dir().path}/${jobId}_$lang.json');

  File _file(String lang) => File('${_dir().path}/${jobId}_$lang.json');

  /// 任务被删时调用：把这个任务所有语言的译文缓存文件删掉
  Future<void> dropCache() async {
    try {
      final d = _dir();
      if (!await d.exists()) return;
      await for (final f in d.list()) {
        if (f is File && f.uri.pathSegments.last.startsWith('${jobId}_')) {
          try {
            await f.delete();
          } catch (e) {
            debugPrint('译文缓存删不掉 ${f.path}: $e');
          }
        }
      }
    } catch (_) {}
  }

  /// 模型拒翻（成人内容常见）时会把「无法翻译此内容」当译文回给我们。
  /// 这种既不能当译文存，也不能写进缓存 —— 存了字幕上就是一句废话，
  /// 而且服务端的 pending 会以为这段翻过了。
  static final RegExp _refuseRe =
      RegExp(r'无法翻译|无法提供|不能翻译|无法完成|抱歉[，,]?\s*我');

  static String _clean(String t) {
    final v = t.trim();
    if (v.isEmpty || _refuseRe.hasMatch(v)) return '';
    return v;
  }

  /// 读缓存：长度和句数对不上就当没有（换过 srt 的旧缓存不能用）
  Future<bool> loadCache(String lang) async {
    try {
      await _ensureCues(); // 先知道总句数，才能判断这份缓存吃完没有
      final f = _file(lang);
      if (!await f.exists()) return false;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return false;
      final list = raw.map((e) => (e ?? '').toString()).toList();
      if (cues.isNotEmpty && list.length != cues.length) return false;
      this.lang = lang;
      out = list;
      doneCount = list.where((s) => s.trim().isNotEmpty).length;
      done = cues.isNotEmpty && doneCount >= cues.length;
      notifyListeners();
      // 老版本的译文只在手机上：读到缓存就顺手回写服务端一次，
      // 以后换设备/清缓存/任务被删都不会再变成「译文 0 句」。
      for (var i = 0; i < out.length; i++) {
        final tr = out[i].trim();
        final src = i < cues.length ? cues[i].text.trim() : '';
        if (tr.isNotEmpty && tr != src && _clean(tr).isNotEmpty) {
          _pushQ.add([i, tr]);
        }
      }
      unawaited(_pushTr(force: true));
      return true;
    } catch (e) {
      debugPrint('译文缓存读失败（$jobId/$lang）: $e');
      return false;
    }
  }

  /// 完整性检查：哪些句子其实没译出来。
  ///
  /// 「译不出来」有两种：空、以及被原样退回（失败兜底会把原文写回去，
  /// 名字/数字这种本来就不用翻的也会命中，所以是「可疑」不是「一定错」）。
  TrAudit audit() {
    final missing = <int>[];
    final same = <int>[];
    final empty = <int>[];
    for (var i = 0; i < cues.length; i++) {
      final o = i < out.length ? out[i].trim() : '';
      final src = cues[i].text.trim();
      if (o.isEmpty) {
        empty.add(i);
        missing.add(i);
      } else if (o == src) {
        same.add(i);
        missing.add(i);
      }
    }
    return TrAudit(
      total: cues.length,
      missing: missing,
      sameAsSource: same,
      empty: empty,
    );
  }

  /// 重新翻译：默认只补没译出来的句子；`all: true` 整片重来。
  Future<void> redo({bool all = false}) async {
    if (busy || paused) return;
    if (cues.isEmpty) await _ensureCues();
    if (cues.isEmpty) return;
    if (out.length != cues.length) out = List<String>.filled(cues.length, '');
    if (all) {
      out = List<String>.filled(cues.length, '');
    } else {
      for (final i in audit().missing) {
        out[i] = '';
      }
    }
    doneCount = out.where((x) => x.trim().isNotEmpty).length;
    done = false;
    await start(lang);
  }

  final List<List<Object>> _pushQ = [];
  DateTime _pushAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 攒够 40 条或过了 8 秒就推一次，别一句一个请求
  Future<void> _pushTr({bool force = false}) async {
    final a = api;
    if (a == null || _pushQ.isEmpty) return;
    final now = DateTime.now();
    if (!force &&
        _pushQ.length < 40 &&
        now.difference(_pushAt).inSeconds < 8) {
      return;
    }
    final items = List<List<Object>>.from(_pushQ);
    _pushQ.clear();
    _pushAt = now;
    try {
      await a.subsPushTr(jobId, lang, items);
      lastPushErr = '';
    } catch (e) {
      // 离线 / 服务端老版本都不该影响翻译本身：
      // 只记一笔，译文还在本地缓存里，下次跟着新批次再推
      lastPushErr = '$e';
    }
  }

  String lastPushErr = '';

  Future<void> _save() async {
    try {
      await _dir().create(recursive: true);
      await _file(lang).writeAsString(jsonEncode(out), flush: true);
    } catch (_) {}
  }

  Future<void> _ensureCues() async {
    if (cues.isNotEmpty) return;
    loading = true;
    notifyListeners();
    try {
      cues = parseSrt(await (loadSrtFn?.call() ?? api!.subsSrtText(jobId)));
      err = '';
    } catch (e) {
      err = '$e';
    }
    loading = false;
    notifyListeners();
  }

  /// 开始或续跑。同语言已有完整缓存 → 直接算完成（绿）。
  Future<void> start(String lang) async {
    if (busy) return;
    this.lang = lang;
    err = '';
    await _ensureCues();
    if (cues.isEmpty) {
      if (err.isEmpty) err = '这个任务还没有字幕';
      notifyListeners();
      return;
    }
    if (out.length != cues.length) {
      out = List<String>.filled(cues.length, '');
    }
    doneCount = out.where((s) => s.trim().isNotEmpty).length;
    if (doneCount >= cues.length) {
      done = true;
      busy = false;
      paused = false;
      notifyListeners();
      return;
    }
    done = false;
    _stop = false;
    paused = false;
    busy = true;
    notifyListeners();
    await _run();
  }

  void pause() {
    if (!busy) return;
    busy = false;
    paused = true;
    unawaited(_save()); // 暂停即落盘：这时候退出 App 也不丢已翻的
    notifyListeners();
  }

  void resume() {
    if (!paused) return;
    paused = false;
    busy = true;
    final g = _gate;
    if (g != null && !g.isCompleted) g.complete();
    notifyListeners();
  }

  void cancel() {
    _stop = true;
    final g = _gate;
    if (g != null && !g.isCompleted) g.complete();
    if (out.isNotEmpty) unawaited(_save());
  }

  /// 暂停时停在两批之间：已经翻好的不丢，恢复后从没翻的继续。
  Future<void> _run() async {
    final texts = cues.map((c) => c.text).toList();
    final bad = <int>[];
    for (var i = 0; i < texts.length; i += 40) {
      if (paused && !_stop) {
        _gate = Completer<void>();
        await _gate!.future;
        _gate = null;
      }
      if (_stop) break;
      // 实时翻译优先：播放器那边开着「显示译文」时，队列翻译在批次之间挂起，
      // 等它结束再继续（播放器退出/关译文自动恢复）。
      await TrBus.waitForQueue(() => paused || _stop);
      if (_stop) break;
      final end = math.min(i + 40, texts.length);
      final pending = <int>[
        for (var k = i; k < end; k++)
          if (out[k].trim().isEmpty) k,
      ];
      if (pending.isEmpty) {
        doneCount = end;
        notifyListeners();
        continue;
      }
      final chunk = [for (final k in pending) texts[k]];
      // 一批失败就整批变原文，等于这段永远漏翻（以前就是这样）。
      // 先重试两次（网络抖动/限流大多是瞬时的），还不行才兜底原文，
      // 并把这些句子记下来，最后再补一轮。
      var ok = false;
      for (var attempt = 0; attempt < 3 && !ok; attempt++) {
        try {
          if (attempt > 0) {
            await Future<void>.delayed(Duration(milliseconds: 600 * attempt));
            if (_stop) break;
          }
          TrBus.queueEnter();
          final List<String> res;
          try {
            res = await (trFn?.call(chunk, lang) ??
                Translator.translate(chunk, lang));
          } finally {
            TrBus.queueExit();
          }
          for (var n = 0; n < pending.length; n++) {
            final t = n < res.length ? res[n] : '';
            final c = _clean(t);
            if (c.isEmpty) bad.add(pending[n]);
            out[pending[n]] = c;
          }
          ok = true;
        } catch (e) {
          err = '$e';
        }
      }
      if (!ok) {
        // 没翻到就是没翻到：留空，别用原文顶着冒充译文
        bad.addAll(pending);
      }
      if (ok) {
        // doneCount 按「真的有译文」重算：以前这里直接记 end，
        // 一批里有一半空着也照样算完成，界面就显示「已译完」而实际是空的。
        doneCount = out.where((x) => x.trim().isNotEmpty).length;
        // 译文回写服务端：本地缓存只当离线备份，任务自己得有一份
        for (final k in pending) {
          // out/texts 都是 List<String>，索引出来不可能是 null
          final tr = out[k].trim();
          final src = texts[k].trim();
          if (tr.isNotEmpty && tr != src && _clean(tr).isNotEmpty) {
            _pushQ.add([k, tr]);
          }
        }
        unawaited(_pushTr());
      } else {
        doneCount = out.where((x) => x.trim().isNotEmpty).length;
      }
      notifyListeners();
      // 每 5 秒落一次盘（不是每批都写，337 句也要写十几遍）
      final now = DateTime.now();
      if (now.difference(_savedAt).inSeconds >= 5) {
        _savedAt = now;
        await _save();
      }
    }
    busy = false;
    paused = false;
    if (_stop) {
      notifyListeners();
      return;
    }
    // 最后再补一轮：前面失败的句子单独重发（一批 20 句，最多两轮）。
    // 全片翻译是后台长任务，等它跑完再发现「这段没译」就没人会去点了。
    for (var round = 0; round < 2 && bad.isNotEmpty && !_stop; round++) {
      final todo = List<int>.from(bad);
      bad.clear();
      for (var i = 0; i < todo.length; i += 20) {
        final part = todo.sublist(i, math.min(i + 20, todo.length));
        try {
          final res = await (trFn?.call([for (final k in part) texts[k]], lang) ??
              Translator.translate([for (final k in part) texts[k]], lang));
          for (var n = 0; n < part.length; n++) {
            final t = n < res.length ? res[n] : '';
            final c = _clean(t);
            if (c.isNotEmpty) out[part[n]] = c;
          }
        } catch (_) {
          bad.addAll(part);
        }
      }
    }
    done = doneCount >= cues.length;
    await _save();
    await _pushTr(force: true);
    err = bad.isEmpty ? '' : '还有 ${bad.length} 句没译上（网络或额度），可以点重试';
    notifyListeners();
  }

  @override
  void dispose() {
    _stop = true;
    super.dispose();
  }
}

/// 一次完整性检查的结果
class TrAudit {
  const TrAudit({
    required this.total,
    required this.missing,
    required this.sameAsSource,
    required this.empty,
  });

  final int total;

  /// 需要重翻的下标：空 + 原样退回
  final List<int> missing;
  final List<int> sameAsSource;
  final List<int> empty;

  int get ok => total - missing.length;
  bool get complete => total > 0 && missing.isEmpty;
  double get ratio => total == 0 ? 0 : ok / total;

  String get summary {
    if (total == 0) return '还没有译文';
    if (complete) return '$total 句全部译好';
    final bits = <String>[
      '共 $total 句',
      '已译 $ok',
      if (sameAsSource.isNotEmpty) '${sameAsSource.length} 句仍是原文',
      if (empty.isNotEmpty) '${empty.length} 句空白',
    ];
    return bits.join(' · ');
  }
}

/// 读某个任务已落盘的译文（与 SubTranslator 的缓存同一份文件）。
/// 播放器打开「已听完」的片子时直接用，不必重翻。
/// 把缓存里已译好的译文套回 cue 列表（`[[起,止,原文,译文], ...]`）。
///
/// 只按句序对齐、不动已有译文；句数以短的一边为准。**不要**再要求
/// 「缓存句数 == 字幕句数」——转写只到 97% 的整片任务、或多出/少掉一条
/// 空段，都会让这个等式不成立，结果就是整片重译一遍（用户看到的
/// 「已经译完的字幕，点开双语又开始实时译」）。
int applyTrCache(List<String> cached, List<dynamic> cues) {
  final n = cached.length < cues.length ? cached.length : cues.length;
  var hit = 0;
  for (var i = 0; i < n; i++) {
    final tr = cached[i].trim();
    if (tr.isEmpty) continue;
    final c = cues[i];
    if (c is List) {
      if (c.length > 3) {
        if ('${c[3]}'.trim().isNotEmpty) continue; // 已有译文，别覆盖
        c[3] = tr;
      } else {
        c.add(tr);
      }
      hit++;
    }
  }
  return hit;
}

/// 语言码归一：zh-Hans / zh-CN / zh_cn / 中文 → zh，zh-Hant / 繁体 → zh-tw。
/// 监控页翻成哪个语言、播放页选的是哪个语言，两边写法不一样也得认得出是同一份译文。
String langKey(String code) {
  final c = code.trim().toLowerCase().replaceAll('_', '-');
  if (c.isEmpty) return '';
  if (c == 'zh' || c.startsWith('zh-cn') || c.startsWith('zh-hans') || c == '中文' || c == '简体中文') {
    return 'zh';
  }
  if (c.startsWith('zh-tw') || c.startsWith('zh-hk') || c.startsWith('zh-hant') ||
      c == '繁体' || c == '繁體中文' || c == '繁體') {
    return 'zh-tw';
  }
  final i = c.indexOf('-');
  return i > 0 ? c.substring(0, i) : c;
}

class TrCache {
  final String lang;
  final List<String> tr;
  const TrCache(this.lang, this.tr);
}

/// 找一个任务最好的译文缓存：先精确语言，再语言归一化，最后「这个任务只有一份」就用它。
///
/// 为什么不能只看精确语言：监控页里翻成什么语言是用户在「翻译成」里选的，
/// 播放页双语的语言是另一个开关，两边不一致时精确查会 0 命中 ——
/// 用户看到的就是「队列听明明译完了，播放页写着译文 0 句」。
Future<TrCache?> loadTrCacheBest(String jobId, String wantLang) async {
  if (jobId.isEmpty) return null;
  final want = langKey(wantLang);
  try {
    final d = SubTranslator.dir();
    if (!await d.exists()) return null;
    TrCache? exact, sameKey, newest;
    var mtExact = DateTime.fromMillisecondsSinceEpoch(0);
    var mtSame = DateTime.fromMillisecondsSinceEpoch(0);
    var mtNew = DateTime.fromMillisecondsSinceEpoch(0);
    await for (final f in d.list()) {
      if (f is! File) continue;
      final n = f.path.split(Platform.pathSeparator).last;
      if (!n.startsWith('${jobId}_') || !n.endsWith('.json')) continue;
      final lang = n.substring(jobId.length + 1, n.length - 5);
      List<String> list;
      try {
        final raw = jsonDecode(await f.readAsString());
        if (raw is! List) continue;
        list = raw.map((e) => (e ?? '').toString()).toList();
      } catch (_) {
        continue;
      }
      if (list.isEmpty || list.every((e) => e.trim().isEmpty)) continue;
      final c = TrCache(lang, list);
      final mt = f.statSync().modified;
      if (lang.toLowerCase() == wantLang.trim().toLowerCase()) {
        if (mt.isAfter(mtExact)) {
          exact = c;
          mtExact = mt;
        }
      } else if (want.isNotEmpty && langKey(lang) == want) {
        if (mt.isAfter(mtSame)) {
          sameKey = c;
          mtSame = mt;
        }
      }
      if (mt.isAfter(mtNew)) {
        newest = c;
        mtNew = mt;
      }
    }
    return exact ?? sameKey ?? newest;
  } catch (e) {
    debugPrint('找译文缓存失败（$jobId）: $e');
    return null;
  }
}

/// 读某任务的译文缓存并套到 cue 上，返回套上的句数。
Future<int> applyCachedTr(String jobId, String lang, List<dynamic> cues) async {
  if (jobId.isEmpty || cues.isEmpty) return 0;
  final c = await loadTrCacheBest(jobId, lang);
  if (c == null || c.tr.isEmpty) return 0;
  return applyTrCache(c.tr, cues);
}

Future<List<String>> loadTrCache(String jobId, String lang) async {
  try {
    final f = File('${SubTranslator.dir().path}/${jobId}_$lang.json');
    if (!await f.exists()) return const <String>[];
    final v = jsonDecode(await f.readAsString());
    if (v is List) return v.map((e) => '$e').toList();
  } catch (e) {
    debugPrint('播放页读译文缓存失败（$jobId/$lang）: $e');
  }
  return const <String>[];
}
