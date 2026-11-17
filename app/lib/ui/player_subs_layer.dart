/// 播放器的字幕层：叠在视频**真实显示区域**里的一行/两行文字。
///
/// 单独成文件（不塞进 player_page.dart）：那边的状态已经够多了，
/// 这里只留「一句字幕怎么切、怎么拼、怎么画」三件事，
/// 纯逻辑（[subIndexAt] / [subRows] / [parseSubLines]）顺手就能单测。
library;

import 'package:flutter/material.dart';

/// 字幕开关：关 / 只原文 / 双语（译文一行 + 原文小字一行）
const int kSubOff = 0;
const int kSubSrc = 1;
const int kSubBoth = 2;

/// 字号档位：小 / 中 / 大
const int kSubSmall = 0;
const int kSubMid = 1;
const int kSubLarge = 2;

const List<String> kSubModeLabels = ['关', '原文', '双语'];
const List<String> kSubSizeLabels = ['小', '中', '大'];

/// 服务端一句字幕：入点/出点（秒）+ 原文 + 译文（没翻译就是空串）
class SubLine {
  final double start;
  final double end;
  final String text;
  final String trans;

  const SubLine({
    required this.start,
    required this.end,
    this.text = '',
    this.trans = '',
  });

  bool get hasTrans => trans.trim().isNotEmpty;

  @override
  String toString() => 'SubLine($start-$end: $text / $trans)';
}

/// 画面上的一行：primary = 正文字号，否则是下面那行小字原文
class SubRow {
  final String text;
  final bool primary;

  const SubRow(this.text, this.primary);

  @override
  bool operator ==(Object other) =>
      other is SubRow && other.text == text && other.primary == primary;

  @override
  int get hashCode => Object.hash(text, primary);

  @override
  String toString() => 'SubRow(${primary ? 'main' : 'sub'}: $text)';
}

double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

/// 解析服务端给的段落数组：`[[起, 止, 原文, 译文], …]`。
/// 顺手兼容对象形式（`{start,end,text,trans}`），换个字段名也不至于整片没字幕。
List<SubLine> parseSubLines(Object? raw) {
  if (raw is! List || raw.isEmpty) return const [];
  final out = <SubLine>[];
  for (final e in raw) {
    if (e is List && e.length >= 3) {
      out.add(
        SubLine(
          start: _num(e[0]),
          end: _num(e[1]),
          text: '${e[2] ?? ''}',
          trans: e.length > 3 ? '${e[3] ?? ''}' : '',
        ),
      );
    } else if (e is Map) {
      final start = e['start'] ?? e['s'] ?? e['from'];
      final end = e['end'] ?? e['e'] ?? e['to'];
      if (start == null || end == null) continue;
      out.add(
        SubLine(
          start: _num(start),
          end: _num(end),
          text: '${e['text'] ?? e['src'] ?? ''}',
          trans: '${e['trans'] ?? e['dst'] ?? ''}',
        ),
      );
    }
  }
  return out;
}

/// 当前播放位置落在哪一句：二分查找，返回下标；-1 = 这一秒没有字幕。
/// 段落按时间递增（服务端就是这么给的），所以不能线性扫 ——
/// 一部两小时的片子有几千句，播放器每帧都要问一次。
int subIndexAt(List<SubLine> lines, double t) {
  var lo = 0;
  var hi = lines.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final s = lines[mid];
    if (t < s.start) {
      hi = mid - 1;
    } else if (t > s.end) {
      lo = mid + 1;
    } else {
      return mid;
    }
  }
  return -1;
}

/// 这一句在当前模式下要画哪几行。
///
/// 双语 = 上面译文（正文）、下面原文（小字）；没译文就只画原文，
/// 不留一个空的译文位把字幕顶得老高。
List<SubRow> subRows(SubLine l, int mode) {
  final src = l.text.trim();
  final tr = l.trans.trim();
  if (mode == kSubOff) return const [];
  if (mode == kSubSrc) return src.isEmpty ? const [] : [SubRow(src, true)];
  if (tr.isEmpty) return src.isEmpty ? const [] : [SubRow(src, true)];
  return [SubRow(tr, true), if (src.isNotEmpty) SubRow(src, false)];
}

/// 正文/小字的字号（逻辑像素）
double subFontSize(int tier) =>
    const [15.0, 19.0, 24.0][tier.clamp(kSubSmall, kSubLarge)];

/// 描边版文字样式：用同字号、同字重的「空心字」垫在底下当黑边，
/// 白色字幕压在任何画面上都读得清（比 shadow 稳，浅色画面上不糊）。
TextStyle _stroke(TextStyle base) => TextStyle(
  fontSize: base.fontSize,
  height: base.height,
  fontWeight: base.fontWeight,
  letterSpacing: base.letterSpacing,
  fontFamily: base.fontFamily,
  foreground: Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = (base.fontSize ?? 18) * 0.16
    ..strokeJoin = StrokeJoin.round
    ..color = const Color(0xE6000000),
);

/// 字幕层：**只能当 Stack 的直接子节点**（自己就是一个 Positioned）。
///
/// 定位思路：调用方把视频塞在 `AspectRatio(视频比例)` 里，这个 Positioned
/// 的 left/right/bottom 就是**画面本身**的边，不是屏幕的边 ——
/// 竖屏看横片时字幕贴着画面底部走，不会飘到黑边上。
class SubtitleLayer extends StatelessWidget {
  final List<SubLine> lines;
  final double position; // 当前播放位置（秒）
  final int mode;
  final int size;
  final double bottom;

  /// 画面高度小于这个值时字号收一点（手机横屏空间有限）
  final double scale;

  const SubtitleLayer({
    super.key,
    required this.lines,
    required this.position,
    this.mode = kSubOff,
    this.size = kSubMid,
    this.bottom = 14,
    this.scale = 1,
  });

  @override
  Widget build(BuildContext context) {
    if (mode == kSubOff || lines.isEmpty) return const SizedBox.shrink();
    final i = subIndexAt(lines, position);
    if (i < 0) return const SizedBox.shrink();
    final rows = subRows(lines[i], mode);
    if (rows.isEmpty) return const SizedBox.shrink();

    final base = subFontSize(size) * scale.clamp(0.75, 1.35);
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottom,
      child: IgnorePointer(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final r in rows)
                Padding(
                  padding: EdgeInsets.only(top: r.primary ? 0 : base * 0.12),
                  child: _OutlinedText(
                    r.text,
                    style: TextStyle(
                      fontSize: r.primary ? base : base * 0.72,
                      height: 1.3,
                      fontWeight: r.primary ? FontWeight.w600 : FontWeight.w400,
                      color: r.primary ? Colors.white : const Color(0xFFDDE3EC),
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 黑描边 + 白字：两层同位置文字，底下那层只画边
class _OutlinedText extends StatelessWidget {
  final String text;
  final TextStyle style;

  const _OutlinedText(this.text, {required this.style});

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: _stroke(style),
        ),
        Text(text, textAlign: TextAlign.center, style: style),
      ],
    );
  }
}
