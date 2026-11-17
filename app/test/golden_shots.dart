// 黄金截图测试：不开手机也能看到界面长什么样。
//
// 用法：
//   flutter test test/golden_test.dart --update-goldens   # 重新出图
//   flutter test test/golden_test.dart                    # 校验有没有跑偏
// 产出：test/goldens/*.png
//
// 字体必须手动加载，否则中文全是方块（测试环境默认用 Ahem）。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/api.dart';
import 'package:yunxia_app/core/app_state.dart';
import 'package:yunxia_app/core/session.dart';
import 'package:yunxia_app/core/tokens.dart';
import 'package:yunxia_app/core/transfer.dart';
import 'package:yunxia_app/main.dart';
import 'package:yunxia_app/ui/browse_page.dart';
import 'package:yunxia_app/ui/home_page.dart';
import 'package:yunxia_app/ui/search_page.dart';
import 'package:yunxia_app/ui/settings_page.dart';
import 'package:yunxia_app/ui/chat_page.dart';

/// 假 API：返回固定数据，测试不碰网络。
class FakeApi extends Api {
  FakeApi() : super('http://demo.local');

  static Map<String, dynamic> _entry(String name, String path, bool isDir,
          int size, String kind, int ageMin) =>
      {
        'name': name,
        'path': path,
        'is_dir': isDir,
        'size': size,
        // 时间戳必须固定：humanTime 对当天的文件显示「今天 HH:MM」，
        // 用 now() 算的话每次跑出来的分钟数都不一样，黄金图永远对不上
        'mtime': DateTime(2024, 5, 1, 10, 30).subtract(Duration(minutes: ageMin)).millisecondsSinceEpoch / 1000,
        'kind': kind,
        'ext': name.contains('.') ? name.split('.').last : '',
      };

  static final List<Map<String, dynamic>> _root = [
    _entry('Jav', '/Jav', true, 0, 'dir', 60),
    _entry('下载', '/下载', true, 0, 'dir', 180),
    _entry('影音库', '/影音库', true, 0, 'dir', 300),
    _entry('盲盒详情页', '/盲盒详情页', true, 0, 'dir', 900),
    _entry('星际穿越.2014.1080p.mkv', '/星际穿越.2014.1080p.mkv', false, 4294967296, 'video', 15),
    _entry('沙丘2.mkv', '/沙丘2.mkv', false, 3221225472, 'video', 240),
    _entry('说明书.html', '/说明书.html', false, 18432, 'code', 1200),
    _entry('全家福.jpg', '/全家福.jpg', false, 2516582, 'image', 4300),
    _entry('备份.zip', '/备份.zip', false, 1073741824, 'archive', 8000),
  ];

  @override
  Future<Map<String, dynamic>> list(String source, String path,
          {String sort = 'name', String order = 'asc'}) async =>
      {
        'source': source,
        'path': path,
        'parent': path == '/' ? null : '/',
        'entries': _root,
        'allow_upload': true,
        'allow_delete': true,
      };

  @override
  Future<Map<String, dynamic>> search(String q,
          {String? source, String? kind, int limit = 50, int offset = 0}) async =>
      {
        'q': q,
        'total': _root.where((e) => e['is_dir'] == false).length,
        'took_ms': 3,
        // 故意把两条放到别的目录，好让「按目录收」那排 chip 在截图里出现
        'items': [
          ..._root.where((e) => e['is_dir'] == false),
          {'name': '漫威合集.mkv', 'path': '/Jav/漫威合集.mkv', 'is_dir': false,
           'size': 8800000000, 'mtime': 1793000000, 'kind': 'video'},
          {'name': '东宫E01.mp4', 'path': '/影音库/TV/东宫E01.mp4', 'is_dir': false,
           'size': 3000000000, 'mtime': 1793000000, 'kind': 'video'},
        ].take(limit).toList(),
      };

  @override
  Future<Map<String, dynamic>> sources() async => {
        'sources': [
          {'id': 'nas', 'name': 'NAS', 'writable': true, 'root': '/'},
          {'id': '115', 'name': '115 网盘', 'writable': false, 'root': '/'},
          {'id': 'pc', 'name': '电脑', 'writable': true, 'root': '/'},
        ],
        'default': 'nas',
      };

  @override
  Future<Map<String, dynamic>> searchStatus() async =>
      {'files': 1284, 'dirs': 96, 'last_scan': '2026-10-30 01:00:07',
       'scanning': false, 'db_bytes': 4096, 'ts': 0};

  @override
  Future<Map<String, dynamic>> get(String path, [Map<String, String>? query]) async {
    if (path == '/meta/storage') {
      return {
        'total': 58304150528,
        'free': 49057161216,
        'used': 9246989312,
        'root': '/mnt/mmc1-4/home/share',
      };
    }
    return {'ok': true};
  }
}

/// 图标字体：不注册的话所有 Icon 都是方框（测试环境不带 MaterialIcons）。
Future<void> loadIcons() async {
  final f = File('${Platform.environment['HOME']}/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (!f.existsSync()) return;
  final bytes = f.readAsBytesSync();
  final loader = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

Future<void> loadFonts() async {
  // 只用**静态**中文字体：可变字体（NotoSansSC-VF）在测试渲染器里大量缺字，
  // 会画成一堆豆腐块，看不出真实效果。
  const candidates = [
    '/mnt/c/Windows/Fonts/simhei.ttf',
    '/mnt/c/Windows/Fonts/Deng.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
  ];
  for (final path in candidates) {
    final f = File(path);
    if (!f.existsSync()) continue;
    final bytes = f.readAsBytesSync();
    // 注册成 'Roboto' 才能顶掉测试环境默认的 Ahem（Ahem 每个字都是一个实心方块，
    // 之前那些灰块/白条就是它画出来的，不是布局问题）。
    for (final family in ['Roboto', 'Noto Sans SC', 'GoldenCJK']) {
      final loader = FontLoader(family)..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    }
    return;
  }
}

Future<App> makeApp(Tone tone) async {
  final app = App(
    Session(server: 'http://demo.local', token: 'demo', toneId: tone.id),
    apiOverride: FakeApi(),
  );
  app.authed = true;
  app.booting = false;
  await app.loadSources();   // 源 chip 要有数据才画得出来
  await app.open('/');
  return app;
}

Widget wrap(Tone tone, Widget child, Size size) {
  return MediaQuery(
    data: MediaQueryData(size: size, devicePixelRatio: 2, padding: EdgeInsets.zero),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(tone),
      home: Scaffold(
        backgroundColor: tone.bg,
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: tone.dark
                  ? [tone.bg2, tone.bg, tone.bg]
                  : [
                      Color.alphaBlend(tone.ac.withValues(alpha: 0.10), tone.bg),
                      tone.bg2,
                      tone.bg2,
                    ],
              stops: const [0.0, 0.42, 1.0],
            ),
          ),
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    await loadFonts();
    await loadIcons();
  });

  const phone = Size(390, 844);
  const tablet = Size(1024, 768);

  testWidgets('首页 · 默认蓝', (tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.blue);
    await tester.pumpWidget(wrap(
      Tokens.blue,
      HomePage(app: app, onOpenSource: (_) {}, onOpenPath: (_, _) {}, onAvatar: () {}),
      phone,
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/home_blue.png'),
    );
  });

  testWidgets('首页 · 深色', (tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.dark);
    await tester.pumpWidget(wrap(
      Tokens.dark,
      HomePage(app: app, onOpenSource: (_) {}, onOpenPath: (_, _) {}, onAvatar: () {}),
      phone,
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/home_dark.png'),
    );
  });

  testWidgets('首页 · 浅灰', (tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.gray);
    await tester.pumpWidget(wrap(
      Tokens.gray,
      HomePage(app: app, onOpenSource: (_) {}, onOpenPath: (_, _) {}, onAvatar: () {}),
      phone,
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/home_gray.png'),
    );
  });

  testWidgets('文件页 · 默认蓝', (tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.blue);
    await tester.pumpWidget(wrap(Tokens.blue, BrowsePage(app: app), phone));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/browse_blue.png'),
    );
  });

  testWidgets('文件页 · 多选', (tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.blue);
    await tester.pumpWidget(wrap(Tokens.blue, BrowsePage(app: app), phone));
    await tester.pumpAndSettle();
    // 长按第一行进多选
    await tester.longPress(find.text('Jav').first);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/browse_select.png'),
    );
  });

  testWidgets('搜索页 · 有结果', (tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.blue);
    await tester.pumpWidget(wrap(Tokens.blue, SearchPage(app: app, onOpenDir: (_) {}), phone));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'a');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/search_results.png'),
    );
  });

  testWidgets('文件页 · 网格', (tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.blue);
    await tester.pumpWidget(wrap(Tokens.blue, BrowsePage(app: app), phone));
    await tester.pumpAndSettle();
    // 切到网格：点标题行右边的视图切换（现在用的是旧版那套 SVG 图标）
    await tester.tap(find.byKey(const ValueKey('grid-toggle')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/browse_grid.png'),
    );
  });

  testWidgets('搜索页 · 默认蓝', (tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.blue);
    await tester.pumpWidget(wrap(
      Tokens.blue,
      SearchPage(app: app, onOpenDir: (_) {}),
      phone,
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/search_blue.png'),
    );
  });

  testWidgets('我的 · 下载中', (tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.blue);
    final t = Transfer(
            id: 'dl1',
            kind: TransferKind.download,
            name: 'Predator.Badlands.2025.mkv',
            total: 100)
      ..done = 37;
    app.transfers.items.add(t);
    await tester.pumpWidget(wrap(Tokens.blue, SettingsPage(app: app), phone));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -620));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/settings_downloading.png'));
  });

  // 整页一屏看：设置收纳之后到底还有多长，一眼就能判断
  testWidgets('我的 · 整页', (tester) async {
    const tall = Size(390, 1500);
    tester.view.physicalSize = tall * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.blue);
    await tester.pumpWidget(wrap(Tokens.blue, SettingsPage(app: app), tall));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/settings_whole.png'));
  });

  testWidgets('我的 · 深色', (tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.dark);
    await tester.pumpWidget(wrap(Tokens.dark, SettingsPage(app: app), phone));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_dark.png'),
    );
  });

  testWidgets('首页 · 平板宽度', (tester) async {
    tester.view.physicalSize = tablet * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.blue);
    await tester.pumpWidget(wrap(
      Tokens.blue,
      HomePage(app: app, onOpenSource: (_) {}, onOpenPath: (_, _) {}, onAvatar: () {}),
      tablet,
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/home_tablet.png'),
    );
  });
  testWidgets('对话 · Markdown', (tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.blue);
    app.session.chatBasic = 'x';
    app.session.chatLog = [
      {'t': 1793524583, 'mine': true, 'text': '帮我看下 NAS 上还有多少空间'},
      {
        't': 1793524643,
        'mine': false,
        'text': '**NAS 还剩 12.4 GB**，够用。\n\n'
            '- 总容量 29 GB\n'
            '- 已用 16.6 GB\n\n'
            '运行 `df -h` 可以自己看：\n\n'
            '```\nFilesystem  Size  Used Avail\n/dev/mmc  29G   16G  12.4G\n```'
      },
      {'t': 1793524673, 'mine': true, 'text': '好，那再转一部听译'},
    ];
    await tester.pumpWidget(wrap(Tokens.blue, ChatPage(app: app), phone));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/chat_blue.png'),
    );
  });

  testWidgets('对话 · 状态与附件', (tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.blue);
    app.session.chatBasic = 'x';
    app.session.chatLog = [
      {'t': 1793524119, 'mine': true, 'text': '把结果整理一下，顺便截个图'},
      {
        't': 1793524419,
        'mine': false,
        'text': '整理好了，报告在这里：\n\n'
            '`/mnt/g/hermes/云匣文件/2026-10-24/分析报告.md`\n\n'
            '截图：\n\n/home/administrator/.hermes/image_cache/ab12.png\n\n'
            '参考 https://example.com/docs/dolby-vision 也有说明。',
        'steps': [
          {
            'n': 'terminal',
            'a': 'ls -la /mnt/g/hermes/云匣文件/2026-10-24/',
            'o': 'total 48\n-rw-r--r-- 1 administrator 4.1K 分析报告.md\n'
                '-rw-r--r-- 1 administrator 812K 分析报告.pdf',
            'd': 1.4,
            'b': false,
          },
          {
            'n': 'read_file',
            'a': '/mnt/g/hermes/云匣文件/2026-10-24/分析报告.md',
            'o': '# 分析报告\n\n1. NAS 剩余空间 12.4 GB\n2. 听译队列 3 个',
            'd': 0.2,
            'b': false,
          },
          {
            'n': 'terminal',
            'a': 'cat /mnt/g/hermes/云匣文件/2026-10-24/缺失.md',
            'o': 'cat: /mnt/g/hermes/云匣文件/2026-10-24/缺失.md: No such file',
            'd': 0.3,
            'b': true,
          },
        ],
        'think': '用户要的是报告 + 截图。先看目录里有没有现成的 md，'
            '再确认 image_cache 里那张 png 还在，然后组织一段说明，'
            '末尾把旧前端那份文档链接也带上，方便对照。',
      },
      {
        't': 1793524659,
        'mine': false,
        'text': '',
        'think': '正在核对截图路径…',
      },
    ];
    await tester.pumpWidget(wrap(Tokens.blue, ChatPage(app: app), phone));
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/chat_attach_blue.png'),
    );
  });

  testWidgets('对话 · 气泡近景', (tester) async {
    tester.view.physicalSize = phone * 2;
    tester.view.devicePixelRatio = 2;
    final app = await makeApp(Tokens.blue);
    app.session.chatBasic = 'x';
    app.session.chatLog = [
      {'t': 0, 'mine': false, 'text': '你好呀'},
      {'t': 1, 'mine': true, 'text': '你好'},
      {'t': 2, 'mine': false, 'text': '要不要看今晚的片子'},
    ];
    await tester.pumpWidget(wrap(Tokens.blue, ChatPage(app: app), phone));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/chat_bubbles.png'),
    );
  });

}
