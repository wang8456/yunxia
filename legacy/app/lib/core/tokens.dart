import 'package:flutter/animation.dart';
import 'package:flutter/material.dart' show ThemeExtension;

/// 云匣设计令牌 —— 与线上 theme.css 一一对应，界面代码不许写死颜色。
/// 来源：docs/design-tokens.md（从线上 CSS 抽出，三套主题）。
class Tone extends ThemeExtension<Tone> {
  final String id;
  final String label;
  final Color bg;
  final Color bg2;
  final Color surface;
  final Color surface2;
  final Color line;
  final Color line2;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color ac;
  final Color ac2;
  final Color acw;
  final Color onac;
  final Color nav;
  final Color ov;
  final Color sh;
  final Color icobg;
  final bool dark;

  const Tone({
    required this.id,
    required this.label,
    required this.bg,
    required this.bg2,
    required this.surface,
    required this.surface2,
    required this.line,
    required this.line2,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.ac,
    required this.ac2,
    required this.acw,
    required this.onac,
    required this.nav,
    required this.ov,
    required this.sh,
    required this.icobg,
    this.dark = false,
  });

  @override
  Tone copyWith({
    String? id,
    String? label,
    Color? bg,
    Color? bg2,
    Color? surface,
    Color? surface2,
    Color? line,
    Color? line2,
    Color? ink,
    Color? ink2,
    Color? ink3,
    Color? ac,
    Color? ac2,
    Color? acw,
    Color? onac,
    Color? nav,
    Color? ov,
    Color? sh,
    Color? icobg,
    bool? dark,
  }) =>
      Tone(
        id: id ?? this.id,
        label: label ?? this.label,
        bg: bg ?? this.bg,
        bg2: bg2 ?? this.bg2,
        surface: surface ?? this.surface,
        surface2: surface2 ?? this.surface2,
        line: line ?? this.line,
        line2: line2 ?? this.line2,
        ink: ink ?? this.ink,
        ink2: ink2 ?? this.ink2,
        ink3: ink3 ?? this.ink3,
        ac: ac ?? this.ac,
        ac2: ac2 ?? this.ac2,
        acw: acw ?? this.acw,
        onac: onac ?? this.onac,
        nav: nav ?? this.nav,
        ov: ov ?? this.ov,
        sh: sh ?? this.sh,
        icobg: icobg ?? this.icobg,
        dark: dark ?? this.dark,
      );

  /// 主题切换动画会调它：逐字段插值（id/label/dark 不插值，过半就切）
  @override
  Tone lerp(ThemeExtension<Tone>? other, double t) {
    if (other is! Tone) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    final half = t < 0.5;
    return Tone(
      id: half ? id : other.id,
      label: half ? label : other.label,
      bg: c(bg, other.bg),
      bg2: c(bg2, other.bg2),
      surface: c(surface, other.surface),
      surface2: c(surface2, other.surface2),
      line: c(line, other.line),
      line2: c(line2, other.line2),
      ink: c(ink, other.ink),
      ink2: c(ink2, other.ink2),
      ink3: c(ink3, other.ink3),
      ac: c(ac, other.ac),
      ac2: c(ac2, other.ac2),
      acw: c(acw, other.acw),
      onac: c(onac, other.onac),
      nav: c(nav, other.nav),
      ov: c(ov, other.ov),
      sh: c(sh, other.sh),
      icobg: c(icobg, other.icobg),
      dark: half ? dark : other.dark,
    );
  }

  /// 语义色的浅底：把前景色按当前主题淡淡压在 surface 上。
  /// 旧前端 5020 里这类“图标底座”就是 --t-icobg / --t-acw，深色下不会发光。
  Color tint(Color c, [double light = 0.10, double darkA = 0.18]) =>
      Color.alphaBlend(c.withValues(alpha: dark ? darkA : light), surface);

  /// 文件类型图标底色 / 前景
  (Color, Color) iconOf(String kind) {
    switch (kind) {
      case 'dir':
        return dark
            ? (const Color(0xFF182B41), const Color(0xFF63A9FF))
            : (const Color(0xFFE8F2FF), const Color(0xFF1677F8));
      case 'image':
        return dark
            ? (const Color(0xFF14322A), const Color(0xFF43D09B))
            : (const Color(0xFFE5F8EF), const Color(0xFF0E9D78));
      case 'video':
        return dark
            ? (const Color(0xFF251F3E), const Color(0xFFA78BFA))
            : (const Color(0xFFEFEAFF), const Color(0xFF7C5CF0));
      case 'audio':
        return dark
            ? (const Color(0xFF2A2142), const Color(0xFFBD9AF7))
            : (const Color(0xFFF2ECFB), const Color(0xFF8859DC));
      case 'pdf':
        return dark
            ? (const Color(0xFF33201F), const Color(0xFFF4796C))
            : (const Color(0xFFFDEBEA), const Color(0xFFC9403A));
      case 'code':
        return dark
            ? (const Color(0xFF122E34), const Color(0xFF4EC8D8))
            : (const Color(0xFFE6F6FB), const Color(0xFF0E8EA3));
      case 'archive':
        return dark
            ? (const Color(0xFF32261A), const Color(0xFFE0B072))
            : (const Color(0xFFF9EBD8), const Color(0xFF96631F));
      case 'text':
        return dark
            ? (const Color(0xFF232A33), const Color(0xFF9FB3CC))
            : (const Color(0xFFEDF1F7), const Color(0xFF3D6396));
      default:
        return dark
            ? (const Color(0xFF232A33), const Color(0xFF9FB3CC))
            : (const Color(0xFFEDF1F7), const Color(0xFF3D6396));
    }
  }
}

class Tokens {
  /// 默认（蓝）
  static const blue = Tone(
    id: 'blue',
    label: '蓝色',
    bg: Color(0xFFF4F7FC),
    bg2: Color(0xFFF7F9FD),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF7FAFE),
    line: Color(0xFFE9EEF5),
    line2: Color(0xFFF2F5F9),
    ink: Color(0xFF26364A),
    ink2: Color(0xFF5D7391),
    ink3: Color(0xFF9AA8BA),
    ac: Color(0xFF1677F8),
    ac2: Color(0xFF0868E9),
    acw: Color(0xFFE7F1FF),
    onac: Color(0xFFFFFFFF),
    nav: Color(0xEDFFFFFF),
    ov: Color(0x5515263E),
    sh: Color(0x0F35639C),
    icobg: Color(0xFFEEF4FF),
  );

  /// 浅（灰）
  static const gray = Tone(
    id: 'light',
    label: '浅色',
    bg: Color(0xFFF2F3F5),
    bg2: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF7F8FA),
    line: Color(0xFFE5E7EB),
    line2: Color(0xFFF0F1F3),
    ink: Color(0xFF2A2A2E),
    ink2: Color(0xFF5C5C63),
    ink3: Color(0xFF9A9AA4),
    ac: Color(0xFF3A3A3C),
    ac2: Color(0xFF1D1D1F),
    acw: Color(0xFFECECEE),
    onac: Color(0xFFFFFFFF),
    nav: Color(0xEDFFFFFF),
    ov: Color(0x57000000),
    sh: Color(0x0D000000),
    icobg: Color(0xFFF0F1F3),
  );

  /// 深
  static const dark = Tone(
    id: 'dark',
    label: '深色',
    bg: Color(0xFF121417),
    bg2: Color(0xFF0E1013),
    surface: Color(0xFF1A1D21),
    surface2: Color(0xFF22262B),
    line: Color(0xFF2B3037),
    line2: Color(0xFF23272C),
    ink: Color(0xFFE2E5E9),
    ink2: Color(0xFF9BA5B1),
    ink3: Color(0xFF6F7782),
    ac: Color(0xFF4C9AFF),
    ac2: Color(0xFF3B82F6),
    acw: Color(0xFF1B2735),
    onac: Color(0xFFFFFFFF),
    nav: Color(0xED121417),
    ov: Color(0x9E000000),
    sh: Color(0x73000000),
    icobg: Color(0xFF262C34),
    dark: true,
  );


  /// 绿（旧版 data-theme=green）
  static const green = Tone(
    id: 'green',
    label: '绿色',
    bg: Color(0xFFF6F8F7),
    bg2: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF2F6F4),
    line: Color(0xFFE5EBE8),
    line2: Color(0xFFEFF4F1),
    ink: Color(0xFF1C2420),
    ink2: Color(0xFF5A6A62),
    ink3: Color(0xFF95A49C),
    ac: Color(0xFF0FA452),
    ac2: Color(0xFF0B8A45),
    acw: Color(0xFFE6F9EF),
    onac: Color(0xFFFFFFFF),
    nav: Color(0xF0FFFFFF),
    ov: Color(0x54102819),
    sh: Color(0x0F0A502D),
    icobg: Color(0xFFEAF7F0),
  );

  /// 米黄（旧版 data-theme=sepia）
  static const sepia = Tone(
    id: 'sepia',
    label: '护眼',
    bg: Color(0xFFF4EFE3),
    bg2: Color(0xFFFAF6EC),
    surface: Color(0xFFFBF7EE),
    surface2: Color(0xFFF2ECDD),
    line: Color(0xFFE4DBC7),
    line2: Color(0xFFEFE7D7),
    ink: Color(0xFF4B4335),
    ink2: Color(0xFF6F6656),
    ink3: Color(0xFF9C9280),
    ac: Color(0xFFB07D3A),
    ac2: Color(0xFF8F6329),
    acw: Color(0xFFEFE3CC),
    onac: Color(0xFFFFFFFF),
    nav: Color(0xF0FAF6EC),
    ov: Color(0x57433D31),
    sh: Color(0x12785F32),
    icobg: Color(0xFFF1E9D8),
  );

  /// 顺序照 5020 旧前端的主题弹窗：浅色 / 深色 / 蓝色 / 绿色 / 护眼
  static const all = [gray, dark, blue, green, sepia];

  static Tone byId(String id) =>
      all.firstWhere((t) => t.id == id, orElse: () => blue);
}

/// 形状与节奏（与网页版一致）
class Shape {
  static const r9 = 9.0;
  static const r11 = 11.0;
  static const r12 = 12.0;
  static const r14 = 14.0;
  static const r15 = 15.0;
  static const r16 = 16.0;
  static const r17 = 17.0;
  static const r19 = 19.0;
  static const r20 = 20.0;
  static const r22 = 22.0;
  static const capsule = 999.0;

  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 340);
  static const curve = Curves.easeOut;
}
