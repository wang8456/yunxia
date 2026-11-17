import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/native.dart';
import '../core/tokens.dart';
import '../core/transfer.dart';
import '../core/ui_icons.dart';
import 'kit.dart';
import 'local_media_page.dart';
import 'widgets.dart';

/// 下载队列（只含本机下载）：文件页 / 播放器点「下载到本机」之后都进这里。
class DownloadsPage extends StatefulWidget {
  final App app;
  const DownloadsPage({super.key, required this.app});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage>
    with WidgetsBindingObserver {
  App get app => widget.app;
  Transfers get tr => app.transfers;

  bool _selMode = false;
  final Set<String> _sel = {};
  bool _showDone = false;

  Transfer? _pendingInstall; // 去开权限前先记住要装哪个，回来接着装

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    final ids = _sel.map((k) => k.substring(2)).toSet();
    if (ids.isEmpty) return;
    final ok = await showConfirmSheet(
      context,
      title: '删除 ${ids.length} 个任务？',
      text: '本机的连文件一起删。',
      okText: '删除',
      cancelText: '取消',
      danger: true,
    );
    if (ok != true) return;
    final hits = tr.downloads.where((t) => ids.contains(t.id)).toList();
    for (final t in hits) {
      await tr.remove(t);
    }
    if (!mounted) return;
    setState(() {
      _sel.clear();
      _selMode = false;
    });
    app.toast('已删除 ${hits.length} 个');
  }

  Future<void> _deleteOne(Transfer t) async {
    final running = t.alive;
    final ok = await showConfirmSheet(
      context,
      title: '删除这个任务？',
      text: '「${_short(t.name)}」会从下载队列移除，已经下到手机上的文件也一起删掉。'
          '${running ? '\n正在下载，会先停下来。' : ''}',
      okText: '删除',
      cancelText: '取消',
      danger: true,
    );
    if (ok != true) return;
    if (t.running || t.queued) {
      tr.cancel(t);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await tr.remove(t);
    app.toast('已删除');
  }

  String _short(String s) => s.length <= 24 ? s : '${s.substring(0, 24)}…';

  // ---------------- 归一化 ----------------

  static String _stateOf(Transfer t) => t.finished
      ? 'done'
      : t.failed
          ? 'error'
          : t.paused
              ? 'paused'
              : t.running
                  ? 'active'
                  : 'waiting';

  List<Transfer> _items() {
    final out = tr.downloads.toList();
    const rank = {'active': 0, 'waiting': 1, 'paused': 2, 'error': 3, 'done': 4};
    out.sort((a, b) {
      final r = (rank[_stateOf(a)] ?? 9).compareTo(rank[_stateOf(b)] ?? 9);
      if (r != 0) return r;
      return b.pct.compareTo(a.pct);
    });
    return out;
  }

  String _speed(num bps) {
    final b = bps.toDouble();
    if (b <= 0) return '';
    if (b < 1024) return '${b.toStringAsFixed(0)} B/s';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB/s';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }

  String _eta(Transfer t) {
    if (t.speed <= 0 || t.total <= 0 || t.done >= t.total) return '';
    final sec = ((t.total - t.done) / t.speed).round();
    if (sec <= 0) return '';
    if (sec < 60) return '$sec 秒';
    if (sec < 3600) return '${(sec / 60).floor()} 分钟';
    return '${(sec / 3600).toStringAsFixed(1)} 小时';
  }

  String _stateLabel(String state) => switch (state) {
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
            final running = all.where((t) => _stateOf(t) == 'active').toList();
            final waiting = all.where((t) => _stateOf(t) == 'waiting').length;
            final speed = running.fold<double>(0, (a, t) => a + t.speed);
            return Column(
              children: [
                _head(tone, all, running.length, waiting, speed),
                Expanded(
                  child: all.isEmpty
                      ? _empty(tone)
                      : RefreshIndicator(
                          onRefresh: () async => setState(() {}),
                          color: tone.ac,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(12, 2, 12, 40),
                            children: _grouped(tone, all),
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

  List<Widget> _grouped(Tone tone, List<Transfer> items) {
    const groups = [
      ('active', '进行中'),
      ('waiting', '排队中'),
      ('paused', '已暂停'),
      ('error', '出错'),
      ('done', '已完成'),
    ];
    final out = <Widget>[];
    for (final (state, label) in groups) {
      final rows = items.where((t) => _stateOf(t) == state).toList();
      if (rows.isEmpty) continue;
      // 已完成默认收起，别把正在下的挤下去；没别的任务时自动展开
      final nothingElse = !items.any((t) => _stateOf(t) != 'done');
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
    List<Transfer> all,
    int running,
    int waiting,
    double speed,
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
                  ..addAll(all.map((t) => 'l:${t.id}'));
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
              if (all.any((t) => t.alive))
                _act(tone, '全部暂停', tr.pauseAll)
              else if (all.any((t) => t.paused))
                _act(tone, '全部继续', tr.resumeAll),
              if (all.any((t) => t.finished || t.failed)) ...[
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
                all.isEmpty
                    ? '还没有任务'
                    : [
                        if (running > 0) '$running 个在下',
                        if (speed > 0) _speed(speed),
                        if (waiting > 0) '$waiting 个排队',
                        if (running == 0 && waiting == 0)
                          '全部完成 · ${all.where((t) => t.finished).length} 个',
                      ].join(' · '),
                style: TextStyle(fontSize: 12, color: tone.ink3),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(Tone tone, Transfer t) {
    const fg = Color(0xFF0E9D78);
    const bg = Color(0xFFE5F8EF);
    final state = _stateOf(t);
    final selected = _sel.contains('l:${t.id}');
    final stateColor = switch (state) {
      'done' => fg,
      'error' => const Color(0xFFE45E53),
      'paused' => const Color(0xFFC78218),
      _ => fg,
    };
    final meta = <String>[
      '本机 · ${_stateLabel(state)}',
      if (t.total > 0) humanSize(t.total),
      if (state == 'active' && t.speed > 0) _speed(t.speed),
      if (state == 'active' && _eta(t).isNotEmpty) '剩 ${_eta(t)}',
      if (t.where.isNotEmpty && (state == 'error' || state == 'done')) t.where,
      if (state == 'error' && (t.error ?? '').isNotEmpty) t.error!,
    ];

    return GestureDetector(
      onLongPress: () => _enterSelect('l:${t.id}'),
      onTap: () {
        if (_selMode) {
          _toggle('l:${t.id}');
        } else if (state == 'done') {
          _openLocal(t);
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
                  child: const Center(
                      child: UIIcon('download', size: 18, color: fg)),
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
                              t.name,
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
                            state == 'done' ? '完成' : '${(t.pct * 100).round()}%',
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
            _bar(tone, state == 'done' ? 1 : t.pct, stateColor),
            if (!_selMode) ...[
              const SizedBox(height: 9),
              Row(
                children: [
                  if (state == 'done')
                    _chip(tone, '打开', () => _openLocal(t), primary: true),
                  if (state == 'error')
                    _chip(tone, '重试', () => tr.retry(t), primary: true),
                  if (state == 'active' || state == 'waiting')
                    _chip(tone, '暂停', () => tr.pause(t))
                  else if (state == 'paused')
                    _chip(tone, '继续', () => tr.resume(t), primary: true),
                  if (t.alive || t.paused || t.failed) ...[
                    const SizedBox(width: 8),
                    _chip(tone, '取消', () => tr.cancel(t), danger: true),
                  ],
                  const Spacer(),
                  _chip(tone, '删除', () => _deleteOne(t), danger: true),
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
                Text('文件右侧「下载」或播放器里的下载键，下到手机后都进这里',
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
