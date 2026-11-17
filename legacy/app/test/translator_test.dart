import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/translator.dart';

void main() {
  late List<String> calls;

  TrSource src() => TrSource(provider: 'deepseek', model: 'deepseek-flash', key: 'sk-test');

  setUp(() {
    calls = [];
    Translator.clearCache();
  });

  tearDown(() => Translator.post = null);

  group('地址拼装', () {
    test('只给域名补 /v1', () {
      expect(
        TrSource(provider: 'deepseek').endpoint,
        'https://api.deepseek.com/v1/chat/completions',
      );
    });

    test('带 /v1 的地址只接 /chat/completions', () {
      final s = TrSource(provider: 'custom', base: 'https://api.siliconflow.cn/v1');
      expect(s.endpoint, 'https://api.siliconflow.cn/v1/chat/completions');
    });

    test('整条 URL 原样用', () {
      final s = TrSource(
        provider: 'custom',
        base: 'https://x.com/v1/chat/completions',
      );
      expect(s.endpoint, 'https://x.com/v1/chat/completions');
    });

    test('漏了协议头自动补 https', () {
      final s = TrSource(provider: 'custom', base: 'api.moonshot.cn/v1');
      expect(s.endpoint, 'https://api.moonshot.cn/v1/chat/completions');
    });
  });

  group('逐行对齐', () {
    test('两行进两行出，顺序不变', () async {
      Translator.post = (url, key, body) async {
        calls.add(body);
        return '你好\n很高兴见到你';
      };
      final out = await Translator.translate(['Hello', 'Nice to meet you'], 'zh', source: src());
      expect(out, ['你好', '很高兴见到你']);
      expect(calls.length, 1);
      expect(calls.first.contains('deepseek-flash'), isTrue);
    });

    test('空行不送模型，原样空串（不能把后面的句子往前挤）', () async {
      Translator.post = (url, key, body) async {
        calls.add(body);
        return '你好';
      };
      final out = await Translator.translate(['', 'Hello'], 'zh', source: src());
      expect(out, ['', '你好']);
      expect(calls.length, 1);
    });

    test('模型把两句并成一句：先用 JSON 再要一次', () async {
      var n = 0;
      Translator.post = (url, key, body) async {
        n++;
        calls.add(body);
        return n == 1 ? '你好，很高兴见到你' : '{"lines":["你好","很高兴见到你"]}';
      };
      final out = await Translator.translate(['Hello', 'Nice to meet you'], 'zh', source: src());
      expect(out, ['你好', '很高兴见到你']);
      expect(calls.length, 2);
      expect(calls[1].contains('lines'), isTrue); // 第二次要的是 JSON 数组形态
    });

    test('两次都对不上就逐句翻，绝不挪位', () async {
      Translator.post = (url, key, body) async {
        calls.add(body);
        if (body.contains('JSON')) return '{"lines":["合并了"]}';
        if (body.contains('\\n')) return '合并了';
        return body.contains('Hello') ? '你好' : '再见';
      };
      final out = await Translator.translate(['Hello', 'Bye'], 'zh', source: src());
      expect(out, ['你好', '再见']);
      expect(calls.length, 4); // 批量 ×2 + 逐句 ×2
    });

    test('模型自作主张加编号也能剥掉', () async {
      Translator.post = (url, key, body) async => '1. 你好\n2) 再见';
      final out = await Translator.translate(['Hello', 'Bye'], 'zh', source: src());
      expect(out, ['你好', '再见']);
    });

    test('包在 ``` 代码块里也能解析', () async {
      Translator.post = (url, key, body) async => '```\n你好\n```';
      final out = await Translator.translate(['Hello'], 'zh', source: src());
      expect(out, ['你好']);
    });

    test('同一句第二次不花钱（缓存命中）', () async {
      Translator.post = (url, key, body) async {
        calls.add(body);
        return '你好';
      };
      await Translator.translate(['Hello'], 'zh', source: src());
      await Translator.translate(['Hello'], 'zh', source: src());
      expect(calls.length, 1);
    });

    test('没填密钥直接告诉用户去哪填', () async {
      final s = TrSource(provider: 'deepseek', model: 'deepseek-flash', key: '');
      expect(
        () => Translator.translate(['Hello'], 'zh', source: s),
        throwsA(
          isA<TrError>().having((e) => e.message, 'message', contains('设置')),
        ),
      );
    });

    test('全空输入不发请求', () async {
      Translator.post = (url, key, body) async {
        calls.add(body);
        return '';
      };
      final out = await Translator.translate(['', '  '], 'zh', source: src());
      expect(out, ['', '']);
      expect(calls, isEmpty);
    });
  });

  group('密钥打码', () {
    test('只露头尾', () {
      final s = TrSource(key: 'sk-1234567890abcdef');
      expect(s.maskedKey.startsWith('sk-123'), isTrue);
      expect(s.maskedKey.endsWith('cdef'), isTrue);
      expect(s.maskedKey.contains('••••'), isTrue);
    });

    test('空密钥就是空', () {
      expect(TrSource(key: '').maskedKey, '');
    });
  });
}
