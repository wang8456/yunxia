import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/langs.dart';

void main() {
  group('音轨标签：能认出语言就写语言，别只剩音轨N', () {
    test('三字母语言码 → 中文名 + 声道', () {
      expect(audioTrackLabel({'lang': 'eng', 'ch': 6}, 0), '英语 5.1');
      expect(audioTrackLabel({'lang': 'spa', 'ch': 6}, 1), '西语 5.1');
      expect(audioTrackLabel({'lang': 'ita', 'ch': 2}, 2), '意语 立体声');
      expect(audioTrackLabel({'lang': 'kor', 'ch': 0}, 3), '韩语');
    });

    test('两字母码也认', () {
      expect(audioTrackLabel({'lang': 'en', 'ch': 2}, 0), '英语 立体声');
      expect(audioTrackLabel({'lang': 'JA', 'ch': 6}, 0), '日语 5.1');
    });

    test('有 title 就用 title（导演评论这类）', () {
      expect(
        audioTrackLabel({'lang': 'eng', 'title': '导演评论', 'ch': 2}, 0),
        '导演评论 立体声',
      );
    });

    test('认不出语言才退回音轨N', () {
      expect(audioTrackLabel({}, 2), '音轨3');
      expect(audioTrackLabel({'lang': '', 'ch': 6}, 0), '音轨1 5.1');
      expect(audioTrackLabel({'lang': 'xyz', 'ch': 0}, 4), '音轨5');
    });
  });
}
