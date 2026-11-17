import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter/services.dart';

import 'core/api.dart';
import 'core/app_state.dart';
import 'core/session.dart';
import 'core/tokens.dart';
import 'core/ui_icons.dart';
import 'ui/browse_page.dart';
import 'ui/chat_page.dart';
import 'ui/home_page.dart';
import 'ui/kit.dart';
import 'ui/settings_page.dart';
import 'ui/widgets.dart';

void main() {
  MediaKit.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );
  runApp(const Bootstrap());
}

class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});

  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  App? _app;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final session = await Session.load(Api.defaultServer);
    final app = App(session);
    if (mounted) setState(() => _app = app);
    await app.boot();
  }

  @override
  void dispose() {
    _app?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    if (app == null) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    return AnimatedBuilder(
      animation: app,
      builder: (ctx, _) => MaterialApp(
        title: '云匣',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(app.tone),
        home: app.api.server.trim().isEmpty
            ? ServerSetupPage(app: app)
            : app.booting
                ? _Splash(tone: app.tone)
                // 不强制登录：没口令也能进来看（只读），写操作在设置里解锁
                : Shell(app: app),
      ),
    );
  }
}

ThemeData buildTheme(Tone t) {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: t.ac,
        brightness: t.dark ? Brightness.dark : Brightness.light,
      ).copyWith(
        surface: t.surface,
        primary: t.ac,
        onPrimary: t.onac,
        secondary: t.ac,
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: t.bg,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    textTheme: Typography.material2021().black.apply(
      bodyColor: t.ink,
      displayColor: t.ink,
    ),
    fontFamilyFallback: const [
      'Noto Sans SC',
      'PingFang SC',
      'Microsoft YaHei',
    ],
    extensions: [t],
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.android: CupertinoPageTransitionsBuilder()},
    ),
  );
}

class _Splash extends StatelessWidget {
  final Tone tone;
  const _Splash({required this.tone});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: tone.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF147BFF), Color(0xFF68B4FF)],
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const UIIcon('brand', color: Colors.white, size: 30),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: tone.ac),
            ),
          ],
        ),
      ),
    );
  }
}

/// 外壳：首页 / 文件 / 对话 / 设置（与旧版前端一致的四栏）
class Shell extends StatefulWidget {
  final App app;
  const Shell({super.key, required this.app});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  // 进程被系统收掉再回来，仍停在刚才那一页
  late int _tab = widget.app.session.lastTab;

  App get app => widget.app;

  /// 设置页永远是最后一栏
  int get _settingsTab => app.chatEnabled ? 3 : 2;

  /// 页签表：对话只在服务端开了 chat.enabled 时才有
  List<(String, Widget)> _tabs() => [
    ('home', HomePage(
      app: app,
      onOpenSource: _openSource,
      onOpenPath: _openPath,
      onAvatar: () => _go(_settingsTab),
    )),
    ('browse', BrowsePage(app: app)),
    if (app.chatEnabled) ('chat', ChatPage(app: app)),
    ('settings', Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780),
        child: SettingsPage(app: app),
      ),
    )),
  ];

  /// 存的页签号可能已经不存在了（对话被关掉 / 页签变少）：夹回合法范围
  int _safeTab(List<(String, Widget)> tabs) =>
      _tab.clamp(0, tabs.length - 1);

  void _go(int i) {
    setState(() => _tab = i);
    if (app.session.lastTab != i) {
      app.session.lastTab = i;
      app.session.save();
    }
  }

  @override
  void initState() {
    super.initState();
    app.onOpenPath = _openPath;
  }

  /// 首页点源 → 文件页并切源
  Future<void> _openSource(String src) async {
    await app.switchSource(src);
    if (mounted) setState(() => _tab = 1);
  }

  /// 收藏 / 面包屑点进来：切源 + 跳目录
  Future<void> _openPath(String src, String path) async {
    if (src != app.source) await app.switchSource(src);
    await app.open(path);
    if (mounted) setState(() => _tab = 1);
  }

    @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final wide = MediaQuery.of(context).size.width >= 760;

    final tabs = _tabs();
    final tab = _safeTab(tabs);
    final pages = [for (final t in tabs) t.$2];
    final isChat = tabs[tab].$1 == 'chat';

    final body = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: tone.dark
              ? [tone.bg2, tone.bg, tone.bg]
              : [
                  Color.alphaBlend(tone.ac.withValues(alpha: 0.08), tone.bg2),
                  tone.bg2,
                  tone.bg2,
                ],
          stops: const [0.0, 0.28, 1.0],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Center(
          // 网页版是 520 的手机框；平板给到 620，别再拉成横条
          child: ConstrainedBox(
            constraints: BoxConstraints(
              // 对话页铺满（平板左右不留白），其它页保持 1040 的阅读宽度
              maxWidth: !wide
                  ? double.infinity
                  : (isChat ? double.infinity : 1040),
            ),
            child: IndexedStack(
              index: tab,
              children: [
                for (var i = 0; i < pages.length; i++)
                  // 非当前页不重建，省电也避免滚动位置乱跳
                  Offstage(
                    offstage: i != tab,
                    child: TickerMode(enabled: i == tab, child: pages[i]),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    final stage = Stack(
      children: [
        Positioned.fill(child: body),
        ToastOverlay(text: app.toastText, bottom: 150),
      ],
    );

    return PopScope(
      // 系统返回键/手势：不在首页时先回首页，别一下退回桌面
      canPop: tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 文件页：先按目录一层层往上退，退到根目录才回首页
        if (tab == 1 && app.path != '/') {
          final p = app.path;
          final i = p.lastIndexOf('/');
          app.open(i <= 0 ? '/' : p.substring(0, i));
          return;
        }
        if (tab != 0) _go(0);
      },
      child: Scaffold(
        backgroundColor: tone.bg,
        resizeToAvoidBottomInset: true,
        // 平板/桌面：导航挪到左侧竖排，底栏只留给手机
        // 背景照 5020：上浅下深的一层渐变，换主题时整页气质跟着变
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [tone.bg2, tone.bg],
              stops: const [0, 0.35],
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide)
                SideNav(index: tab, onSelect: _go, chatEnabled: app.chatEnabled),
              Expanded(child: stage),
            ],
          ),
        ),
        bottomNavigationBar: wide
            ? null
            : NavBar(index: tab, onSelect: _go, chatEnabled: app.chatEnabled),
      ),
    );
  }
}

/// 首次启动（或清过数据）时填服务器地址。开源版不预置任何地址，这一屏是必经之路。
/// 地址之后也能在「设置 → 账号 → 服务器地址」里改。
class ServerSetupPage extends StatefulWidget {
  final App app;
  const ServerSetupPage({super.key, required this.app});

  @override
  State<ServerSetupPage> createState() => _ServerSetupPageState();
}

class _ServerSetupPageState extends State<ServerSetupPage> {
  late final TextEditingController _ctl =
      TextEditingController(text: widget.app.api.server);
  bool _busy = false;
  String? _err;

  static String _norm(String v) {
    var s = v.trim();
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Future<void> _go() async {
    final url = _norm(_ctl.text);
    if (url.isEmpty) return;
    setState(() {
      _busy = true;
      _err = null;
    });
    await widget.app.changeServer(url);
    await widget.app.boot();
    if (!mounted) return;
    final bad = widget.app.api.server.trim().isEmpty;
    setState(() {
      _busy = false;
      _err = bad ? '地址没存上' : (widget.app.fatal ?? '');
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Scaffold(
      backgroundColor: tone.bg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF147BFF), Color(0xFF68B4FF)],
                      ),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const UIIcon('brand', color: Colors.white, size: 30),
                  ),
                ),
                const SizedBox(height: 16),
                Text('云匣',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: tone.ink)),
                const SizedBox(height: 6),
                Text('填一下服务器地址，之后随时能改',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: tone.ink3)),
                const SizedBox(height: 22),
                TextField(
                  controller: _ctl,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'http://192.168.1.10:8686',
                  ),
                  onSubmitted: (_) => _go(),
                ),
                const SizedBox(height: 8),
                Text('就是跑 server 的那台机器，例如 http://192.168.1.10:8686',
                    style: TextStyle(fontSize: 11.5, color: tone.ink3)),
                if ((_err ?? '').isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(_err!,
                      style: const TextStyle(
                          fontSize: 12.5, color: Color(0xFFE45E53))),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: _busy ? null : _go,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('连接'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
