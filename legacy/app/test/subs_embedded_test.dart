import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/subs_util.dart';
import 'package:yunxia_app/core/subtitles.dart';

void main() {
  group('ASS/SSA 解析（外挂和内封都可能给 ASS）', () {
    const ass = '''
[Script Info]
Title: demo
ScriptType: v4.00+

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,{\\i1}Hello there{\\i0}
Dialogue: 0,0:00:04.00,0:00:06.00,Default,,0,0,0,,第一行\\N第二行
Comment: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,别理我
''';

    test('起止时间和文本都认得', () {
      final cues = parseSubtitle(ass);
      expect(cues.length, 2);
      expect(cueStart(cues[0]), closeTo(1.0, 0.001));
      expect(cueEnd(cues[0]), closeTo(3.5, 0.001));
      expect(cueText(cues[0]), 'Hello there'); // 样式标签去掉了
      expect(cueText(cues[1]), '第一行 第二行'); // \N 变空格
    });

    test('Comment 行不算字幕', () {
      final cues = parseSubtitle(ass);
      expect(cues.any((c) => cueText(c).contains('别理我')), isFalse);
    });

    test('SRT 不会被误判成 ASS', () {
      const srt = '1\n00:00:01,000 --> 00:00:02,000\nHi\n';
      final cues = parseSubtitle(srt);
      expect(cues.length, 1);
      expect(cueText(cues.first), 'Hi');
    });
  });

  group('sameNameSubtitle（外挂同名）', () {
    test('中文标签优先：chs 胜过 eng', () {
      final hit = sameNameSubtitle('Show.E01.mkv', [
        'Show.E01.eng.srt',
        'Show.E01.chs.ass',
      ]);
      expect(hit, 'Show.E01.chs.ass');
    });

    test('支持 ass / ssa / vtt，不只是 srt', () {
      expect(sameNameSubtitle('a/b.mkv', ['b.ssa']), 'b.ssa');
      expect(sameNameSubtitle('a/b.mkv', ['b.vtt']), 'b.vtt');
      expect(sameNameSubtitle('a/b.mkv', ['b.ass']), 'b.ass');
    });

    test('完全同名的优先于带语言后缀的', () {
      final hit = sameNameSubtitle('b.mkv', ['b.eng.srt', 'b.srt']);
      expect(hit, 'b.srt');
    });

    test('不相关的文件不认', () {
      expect(sameNameSubtitle('b.mkv', ['c.srt', 'b2.srt']), isNull);
    });

    test('大小写不敏感', () {
      expect(sameNameSubtitle('B.MKV', ['b.CHS.ASS']), 'b.CHS.ASS');
    });
  });
}
