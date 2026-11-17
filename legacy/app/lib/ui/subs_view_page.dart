import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/langs.dart';
import '../core/native.dart';
import '../core/subs_srt.dart';
import '../core/translator.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';
import 'subs_monitor.dart';
import 'widgets.dart';

/// 听译结果查看页：队列里「听完」的字幕点开就能逐句看，
/// 也能整份导出（.srt 走服务端原件，.txt 是纯文本）。
class SubsViewPage extends StatefulWidget {
  final App app;
  final SubJob job;

  /// 只给测试/预览用：直接塞入解析好的句子，跳过网络
  final List<Cue>? preview;

  /// 从「翻译」按钮进来时，打开就弹语言选择
  final bool askTranslate;

  /// 只给截图测试用：直接塞入译文，跳过翻译请求
  final String? previewTrLang;
  final List<String>? previewTr;
  const SubsViewPage({
    super.key,
    required this.app,
    required this.job,
    this.preview,
    this.askTranslate = false,
    this.previewTrLang,
    this.previewTr,
  });

  @override
  State<SubsViewPage> createState() => _SubsViewPageState();
}

class _SubsViewPageState extends State<SubsViewPage> {
  App get app => widget.app;

  bool _loading = true;
  String _err = '';
  List<Cue> _cues = const [];
  bool _busy = false;

  // ---- 翻译 ----
  String _trLang = ''; // 已翻译到哪种语言（空 = 还没翻）
  List<String> _tr = const []; // 与 _cues 等长
  bool _trBusy = false;
  bool _trCancel = false;
  int _trDone = 0;
  int _mode = 0; // 0 原文 / 1 双语 / 2 译文

  @override
  void initState() {
    super.initState();
    final p = widget.preview;
    if (p != null) {
      _cues = p;
      _loading = false;
      if (widget.previewTr != null && widget.previewTrLang != null) {
        _tr = widget.previewTr!;
        _trLang = widget.previewTrLang!;
        _trDone = _tr.length;
        _mode = 1;
      }
      if (widget.askTranslate) {
        // initState 里不能直接弹 sheet，等第一帧画完
        WidgetsBinding.instance.addPostFrameCallback((_) => _pickLang());
      }
      return;
    }
    _load().then((_) {
      if (widget.askTranslate && _cues.isNotEmpty) _pickLang();
    });
  }

  Future<void> _load() async {
    try {
      final text = await app.api.subsSrtText(widget.job.id);
      final cues = parseSrt(text);
      if (!mounted) return;
      setState(() {
        _cues = cues;
        _loading = false;
        _err = cues.isEmpty ? '这份字幕是空的（可能只转了前一段就停了）' : '';
      });
      await _loadTrCache();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _err = '读取失败：$e';
        });
      }
    }
  }

  // ---------------- 翻译 ----------------

  /// 译文缓存目录（跟 session 同一个 files 目录，重启还在）
  static Directory _trDir() {
    final base = Directory('${Directory.systemTemp.parent.path}/files');
    final d = Directory('${base.path}/subs_tr');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  File _trFile(String lang) =>
      File('${_trDir().path}/${widget.job.id}_$lang.json');

  /// 打开时把上次翻过的语言接回来（有缓存就直接显示）
  Future<void> _loadTrCache() async {
    try {
      final d = _trDir();
      if (!d.existsSync()) return;
      final files = d
          .listSync()
          .whereType<File>()
          .where((f) => f.path.split('/').last.startsWith('${widget.job.id}_'))
          .toList();
      if (files.isEmpty) return;
      files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      final f = files.first;
      final lang = f.path.split('_').last.replaceAll('.json', '');
      final arr = (jsonDecode(f.readAsStringSync()) as List).cast<dynamic>();
      if (arr.length != _cues.length) return;
      if (!mounted) return;
      setState(() {
        _trLang = lang;
        _tr = arr.map((e) => e.toString()).toList();
        _trDone = _tr.length;
        _mode = 1;
      });
    } catch (_) {
      /* 缓存坏了就当没有 */
    }
  }

  Future<void> _saveTrCache() async {
    try {
      await _trFile(_trLang).writeAsString(jsonEncode(_tr), flush: true);
    } catch (_) {}
  }

  Future<void> _pickLang() async {
    if (_cues.isEmpty || _trBusy) return;
    final lang = await showSheet<String>(
      context,
      builder: (ctx) => SubLangSheet(current: _trLang),
    );
    if (lang == null || !mounted) return;
    if (lang == _trLang && _tr.isNotEmpty) {
      setState(() => _mode = _mode == 2 ? 1 : 2);
      return;
    }
    await _translate(lang);
  }

  /// 整片翻译：每批 40 句（hub 的上限），一句失败就保留原文
  Future<void> _translate(String lang) async {
    if (_cues.isEmpty) return;
    setState(() {
      _trLang = lang;
      _tr = List<String>.filled(_cues.length, '');
      _trBusy = true;
      _trCancel = false;
      _trDone = 0;
      _mode = 1;
    });
    final texts = _cues.map((c) => c.text).toList();
    var failed = 0;
    for (var i = 0; i < texts.length; i += 40) {
      if (!mounted || _trCancel) break;
      final chunk = texts.sublist(i, math.min(i + 40, texts.length));
      try {
        final out = await Translator.translate(chunk, lang);
        for (var k = 0; k < chunk.length; k++) {
          _tr[i + k] = k < out.length && out[k].trim().isNotEmpty
              ? out[k]
              : chunk[k];
        }
      } catch (_) {
        failed += chunk.length;
        for (var k = 0; k < chunk.length; k++) {
          _tr[i + k] = chunk[k];
        }
      }
      if (!mounted) return;
      setState(() => _trDone = math.min(i + chunk.length, texts.length));
    }
    if (!mounted) return;
    setState(() => _trBusy = false);
    if (_trCancel) {
      app.toast('已停止翻译');
    } else if (failed == 0) {
      app.toast('翻译完成 · ${_cues.length} 句');
      await _saveTrCache();
    } else {
      app.toast('翻译完成，其中 $failed 句失败保留原文');
      await _saveTrCache();
    }
  }

  /// 一句的显示文本（按当前模式）
  String _line(int i) {
    final orig = _cues[i].text;
    if (_trLang.isEmpty || _mode == 0) return orig;
    final t = i < _tr.length ? _tr[i] : '';
    if (t.isEmpty) return orig;
    return _mode == 2 ? t : '$orig\n$t';
  }

  String get _plain => _cues.map((c) => c.text).join('\n');

  /// 导出用的文本：双语模式就「原文\n译文」，否则按当前模式
  String get _exportPlain {
    if (_trLang.isEmpty || _trBusy) return _plain;
    final lines = <String>[];
    for (var i = 0; i < _cues.length; i++) {
      lines.add(_line(i));
    }
    return lines.join('\n');
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _exportPlain));
    if (mounted) {
      app.toast(
        '已复制 ${_cues.length} 句'
        '${_trLang.isEmpty ? '' : '（${subLangName(_trLang)}）'}',
      );
    }
  }

  Future<void> _exportSrt() async {
    if (_busy) return;
    // 没译文就直接存服务端原件，省事也不会格式跑偏
    if (_trLang.isEmpty) {
      setState(() => _busy = true);
      try {
        final abs = app.api.absolute(
          '/api/v1/subs/${Uri.encodeComponent(widget.job.id)}/srt',
        );
        final tok = app.session.token;
        final where = await app.transfers.downloadRaw(
          app.api,
          '${subStem(widget.job.name)}.srt',
          abs,
          headers: {if ((tok ?? '').isNotEmpty) 'Authorization': 'Bearer $tok'},
        );
        if (mounted) {
          app.toast(where == null || where.isEmpty ? '导出失败' : '已存到 $where');
        }
      } catch (e) {
        if (mounted) app.toast('导出失败：$e');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    // 有译文：本地拼 srt，一句一块，双语就分两行
    final b = StringBuffer();
    for (var i = 0; i < _cues.length; i++) {
      b.writeln('${i + 1}');
      b.writeln('${_srtTime(_cues[i].start)} --> ${_srtTime(_cues[i].end)}');
      b.writeln(_line(i));
      b.writeln();
    }
    final name = '${subStem(widget.job.name)}.${_trLang}.srt';
    await _saveText(b.toString(), name);
  }

  /// 把一段文本存到系统「下载」目录
  Future<void> _saveText(String content, String name) async {
    if (_busy) return;
    setState(() => _busy = true);
    File? tmp;
    try {
      final dir = Directory('${Directory.systemTemp.path}/dl');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      tmp = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$name');
      await tmp.writeAsString(content, flush: true);
      final where = await Native.saveToDownloads(
        tmp,
        name: name,
        mime: 'text/plain',
      );
      if (mounted) app.toast(where.isEmpty ? '导出失败' : '已存到 $where');
    } catch (e) {
      if (mounted) app.toast('导出失败：$e');
    } finally {
      try {
        if (tmp != null && tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportTxt() async {
    if (_busy) return;
    setState(() => _busy = true);
    File? tmp;
    try {
      final dir = Directory('${Directory.systemTemp.path}/dl');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final name = '${subStem(widget.job.name)}.txt';
      tmp = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$name');
      // 纯文本：一行一句，给别的工具用
      await tmp.writeAsString(_exportPlain, flush: true);
      final where = await Native.saveToDownloads(
        tmp,
        name: name,
        mime: 'text/plain',
      );
      if (mounted) app.toast(where.isEmpty ? '导出失败' : '已存到 $where');
    } catch (e) {
      if (mounted) app.toast('导出失败：$e');
    } finally {
      try {
        if (tmp != null && tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final j = widget.job;
    return Scaffold(
      backgroundColor: tone.bg,
      body: SafeArea(
        child: Column(
          children: [
            // 顶栏
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
              child: Row(
                children: [
                  _IconBtn(
                    icon: 'arrow-left',
                    onTap: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          j.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: tone.ink,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          _loading
                              ? '读取中…'
                              : [
                                  '${_cues.length} 句',
                                  if (j.lang.isNotEmpty) j.lang,
                                  if (j.dur > 0) _mmss(j.dur),
                                ].join(' · '),
                          style: TextStyle(fontSize: 11.5, color: tone.ink3),
                        ),
                      ],
                    ),
                  ),
                  if (_cues.isNotEmpty)
                    _IconBtn(
                      icon: 'translate',
                      onTap: _pickLang,
                      tint: _trLang.isEmpty ? tone.ink : tone.ac,
                    ),
                ],
              ),
            ),
            // 翻译进度
            if (_trBusy)
              Container(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                color: tone.surface2,
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '翻译中 · $_trDone/${_cues.length} 句 · ${subLangName(_trLang)}',
                            style: TextStyle(fontSize: 11.5, color: tone.ink2),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => setState(() => _trCancel = true),
                          child: Text(
                            '停止',
                            style: TextStyle(fontSize: 11.5, color: tone.ac),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: _cues.isEmpty ? null : _trDone / _cues.length,
                        minHeight: 3,
                        backgroundColor: tone.line,
                        valueColor: AlwaysStoppedAnimation(tone.ac),
                      ),
                    ),
                  ],
                ),
              ),
            // 原文/双语/译文
            if (_trLang.isNotEmpty && !_trBusy)
              Container(
                padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
                color: tone.surface,
                child: Row(
                  children: [
                    Text(
                      subLangName(_trLang),
                      style: TextStyle(fontSize: 11.5, color: tone.ink3),
                    ),
                    const Spacer(),
                    for (final (i, label) in [(0, '原文'), (1, '双语'), (2, '译文')])
                      GestureDetector(
                        onTap: () => setState(() => _mode = i),
                        child: Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _mode == i ? tone.ac : tone.surface2,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: _mode == i ? Colors.white : tone.ink2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Divider(height: 1, color: tone.line),
            Expanded(child: _body(tone)),
            // 底部操作
            if (_cues.isNotEmpty)
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                decoration: BoxDecoration(
                  color: tone.surface,
                  border: Border(top: BorderSide(color: tone.line)),
                ),
                child: Row(
                  children: [
                    _Btn(tone, icon: 'copy', label: '复制全文', onTap: _copy),
                    const SizedBox(width: 8),
                    _Btn(
                      tone,
                      icon: 'download',
                      label: _busy ? '导出中…' : '导出 .srt',
                      onTap: _busy ? null : _exportSrt,
                    ),
                    const SizedBox(width: 8),
                    _Btn(
                      tone,
                      icon: 'type-doc',
                      label: '导出 .txt',
                      onTap: _busy ? null : _exportTxt,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(Tone tone) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_err.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              UIIcon('info', size: 26, color: tone.ink3),
              const SizedBox(height: 10),
              Text(
                _err,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: tone.ink2),
              ),
              const SizedBox(height: 14),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _loading = true;
                    _err = '';
                  });
                  _load();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: tone.surface2,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '重试',
                    style: TextStyle(fontSize: 13, color: tone.ink2),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
      itemCount: _cues.length,
      separatorBuilder: (_, _) => const SizedBox(height: 2),
      itemBuilder: (ctx, i) {
        final c = _cues[i];
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: _line(i)));
            if (mounted) app.toast('已复制这一句');
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 56,
                  child: Text(
                    c.stamp,
                    style: TextStyle(
                      fontSize: 11,
                      color: tone.ink3,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.text,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: tone.ink,
                        ),
                      ),
                      if (_trLang.isNotEmpty &&
                          !_trBusy &&
                          _mode != 0 &&
                          i < _tr.length &&
                          _tr[i].isNotEmpty &&
                          _tr[i] != c.text)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            _tr[i],
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.45,
                              color: tone.ink2,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// srt 时间戳：00:00:01,500
String _srtTime(double sec) {
  final ms = (sec * 1000).round();
  final h = ms ~/ 3600000;
  final m = (ms % 3600000) ~/ 60000;
  final ss = (ms % 60000) ~/ 1000;
  final mmm = ms % 1000;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(ss)},${mmm.toString().padLeft(3, '0')}';
}

String _mmss(double sec) {
  final d = Duration(seconds: sec.round());
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// 语言选择：按 kSubLangs 排，两列
class SubLangSheet extends StatelessWidget {
  final String current;
  const SubLangSheet({super.key, required this.current});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                UIIcon('translate', size: 16, color: tone.ink2),
                const SizedBox(width: 7),
                Text(
                  '翻译成',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: tone.ink,
                  ),
                ),
                const Spacer(),
                if (current.isNotEmpty)
                  Text(
                    '当前 ${subLangName(current)}',
                    style: TextStyle(fontSize: 11.5, color: tone.ink3),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final l in kSubLangs)
                  GestureDetector(
                    onTap: () => Navigator.pop(context, l.code),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: l.code == current ? tone.ac : tone.surface2,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        l.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: l.code == current ? Colors.white : tone.ink2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final String icon;
  final VoidCallback onTap;
  final Color? tint;
  const _IconBtn({required this.icon, required this.onTap, this.tint});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Center(child: UIIcon(icon, size: 20, color: tint ?? tone.ink)),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  final Tone tone;
  final String icon;
  final String label;
  final VoidCallback? onTap;
  const _Btn(this.tone, {required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: tone.surface2,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              UIIcon(
                icon,
                size: 15,
                color: on ? tone.ink2 : tone.ink3.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: on ? tone.ink2 : tone.ink3.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
