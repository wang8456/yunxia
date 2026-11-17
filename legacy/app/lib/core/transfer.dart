import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';
import 'native.dart';

enum TransferKind { upload, download }

class Transfer {
  final String id;
  final TransferKind kind;
  final String name;
  int done = 0;
  int total = 0;

  /// queued | running | paused | done | error | canceled
  String state = 'running';
  String? error;
  String where = '';

  // 续传要用：源、远端路径、签名直链、临时文件
  String source = '';
  String path = '';
  String url = '';

  /// 直链需要的请求头（对话附件走 /hermes/api/dl，得带 Basic 口令）。
  /// 必须跟着一起存盘，否则重试/续传就 401。
  Map<String, String> headers = const {};

  String? tmpPath;

  /// 边下边写：MediaStore 的 content:// 地址（打开/删除都用它）
  String uri = '';

  /// 当前速度（字节/秒）与剩余秒数
  double speed = 0;
  double eta = 0;

  Transfer({
    required this.id,
    required this.kind,
    required this.name,
    this.total = 0,
  });

  double get pct => total > 0 ? (done / total).clamp(0, 1).toDouble() : 0;
  bool get running => state == 'running';
  bool get queued => state == 'queued';
  bool get paused => state == 'paused';
  bool get finished => state == 'done';
  bool get failed => state == 'error';
  bool get alive => state == 'running' || state == 'queued';

  String get stateLabel => switch (state) {
    'queued' => '排队中',
    'running' => '下载中',
    'paused' => '已暂停',
    'done' => '已完成',
    'error' => '出错',
    'canceled' => '已取消',
    _ => state,
  };
}

/// 传输队列：上传/下载都「边传边报进度」，界面只读这个列表。
///
/// 下载是真队列：并发可设、可暂停（临时文件留着，续传用 Range）、可取消、可重试。
class Transfers extends ChangeNotifier {
  final List<Transfer> items = [];
  int _seq = 0;

  /// 同时下载几个（设置页可改）
  int maxActive = 2;

  /// 下载完成后是否提示
  bool notifyDone = true;

  /// 完成/失败时回调给界面（弹 toast 用）
  void Function(String msg)? onDone;

  Api? _api;
  Timer? _saveTimer;

  /// 队列落盘：以前只存在内存里，杀掉进程下载记录就没了（文件却还在手机里）。
  /// 现在跟 session 一样写 <数据根>/files/transfers.json。
  @visibleForTesting
  static Directory? overrideDir;

  static Future<File> _fileHandle() async {
    if (overrideDir != null) return File('${overrideDir!.path}/transfers.json');
    final candidates = <Directory>[
      Directory('${Directory.systemTemp.parent.path}/files'),
      Directory.systemTemp,
    ];
    for (final d in candidates) {
      try {
        if (!d.existsSync()) d.createSync(recursive: true);
        return File('${d.path}/transfers.json');
      } catch (_) {}
    }
    return File('${Directory.systemTemp.path}/transfers.json');
  }

  Future<void> load() async {
    try {
      final f = await _fileHandle();
      if (!f.existsSync()) return;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return;
      for (final e in raw) {
        if (e is! Map) continue;
        final m = e.cast<String, dynamic>();
        final t =
            Transfer(
                id:
                    (m['id'] as String?) ??
                    '${DateTime.now().microsecondsSinceEpoch}-${_seq++}',
                kind: m['kind'] == 'upload'
                    ? TransferKind.upload
                    : TransferKind.download,
                name: (m['name'] as String?) ?? '',
                total: (m['total'] as num?)?.toInt() ?? 0,
              )
              ..done = (m['done'] as num?)?.toInt() ?? 0
              ..state = (m['state'] as String?) ?? 'done'
              ..error = m['error'] as String?
              ..where = (m['where'] as String?) ?? ''
              ..source = (m['source'] as String?) ?? ''
              ..path = (m['path'] as String?) ?? ''
              ..uri = (m['uri'] as String?) ?? ''
              ..url = (m['url'] as String?) ?? ''
              ..headers = ((m['headers'] as Map?) ?? const {}).map(
                (k, v) => MapEntry('$k', '$v'),
              )
              ..tmpPath = m['tmpPath'] as String?;
        // 上次是被杀掉的：状态归成「已暂停」，别谎报还在下；链接留空让续传重新签
        if (t.state == 'running' || t.state == 'queued') {
          t.state = 'paused';
          t.speed = 0;
          t.eta = 0;
        }
        // 签名直链会过期，重开时重新签；对话附件那条是固定地址，留着
        if (t.source.isNotEmpty && t.path.isNotEmpty) t.url = '';
        items.add(t);
      }
      notifyListeners();
    } catch (_) {}
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _save);
  }

  Future<void> _save() async {
    try {
      final f = await _fileHandle();
      final list = items
          .take(60)
          .map(
            (t) => {
              'id': t.id,
              'kind': t.kind == TransferKind.upload ? 'upload' : 'download',
              'name': t.name,
              'done': t.done,
              'total': t.total,
              'state': t.state,
              'error': t.error,
              'where': t.where,
              'source': t.source,
              'path': t.path,
              'uri': t.uri,
              'url': t.url,
              'headers': t.headers,
              'tmpPath': t.tmpPath,
            },
          )
          .toList();
      await f.writeAsString(jsonEncode(list), flush: false);
    } catch (_) {}
  }

  void bind(Api api) => _api = api;

  @visibleForTesting
  Transfer addForTest(TransferKind kind, String name, {int total = 100}) =>
      _add(kind, name, total);

  @visibleForTesting
  Future<void> saveNow() => _save();

  final Map<String, HttpClient> _clients = {};
  final Map<String, IOSink> _sinks = {};
  final Map<String, int> _lastDone = {};
  final Map<String, DateTime> _lastTick = {};

  List<Transfer> get active =>
      items.where((t) => t.state == 'running' || t.state == 'queued').toList();

  List<Transfer> get downloads =>
      items.where((t) => t.kind == TransferKind.download).toList();

  int get runningCount => items
      .where((t) => t.kind == TransferKind.download && t.state == 'running')
      .length;

  double get totalSpeed =>
      downloads.fold(0.0, (a, t) => a + (t.running ? t.speed : 0));

  Transfer _add(TransferKind kind, String name, int total) {
    final t = Transfer(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_seq++}',
      kind: kind,
      name: name,
      total: total,
    );
    items.insert(0, t);
    if (items.length > 60) items.removeLast();
    _scheduleSave();
    notifyListeners();
    return t;
  }

  void _finish(Transfer t, {String? error}) {
    t.state = error == null ? 'done' : 'error';
    t.error = error;
    _scheduleSave();
    notifyListeners();
  }

  /// 清掉已完成/已取消/出错（在跑的不动）
  void clearDone() {
    items.removeWhere(
      (t) => t.state == 'done' || t.state == 'canceled' || t.state == 'error',
    );
    _scheduleSave();
    notifyListeners();
  }

  // ---------------- 上传 ----------------

  Future<void> uploadMany(
    Api api,
    String source,
    String dir,
    List<File> files,
  ) async {
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      int total = 0;
      try {
        total = await f.length();
      } catch (_) {}
      final t = _add(TransferKind.upload, name, total);
      try {
        await api.upload(
          source,
          dir,
          name,
          f,
          onProgress: (sent, all) {
            t.done = sent;
            t.total = all;
            notifyListeners();
          },
        );
        _finish(t);
      } catch (e) {
        _finish(t, error: '$e');
      }
    }
  }

  // ---------------- 下载（队列 + 断点续传） ----------------

  /// 加进下载队列；进度看 [items]。
  Transfer enqueue(Api api, String source, Entry entry) {
    _api = api;
    final t = _add(TransferKind.download, entry.name, entry.size)
      ..state = 'queued'
      ..source = source
      ..path = entry.path;
    notifyListeners();
    _pump();
    return t;
  }

  /// 旧接口：等这一个下完，返回落盘路径
  Future<String?> download(Api api, String source, Entry entry) async {
    final t = enqueue(api, source, entry);
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(minutes: 60)) {
      if (t.state == 'done') return t.where;
      if (t.state == 'error' || t.state == 'canceled') return null;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  void _pump() {
    final api = _api;
    if (api == null) return;
    var free = maxActive - runningCount;
    if (free <= 0) return;
    final pend = items.reversed
        .where((t) => t.kind == TransferKind.download && t.state == 'queued')
        .toList();
    for (final t in pend) {
      if (free-- <= 0) break;
      unawaited(_run(t));
    }
  }

  void _tickSpeed(Transfer t) {
    final now = DateTime.now();
    final last = _lastTick[t.id] ?? now;
    final lastBytes = _lastDone[t.id] ?? 0;
    final ms = now.difference(last).inMilliseconds;
    if (ms >= 800) {
      t.speed = (t.done - lastBytes) * 1000 / ms;
      _lastDone[t.id] = t.done;
      _lastTick[t.id] = now;
      t.eta = (t.speed > 0 && t.total > t.done)
          ? (t.total - t.done) / t.speed
          : 0;
      _scheduleSave();
    }
  }

  Future<void> _run(Transfer t) async {
    final api = _api;
    if (api == null) return;
    t.state = 'running';
    t.error = null;
    t.speed = 0;
    notifyListeners();

    HttpClient? client;
    StreamWriter? sw;
    File? tmp;
    IOSink? sink;
    var startAt = t.uri.isNotEmpty ? t.done : 0;
    if (t.uri.isNotEmpty) {
      // 上次可能被系统杀掉：文件真实长度才是续传起点（存进 JSON 的进度可能落后/超前）
      final real = await Native.fileSize(uri: t.uri);
      if (real > 0) startAt = real;
      if (t.total > 0 && startAt > t.total) startAt = 0;
    }
    try {
      var url = t.url;
      if (url.isEmpty) {
        if (t.source.isEmpty || t.path.isEmpty) {
          // 这种条目是「对话附件」一类只有绝对地址的下载，
          // 以前会拿空参数去签 /fs/link，服务端回 400，
          // 界面上就是一条永远失败的「HTTP 400」。
          throw StateError('这条下载没有可续传的地址，请回到对话重新点保存');
        }
        final l = await api.link(t.source, t.path);
        url = api.absolute(l['url'] as String);
        t.url = url;
      }

      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      _clients[t.id] = client;
      final req = await client.getUrl(Uri.parse(url));
      for (final e in t.headers.entries) {
        req.headers.set(e.key, e.value);
      }
      if (startAt > 0) req.headers.set('Range', 'bytes=$startAt-');
      final res = await req.close();
      if (res.statusCode >= 400) throw StateError('HTTP ${res.statusCode}');
      if (startAt > 0 && res.statusCode != 206) startAt = 0;

      t.done = startAt;
      t.total = startAt + (res.contentLength > 0 ? res.contentLength : 0);
      _lastDone[t.id] = t.done;
      _lastTick[t.id] = DateTime.now();

      // 边下边写：直接写进「下载/云匣」，不落临时文件
      sw = await Native.beginWrite(
        t.name,
        Native.mimeOf(t.name),
        uri: startAt > 0 ? t.uri : '',
        offset: startAt,
      );
      if (sw != null) {
        t.uri = sw.uri;
      } else {
        // 原生不支持（桌面调试）→ 退回临时文件
        final tmpDir = Directory('${Directory.systemTemp.path}/dl');
        if (!tmpDir.existsSync()) tmpDir.createSync(recursive: true);
        tmp = File('${tmpDir.path}/${t.id}_${t.name}');
        t.tmpPath = tmp.path;
        sink = tmp.openWrite(
          mode: startAt > 0 ? FileMode.append : FileMode.write,
        );
        _sinks[t.id] = sink;
      }
      notifyListeners();

      await for (final chunk in res) {
        if (t.state != 'running') break;
        if (sw != null) {
          await sw.write(chunk);
        } else {
          sink!.add(chunk);
        }
        t.done += chunk.length;
        if (t.total > 0 && t.done > t.total) t.total = t.done;
        _tickSpeed(t);
        notifyListeners();
      }

      if (t.state != 'running') {
        // 暂停/取消：关流，条目留着（取消时删掉）
        if (sw != null) {
          if (t.state == 'canceled') {
            await sw.abort();
            t.uri = '';
          } else {
            await sw.closeKeep();
          }
          sw = null;
        }
        try {
          await sink?.flush();
          await sink?.close();
        } catch (_) {}
        sink = null;
        _sinks.remove(t.id);
        if (t.state == 'canceled') _dropTemp(t);
        t.speed = 0;
        notifyListeners();
        return;
      }

      if (t.total > 0 && t.done < t.total) {
        throw StateError('连接中断（${t.done}/${t.total}）');
      }

      if (sw != null) {
        final r = await sw.finish();
        sw = null;
        t.where = r?.path ?? '';
        t.uri = r?.uri ?? t.uri;
      } else {
        try {
          await sink?.flush();
          await sink?.close();
        } catch (_) {}
        sink = null;
        _sinks.remove(t.id);
        if (tmp != null)
          t.where = await Native.saveToDownloads(tmp, name: t.name);
        _dropTemp(t);
      }
      t.done = t.total > 0 ? t.total : t.done;
      t.speed = 0;
      t.eta = 0;
      t.state = 'done';
      if (notifyDone) onDone?.call('下载完成：${t.name}');
    } catch (e) {
      try {
        await sink?.flush();
        await sink?.close();
      } catch (_) {}
      _sinks.remove(t.id);
      // 流式写到一半出错：关流保留半截，重试能续
      if (sw != null) {
        try {
          await sw.closeKeep();
        } catch (_) {}
        sw = null;
      }
      t.speed = 0;
      if (t.state == 'running') {
        t.state = 'error';
        t.error = '$e';
        onDone?.call('下载失败：${t.name}');
      }
      if (t.state == 'canceled') {
        _dropTemp(t);
        t.uri = '';
      }
    } finally {
      client?.close(force: true);
      _clients.remove(t.id);
      notifyListeners();
      _pump();
    }
  }

  void _dropTemp(Transfer t) {
    final p = t.tmpPath;
    t.tmpPath = null;
    if (p == null) return;
    try {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  void pause(Transfer t) {
    if (t.kind != TransferKind.download || !t.alive) return;
    t.state = 'paused';
    t.speed = 0;
    _clients[t.id]?.close(force: true);
    _clients.remove(t.id);
    notifyListeners();
    _pump();
    _scheduleSave();
  }

  void resume(Transfer t) {
    if (t.kind != TransferKind.download) return;
    if (t.state != 'paused' && t.state != 'error') return;
    t.state = 'queued';
    t.error = null;
    notifyListeners();
    _pump();
    _scheduleSave();
  }

  void cancel(Transfer t) {
    if (t.kind != TransferKind.download) return;
    if (!t.alive && t.state != 'paused' && t.state != 'error') return;
    t.state = 'canceled';
    t.speed = 0;
    _clients[t.id]?.close(force: true);
    _clients.remove(t.id);
    // 暂停中的条目还挂在 MediaStore 里（隐藏状态），取消要连它一起删
    if (t.uri.isNotEmpty) {
      Native.delete(t.uri, '');
      t.uri = '';
    }
    _dropTemp(t);
    t.done = 0;
    notifyListeners();
    _pump();
    _scheduleSave();
  }

  void retry(Transfer t) {
    if (t.kind != TransferKind.download) return;
    if (t.state != 'error' && t.state != 'canceled') return;
    t.state = 'queued';
    t.error = null;
    t.done = 0;
    t.total = 0;
    t.url = '';
    notifyListeners();
    _pump();
    _scheduleSave();
  }

  /// 删掉一条记录（连带手机上的文件）
  Future<void> remove(Transfer t) async {
    _clients[t.id]?.close(force: true);
    _clients.remove(t.id);
    if (t.uri.isNotEmpty || (t.where.isNotEmpty && t.where.startsWith('/'))) {
      await Native.delete(t.uri, t.where);
    }
    _dropTemp(t);
    items.remove(t);
    notifyListeners();
    _scheduleSave();
  }

  Future<void> removeMany(List<Transfer> list) async {
    for (final t in list) {
      await remove(t);
    }
    _scheduleSave();
  }

  void pauseAll() {
    for (final t in downloads.where((t) => t.running || t.queued)) {
      t.state = 'paused';
      _clients[t.id]?.close(force: true);
      _clients.remove(t.id);
    }
    notifyListeners();
    _scheduleSave();
  }

  void resumeAll() {
    for (final t in downloads.where((t) => t.paused)) {
      t.state = 'queued';
    }
    notifyListeners();
    _pump();
    _scheduleSave();
  }

  // ---------------- 直接 URL 下载（导出 .srt 之类） ----------------

  Future<String?> downloadRaw(
    Api api,
    String name,
    String absUrl, {
    Map<String, String>? headers,
  }) async {
    final t = _add(TransferKind.download, name, 0)
      ..url = absUrl
      ..headers = headers ?? const {}
      ..state = 'running';
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(absUrl));
      headers?.forEach(req.headers.set);
      final res = await req.close();
      if (res.statusCode >= 400) throw StateError('HTTP ${res.statusCode}');
      t.total = res.contentLength > 0 ? res.contentLength : 0;
      final tmpDir = Directory('${Directory.systemTemp.path}/dl');
      if (!tmpDir.existsSync()) tmpDir.createSync(recursive: true);
      final tmp = File('${tmpDir.path}/${t.id}_$name');
      t.tmpPath = tmp.path;
      final sink = tmp.openWrite();
      _sinks[t.id] = sink;
      _lastDone[t.id] = 0;
      _lastTick[t.id] = DateTime.now();
      await for (final chunk in res) {
        sink.add(chunk);
        t.done += chunk.length;
        if (t.total < t.done) t.total = t.done;
        _tickSpeed(t);
        notifyListeners();
      }
      await sink.flush();
      await sink.close();
      _sinks.remove(t.id);
      final where = await Native.saveToDownloads(tmp, name: name);
      _dropTemp(t);
      t.where = where;
      t.done = t.total;
      t.speed = 0;
      t.state = 'done';
      notifyListeners();
      return where;
    } catch (e) {
      _sinks.remove(t.id);
      t.state = 'error';
      t.error = '$e';
      notifyListeners();
      return null;
    } finally {
      client?.close(force: true);
    }
  }
}
