import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/subs_util.dart';

/// 拖动进度条之后字幕还在不在、翻译还对不对 —— 全押在这几个纯函数上。
void main() {
  List<dynamic> cue(double a, double b, String text, [String tr = '']) =>
      <dynamic>[a, b, text, tr];

  group('mergeCues：多条任务的段落合起来', () {
    test('两段窗口（前后的）都留着，按时间排序', () {
      final a = [cue(300, 306, '后半段'), cue(310, 315, '后半段2')];
      final b = [cue(30, 33, '前半段'), cue(60, 64, '前半段2')];
      final m = mergeCues(b, a);
      expect(m.length, 4);
      expect(m.map((c) => cueStart(c)).toList(), [30, 60, 300, 310]);
    });

    test('同一 start 只留一条，新到的译文不会丢', () {
      final old = [cue(10, 12, 'Hello', '你好')];
      final add = [cue(10, 12, 'Hello', '')];
      final m = mergeCues(old, add);
      expect(m.length, 1);
      expect(cueTr(m.single), '你好', reason: '不能把译好的覆盖成没译的');
    });

    test('原文修对了就更新（后到的为准）', () {
      final old = [cue(10, 12, 'Helo', '')];
      final add = [cue(10.004, 12, 'Hello', '')];
      final m = mergeCues(old, add);
      expect(m.single[2], 'Hello');
    });

    test('空列表合并不炸', () {
      expect(mergeCues(const [], const []), isEmpty);
      expect(mergeCues([cue(1, 2, 'a')], const []).length, 1);
    });
  });

  group('cueAt / cuesCover / cuesUntil', () {
    final cues = [cue(0, 2, 'A'), cue(30, 32, 'B'), cue(600, 605, 'C')];

    test('命中当前句', () {
      expect(cueAt(cues, 0.5)?[2], 'A');
      expect(cueAt(cues, 31)?[2], 'B');
      expect(cueAt(cues, 15), isNull);
    });

    test('字幕延迟按秒生效', () {
      // 延迟 1 秒：t=1.5 时应该看的是 0.5 秒那句
      expect(cueAt(cues, 1.5, delay: 1)?.length, isNotNull);
      expect(cueAt(cues, 1.5, delay: -1), isNull);
    });

    test('覆盖判断前后留 1.5 秒容差', () {
      expect(cuesCover(cues, 601), isTrue);
      expect(cuesCover(cues, 606.5), isTrue);
      expect(cuesCover(cues, 607), isFalse);
      expect(cuesCover(cues, 100), isFalse);
    });

    test('cuesUntil 取最晚结束时间', () {
      expect(cuesUntil(cues), 605);
      expect(cuesUntil(const []), 0);
    });
  });

  group('pickTrCandidates：拖回来之后先翻眼前这句', () {
    test('乱序也必须找到（旧实现遇到 a>t+150 就 break，会漏）', () {
      final cues = [
        cue(600, 610, '很后面'),
        cue(30, 33, '眼前这句'),
        cue(40, 44, '下一句'),
      ];
      final w = pickTrCandidates(cues, 30);
      expect(w.map((c) => cueText(c)).toList(), containsAll(['眼前这句', '下一句']));
      expect(cueText(w.first), '眼前这句');
    });

    test('已经译过的不再送', () {
      final cues = [cue(30, 33, 'a', '甲'), cue(40, 44, 'b')];
      final w = pickTrCandidates(cues, 30);
      expect(w.length, 1);
      expect(cueText(w.single), 'b');
    });

    test('离播放头近的优先，最多 20 句', () {
      final cues = [
        for (var i = 0; i < 40; i++) cue(100.0 + i, 101.0 + i, 'line$i'),
      ];
      final w = pickTrCandidates(cues, 130);
      expect(w.length, 20);
      expect(cueText(w.first), 'line30');
      expect(cueText(w[1]), 'line31');
    });

    test('窗口外的不要：太早的不翻、太远的先不翻', () {
      // t=100：往前 30 秒以外的不翻，往后 150 秒以外的不翻（别一次刷整片）
      final cues = [
        cue(10, 12, '太早'),
        cue(100, 103, '眼前'),
        cue(900, 905, '太远'),
      ];
      final w = pickTrCandidates(cues, 100);
      expect(w.map(cueText).toList(), ['眼前']);
    });

    test('空原文跳过', () {
      final cues = [cue(30, 33, ''), cue(31, 34, 'x')];
      expect(pickTrCandidates(cues, 30).length, 1);
    });
  });

  group('shouldRestartLive：拖动后要不要重开实时窗', () {
    const gap = Duration(minutes: 1);

    test('当前位置有字幕 → 什么都不用做', () {
      expect(
        shouldRestartLive(
          t: 600,
          covered: true,
          running: false,
          anchor: 0,
          since: gap,
        ),
        isFalse,
      );
    });

    test('没在转、位置又没字幕 → 必须重开（实时任务转完就停在这儿）', () {
      expect(
        shouldRestartLive(
          t: 900,
          covered: false,
          running: false,
          anchor: 755,
          since: gap,
        ),
        isTrue,
      );
    });

    test('正在转、离推进点不远 → 等它推过来，别抢', () {
      expect(
        shouldRestartLive(
          t: 700,
          covered: false,
          running: true,
          anchor: 690,
          since: gap,
        ),
        isFalse,
      );
      expect(
        shouldRestartLive(
          t: 640,
          covered: false,
          running: true,
          anchor: 690,
          since: gap,
        ),
        isFalse,
      );
    });

    test('正在转，但拖到了很远的地方 → 重开', () {
      expect(
        shouldRestartLive(
          t: 1800,
          covered: false,
          running: true,
          anchor: 700,
          since: gap,
        ),
        isTrue,
      );
      expect(
        shouldRestartLive(
          t: 120,
          covered: false,
          running: true,
          anchor: 700,
          since: gap,
        ),
        isTrue,
      );
    });

    test('8 秒内不重复开（防止疯狂拖动时刷爆队列）', () {
      expect(
        shouldRestartLive(
          t: 1800,
          covered: false,
          running: false,
          anchor: 0,
          since: const Duration(seconds: 3),
        ),
        isFalse,
      );
    });

    test('开头 1 秒内不触发', () {
      expect(
        shouldRestartLive(
          t: 0.5,
          covered: false,
          running: false,
          anchor: 0,
          since: gap,
        ),
        isFalse,
      );
    });
  });

  group('拖回前面：合并后的列表要能同时命中前后两段', () {
    test('窗口 A(0-60) + 窗口 B(300-360)，来回拖都有字幕', () {
      final a = [cue(30, 33, 'A30'), cue(45, 48, 'A45')];
      final b = [cue(300, 303, 'B300'), cue(330, 333, 'B330')];
      final all = mergeCues(a, b);

      expect(cueAt(all, 31)?[2], 'A30'); // 拖回前面
      expect(cueAt(all, 301)?[2], 'B300'); // 再拖到后面
      expect(cueAt(all, 331)?[2], 'B330');
      // 两个窗口之间没转过的空隙：不显示字幕，但要被判定为「没覆盖」→ 重开实时窗
      expect(cueAt(all, 150), isNull);
      expect(cuesCover(all, 150), isFalse);
    });
  });

  group('nextUncovered：落点有字幕就跳到后面第一段空缺', () {
    final cues = [cue(100, 110, 'a'), cue(110.5, 120, 'b'), cue(140, 150, 'c')];

    test('落点在字幕中间 → 顶到这一串连续字幕的结尾', () {
      // 100-110 与 110.5-120 只隔 0.5s（< tol），当成一句话连着看
      expect(nextUncovered(cues, 105), closeTo(120, 0.01));
    });

    test('相接的两句（间隔 < tol）也一路顶过去', () {
      expect(nextUncovered(cues, 110.2), closeTo(120, 0.01));
      expect(nextUncovered(cues, 119.8), closeTo(120, 0.01));
    });

    test('落点本身在空档 → 原地开始，不跳', () {
      expect(nextUncovered(cues, 125), closeTo(125, 0.01));
      expect(nextUncovered(cues, 155), closeTo(155, 0.01));
    });

    test('落点在所有字幕之前 → 原地', () {
      expect(nextUncovered(cues, 10), closeTo(10, 0.01));
    });

    test('一句话都没有 → 原地（负数归零）', () {
      expect(nextUncovered(const [], 42), closeTo(42, 0.01));
      expect(nextUncovered(const [], -5), 0);
    });

    test('乱序输入也能算对', () {
      final messy = [
        cue(140, 150, 'c'),
        cue(100, 110, 'a'),
        cue(110.5, 120, 'b'),
      ];
      expect(nextUncovered(messy, 105), closeTo(120, 0.01));
    });
  });
}
