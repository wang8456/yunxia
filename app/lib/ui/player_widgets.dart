part of 'player_page.dart';

/// 旧版那条进度条：4px（拖拽时 6px）、灰白缓冲层、蓝渐变填充、右端白色圆钮
class _ScrubBar extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool dragging;
  final Duration dragPos;
  final void Function(Duration) onDrag;
  final void Function(Duration) onSeek;

  const _ScrubBar({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.dragging,
    required this.dragPos,
    required this.onDrag,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    final total = duration.inMilliseconds <= 0 ? 1 : duration.inMilliseconds;
    final cur = (dragging ? dragPos : position).inMilliseconds.clamp(0, total);
    final buf = buffered.inMilliseconds.clamp(0, total);

    return LayoutBuilder(
      builder: (ctx, cons) {
        final w = cons.maxWidth;
        final h = dragging ? 6.0 : 4.0;
        void handle(Offset o, {required bool end}) {
          final ms = ((o.dx.clamp(0, w) / w) * total).round();
          final d = Duration(milliseconds: ms);
          if (end) {
            onSeek(d);
          } else {
            onDrag(d);
          }
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => handle(d.localPosition, end: false),
          onHorizontalDragUpdate: (d) => handle(d.localPosition, end: false),
          onHorizontalDragEnd: (_) => onSeek(dragging ? dragPos : position),
          onTapDown: (d) => handle(d.localPosition, end: false),
          onTapUp: (d) => handle(d.localPosition, end: true),
          child: SizedBox(
            height: 22,
            child: Center(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: w,
                    height: h,
                    decoration: BoxDecoration(
                      color: const Color(0x80000000),
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(
                        color: const Color(0x2EFFFFFF),
                        width: 1,
                      ),
                    ),
                  ),
                  Container(
                    width: w * (buf / total),
                    height: h,
                    decoration: BoxDecoration(
                      color: const Color(0x73FFFFFF),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  Container(
                    width: w * (cur / total),
                    height: h,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1681FF), Color(0xFF48A8FF)],
                      ),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  Positioned(
                    left: (w * (cur / total) - 6).clamp(-6, w - 6),
                    top: (h - 12) / 2,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x8C000000),
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 工具条按钮：白色 14% 底、圆角 11、38 高（旧版 .vp-btn）
class _VpBtn extends StatelessWidget {
  final String? icon;
  final bool small;
  final bool gradient;
  final bool active;
  final double iconSize;
  final VoidCallback onTap;

  const _VpBtn({
    this.icon,
    this.small = false,
    this.gradient = false,
    this.active = false,
    this.iconSize = 19,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(
          minWidth: gradient ? 52 : (small ? 34 : 42),
        ),
        height: small ? 34 : 38,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: gradient ? null : Color(active ? 0x40FFFFFF : 0x24FFFFFF),
          gradient: gradient
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1681FF), Color(0xFF0868E9)],
                )
              : null,
          borderRadius: BorderRadius.circular(11),
        ),
        alignment: Alignment.center,
        child: icon == null
            ? const SizedBox.shrink()
            : UIIcon(icon!, size: iconSize, color: Colors.white),
      ),
    );
  }
}

/// 播放设置面板里的两枚按钮（画中画 / 从头播放）
class _MenuAction extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback onTap;
  const _MenuAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 42,
          decoration: BoxDecoration(
            color: const Color(0x1FFFFFFF),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              UIIcon(icon, size: 17, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 上一集/下一集圆钮（旧版 .vp-nav：46 圆、白 13% 底）
class _NavBtn extends StatelessWidget {
  final String icon;
  final VoidCallback onTap;
  const _NavBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: 0.5,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0x24FFFFFF),
            borderRadius: BorderRadius.circular(11),
          ),
          alignment: Alignment.center,
          child: UIIcon(icon, size: 24, color: Colors.white),
        ),
      ),
    );
  }
}

/// 深色面板里的选项胶囊（播放设置 / 字幕面板共用同一套尺寸与配色）
class _PanelChip extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback? onTap;

  const _PanelChip({required this.label, required this.on, this.onTap});

  @override
  Widget build(BuildContext context) {
    const c = Color(0xFF1677F8);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: on ? c : const Color(0x1FFFFFFF),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: on ? Colors.white : const Color(0xFFCFCFD4),
          ),
        ),
      ),
    );
  }
}

/// 深色面板底部的整条操作按钮（字幕面板用）
class _PanelBtn extends StatelessWidget {
  final String label;
  final String? icon;
  final VoidCallback? onTap;
  final bool primary;

  const _PanelBtn({
    required this.label,
    this.icon,
    this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 42,
          decoration: BoxDecoration(
            color: primary ? null : const Color(0x1FFFFFFF),
            gradient: primary
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF1681FF), Color(0xFF0868E9)],
                  )
                : null,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                UIIcon(icon!, size: 17, color: Colors.white),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
