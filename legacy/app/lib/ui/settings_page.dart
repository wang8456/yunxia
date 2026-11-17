
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/tokens.dart';
import '../core/translator.dart';
import '../core/ui_icons.dart';
import 'downloads_page.dart';
import 'kit.dart';
import 'subs_page.dart';
import 'settings_more_page.dart';
import 'subs_settings_page.dart';
import 'tr_source_page.dart';
import 'widgets.dart';

/// 设置页 —— 照旧版前端：品牌栏 → 副标题 → 大标题 → 存储卡 →
/// 账号状态 → 显示与外观 → 更多 → 退出登录。
class SettingsPage extends StatefulWidget {
  final App app;
  const SettingsPage({super.key, required this.app});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  App get app => widget.app;

  /// CloudDrive2 状态：设置页只负责「令牌」，云下载入口在文件页
  Map<String, dynamic> _cd2 = const {};
  bool _cd2Busy = false;

  /// ── 下载监控（云下载 / 磁力 / ed2k）─────────────────────────
  /// 只在设置页活着的时候每 5 秒拉一次；退出页面就停。
  final Map<String, Map<String, dynamic>> _dl = {
    'cd2': {'ok': false, 'active': 0, 'total': 0, 'rows': <Map<String, dynamic>>[]},
    'magnet': {'ok': false, 'active': 0, 'speed': 0, 'rows': <Map<String, dynamic>>[]},
    'ed2k': {'ok': false, 'active': 0, 'speed': 0, 'rows': <Map<String, dynamic>>[]},
  };
  Timer? _dlTimer;

  static const Map<int, String> _cloudState = {
    0: '排队中',
    1: '下载中',
    2: '已完成',
    3: '出错',
    4: '已暂停',
  };

  Future<void> _dlLoad() async {
    Map<String, dynamic>? c;
    Map<String, dynamic>? t;
    try {
      c = await app.api.cd2OfflineAll();
    } catch (_) {/* 连不上就标离线，不编数字 */}
    try {
      t = await app.api.tasks();
    } catch (_) {}
    if (!mounted) return;

    final cd2 = <String, dynamic>{
      'ok': c != null,
      'active': 0,
      'total': 0,
      'rows': <Map<String, dynamic>>[],
    };
    final items = (c?['items'] as List?) ?? const [];
    if (c != null) {
      final rows = <Map<String, dynamic>>[];
      var active = 0;
      var waiting = 0;
      for (final raw in items) {
        final m = raw as Map;
        final st = (m['status'] as num?)?.toInt() ?? 0;
        if (st == 2) continue; // 完成的不占位
        if (st == 1) active++; // 下载中
        if (st == 0) waiting++; // 排队
        rows.add({
          'name': (m['name'] ?? '未命名').toString(),
          'pct': ((m['percent'] as num?)?.toDouble() ?? 0).clamp(0, 100),
          'state': _cloudState[st] ?? '未知',
          'speed': 0,
        });
      }
      cd2['active'] = active;
      cd2['waiting'] = waiting;
      cd2['total'] = items.length;
      cd2['rows'] = rows.take(8).toList();
    }

    final hubs = (t?['hubs'] as Map?) ?? const {};
    final all = (t?['tasks'] as List?) ?? const [];
    final next = <String, Map<String, dynamic>>{'cd2': cd2};
    for (final k in ['magnet', 'ed2k']) {
      final hub = (hubs[k] as Map?) ?? const {};
      final rows = <Map<String, dynamic>>[];
      var active = 0;
      var sp = 0;
      for (final raw in all) {
        final m = raw as Map;
        if (m['kind'] != k) continue;
        // aMule 回 "Waiting"（大写），aria2 是小写
        final st = (m['state'] ?? '').toString().toLowerCase();
        if (st == 'done') continue;
        final speed = (m['speed'] as num?)?.toInt() ?? 0;
        if (st == 'active' || st == 'waiting') active++;
        if (st == 'active') sp += speed;
        rows.add({
          'name': (m['name'] ?? m['id'] ?? '未命名').toString(),
          'pct': ((m['pct'] as num?)?.toDouble() ?? 0).clamp(0, 100),
          'state': {
                'active': '下载中',
                'waiting': '排队中',
                'paused': '已暂停',
                'error': '出错',
              }[st] ??
              st,
          'speed': speed,
        });
      }
      next[k] = {
        'ok': hub['online'] == true,
        'active': active,
        'speed': sp,
        'rows': rows.take(8).toList(),
      };
    }

    setState(() {
      _dl.addAll(next);
    });
  }

  /// 设置页只留一句合并摘要：详情都在下载队列页里
  String _qSub() {
    final cloud = (_dl['cd2']?['active'] as int?) ?? 0;
    final mag = (_dl['magnet']?['active'] as int?) ?? 0;
    final ed = (_dl['ed2k']?['active'] as int?) ?? 0;
    // 排队只数「排队中」：暂停 / 出错 都不算排队
    int q(Map<String, dynamic>? d) =>
        ((d?['rows'] as List?) ?? const [])
            .where((r) => (r as Map)['state'] == '排队中')
            .length;
    final waiting =
        ((_dl['cd2']?['waiting'] as int?) ?? 0) + q(_dl['magnet']) + q(_dl['ed2k']);
    final local = app.transfers.downloads.length;
    if (cloud + mag + ed + local == 0) {
      // 已完成的不算任务，但也别写成「没有任务」——队列里可能躺着一堆已完成的
      return '云下载 / 磁力 / ed2k / 本机 · 没有在下的';
    }
    final parts = <String>[];
    final running = cloud + mag + ed;
    if (running > 0) parts.add('NAS 上 $running 个在下');
    if (waiting > 0) parts.add('$waiting 个排队');
    if (local > 0) parts.add('本机 $local 个');
    return parts.join(' · ');
  }

  @override
  void initState() {
    super.initState();
    _cd2Load();
    _dlLoad();
    _dlTimer = Timer.periodic(const Duration(seconds: 5), (_) => _dlLoad());
  }

  @override
  void dispose() {
    _dlTimer?.cancel();
    super.dispose();
  }

  Future<void> _cd2Load() async {
    try {
      final r = await app.api.cd2Status();
      if (mounted) setState(() => _cd2 = r);
    } catch (_) {
      if (mounted) setState(() => _cd2 = const {'ok': false});
    }
  }

  Future<void> _cd2Token() async {
    final tok = await showTextSheet(
      context,
      title: 'CloudDrive 令牌',
      hint: 'CloudDrive 后台 → 设置 → API 令牌',
      confirm: '保存并验证',
    );
    final v = (tok ?? '').trim();
    if (v.isEmpty) return;
    setState(() => _cd2Busy = true);
    try {
      final r = await app.api.cd2Token(v);
      if (!mounted) return;
      app.toast('令牌可用 · 目录里 ${r['items']} 个条目');
      await _cd2Load();
    } catch (e) {
      if (mounted) app.toast('$e');
    } finally {
      if (mounted) setState(() => _cd2Busy = false);
    }
  }

  int get _dirs => app.entries.where((e) => e.isDir).length;
  int get _files => app.entries.where((e) => !e.isDir).length;

  /// 来源说明优先用服务端给的副标题，没有才按 kind 兜底
  static String _sourceSub(Map<String, dynamic> s) {
    final sub = (s['sub'] as String? ?? '').trim();
    if (sub.isNotEmpty) return sub;
    switch (s['kind'] as String? ?? '') {
      case 'dufs':
        return 'files · 192.168.1.10:5007';
      case 'relay115':
      case 'webdav':
        return 'CloudDrive 网盘 · 只读';
      case 'pcdufs':
        return '经 NAS 中转';
      default:
        return '';
    }
  }

  /// 当前源的显示名（顶栏那张卡和「文件源」行都用它）
  String _curName() {
    for (final s in app.sources) {
      if ((s['id'] as String? ?? '') == app.source) {
        return (s['name'] as String? ?? app.source);
      }
    }
    return app.sources.isEmpty ? '—' : (app.sources.first['name'] as String? ?? '');
  }

  /// 文件源列表收进底部弹窗：主列表里平铺 3-4 行，页面立刻长一截
  void _showSources() {
    final tone = Theme.of(context).extension<Tone>()!;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(10),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
        decoration: BoxDecoration(
          color: tone.surface,
          borderRadius: BorderRadius.circular(22),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
                child: Text('文件源',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: tone.ink)),
              ),
              GroupCard(
                children: [
                  for (final s in app.sources)
                    Builder(builder: (c) {
                      final id = s['id'] as String? ?? '';
                      final tone0 = Theme.of(c).extension<Tone>()!;
                      final (i2, b2, f2) = _iconOf(s, tone0);
                      final writable = s['writable'] == true;
                      final on = id == app.source;
                      return KitRow(
                        icon: i2,
                        iconBg: b2,
                        iconColor: f2,
                        title: s['name'] as String? ?? id,
                        sub: on
                            ? '正在用这个源'
                            : (writable ? '可写 · 上传 / 改名 / 删除' : '只读 · 浏览和播放不用登录'),
                        trailing: _Pill(
                          text: on ? '当前' : (writable ? '可写' : '只读'),
                          bg: on
                              ? tone.acw
                              : (writable ? tone.surface2 : tone.surface2),
                          fg: on ? tone.ac : tone.ink3,
                        ),
                        onTap: () async {
                          Navigator.pop(c);
                          if (on) return;
                          await app.switchSource(id);
                        },
                      );
                    }),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 图标形状区分来源，颜色跟主题（照 5020 的 .src-ico）
  static (String, Color, Color) _iconOf(Map<String, dynamic> s, Tone tone) {
    final kind = s['kind'] as String? ?? '';
    final id = s['id'] as String? ?? '';
    final icon = (kind == 'relay115' || kind == 'webdav')
        ? 'src-cloud'
        : kind == 'pcdufs'
            ? 'src-pc'
            : id == 'nas'
                ? 'src-nas'
                : 'src-disk';
    return (icon, tone.acw, tone.ac);
  }

  /// 填口令：一次解锁「写文件 + 对话」。填过的可以在这里关掉回到只读。
  Future<void> _askKey(BuildContext context) async {
    // 写权限在、但对话口令丢了（比如在对话页点了头像断开）时，这里要能补填，别再问「关闭口令」
    if (app.canWrite && app.session.chatBasic.isNotEmpty) {
      final ok = await showConfirmSheet(
        context,
        title: '关闭口令？',
        text: '关掉之后又回到只读模式：不能删除/移动/上传，对话也用不了。',
        danger: true,
        okText: '关闭',
        cancelText: '算了',
      );
      if (ok == true) {
        await app.logout();
        if (context.mounted) app.toast('已回到只读模式');
      }
      return;
    }
    final ctl = TextEditingController();
    final pw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('填写口令'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(hintText: '口令'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(ctl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    ctl.dispose();
    final v = (pw ?? '').trim();
    if (v.isEmpty) return;
    final ok = await app.login(v);
    if (context.mounted) {
      app.toast(ok ? '口令已填 · 写入和对话都开了' : (app.fatal ?? '口令不对'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final src = app.sources.firstWhere((s) => s['id'] == app.source,
        orElse: () => const {'id': 'nas', 'name': 'NAS', 'writable': true});
    final (ico, bg, fg) = _iconOf(src, tone);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(19, 18, 19, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BrandBar(),
              Text('改动立刻生效 · 只存在这台设备',
                  style: TextStyle(fontSize: 12, color: tone.ink3)),
              const SizedBox(height: 5),
              const PageTitle('设置'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 当前源快照 + 三个统计
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: tone.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: tone.line),
                  boxShadow: [
                    BoxShadow(color: tone.sh, blurRadius: 10, offset: const Offset(0, 2)),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 13),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                                color: bg, borderRadius: BorderRadius.circular(12)),
                            alignment: Alignment.center,
                            child: UIIcon(ico, size: 22, color: fg),
                          ),
                          const SizedBox(width: 13),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(src['name'] as String? ?? 'NAS',
                                    style: TextStyle(
                                        fontSize: 15.5,
                                        fontWeight: FontWeight.w600,
                                        color: tone.ink)),
                                const SizedBox(height: 2),
                                Text(_sourceSub(src),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 12, color: tone.ink2)),
                              ],
                            ),
                          ),
                          _Pill(
                            text: app.authed ? '已连接' : '未登录',
                            bg: app.authed ? tone.acw : tone.surface2,
                            fg: app.authed ? tone.ac : tone.ink3,
                          ),
                        ],
                      ),
                    ),
                    Container(height: 1, color: tone.line2),
                    Row(
                      children: [
                        _Stat(value: '$_dirs', label: '文件夹'),
                        Container(width: 1, height: 34, color: tone.line2),
                        _Stat(value: '$_files', label: '文件'),
                        Container(width: 1, height: 34, color: tone.line2),
                        _Stat(value: '${app.favorites.length}', label: '收藏'),
                      ],
                    ),
                  ],
                ),
              ),
              const SectionHead('账号'),
              GroupCard(
                children: [
                  KitRow(
                    icon: 'src-nas',
                    iconBg: tone.icobg,
                    iconColor: tone.ac,
                    title: '文件源',
                    sub: app.sources.isEmpty
                        ? '还没有文件源'
                        : '共 ${app.sources.length} 个 · 当前 ${_curName()}',
                    trailing: UIIcon('chevron-right',
                        size: 17, color: tone.ink3.withValues(alpha: 0.55)),
                    onTap: () => _showSources(),
                  ),
                  KitRow(
                    icon: 'lock',
                    iconBg: const Color(0xFFFFF3E5),
                    iconColor: const Color(0xFFE08A16),
                    title: '写入口令',
                    sub: app.canWrite
                        ? (app.session.chatBasic.isEmpty
                            ? '已连接 · 对话口令缺失，点这里重填一次'
                            : '已填 · 能改文件，对话也能用')
                        : '未填 · 现在只能看，改文件和对话要填一次',
                    trailing: UIIcon('chevron-right',
                        size: 17, color: tone.ink3.withValues(alpha: 0.55)),
                    onTap: () => _askKey(context),
                  ),
                  KitRow(
                    icon: 'src-cloud',
                    iconBg: const Color(0xFFE8F2FF),
                    iconColor: const Color(0xFF1677F8),
                    title: 'CloudDrive2 令牌',
                    sub: _cd2['ok'] == true
                        ? (_cd2['token_set'] == true
                            ? '已配置 · 115 网盘可读写、可云下载'
                            : '在线 · 还差一个令牌')
                        : (_cd2.isEmpty ? '读取中…' : '连不上，检查 NAS 上的容器'),
                    trailing: _cd2Busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _cd2['token_set'] == true ? '正常' : '待配置',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _cd2['token_set'] == true
                                  ? const Color(0xFF16A34A)
                                  : const Color(0xFFE45E53),
                            ),
                          ),
                    onTap: _cd2Busy ? null : _cd2Token,
                  ),
                ],
              ),
              const SectionHead('外观'),
              GroupCard(
                children: [
                  // 显示方式：与旧版“紧凑列表 / 网格缩略图”一致，改完立刻存本地
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
                    child: Row(
                      children: [
                        UIIcon('grid', size: 19, color: tone.ink2),
                        const SizedBox(width: 10),
                        Text('显示方式',
                            style: TextStyle(
                                fontSize: 15.5,
                                fontWeight: FontWeight.w600,
                                color: tone.ink)),
                        const Spacer(),
                        _Seg(
                          options: const ['紧凑列表', '网格缩略图'],
                          index: app.gridMode ? 1 : 0,
                          onPick: (i) => app.setGridMode(i == 1),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            UIIcon('setting', size: 19, color: tone.ink2),
                            const SizedBox(width: 10),
                            Text('主题',
                                style: TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w600,
                                    color: tone.ink)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final t in Tokens.all)
                              Press(
                                onTap: () => app.setTone(t),
                                scale: 0.96,
                                radius: const BorderRadius.all(Radius.circular(11)),
                                pressColor: Colors.transparent,
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: app.tone.id == t.id ? tone.ac : tone.surface2,
                                    borderRadius: BorderRadius.circular(11),
                                    border: Border.all(
                                        color: app.tone.id == t.id ? tone.ac : tone.line),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // 双色板：主题底色方块 + 该主题主色圆点（照 5020 的 .th-sw）
                                      SizedBox(
                                        width: 26,
                                        height: 22,
                                        child: Stack(
                                          children: [
                                            Positioned(
                                              left: 0,
                                              top: 3,
                                              child: Container(
                                                width: 17,
                                                height: 17,
                                                decoration: BoxDecoration(
                                                  color: t.bg,
                                                  borderRadius: BorderRadius.circular(6),
                                                  border: Border.all(
                                                    color: Colors.black.withValues(alpha: 0.12),
                                                  ),
                                                ),
                                              ),
                                            ),
                                            Positioned(
                                              left: 12,
                                              top: 8,
                                              child: Container(
                                                width: 11,
                                                height: 11,
                                                decoration: BoxDecoration(
                                                  color: t.ac,
                                                  shape: BoxShape.circle,
                                                  border: Border.all(
                                                    color: app.tone.surface,
                                                    width: 2,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(t.label,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                            color: app.tone.id == t.id ? tone.onac : tone.ink2,
                                          )),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SectionHead('下载'),
              GroupCard(
                children: [
                  KitRow(
                    icon: 'download',
                    iconBg: const Color(0xFFE5F8EF),
                    iconColor: const Color(0xFF0E9D78),
                    title: '下载队列',
                    sub: _qSub(),
                    // 进度就放这一处：别在页面上再飘一条
                    trailing: app.transfers.active.isEmpty
                        ? UIIcon('chevron-right',
                            size: 17, color: tone.ink3.withValues(alpha: 0.55))
                        : AnimatedBuilder(
                            animation: app.transfers,
                            builder: (ctx, _) {
                              final t = app.transfers.active.first;
                              final pct = (t.pct * 100).round();
                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 42,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(99),
                                      child: LinearProgressIndicator(
                                        value: t.pct,
                                        minHeight: 5,
                                        backgroundColor: tone.surface2,
                                        valueColor:
                                            AlwaysStoppedAnimation(tone.ac),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text('$pct%',
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: tone.ink2)),
                                ],
                              );
                            },
                          ),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => DownloadsPage(app: app),
                    )),
                  ),
                  KitRow(
                    icon: 'speed',
                    iconBg: const Color(0xFFE8F2FF),
                    iconColor: const Color(0xFF1677F8),
                    title: '同时下载',
                    sub: '现在 ${app.transfers.maxActive} 个一起下',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final n in const [1, 2, 3]) ...[
                          GestureDetector(
                            onTap: () {
                              setState(() => app.session.dlMaxActive = n);
                              app.session.save();
                              app.applyTransferPrefs();
                            },
                            child: Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: app.session.dlMaxActive == n
                                    ? tone.ac
                                    : tone.surface2,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('$n',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: app.session.dlMaxActive == n
                                        ? Colors.white
                                        : tone.ink2,
                                  )),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  KitRow(
                    icon: 'info',
                    iconBg: const Color(0xFFEFEAFF),
                    iconColor: const Color(0xFF7C5CF0),
                    title: '完成后提示',
                    sub: app.session.dlNotify ? '下完弹一条提示' : '默默下完，不打扰',
                    trailing: GestureDetector(
                      onTap: () {
                        setState(() => app.session.dlNotify = !app.session.dlNotify);
                        app.session.save();
                        app.applyTransferPrefs();
                      },
                      child: Container(
                        width: 44,
                        height: 26,
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: app.session.dlNotify ? tone.ac : tone.surface2,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: AnimatedAlign(
                          duration: Shape.base,
                          curve: Shape.curve,
                          alignment: app.session.dlNotify
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: const BoxDecoration(
                                color: Colors.white, shape: BoxShape.circle),
                          ),
                        ),
                      ),
                    ),
                  ),
                  KitRow(
                    icon: 'folder',
                    iconBg: const Color(0xFFFFF3DF),
                    iconColor: const Color(0xFFC78218),
                    title: '保存位置',
                    sub: '系统「下载/云匣」· 手机相册/文件管理器都能看到',
                  ),
                ],
              ),
              const SectionHead('听 · 译'),
              GroupCard(
                children: [
                  KitRow(
                    icon: 'translate',
                    iconBg: const Color(0xFFEAF7F0),
                    iconColor: const Color(0xFF0D9C7A),
                    title: '听队列',
                    sub: '只含「加入队列听」的任务 · 实时听不占队列',
                    trailing: UIIcon('chevron-right',
                        size: 17, color: tone.ink3.withValues(alpha: 0.55)),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SubsPage(app: app),
                    )),
                  ),
                  KitRow(
                    icon: 'speed',
                    iconBg: const Color(0xFFEFEAFF),
                    iconColor: const Color(0xFF7C5CF0),
                    title: '听设置',
                    sub: '实时开关 · 识别精度 · 服务地址',
                    trailing: UIIcon('chevron-right',
                        size: 17, color: tone.ink3.withValues(alpha: 0.55)),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SubsSettingsPage(app: app),
                    )),
                  ),
                  KitRow(
                    icon: 'type-doc',
                    iconBg: const Color(0xFFE8F2FF),
                    iconColor: const Color(0xFF1677F8),
                    title: '翻译源',
                    sub: TrSource.current.ready
                        ? '${TrSource.current.providerName} · ${TrSource.current.shownModel}'
                        : '未配置 · 听在服务器，译在本地，要填一次密钥',
                    trailing: UIIcon('chevron-right',
                        size: 17, color: tone.ink3.withValues(alpha: 0.55)),
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(
                          builder: (_) => TrSourcePage(app: app),
                        ))
                        .then((_) {
                          if (mounted) setState(() {});
                        }),
                  ),
                ],
              ),
              const SectionHead('更多'),
              GroupCard(
                children: [
                  KitRow(
                    icon: 'more',
                    iconBg: tone.icobg,
                    iconColor: tone.ink2,
                    title: '更多',
                    sub: '连接检测 · 清理缓存 · 权限',
                    trailing: UIIcon('chevron-right',
                        size: 17, color: tone.ink3.withValues(alpha: 0.55)),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SettingsMorePage(app: app),
                    )),
                  ),
                ],
              ),
              // 退出登录（旧版在最后一行，红字）
              Press(
                onTap: () async {
                  final ok = await showConfirmSheet(context,
                      title: '退出登录', text: '退出后要重新输入口令才能上传。', danger: true);
                  if (ok == true) await app.logout();
                },
                scale: 1,
                pressColor: tone.surface2,
                child: Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tone.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: tone.line),
                  ),
                  child: const Text('退出登录',
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFE45E53))),
                ),
              ),
              const SizedBox(height: 100),
            ],
          ),
        ),
      ],
    );
  }

}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Column(
          children: [
            Text(value,
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700, color: tone.ink)),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(fontSize: 11.5, color: tone.ink3)),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const _Pill({required this.text, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Text(text,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

class _Seg extends StatelessWidget {
  final List<String> options;
  final int index;
  final void Function(int) onPick;

  const _Seg({required this.options, required this.index, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: tone.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tone.line2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < options.length; i++)
            Press(
              onTap: () => onPick(i),
              scale: 0.98,
              radius: const BorderRadius.all(Radius.circular(8)),
              pressColor: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: i == index ? tone.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: i == index
                      ? [BoxShadow(color: tone.sh, blurRadius: 6, offset: const Offset(0, 1))]
                      : null,
                ),
                child: Text(options[i],
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: i == index ? tone.ink : tone.ink3,
                    )),
              ),
            ),
        ],
      ),
    );
  }
}
