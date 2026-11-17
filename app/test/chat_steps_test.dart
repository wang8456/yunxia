import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/ui/chat_page.dart';

/// 终端过程的解析：用网关真吐出来的 SSE 载荷做输入，别凭空造格式。
void main() {
  test('function_call 参数只留一行关键值', () {
    expect(chatShortArg('{"command": "date"}'), 'date');
    expect(chatShortArg('{"file_path": "/mnt/g/hermes/a.md", "limit": 50}'),
        '/mnt/g/hermes/a.md');
    // 没有已知键就取第一个非空字符串
    expect(chatShortArg('{"foo": "bar"}'), 'bar');
    // 超长截断到 140
    final long = 'x' * 400;
    expect(chatShortArg('{"command": "$long"}').length, 141);
    // 不是 JSON 就原样（压平空白）
    expect(chatShortArg('ls  -la\n/tmp'), 'ls -la /tmp');
  });

  test('工具输出剥 JSON 壳、取 output、exit_code!=0 算失败', () {
    final ok = chatStepOutput({
      'output': [
        {
          'type': 'input_text',
          'text': '{"output": "Sun Nov  1 17:15:57 CST 2026", "exit_code": 0, "error": null}',
        }
      ]
    });
    expect(ok.text, 'Sun Nov  1 17:15:57 CST 2026');
    expect(ok.bad, isFalse);

    final bad = chatStepOutput({
      'output': [
        {
          'type': 'input_text',
          'text': '{"output": "ls: cannot access", "exit_code": 2, "error": null}',
        }
      ]
    });
    expect(bad.text, 'ls: cannot access');
    expect(bad.bad, isTrue);

    // 只有 error 没有 output
    final err = chatStepOutput({
      'output': [
        {'type': 'input_text', 'text': '{"error": "timeout"}'}
      ]
    });
    expect(err.text, 'timeout');
    expect(err.bad, isTrue);

    // 纯文本输出也要能显示
    final plain = chatStepOutput({
      'output': [
        {'type': 'input_text', 'text': 'hello'}
      ]
    });
    expect(plain.text, 'hello');
    expect(plain.bad, isFalse);
  });
}
