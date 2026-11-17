// 设置页「下载监控」冒烟：三行能出来、能展开、数据对得上。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/api.dart';
import 'package:yunxia_app/core/app_state.dart';
import 'package:yunxia_app/core/session.dart';
import 'package:yunxia_app/core/tokens.dart';
import 'package:yunxia_app/main.dart' show buildTheme;
import 'package:yunxia_app/ui/settings_page.dart';

class FakeApi extends Api {
  FakeApi() : super('http://demo.local');

  @override
  Future<Map<String, dynamic>> sources() async => {
        'sources': [
          {'id': 'nas', 'name': 'NAS · 本机存储', 'kind': 'local', 'writable': true},
        ],
        'default': 'nas',
      };

  @override
  Future<Map<String, dynamic>> list(
    String source,
    String path, {
    String sort = 'name',
    String order = 'asc',
  }) async =>
      {'source': source, 'path': path, 'entries': const [], 'allow_upload': true};

  @override
  Future<Map<String, dynamic>> cd2Status() async =>
      {'ok': true, 'ready': true, 'login': true, 'user': '115', 'token_set': true};

  @override
  Future<Map<String, dynamic>> cd2OfflineAll() async => {
        'items': [
          {'name': '__probe_cloud', 'size': 1000, 'status': 1, 'percent': 42.0, 'hash': 'h1'},
          {'name': 'done_one', 'size': 1000, 'status': 2, 'percent': 100.0, 'hash': 'h2'},
        ],
        'total': 2,
      };

  @override
  Future<Map<String, dynamic>> tasks() async => {
        'tasks': [
          {'id': 'g1', 'kind': 'magnet', 'name': '__probe_magnet', 'pct': 12.5, 'speed': 1048576, 'state': 'active'},
          {'id': 'e1', 'kind': 'ed2k', 'name': '__probe_ed2k', 'pct': 77.0, 'speed': 0, 'state': 'waiting'},
        ],
        'hubs': {
          'magnet': {'online': true},
          'ed2k': {'online': true},
        },
      };
}

Future<App> _make() async {
  final app = App(
    Session(server: 'http://demo.local', token: 'demo', toneId: 'blue'),
    apiOverride: FakeApi(),
  )
    ..authed = true
    ..booting = false;
  await app.loadSources();
  await app.open('/');
  return app;
}

void main() {
  testWidgets('下载监控三行 + 展开明细', (tester) async {
    final app = await _make();
    const size = Size(390, 844);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: size, devicePixelRatio: 2),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Tokens.blue),
        home: Scaffold(body: SettingsPage(app: app)),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.takeException(), isNull);

    // 三行都在，云下载有 1 个在下（已完成的那条不算）
    // 只允许一个「下载」分区标题（之前 App 里有两个，重复）
    expect(find.text('下载'), findsOneWidget);
    // 三个来源的明细行已经收进下载队列页，设置页只留一句合并摘要
    expect(find.text('下载队列'), findsOneWidget);
    expect(find.text('云下载'), findsNothing);
    expect(find.text('磁力'), findsNothing);
    expect(find.textContaining('NAS 上 3 个在下'), findsOneWidget);

    // 收尾：把树拆掉，Timer.periodic 才会被取消
    await tester.pumpWidget(const SizedBox());
  });
}
