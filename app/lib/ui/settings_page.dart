import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';
import 'downloads_page.dart';
import 'kit.dart';
import 'settings_more_page.dart';
import 'subs_page.dart';
import 'widgets.dart';

/// 设置页 —— 照旧版前端：品牌栏 → 副标题 → 大标题 → 存储卡 →
/// 账号状态 → 显示与外观 → 本机下载 → 更多 → 退出登录。
class SettingsPage extends StatefulWidget {
  final App app;
  const SettingsPage({super.key, required this.app});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  App get app => widget.app;

  /// 听译语言的选项（下标 = 服务端认的 lang 值）
  static const _langCodes = ['auto', 'ja', 'en', 'zh'];
  static const _langLabels = ['自动', '日语', '英语', '中文'];

  bool _subsAsked = false;

  /// 队列数据只在真正用到时拉一次：进设置页本来不该发请求
  void _ensureSubs() {
    if (!app.subsEnabled || app.subsLoaded || _subsAsked) return;
    _subsAsked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) app.refreshSubs();
    });
  }

  /// 本机下载只留一句摘要：详情都在下载队列页里
  String _qSub() {
    final local = app.transfers.downloads.length;
    if (local == 0) return '还没有下载任务';
    final running = app.transfers.active.length;
    final parts = <String>['本机 $local 个'];
    if (running > 0) parts.add('$running 个在下');
    return parts.join(' · ');
  }

  int get _dirs => app.entries.where((e) => e.isDir).length;
  int get _files => app.entries.where((e) => !e.isDir).length;

  /// 来源说明优先用服务端给的副标题，没有才按 kind 兜底
  static String _sourceSub(Map<String, dynamic> s) {
    final sub = (s['sub'] as String? ?? '').trim();
    if (sub.isNotEmpty) return sub;
    switch (s['kind'] as String? ?? '') {
      case 'dufs':
        return 'HTTP 文件服务';
      case 'webdav':
        return 'WebDAV 网盘 · 只读';
      case 'local':
        return '本机磁盘';
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
    final icon = kind == 'webdav'
        ? 'src-cloud'
        : kind == 'dufs'
            ? 'src-pc'
            : (id == 'nas' || id == 'local')
                ? 'src-nas'
                : 'src-disk';
    return (icon, tone.acw, tone.ac);
  }

  /// 改服务器地址：填完立刻重连一次（地址不对会显示 app.fatal 的原因）
  Future<void> _askServer(BuildContext context) async {
    final ctl = TextEditingController(text: app.api.server);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('服务器地址'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(hintText: 'http://192.168.1.10:8686'),
          onSubmitted: (x) => Navigator.of(ctx).pop(x),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(ctl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    ctl.dispose();
    var url = (v ?? '').trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) url = 'http://$url';
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    await app.changeServer(url);
    await app.boot();
    if (context.mounted) app.toast(app.fatal ?? '已连接 · ${app.api.server}');
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
    _ensureSubs();
    final src = app.sources.firstWhere((s) => s['id'] == app.source,
        orElse: () => const {'id': 'local', 'name': '本机', 'writable': true});
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
                                Text(src['name'] as String? ?? '本机',
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
                    icon: 'link',
                    iconBg: tone.icobg,
                    iconColor: tone.ac,
                    title: '服务器地址',
                    sub: app.api.server.isEmpty ? '还没填 · 点这里填' : app.api.server,
                    trailing: UIIcon('chevron-right',
                        size: 17, color: tone.ink3.withValues(alpha: 0.55)),
                    onTap: () => _askServer(context),
                  ),
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
              const SectionHead('本机下载'),
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
              // 听译：服务端没开（/meta/sources subs.enabled=false）就整块不出现，
              // 免得摆一排按不动的行
              if (app.subsEnabled) ...[
                const SectionHead('听·译'),
                GroupCard(
                  children: [
                    KitRow(
                      icon: 'translate',
                      iconBg: tone.icobg,
                      iconColor: tone.ac,
                      title: '转写模型',
                      sub: app.subsModel.isEmpty
                          ? '服务端还没报模型'
                          : '${app.subsModel} · 在服务器本机跑',
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      child: Row(
                        children: [
                          UIIcon('list', size: 19, color: tone.ink2),
                          const SizedBox(width: 10),
                          Text('转写语言',
                              style: TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w600,
                                  color: tone.ink)),
                          const Spacer(),
                          _Seg(
                            options: _langLabels,
                            index: _langCodes.indexOf(app.session.subsLang)
                                .clamp(0, _langCodes.length - 1),
                            onPick: (i) {
                              setState(() => app.session.subsLang = _langCodes[i]);
                              app.session.save();
                              app.toast('转写语言：${_langLabels[i]}');
                            },
                          ),
                        ],
                      ),
                    ),
                    KitRow(
                      icon: 'speed',
                      iconBg: tone.icobg,
                      iconColor: tone.ac,
                      title: '同时转写',
                      sub: '现在 ${app.subsMaxActive} 个一起转',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final n in const [1, 2, 3])
                            GestureDetector(
                              onTap: () async {
                                if (app.subsMaxActive == n) return;
                                try {
                                  await app.api.subsSetMaxActive(n);
                                  if (!mounted) return;
                                  setState(() => app.subsMaxActive = n);
                                  app.toast('同时转写 $n 个');
                                } catch (e) {
                                  app.toast('设置失败：$e');
                                }
                              },
                              child: Container(
                                margin: const EdgeInsets.only(left: 6),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: app.subsMaxActive == n
                                      ? tone.ac
                                      : tone.surface2,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text('$n',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: app.subsMaxActive == n
                                          ? Colors.white
                                          : tone.ink2,
                                    )),
                              ),
                            ),
                        ],
                      ),
                    ),
                    KitRow(
                      icon: 'translate',
                      iconBg: const Color(0xFFEFEAFF),
                      iconColor: const Color(0xFF7C5CF0),
                      title: '字幕翻译',
                      sub: app.subsTranslate['ready'] == true
                          ? '已配置 · 译成 ${(app.subsTranslate['to'] as String? ?? '').isEmpty ? '目标语言' : app.subsTranslate['to']}'
                          : '未配置 · 只能出原文',
                    ),
                    KitRow(
                      icon: 'list',
                      iconBg: tone.icobg,
                      iconColor: tone.ac,
                      title: '听译队列',
                      sub: app.subsJobs.isEmpty
                          ? '还没有作业'
                          : '${app.subsJobs.length} 个作业 · ${app.subsActive} 个在跑',
                      trailing: UIIcon('chevron-right',
                          size: 17, color: tone.ink3.withValues(alpha: 0.55)),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => SubsPage(app: app)),
                      ),
                    ),
                  ],
                ),
              ],
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
