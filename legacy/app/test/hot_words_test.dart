import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/subs_util.dart';

void main() {
  group('hotWordsFor', () {
    test('去掉画质/编码标记，保留片名', () {
      final h = hotWordsFor(
        '/TV/我的事说来话长 俺の話は長い\u00a0(2019)/我的事说来话长.My.Story.Is.Long.2019.E01.1080p.WEB-DL.H264.AAC-PTerWEB.mp4',
        '我的事说来话长.My.Story.Is.Long.2019.E01.1080p.WEB-DL.H264.AAC-PTerWEB.mp4',
      );
      expect(h.contains('1080p'), isFalse);
      expect(h.contains('WEB-DL'), isFalse);
      expect(h.contains('H264'), isFalse);
      expect(h.contains('我的事说来话长'), isTrue);
      expect(h.contains('My Story Is Long'), isTrue);
    });

    test('目录名也带进来（剧名常只在目录上）', () {
      final h = hotWordsFor('/动漫/鬼灭之刃 第一季/E01.mkv', 'E01.mkv');
      expect(h.contains('鬼灭之刃'), isTrue);
    });

    test('不超过 180 字', () {
      final h = hotWordsFor('/${'长' * 300}/x.mp4', 'x.mp4');
      expect(h.length, lessThanOrEqualTo(180));
    });

    test('没有目录时不留前导逗号', () {
      final h = hotWordsFor('/movie.mp4', 'movie.mp4');
      expect(h.startsWith(','), isFalse);
      expect(h, 'movie');
    });
  });
}
