/// 播放器手势仲裁：一根手指同一时刻只做一件事。
///
/// 以前四种手势（长按倍速、横向拖进度、左侧竖滑亮度、右侧竖滑音量）
/// 挂在同一个 GestureDetector 上靠竞技场决胜负 —— 按住稍久再拖进度条，
/// 赢的是长按；慢慢竖着划调音量，也可能先被判成长按。改成按下时计时、
/// 越过阈值就按**主方向**定性，定性之后不再改判，直到抬手。
library;

import 'dart:ui' show Offset;

/// 位移小于这个值算「手指抖了」，还不定性。
const double kGestSlop = 14;

/// 长按判定时长（毫秒）。按住超过它且没越过 [kGestSlop] = 长按倍速。
const int kLongPressMs = 500;

enum GestMode {
  /// 还没定性（点按、或刚开始抖）
  none,

  /// 横向：拖进度
  seek,

  /// 右半屏竖向：调音量
  vol,

  /// 左半屏竖向：调亮度
  bri,

  /// 按住不动：长按倍速
  speed,
}

/// 按累计位移定性。横向位移大 → 调进度；竖向位移大 → 看按下的那一半屏幕
/// （左亮度、右音量）。
///
/// [startX] 是按下时的横坐标，[width] 是屏幕宽 —— 判定用**按下点**而不是
/// 当前点，否则从右半屏往左划一点就跳到亮度了。
GestMode decideGesture(
  Offset delta,
  double startX,
  double width, {
  double slop = kGestSlop,
}) {
  if (delta.distance < slop) return GestMode.none;
  if (delta.dx.abs() > delta.dy.abs()) return GestMode.seek;
  return startX < width / 2 ? GestMode.bri : GestMode.vol;
}

/// 定性之后不改判：已经进入某个模式就一路走到底，直到抬手。
///
/// 这是「不冲突」的关键 —— 横向拖进度途中手抬高了，不能突然变成调音量；
/// 长按加速途中横着挪，也不能跳去拖进度条。
GestMode advanceMode(
  GestMode current,
  Offset delta,
  double startX,
  double width,
) {
  if (current != GestMode.none) return current;
  return decideGesture(delta, startX, width);
}

/// 长按调倍速：以**按下那一刻正在播的倍数**为基准，左右滑 110px 变 1x，限 0.5x–4x。
/// 不从设置里的固定值起跳 —— 用户原话：`长按之后倍数不需要从2.0开始`。
double lpRateAt(double base, double dx) => (base + dx / 110).clamp(0.5, 4.0);
