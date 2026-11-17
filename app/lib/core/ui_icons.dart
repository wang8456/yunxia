import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'ui_icons_data.dart';

/// 旧版前端的 68 个 SVG 图标（ico-sprite 原样搬运）。
///
/// 用法等同网页 `<svg class="ic"><use href="#ico-home"/></svg>`：
/// 图标内部的 `currentColor` 会换成 [color]，线宽与端点跟网页一致。
class UIIcon extends StatelessWidget {
  const UIIcon(this.name, {super.key, this.size = 22, this.color = const Color(0xFF40536D)});

  final String name;
  final double size;
  final Color color;

  static String _hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

  @override
  Widget build(BuildContext context) {
    final entry = kUiIcons[name];
    if (entry == null) {
      // 名字写错时别白屏：画个灰点，一眼看出漏了哪个
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color.withValues(alpha: .25),
          shape: BoxShape.circle,
        ),
      );
    }
    final (vb, body) = entry;
    final svg = '<svg viewBox="$vb" xmlns="http://www.w3.org/2000/svg">'
        '${body.replaceAll('currentColor', _hex(color))}</svg>';
    return SvgPicture.string(svg, width: size, height: size);
  }
}
