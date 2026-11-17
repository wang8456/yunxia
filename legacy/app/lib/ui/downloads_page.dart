import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/dl_task.dart';
import '../core/models.dart';
import '../core/native.dart';
import '../core/tokens.dart';
import '../core/transfer.dart';
import '../core/ui_icons.dart';
import 'kit.dart';
import 'local_media_page.dart';
import 'widgets.dart';

/// 下载队列：云下载（115 离线）+ 磁力 + ed2k + 本机下载，
/// 四个来源合成一个列表，按状态分组、按来源过滤。
class DownloadsPage extends StatefulWidget {
  final App app;
  const DownloadsPage({super.key, required this.app});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

/// 一条队列条目 —— 四个来源归一化成同一种东西，界面只认它
class _Item {
  final String kind; // cloud | magnet | ed2k | local
  final String key;
  final String name;
  final double pct; // 0..1
  final int speed; // B/s
  final int size;
  final int done;
  final String state; // active | waiting | paused | error | done
  final String extra; // 落盘位置 / 报错
  final Transfer? local;
  final DlTask? nas;
  final String cloudHash;

  const _Item({
    required this.kind,
    required this.key,
    required this.name,
    required this.pct,
    required this.speed,
    required this.size,
    required this.done,
    required this.state,
    this.extra = '',
    this.local,
    this.nas,
    this.cloudHash = '',
  });
}

class _DownloadsPageState extends State<DownloadsPage>
    with WidgetsBindingObserver {
  App get app => widget.app;
  Transfers get tr => app.transfers;

  List<DlTask> nas = const [];
  List<Map<String, dynamic>> clouds = const [];
  String _nasErr = '';
  String _cloudErr = '';
  bool _inflight = false;
  Timer? _timer;

  bool _selMode = false;
  final Set<String> _sel = {};
  String _filter = 'all';
  bool _showDone = false;

  Transfer? _pendingInstall; // 去开权限前先记住要装哪个，回来接着装

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从「安装未知应用」设置页回来：权限开了就自动继续装
    if (state == AppLifecycleState.resumed && _pendingInstall != null) {
      final t = _pendingInstall!;
      _pendingInstall = null;
      _install(t, askPermission: false);
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (_inflight) return;
    _inflight = true;
    try {
      Map<String, dynamic>? r;
      Map<String, dynamic>? c;
      try {
        r = await app.api.tasks();
      } catch (e) {
        if (mounted && !silent) setState(() => _nasErr = '$e');
      }
      try {
        c = await app.api.cd2OfflineAll();
      } catch (e) {
        if (mounted && !silent) setState(() => _cloudErr = '$e');
      }
      if (!mounted) return;
      setState(() {
        if (r != null) {
          nas = ((r['tasks'] as List?) ?? const [])
              .map((e) => DlTask.fromJson((e as Map).cast<String, dynamic>()))
              .toList();
          _nasErr = '';
        }
        if (c != null) {
          clouds = ((c['items'] as List?) ?? const [])
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList();
          _cloudErr = '';
        }
      });
    } finally {
      _inflight = false;
    }
  }

  // ---------------- 打开 ----------------

  Future<void> _openLocal(Transfer t) async {
    final ext = t.name.contains('.') ? t.name.split('.').last.toLowerCase() : '';
    if (const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'}.contains(ext)) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LocalImagePage(name: t.name, uri: t.uri, path: t.where),
      ));
      return;
    }
    if (const {
      'mp4', 'mkv', 'mov', 'avi', 'webm', 'ts', 'm4v',
      'mp3', 'flac', 'm4a', 'wav', 'aac', 'ogg'
    }.contains(ext)) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LocalVideoPage(name: t.name, uri: t.uri, path: t.where),
      ));
      return;
    }
    if (ext == 'apk') {
      await _install(t);
      return;
    }
    // 云匣不认的类型交给系统（PDF / 压缩包 / 文档）
    try {
      await Native.open(t.uri, t.where, Native.mimeOf(t.name));
    } catch (e) {
      app.toast('打不开：$e');
    }
  }

  /// 装本机上的 APK：没权限先跳系统授权页，回来后自动接着装
  Future<void> _install(Transfer t, {bool askPermission = true}) async {
    if (!await Native.canInstall()) {
      if (!askPermission) {
        // 从设置页回来还没开，别再自动跳，免得死循环
        app.toast('还没开「安装未知应用」，在设置里打开后再点一次');
        return;
      }
      if (!mounted) return;
      final ok = await showConfirmSheet(
        context,
        title: '需要「安装未知应用」权限',
        text: 'Android 要求装 APK 前先授权。点「去开启」会跳到系统开关页，'
            '打开「允许来自此来源」再返回云匣，会自动继续安装。',
        okText: '去开启',
        cancelText: '取消',
      );
      if (ok != true) return;
      _pendingInstall = t;
      await Native.openInstallPermission();
      return;
    }
    final r = await Native.installApk(uri: t.uri, path: t.where);
    if (r == 'ok') return;
    if (r == 'need_permission') {
      _pendingInstall = t;
      await Native.openInstallPermission();
      return;
    }
    app.toast(r == 'missing' ? '文件不在了，重新下一遍吧' : '安装失败：$r');
  }

  void _openNas(DlTask t) {
    final dir = t.path.contains('/')
        ? t.path.substring(0, t.path.lastIndexOf('/'))
        : (t.path.isEmpty ? '/' : t.path);
    final open = app.onOpenPath;
    if (open == null) {
      app.toast('文件在 NAS：${t.path}');
      return;
    }
    Navigator.of(context).pop();
    open('nas', dir.isEmpty ? '/' : dir);
  }

  // ---------------- 选择 / 删除 ----------------

  void _toggle(String key) {
    setState(() {
      if (!_sel.remove(key)) _sel.add(key);
      if (_sel.isEmpty) _selMode = false;
    });
  }

  void _enterSelect(String key) => setState(() {
        _selMode = true;
        _sel.add(key);
      });

  Future<void> _deleteSelected() async {
    final keys = _sel.toList();
    if (keys.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除 ${keys.length} 个任务？'),
        content: const Text('本机的连文件一起删；云下载和磁力只从队列移除，网盘 / 硬盘上的文件不动。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFE45E53))),
          ),
        ],
      ),
    );
    if (ok != true) return;

    for (final k in keys) {
      if (k.startsWith('l:')) {
        final id = k.substring(2);
        final hit = tr.downloads.where((t) => t.id == id).toList();
        if (hit.isNotEmpty) await tr.remove(hit.first);
      } else if (k.startsWith('c:')) {
        try {
          await app.api.cd2OfflineDel(k.substring(2), deleteFiles: false);
        } catch (e) {
          app.toast('云下载删除失败：$e');
        }
      } else {
        final parts = k.split(':');
        if (parts.length < 3) continue;
        final kind = parts[1];
        final id = parts.sublist(2).join(':');
        try {
          await app.api.taskAct(kind, id, 'remove');
        } catch (e) {
          app.toast('$kind 删除失败：$e');
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _sel.clear();
      _selMode = false;
    });
    app.toast('已删除 ${keys.length} 个');
    await _load();
  }

  Future<void> _deleteOne(_Item it) async {
    final running = it.state == 'active' || it.state == 'waiting';
    final ok = await showConfirmSheet(
      context,
      title: '删除这个任务？',
      text: it.local != null
          ? '「${_short(it.name)}」会从下载队列移除，已经下到手机上的文件也一起删掉。'
              '${running ? '\n正在下载，会先停下来。' : ''}'
          : it.kind == 'cloud'
              ? '「${_short(it.name)}」会从 115 的离线列表移除，已经下到网盘上的文件不动。'
              : '「${_short(it.name)}」会从下载器里移除，NAS 上的文件不动。'
                  '${running ? '\n正在下载，会先停下来。' : ''}',
      okText: '删除',
      cancelText: '取消',
      danger: true,
    );
    if (ok != true) return;

    if (it.local != null) {
      final l = it.local!;
      if (l.running || l.queued) {
        tr.cancel(l);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await tr.remove(l);
      app.toast('已删除');
      return;
    }
    try {
      if (it.kind == 'cloud') {
        await app.api.cd2OfflineDel(it.cloudHash, deleteFiles: false);
      } else {
        await app.api.taskAct(it.nas!.kind, it.nas!.id, 'remove');
      }
      app.toast('已删除');
      await _load();
    } catch (e) {
      app.toast('删除失败：$e');
    }
  }

  Future<void> _pauseResume(_Item it, String act) async {
    try {
      await app.api.taskAct(it.nas!.kind, it.nas!.id, act);
      await _load();
    } catch (e) {
      app.toast('${act == 'pause' ? '暂停' : '继续'}失败：$e');
    }
  }

  String _short(String s) => s.length <= 24 ? s : '${s.substring(0, 24)}…';

  // ---------------- 归一化 ----------------

  /// aMule 回的是 Waiting / Downloading（首字母大写），aria2 是小写
  static String _stateOf(String raw) {
    final s = raw.toLowerCase();
    if (s.startsWith('active') || s == 'downloading' || s == 'seeding') return 'active';
    if (s.startsWith('wait') || s == 'queued') return 'waiting';
    if (s.contains('pause')) return 'paused';
    if (s.contains('error') || s.contains('fail')) return 'error';
    if (s.contains('complete') || s == 'done' || s == 'finished') return 'done';
    return 'waiting';
  }

  List<_Item> _items() {
    final out = <_Item>[];
    for (final t in tr.downloads) {
      out.add(_Item(
        kind: 'local',
        key: 'l:${t.id}',
        name: t.name,
        pct: t.finished ? 1 : t.pct.clamp(0, 1).toDouble(),
        speed: t.speed.round(),
        size: t.total,
        done: t.done,
        state: t.finished
            ? 'done'
            : t.failed
                ? 'error'
                : t.paused
                    ? 'paused'
                    : t.running
                        ? 'active'
                        : 'waiting',
        extra: t.finished ? t.where : (t.error ?? ''),
        local: t,
      ));
    }
    for (final t in nas) {
      final pct = t.pct / 100;
      out.add(_Item(
        kind: t.kind == 'ed2k' ? 'ed2k' : 'magnet',
        key: 'n:${t.kind}:${t.id}',
        name: t.name.isEmpty ? t.id : t.name,
        pct: (pct.isFinite ? pct : 0).clamp(0, 1).toDouble(),
        speed: t.speed,
        size: t.size,
        done: (t.size * pct).round(),
        state: pct >= 1 ? 'done' : _stateOf(t.state),
        extra: t.error,
        nas: t,
      ));
    }
    for (final c in clouds) {
      final status = (c['status'] as num?)?.toInt() ?? 0;
      final raw = ((c['percent'] as num?)?.toDouble() ?? 0) / 100;
      final pct = (raw.isFinite ? raw : 0).clamp(0, 1).toDouble();
      final size = (c['size'] as num?)?.toInt() ?? 0;
      out.add(_Item(
        kind: 'cloud',
        key: 'c:${c['hash']}',
        name: (c['name'] ?? '未命名').toString(),
        pct: pct,
        speed: 0,
        size: size,
        done: (size * pct).round(),
        state: const {0: 'waiting', 1: 'active', 2: 'done', 3: 'error', 4: 'paused'}[status] ??
            'waiting',
        cloudHash: (c['hash'] ?? '').toString(),
      ));
    }
    const rank = {'active': 0, 'waiting': 1, 'paused': 2, 'error': 3, 'done': 4};
    out.sort((a, b) {
      final r = (rank[a.state] ?? 9).compareTo(rank[b.state] ?? 9);
      if (r != 0) return r;
      return b.pct.compareTo(a.pct);
    });
    return out;
  }

  /// 每个来源一套色：云下载蓝、磁力紫、ed2k 绿、本机青
  static const Map<String, (String, Color, Color)> _kindStyle = {
    'cloud': ('云下载', Color(0xFF1677F8), Color(0xFFE8F2FF)),
    'magnet': ('磁力', Color(0xFF7C5CF0), Color(0xFFF0ECFF)),
    'ed2k': ('ed2k', Color(0xFF16A34A), Color(0xFFE6F7EE)),
    'local': ('本机', Color(0xFF0E9D78), Color(0xFFE5F8EF)),
  };

  static String _kindIcon(String k) => switch (k) {
        'cloud' => 'src-cloud',
        'magnet' => 'link',
        'ed2k' => 'download',
        _ => 'type-file',
      };

  String _speed(num bps) {
    final b = bps.toDouble();
    if (b <= 0) return '';
    if (b < 1024) return '${b.toStringAsFixed(0)} B/s';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB/s';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }

  String _eta(_Item it) {
    if (it.speed <= 0 || it.size <= 0 || it.done >= it.size) return '';
    final sec = ((it.size - it.done) / it.speed).round();
    if (sec <= 0) return '';
    if (sec < 60) return '$sec 秒';
    if (sec < 3600) return '${(sec / 60).floor()} 分钟';
    return '${(sec / 3600).toStringAsFixed(1)} 小时';
  }

  String _stateLabel(_Item it) => switch (it.state) {
        'active' => '下载中',
        'waiting' => '排队中',
        'paused' => '已暂停',
        'error' => '出错',
        _ => '已完成',
      };

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Scaffold(
      backgroundColor: tone.bg,
      body: SafeArea(
        bottom: false,
        child: AnimatedBuilder(
          animation: tr,
          builder: (ctx, _) {
            final all = _items();
            final shown =
                _filter == 'all' ? all : all.where((i) => i.kind == _filter).toList();
            final running = all.where((i) => i.state == 'active').toList();
            final waiting = all.where((i) => i.state == 'waiting').length;
            final speed = running.fold<int>(0, (a, i) => a + i.speed);
            return Column(
              children: [
                _head(tone, all, running, waiting, speed),
                if (all.isNotEmpty) _filters(tone, all),
                Expanded(
                  child: all.isEmpty
                      ? _empty(tone)
                      : RefreshIndicator(
                          onRefresh: _load,
                          color: tone.ac,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(12, 2, 12, 40),
                            children: shown.isEmpty
                                ? [
                                    Padding(
                                      padding: const EdgeInsets.only(top: 70),
                                      child: Center(
                                        child: Text(
                                          '这个来源没有任务',
                                          style: TextStyle(
                                              fontSize: 12.5, color: tone.ink3),
                                        ),
                                      ),
                                    ),
                                  ]
                                : _grouped(tone, shown),
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _grouped(Tone tone, List<_Item> items) {
    const groups = [
      ('active', '进行中'),
      ('waiting', '排队中'),
      ('paused', '已暂停'),
      ('error', '出错'),
      ('done', '已完成'),
    ];
    final out = <Widget>[];
    for (final (state, label) in groups) {
      final rows = items.where((i) => i.state == state).toList();
      if (rows.isEmpty) continue;
      // 已完成默认收起，别把正在下的挤下去；没别的任务时自动展开
      final nothingElse = !items.any((i) => i.state != 'done');
      if (state == 'done' && !_showDone && !nothingElse) {
        out.add(GestureDetector(
          onTap: () => setState(() => _showDone = true),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
            child: Row(
              children: [
                Text('已完成 · ${rows.length}',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: tone.ink3)),
                const Spacer(),
                Text('展开',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: tone.ac)),
              ],
            ),
          ),
        ));
        continue;
      }
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
        child: Text('$label · ${rows.length}',
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: tone.ink3)),
      ));
      for (final it in rows) {
        out.add(_row(tone, it));
        out.add(const SizedBox(height: 8));
      }
      if (state == 'done') {
        out.add(GestureDetector(
          onTap: () => setState(() => _showDone = false),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Center(
              child: Text('收起已完成',
                  style: TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w600, color: tone.ac)),
            ),
          ),
        ));
      }
    }
    return out;
  }

  Widget _head(
    Tone tone,
    List<_Item> all,
    List<_Item> running,
    int waiting,
    int speed,
  ) {
    if (_selMode) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 6),
        child: Row(
          children: [
            Text('已选 ${_sel.length}',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: tone.ink)),
            const Spacer(),
            _act(tone, '全选', () {
              setState(() {
                _sel
                  ..clear()
                  ..addAll(all.map((i) => i.key));
              });
            }),
            const SizedBox(width: 8),
            _act(tone, '删除', _deleteSelected, danger: true),
            const SizedBox(width: 8),
            _act(tone, '取消', () {
              setState(() {
                _sel.clear();
                _selMode = false;
              });
            }),
          ],
        ),
      );
    }
    final locals = tr.downloads;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 14, 4),
      child: Column(
        children: [
          Row(
            children: [
              Press(
                onTap: () => Navigator.pop(context),
                scale: 0.94,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: UIIcon('arrow-left', size: 22, color: tone.ink),
                ),
              ),
              const SizedBox(width: 4),
              Text('下载队列',
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700, color: tone.ink)),
              const Spacer(),
              if (locals.any((t) => t.alive))
                _act(tone, '全部暂停', tr.pauseAll)
              else if (locals.any((t) => t.paused))
                _act(tone, '全部继续', tr.resumeAll),
              if (locals.any((t) => t.finished || t.failed)) ...[
                const SizedBox(width: 6),
                _act(tone, '清理', tr.clearDone),
              ],
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 0, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _nasErr.isNotEmpty && _cloudErr.isNotEmpty
                    ? '任务读不到 · 检查 NAS'
                    : all.isEmpty
                        ? '还没有任务'
                        : [
                            if (running.isNotEmpty) '${running.length} 个在下',
                            if (speed > 0) _speed(speed),
                            if (waiting > 0) '$waiting 个排队',
                            if (running.isEmpty && waiting == 0)
                              '全部完成 · ${all.where((i) => i.state == 'done').length} 个',
                          ].join(' · '),
                style: TextStyle(fontSize: 12, color: tone.ink3),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filters(Tone tone, List<_Item> all) {
    final counts = <String, int>{'all': all.length};
    for (final k in const ['cloud', 'magnet', 'ed2k', 'local']) {
      final n = all.where((i) => i.kind == k).length;
      if (n > 0) counts[k] = n;
    }
    final chips = <Widget>[];
    for (final k in counts.keys) {
      final on = _filter == k;
      final label = k == 'all' ? '全部' : _kindStyle[k]!.$1;
      chips.add(GestureDetector(
        onTap: () => setState(() => _filter = k),
        child: Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: on ? tone.ac : tone.surface2,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(
            '$label ${counts[k]}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: on ? Colors.white : tone.ink2,
            ),
          ),
        ),
      ));
    }
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        children: chips,
      ),
    );
  }

  Widget _row(Tone tone, _Item it) {
    final selected = _sel.contains(it.key);
    final (label, fg, bg) = _kindStyle[it.kind]!;
    final stateColor = switch (it.state) {
      'done' => const Color(0xFF0E9D78),
      'error' => const Color(0xFFE45E53),
      'paused' => const Color(0xFFC78218),
      _ => fg,
    };
    final meta = <String>[
      '$label · ${_stateLabel(it)}',
      if (it.size > 0) humanSize(it.size),
      if (it.state == 'active' && it.speed > 0) _speed(it.speed),
      if (it.state == 'active' && _eta(it).isNotEmpty) '剩 ${_eta(it)}',
      if (it.extra.isNotEmpty && (it.state == 'error' || it.state == 'done')) it.extra,
    ];

    return GestureDetector(
      onLongPress: () => _enterSelect(it.key),
      onTap: () {
        if (_selMode) {
          _toggle(it.key);
        } else if (it.state == 'done') {
          if (it.local != null) {
            _openLocal(it.local!);
          } else if (it.nas != null) {
            _openNas(it.nas!);
          }
        }
      },
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_selMode) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: _check(tone, selected),
                  ),
                  const SizedBox(width: 10),
                ],
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child:
                      Center(child: UIIcon(_kindIcon(it.kind), size: 18, color: fg)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              it.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: tone.ink),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            it.state == 'done' ? '完成' : '${(it.pct * 100).round()}%',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: stateColor,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        meta.join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(fontSize: 11.5, height: 1.4, color: tone.ink3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            _bar(tone, it.state == 'done' ? 1 : it.pct, stateColor),
            if (!_selMode) ...[
              const SizedBox(height: 9),
              Row(
                children: [
                  if (it.state == 'done' && it.local != null)
                    _chip(tone, '打开', () => _openLocal(it.local!), primary: true)
                  else if (it.state == 'done' && it.nas != null)
                    _chip(tone, '在云匣打开', () => _openNas(it.nas!), primary: true),
                  if (it.state == 'error' && it.local != null)
                    _chip(tone, '重试', () => tr.retry(it.local!), primary: true),
                  if (it.kind != 'cloud') ...[
                    if (it.state == 'active' || it.state == 'waiting')
                      _chip(
                        tone,
                        '暂停',
                        () =>
                            it.local != null ? tr.pause(it.local!) : _pauseResume(it, 'pause'),
                      )
                    else if (it.state == 'paused')
                      _chip(
                        tone,
                        '继续',
                        () => it.local != null
                            ? tr.resume(it.local!)
                            : _pauseResume(it, 'resume'),
                        primary: true,
                      ),
                  ],
                  if (it.local != null &&
                      (it.local!.alive || it.local!.paused || it.local!.failed)) ...[
                    const SizedBox(width: 8),
                    _chip(tone, '取消', () => tr.cancel(it.local!), danger: true),
                  ],
                  const Spacer(),
                  _chip(tone, '删除', () => _deleteOne(it), danger: true),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _empty(Tone tone) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 90),
          Center(
            child: Column(
              children: [
                UIIcon('download', size: 44, color: tone.ink3),
                const SizedBox(height: 12),
                Text('还没有下载任务',
                    style: TextStyle(fontSize: 13, color: tone.ink3)),
                const SizedBox(height: 6),
                Text('文件页「＋」里加云下载 / 磁力 · 文件右侧「下载」下到手机',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11.5, color: tone.ink3)),
              ],
            ),
          ),
        ],
      );

  Widget _act(Tone tone, String label, VoidCallback onTap, {bool danger = false}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: danger ? const Color(0x1FE45E53) : tone.surface2,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: danger ? const Color(0xFFE45E53) : tone.ink2)),
        ),
      );

  Widget _bar(Tone tone, double pct, Color color) => ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: LinearProgressIndicator(
          value: pct.clamp(0, 1).toDouble(),
          minHeight: 5,
          backgroundColor: tone.surface2,
          valueColor: AlwaysStoppedAnimation(color),
        ),
      );

  Widget _check(Tone tone, bool on) => Container(
        width: 21,
        height: 21,
        decoration: BoxDecoration(
          color: on ? tone.ac : Colors.transparent,
          border: Border.all(color: on ? tone.ac : tone.ink3, width: 1.6),
          shape: BoxShape.circle,
        ),
        child: on
            ? const Center(child: UIIcon('check', size: 13, color: Colors.white))
            : const SizedBox.shrink(),
      );

  Widget _chip(Tone tone, String label, VoidCallback onTap,
          {bool primary = false, bool danger = false}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: primary
                ? tone.ac
                : danger
                    ? const Color(0x14E45E53)
                    : tone.surface2,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: primary
                  ? Colors.white
                  : danger
                      ? const Color(0xFFE45E53)
                      : tone.ink2,
            ),
          ),
        ),
      );
}
