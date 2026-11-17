// 字幕层的纯逻辑：不信网络、不建界面，只验「哪一秒是哪句」和「双语怎么拼」。
// 这两件事错了，播放器上要么整片没字幕、要么译文和原文对不上，
// 但它们跟 UI 无关，值得单独钉死。

import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/ui/player_subs_layer.dart';

void main() {
  group('parseSubLines', () {
    test('解析服务端的 [起, 止, 原文, 译文] 四元组', () {
      final lines = parseSubLines([
        [0.0, 1.5, 'こんにちは', '你好'],
        [1.5, 3.0, 'さようなら', ''],
      ]);
      expect(lines.length, 2);
      expect(lines[0].start, 0.0);
      expect(lines[0].end, 1.5);
      expect(lines[0].text, 'こんにちは');
      expect(lines[0].trans, '你好');
      expect(lines[0].hasTrans, isTrue);
      expect(lines[1].hasTrans, isFalse);
    });

    test('坏数据不吃异常：null / 空 / 缺字段一律跳过', () {
      expect(parseSubLines(null), isEmpty);
      expect(parseSubLines(const []), isEmpty);
      final lines = parseSubLines([
        null,
        'x',
        [1, 2], // 少一列
        [3, 4, 'ok'],
      ]);
      expect(lines.length, 1);
      expect(lines.single.text, 'ok');
      expect(lines.single.trans, '');
    });
  });

  group('subIndexAt（二分查找）', () {
    final lines = parseSubLines([
      [0.0, 1.9, 'a'],
      [2.0, 3.9, 'b'],
      [4.0, 5.9, 'c'],
      [10.0, 12.0, 'd'], // 中间有 4 秒空白
    ]);

    test('落在句内、边界都算这一句', () {
      expect(subIndexAt(lines, 0.0), 0);
      expect(subIndexAt(lines, 1.9), 0);
      expect(subIndexAt(lines, 2.0), 1);
      expect(subIndexAt(lines, 11.2), 3);
    });

    test('句子之间的空白返回 -1（不硬粘上一句）', () {
      expect(subIndexAt(lines, 1.95), -1);
      expect(subIndexAt(lines, 6.5), -1);
      expect(subIndexAt(lines, 99.0), -1);
    });

    test('空列表 / 负数时间不炸', () {
      expect(subIndexAt(const [], 1), -1);
      expect(subIndexAt(lines, -1), -1);
    });

    test('上千句也能对上（二分不会漏）', () {
      final many = [
        for (var i = 0; i < 2000; i++)
          SubLine(start: i * 2.0, end: i * 2.0 + 1.8, text: '第$i句'),
      ];
      expect(subIndexAt(many, 0.5), 0);
      expect(subIndexAt(many, 1999 * 2.0 + 0.9), 1999);
      expect(subIndexAt(many, 1000 * 2.0 + 1.9), -1); // 句间空白
    });
  });

  group('subRows（双语怎么拼）', () {
    const both = SubLine(start: 0, end: 1, text: 'おはよう', trans: '早上好');
    const srcOnly = SubLine(start: 0, end: 1, text: 'おはよう');

    test('关掉就一行都不给', () {
      expect(subRows(both, kSubOff), isEmpty);
    });

    test('单语模式只给原文', () {
      expect(subRows(both, kSubSrc), [const SubRow('おはよう', true)]);
    });

    test('双语模式：译文在上（正文），原文在下（小字）', () {
      final rows = subRows(both, kSubBoth);
      expect(rows.length, 2);
      expect(rows[0], const SubRow('早上好', true));
      expect(rows[1], const SubRow('おはよう', false));
    });

    test('还没翻译时双语模式退化成一行原文，不留空位', () {
      expect(subRows(srcOnly, kSubBoth), [const SubRow('おはよう', true)]);
    });

    test('字号档位越大字号越大，越界不抛', () {
      expect(subFontSize(kSubMid), greaterThan(subFontSize(kSubSmall)));
      expect(subFontSize(kSubLarge), greaterThan(subFontSize(kSubMid)));
      expect(subFontSize(9), subFontSize(kSubLarge));
      expect(subFontSize(-3), subFontSize(kSubSmall));
    });
  });
}
