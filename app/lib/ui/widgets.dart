import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/app_icons.dart';
import '../core/tokens.dart';

/// 无波纹点击区：按下缩到 0.97 + 变色，与网页版 `:active{transform:scale(.97)}` 一致。
class Press extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? pressColor;
  final double scale;
  final BorderRadius? radius;
  final Duration duration;

  const Press({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressColor,
    this.scale = 0.975,
    this.radius,
    this.duration = Shape.fast,
  });

  @override
  State<Press> createState() => _PressState();
}

class _PressState extends State<Press> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: widget.duration,
        curve: Shape.curve,
        child: AnimatedContainer(
          duration: widget.duration,
          curve: Shape.curve,
          decoration: BoxDecoration(
            color: _down ? (widget.pressColor ?? tone.acw) : Colors.transparent,
            borderRadius: widget.radius,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 毛玻璃条（顶栏 / 底部导航 / 浮层），对应 web 的 backdrop-filter。
class Glass extends StatelessWidget {
  final Widget child;
  final double blur;
  final Color color;
  final BorderRadius? radius;
  final Border? border;
  final List<BoxShadow>? shadow;

  const Glass({
    super.key,
    required this.child,
    required this.color,
    this.blur = 18,
    this.radius,
    this.border,
    this.shadow,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: radius ?? BorderRadius.zero,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: radius,
            border: border,
            boxShadow: shadow,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 文件类型图标底座（43×43 圆角 13）
///
/// 图标与配色都照旧版前端 `手机共享-图标方案.html` 的方案 B（分类配色）：
/// Hugeicons Stroke Rounded 线稿 + 类型色 + 浅色底。
class KindIcon extends StatelessWidget {
  final String kind;
  final double size;
  final double radius;

  const KindIcon(this.kind, {super.key, this.size = 43, this.radius = 13});

  static const _map = <String, String>{
    'dir': 'type-folder',
    'folder': 'type-folder',
    'image': 'type-image',
    'video': 'type-video',
    'audio': 'type-audio',
    'pdf': 'type-pdf',
    'code': 'type-code',
    'archive': 'type-zip',
    'zip': 'type-zip',
    'text': 'type-doc',
    'doc': 'type-doc',
    'file': 'type-file',
  };

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final name = _map[kind] ?? 'type-file';
    // 配色照 5020：八种类型色相固定，主题只换明度（见 kTypeToneByTheme）
    final t = typeTone(_groupOf(kind), tone.id);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: t.bg, borderRadius: BorderRadius.circular(radius)),
      alignment: Alignment.center,
      child: AppIcon(name, size: size * 0.52, color: t.fg),
    );
  }

  /// App 的 kind 比旧前端细，这里归到八种色相上
  static String _groupOf(String kind) {
    switch (kind) {
      case 'dir':
      case 'folder':
        return 'folder';
      case 'image':
        return 'image';
      case 'video':
        return 'video';
      case 'audio':
        return 'audio';
      case 'archive':
      case 'zip':
        return 'zip';
      case 'code':
        return 'code';
      case 'pdf':
        return 'pdf';
      case 'text':
      case 'doc':
      case 'file':
      default:
        return 'doc';
    }
  }
}

/// 卡片：白底 + 极淡阴影 + 细边（网页版 surface）
class SurfaceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  final bool shadow;

  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.radius = Shape.r16,
    this.color,
    this.shadow = true,
  });

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? tone.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: tone.line, width: 1),
        boxShadow: shadow
            ? [BoxShadow(color: tone.sh, blurRadius: 13, offset: const Offset(0, 4))]
            : null,
      ),
      child: child,
    );
  }
}

/// 底部弹窗（圆角 22、抓手、最多 88% 高），对应 web 的 .sheet
Future<T?> showSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) {
  final tone = Theme.of(context).extension<Tone>()!;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: tone.ov,
    transitionAnimationController: BottomSheet.createAnimationController(
      Navigator.of(context),
    )..duration = Shape.base,
    builder: (ctx) {
      final maxH = MediaQuery.of(ctx).size.height * 0.88;
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Container(
          decoration: BoxDecoration(
            color: tone.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(Shape.r22)),
            boxShadow: [BoxShadow(color: tone.sh, blurRadius: 45, offset: const Offset(0, -12))],
          ),
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 22,
            bottom: 22 + MediaQuery.of(ctx).padding.bottom,
          ),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    height: 4,
                    width: 40,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: tone.line,
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                ),
                builder(ctx),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// 顶部轻提示（网页版 toast：深蓝底、圆角 12、淡入上移）
class ToastOverlay extends StatelessWidget {
  final String? text;
  final double bottom;

  const ToastOverlay({super.key, required this.text, this.bottom = 160});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final show = text != null && text!.isNotEmpty;
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottom,
      child: IgnorePointer(
        child: AnimatedSlide(
          offset: show ? Offset.zero : const Offset(0, 0.4),
          duration: Shape.base,
          curve: Shape.curve,
          child: AnimatedOpacity(
            opacity: show ? 1 : 0,
            duration: Shape.base,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                constraints: const BoxConstraints(maxWidth: 320),
                decoration: BoxDecoration(
                  color: tone.dark ? const Color(0xFF2B3037) : const Color(0xFF1D2E46),
                  borderRadius: BorderRadius.circular(Shape.r12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Text(
                  text ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 主按钮（渐变 + 投影，网页版 .fab / .primary）
class PrimaryButton extends StatelessWidget {
  final String label;
  final String? icon;
  final VoidCallback? onTap;
  final bool dense;

  const PrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Press(
      onTap: onTap,
      radius: BorderRadius.circular(Shape.r12),
      pressColor: tone.ac2.withValues(alpha: 0.15),
      child: Container(
        height: dense ? 40 : 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tone.ac, tone.ac2],
          ),
          borderRadius: BorderRadius.circular(Shape.r12),
          boxShadow: [
            BoxShadow(
              color: tone.ac.withValues(alpha: 0.24),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              AppIcon(icon!, size: 18, color: tone.onac),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: TextStyle(
                color: tone.onac,
                fontSize: dense ? 13 : 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空态：图标 + 一行说明
class EmptyState extends StatelessWidget {
  final String icon;
  final String text;
  final String? hint;

  const EmptyState({super.key, required this.icon, required this.text, this.hint});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: tone.icobg, shape: BoxShape.circle),
            child: AppIcon(icon, size: 28, color: tone.ink3),
          ),
          const SizedBox(height: 14),
          Text(text, style: TextStyle(fontSize: 13, color: tone.ink2, fontWeight: FontWeight.w600)),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(hint!, style: TextStyle(fontSize: 11, color: tone.ink3), textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}
