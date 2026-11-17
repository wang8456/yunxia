// 下载队列：四个来源合成一个列表，按状态分组、按来源过滤。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/api.dart';
import 'package:yunxia_app/core/app_state.dart';
import 'package:yunxia_app/core/session.dart';
import 'package:yunxia_app/core/tokens.dart';
import 'package:yunxia_app/main.dart' show buildTheme;
import 'package:yunxia_app/ui/downloads_page.dart';

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
  Future<Map<String, dynamic>> cd2OfflineAll() async => {
        'items': [
          {'name': '__probe_cloud', 'size': 1000, 'status': 1, 'percent': 42.0, 'hash': 'c1'},
          {'name': 'cloud_done', 'size': 1000, 'status': 2, 'percent': 100.0, 'hash': 'c2'},
        ],
        'total': 2,
      };

  @override
  Future<Map<String, dynamic>> tasks() async => {
        'tasks': [
          {
            'id': 'g1',
            'kind': 'magnet',
            'name': '__probe_magnet',
            'size': 104857600,
            'done': 13107200,
            'pct': 12.5,
            'speed': 1048576,
            'state': 'active',
          },
          {
            'id': 'e1',
            'kind': 'ed2k',
            'name': '__probe_ed2k.bin',
            'size': 2048,
            'done': 0,
            'pct': 0.0,
            'speed': 0,
            'state': 'Waiting', // aMule 是大写，必须兼容
          },
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
  testWidgets('云下载 / 磁力 / ed2k 同列一表，能分组能筛选', (tester) async {
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
        home: DownloadsPage(app: app),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.takeException(), isNull);

    // 标题 + 汇总结论
    expect(find.text('下载队列'), findsOneWidget);
    expect(find.textContaining('2 个在下'), findsOneWidget);

    // 三个来源都在一个列表里，meta 里带来源名
    expect(find.text('__probe_cloud'), findsOneWidget);
    expect(find.text('__probe_magnet'), findsOneWidget);
    expect(find.text('__probe_ed2k.bin'), findsOneWidget);
    expect(find.textContaining('云下载 · 下载中'), findsOneWidget);
    expect(find.textContaining('磁力 · 下载中'), findsOneWidget);
    expect(find.textContaining('ed2k · 排队中'), findsOneWidget);

    // 分组标题
    expect(find.text('进行中 · 2'), findsOneWidget);
    expect(find.text('排队中 · 1'), findsOneWidget);
    expect(find.text('已完成 · 1'), findsOneWidget);

    // 来源筛选：点「磁力 1」只剩磁力
    expect(find.text('全部 4'), findsOneWidget);
    await tester.tap(find.text('磁力 1'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('__probe_magnet'), findsOneWidget);
    expect(find.text('__probe_cloud'), findsNothing);
    expect(find.text('__probe_ed2k.bin'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
