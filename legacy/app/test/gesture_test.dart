import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/gestures.dart';

void main() {
  group('decideGesture：一根手指只做一件事', () {
    test('几乎没动 → 不定性（留给长按/点击）', () {
      expect(decideGesture(const Offset(3, 2), 100, 400), GestMode.none);
      expect(decideGesture(Offset.zero, 100, 400), GestMode.none);
    });

    test('抖动刚过阈值仍算 none', () {
      expect(decideGesture(const Offset(10, 8), 100, 400), GestMode.none);
    });

    test('横向为主 → 拖进度（不管在哪半边）', () {
      expect(decideGesture(const Offset(40, 6), 100, 400), GestMode.seek);
      expect(decideGesture(const Offset(-40, 6), 300, 400), GestMode.seek);
      expect(decideGesture(const Offset(15, 14), 300, 400), GestMode.seek);
    });

    test('竖向为主且按在左半屏 → 亮度', () {
      expect(decideGesture(const Offset(4, -40), 100, 400), GestMode.bri);
      expect(decideGesture(const Offset(6, 30), 199, 400), GestMode.bri);
    });

    test('竖向为主且按在右半屏 → 音量', () {
      expect(decideGesture(const Offset(4, -40), 300, 400), GestMode.vol);
      expect(decideGesture(const Offset(-6, 30), 201, 400), GestMode.vol);
    });

    test('判定看按下点，不看当前位置（从右半屏划到左半边仍是音量）', () {
      // 起点 380 在右半屏，累计已经划到 -60（当前点理论在左侧）也还是音量
      expect(decideGesture(const Offset(-30, 60), 380, 400), GestMode.vol);
    });

    test('45 度斜向：横向略占优就算拖进度，不会两边都动', () {
      expect(decideGesture(const Offset(20, 19), 50, 400), GestMode.seek);
      expect(decideGesture(const Offset(19, 20), 50, 400), GestMode.bri);
    });

    test('自定义 slop 生效', () {
      expect(decideGesture(const Offset(6, 0), 0, 400, slop: 4), GestMode.seek);
    });
  });

  group('定性后不改判（互斥的核心保证）', () {
    test('已经在拖进度：手抬高也不变成音量', () {
      var m = advanceMode(GestMode.none, const Offset(40, 0), 300, 400);
      expect(m, GestMode.seek);
      m = advanceMode(m, const Offset(40, 200), 300, 400); // 后面竖着走了一大段
      expect(m, GestMode.seek);
    });

    test('已经在调音量：手转横向也不变成拖进度', () {
      var m = advanceMode(GestMode.none, const Offset(2, -40), 300, 400);
      expect(m, GestMode.vol);
      m = advanceMode(m, const Offset(-200, -40), 300, 400);
      expect(m, GestMode.vol);
    });

    test('长按加速期间：后续任何移动都不改模式', () {
      var m = advanceMode(GestMode.speed, const Offset(300, 0), 300, 400);
      expect(m, GestMode.speed);
      m = advanceMode(m, const Offset(-300, 300), 10, 400);
      expect(m, GestMode.speed);
    });

    test('还没定性才会重新判（抖动阶段）', () {
      expect(
        advanceMode(GestMode.none, const Offset(5, 5), 10, 400),
        GestMode.none,
      );
      expect(
        advanceMode(GestMode.none, const Offset(30, 5), 10, 400),
        GestMode.seek,
      );
    });
  });

  group('lpRateAt：长按调速以「当前倍数」为基准', () {
    test('不动就不变（不会从 2.0 起跳）', () {
      expect(lpRateAt(1.0, 0), 1.0);
      expect(lpRateAt(1.25, 0), 1.25);
      expect(lpRateAt(0.75, 0), 0.75);
    });

    test('右滑加速、左滑减速，110px 一级', () {
      expect(lpRateAt(1.0, 110), closeTo(2.0, 0.001));
      expect(lpRateAt(1.0, -110), closeTo(0.5, 0.001)); // 0 被下限截住
      expect(lpRateAt(2.0, 55), closeTo(2.5, 0.001));
      expect(lpRateAt(2.0, -165), closeTo(0.5, 0.001));
    });

    test('上下限 0.5x–4x', () {
      expect(lpRateAt(4.0, 500), 4.0);
      expect(lpRateAt(0.5, -500), 0.5);
    });

    test('手滑过头再滑回来能回到原值（基准不变）', () {
      const base = 1.5;
      expect(lpRateAt(base, 300), 4.0);
      expect(lpRateAt(base, 0), 1.5);
    });
  });
}
