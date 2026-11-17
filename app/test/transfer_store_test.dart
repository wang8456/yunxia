import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/transfer.dart';

/// 下载记录要跨进程活着：杀掉 App 再打开，队列里还得有那条记录。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tr_test_');
    Transfers.overrideDir = dir;
  });

  tearDown(() {
    Transfers.overrideDir = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('保存后重新 load：记录还在，下载中的归成已暂停', () async {
    final a = Transfers();
    final done = a.addForTest(TransferKind.download, '电影A.mkv')
      ..done = 100
      ..state = 'done'
      ..where = '/storage/emulated/0/Download/云匣/电影A.mkv'
      ..uri = 'content://media/external/file/1'
      ..path = '/电影/电影A.mkv'
      ..source = 'nas';
    final running = a.addForTest(TransferKind.download, '剧集B.mkv')
      ..done = 40
      ..state = 'running'
      ..url = 'http://x/expired'
      ..source = 'nas'
      ..path = '/剧集/剧集B.mkv';
    // 只有直链的那种（对话附件）：没有 source/path，url 必须留着，
    // 否则重试时就变成「拿空参数去签直链」→ 400。
    a.addForTest(TransferKind.download, '歌.mp3')
      ..state = 'running'
      ..url = 'http://127.0.0.1:8088/hermes/api/dl?path=%2Fx.mp3'
      ..headers = const {'Authorization': 'Basic abc'};
    expect(done.id, isNot(running.id));
    await a.saveNow();

    final b = Transfers();
    await b.load();

    expect(b.items.length, 3);
    final r1 = b.items.firstWhere((t) => t.name == '电影A.mkv');
    expect(r1.state, 'done');
    expect(r1.done, 100);
    expect(r1.where, contains('云匣'));
    expect(r1.uri, isNotEmpty);

    final r2 = b.items.firstWhere((t) => t.name == '剧集B.mkv');
    expect(r2.state, 'paused'); // 上次被系统杀掉，不能谎报还在下
    expect(r2.done, 40);
    expect(r2.url, isEmpty); // 旧签名链接已过期，续传时重新签

    final r3 = b.items.firstWhere((t) => t.name == '歌.mp3');
    expect(r3.url, contains('/hermes/api/dl'));
    expect(r3.headers['Authorization'], 'Basic abc');
  });

  test('没有存档文件时 load 不炸、列表为空', () async {
    final t = Transfers();
    await t.load();
    expect(t.items, isEmpty);
  });

  test('删掉记录后存档同步（重开不会复活）', () async {
    final a = Transfers();
    final x = a.addForTest(TransferKind.download, 'C.mkv')..state = 'done';
    await a.saveNow();
    await a.remove(x);
    await a.saveNow();

    final b = Transfers();
    await b.load();
    expect(b.items.where((t) => t.name == 'C.mkv'), isEmpty);
  });
}
