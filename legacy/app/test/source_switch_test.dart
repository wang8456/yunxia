// 切源回归：慢请求回来得晚，不许把新源的列表盖掉；
// 旧源请求失败，也不许把新源的列表清空。
import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/api.dart';
import 'package:yunxia_app/core/app_state.dart';
import 'package:yunxia_app/core/session.dart';

class FakeApi extends Api {
  FakeApi() : super('http://demo.local');

  /// 每个源故意用不同延迟：slow 最慢、boom 会报错、nas 立刻返回
  @override
  Future<Map<String, dynamic>> list(
    String source,
    String path, {
    String sort = 'name',
    String order = 'asc',
  }) async {
    if (source == 'slow') {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    } else if (source == 'boom') {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      throw ApiError(500, '磁盘挂了');
    }
    return {
      'source': source,
      'path': path,
      'parent': null,
      'entries': [
        {
          'name': '$source$path',
          'path': '$path$source',
          'is_dir': true,
          'size': 0,
          'mtime': 0.0,
          'kind': 'dir',
          'ext': '',
        },
      ],
      'allow_upload': true,
      'allow_delete': true,
    };
  }

  @override
  Future<Map<String, dynamic>> sources() async =>
      {'sources': <Map<String, dynamic>>[], 'default': 'nas'};
}

void main() {
  test('切源：慢的旧请求回来后不覆盖新源列表', () async {
    final app = App(Session(server: 'http://demo.local'), apiOverride: FakeApi());
    app.source = 'nas';

    final slow = app.switchSource('slow'); // 开始 120ms 的慢请求
    final back = app.switchSource('nas'); // 立刻切回来
    await Future.wait([slow, back]);
    // 再等一会儿，让慢请求真的落地
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(app.source, 'nas');
    expect(app.busy, isFalse);
    expect(app.entries.length, 1);
    expect(app.entries.first.name, 'nas/');
  });

  test('切源：旧源报错不清空新源列表', () async {
    final app = App(Session(server: 'http://demo.local'), apiOverride: FakeApi());
    app.source = 'nas';

    final boom = app.switchSource('boom');
    final back = app.switchSource('nas');
    await Future.wait([boom, back]);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(app.entries, isNotEmpty);
    expect(app.entries.first.name, 'nas/');
    expect(app.busy, isFalse);
  });

  test('切源：旧列表当场清掉（不把上一个源的内容留在屏幕上）', () async {
    final app = App(Session(server: 'http://demo.local'), apiOverride: FakeApi());
    app.source = 'nas';
    await app.open('/');
    expect(app.entries.first.name, 'nas/');

    final f = app.switchSource('slow');
    // 切完瞬间就该是空的 + 转圈，而不是还挂着 nas 的条目
    expect(app.entries, isEmpty);
    expect(app.busy, isTrue);
    await f;
    expect(app.entries.first.name, 'slow/');
  });
}
