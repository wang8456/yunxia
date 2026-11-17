import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/subs_util.dart';

void main() {
  group('keepTrByStart（整份重拉要保住译文）', () {
    test('旧译文按起点搬回没有译文的新段落', () {
      final prev = [
        [1.0, 2.0, 'Hello', '你好'],
        [2.5, 3.5, 'World', '世界'],
      ];
      final rows = [
        [1.0, 2.0, 'Hello', ''],
        [2.5, 3.5, 'World', ''],
      ];
      final out = keepTrByStart(prev, rows);
      expect(cueTr(out[0]), '你好');
      expect(cueTr(out[1]), '世界');
      // 不能改到入参
      expect(cueTr(rows[0]), '');
    });

    test('服务端带来译文时以新段落为准', () {
      final prev = [
        [1.0, 2.0, 'Hello', '旧译'],
      ];
      final rows = [
        [1.0, 2.0, 'Hello', '新译'],
      ];
      expect(cueTr(keepTrByStart(prev, rows).first), '新译');
    });

    test('起点对不上就原样返回（不串行）', () {
      final prev = [
        [1.0, 2.0, 'Hello', '你好'],
      ];
      final rows = [
        [9.0, 10.0, 'Bye', ''],
      ];
      final out = keepTrByStart(prev, rows);
      expect(out.length, 1);
      expect(cueTr(out.first), '');
      expect(cueText(out.first), 'Bye');
    });
  });

  group('pickTrCandidates（漏翻：窗口与顺序）', () {
    test('回跳 45 秒的句子也算候选（窗口已放宽到 60 秒）', () {
      final cues = [
        [100.0, 101.0, 'a', ''],
      ];
      expect(pickTrCandidates(cues, 145.0).length, 1);
    });

    test('已有译文的句子不再当候选', () {
      final cues = [
        [100.0, 101.0, 'a', '甲'],
        [101.0, 102.0, 'b', ''],
      ];
      final got = pickTrCandidates(cues, 101.5);
      expect(got.length, 1);
      expect(cueText(got.first), 'b');
    });

    test('一轮最多给 20 句（放大了但仍有上限）', () {
      final cues = [
        for (var i = 0; i < 40; i++) [10.0 + i, 10.5 + i, 'x$i', ''],
      ];
      expect(pickTrCandidates(cues, 30.0).length, 20);
    });

    test('按离播放头最近排序：跳回来先翻眼前这句', () {
      final cues = [
        [20.0, 21.0, 'far', ''],
        [50.0, 51.0, 'near', ''],
      ];
      expect(cueText(pickTrCandidates(cues, 51.2).first), 'near');
    });
  });
}
