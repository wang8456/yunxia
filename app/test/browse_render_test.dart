// 文件页渲染冒烟：pump 出来不能有异常。
// 打包版 Flutter 里 build 抛异常不会显示红屏，只留一块灰——真机上就是「整个内容区变灰」。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/api.dart';
import 'package:yunxia_app/core/app_state.dart';
import 'package:yunxia_app/core/session.dart';
import 'package:yunxia_app/core/tokens.dart';
import 'package:yunxia_app/main.dart' show buildTheme;
import 'package:yunxia_app/ui/browse_page.dart';

class FakeApi extends Api {
  FakeApi() : super('http://demo.local');

  @override
  Future<Map<String, dynamic>> sources() async => {
        'sources': [
          {'id': 'nas', 'name': 'NAS · 本机存储', 'kind': 'local', 'writable': true},
          {'id': 'nas115', 'name': 'NAS · 115网盘', 'kind': 'cd2', 'writable': true},
        ],
        'default': 'nas',
      };

  static Map<String, dynamic> _e(String name, String path, bool dir, String kind) => {
        'name': name,
        'path': path,
        'is_dir': dir,
        'size': dir ? 0 : 1234567,
        'mtime': 1700000000.0,
        'kind': dir ? 'dir' : kind,
        'ext': name.contains('.') ? name.split('.').last : '',
      };

  @override
  Future<Map<String, dynamic>> list(
    String source,
    String path, {
    String sort = 'name',
    String order = 'asc',
  }) async =>
      {
        'source': source,
        'path': path,
        'parent': null,
        'entries': source == 'nas115'
            ? [_e('云下载', '/云下载', true, 'dir')]
            : [
                _e('Jav', '/Jav', true, 'dir'),
                _e('下载', '/下载', true, 'dir'),
                _e('星际穿越.2014.mkv', '/星际穿越.2014.mkv', false, 'video'),
                _e('全家福.jpg', '/全家福.jpg', false, 'image'),
              ],
        'allow_upload': true,
        'allow_delete': true,
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

Future<void> _pump(WidgetTester tester, App app, Size size) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size, devicePixelRatio: 2),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Tokens.blue),
        home: Scaffold(
          backgroundColor: Tokens.blue.bg,
          // 真机上外层是 AnimatedBuilder(animation: app)，这里照做
          body: AnimatedBuilder(
            animation: app,
            builder: (_, _) => BrowsePage(app: app),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('手机：文件页能画出来', (tester) async {
    final app = await _make();
    await _pump(tester, app, const Size(390, 844));
    expect(find.text('Jav'), findsOneWidget);
  });

  testWidgets('平板：文件页能画出来（双栏）', (tester) async {
    final app = await _make();
    await _pump(tester, app, const Size(1024, 768));
    expect(tester.takeException(), isNull);
  });

  testWidgets('切源 + 切视图 + 打开目录：全程不抛异常', (tester) async {
    final app = await _make();
    await _pump(tester, app, const Size(1024, 768));

    await app.switchSource('nas115');
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.text('云下载'), findsWidgets);

    await app.switchSource('nas');
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    app.setGridMode(true);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    await app.open('/Jav');
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('多选模式进出不抛异常', (tester) async {
    final app = await _make();
    await _pump(tester, app, const Size(390, 844));
    final row = find.text('Jav');
    await tester.longPress(row);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('已选'), findsWidgets);
  });
}
