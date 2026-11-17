// 会话落盘回归：切后台/被系统收掉后，对话记录和所在页签都必须还在。
import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/session.dart';

void main() {
  test('chatLog 与 lastTab 能存能读', () async {
    final s = Session(server: 'http://demo.local')
      ..chatBasic = 'hermes:pw'
      ..lastTab = 2
      ..chatLog = [
        {'t': 1700000000, 'mine': true, 'text': '你好'},
        {
          't': 1700000001,
          'mine': false,
          'text': '你好，有什么需要我做？',
          'think': 'Simple greeting.',
          'steps': [
            {'n': 'code', 'a': 'ls', 'o': 'ok', 'b': false, 'd': 0.4},
          ],
        },
      ];
    await s.save();

    final back = await Session.load('http://demo.local');
    expect(back.chatBasic, 'hermes:pw');
    expect(back.lastTab, 2);
    expect(back.chatLog.length, 2);
    expect(back.chatLog[0]['text'], '你好');
    expect(back.chatLog[1]['think'], 'Simple greeting.');
    expect((back.chatLog[1]['steps'] as List).first['n'], 'code');
  });
}
