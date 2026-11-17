import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/subs_tr.dart';

void main() {
  test('已译好的译文套回去，不覆盖已有译文', () {
    final cues = <dynamic>[
      [0.0, 1.0, 'hello'],
      [1.0, 2.0, 'world', '已有'],
      [2.0, 3.0, 'again'],
    ];
    final n = applyTrCache(['你好', '世界', '再来'], cues);
    expect(n, 2);
    expect(cues[0][3], '你好');
    expect(cues[1][3], '已有');
    expect(cues[2][3], '再来');
  });

  test('缓存比字幕短（转写到 97%）也照样套，不要求句数相等', () {
    final cues = <dynamic>[
      [0.0, 1.0, 'a'],
      [1.0, 2.0, 'b'],
      [2.0, 3.0, 'c'],
    ];
    expect(applyTrCache(['甲', '乙'], cues), 2);
    expect(cues[2].length, 3);
  });

  test('空译文跳过，不写空串', () {
    final cues = <dynamic>[
      [0.0, 1.0, 'a'],
      [1.0, 2.0, 'b'],
    ];
    expect(applyTrCache(['', '乙'], cues), 1);
    expect(cues[0].length, 3);
  });

  test('只有三条元素的 cue 也能补上第四条', () {
    final cues = <dynamic>[
      [0.0, 1.0, 'x'],
    ];
    expect(applyTrCache(['叉'], cues), 1);
    expect(cues[0][3], '叉');
  });
}
