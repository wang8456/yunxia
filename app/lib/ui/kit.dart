/// 旧版前端的界面原子件 —— 所有尺寸/颜色/圆角都照 theme.css 抄，
/// 不许在这里「顺手优化」：改一个值，App 就和网页对不上了。
library;

import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/tokens.dart';
import '../core/ui_icons.dart';
import '../core/app_state.dart';
import 'widgets.dart';


/// 顶栏：品牌块 + 「云匣」+ 右侧头像（对应 .topline / .brand / .avatar）
class BrandBar extends StatelessWidget {
  final VoidCallback? onAvatar;

  const BrandBar({super.key, this.onAvatar});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 19),
      child: Row(
        children: [
          Text(
            '云匣',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              color: tone.ink,
            ),
          ),
          const Spacer(),
          // 没传 onAvatar 就不画这个圆头像：画出来是「看着能点、点了没反应」
          if (onAvatar != null)
          Press(
            onTap: onAvatar,
            scale: 0.94,
            radius: const BorderRadius.all(Radius.circular(99)),
            pressColor: tone.icobg,
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tone.surface,
                shape: BoxShape.circle,
                border: Border.all(color: tone.line),
              ),
              child: Text(
                '我',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: tone.ac,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 页面大标题（26px / 750 / -0.6 字距，对应 .title-row .page-title）
class PageTitle extends StatelessWidget {
  final String text;
  final Widget? action;

  const PageTitle(this.text, {super.key, this.action});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 26,
                height: 1.15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.6,
                color: tone.ink,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// 蓝色文字按钮（.text-btn：12px / 600 / padding 6 2）
class TextButton2 extends StatelessWidget {
  final String label;
  final String? icon;
  final VoidCallback? onTap;
  final bool danger;

  const TextButton2(this.label, {super.key, this.icon, this.onTap, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final c = danger ? const Color(0xFFE45E53) : tone.ac;
    return Press(
      onTap: onTap,
      scale: 0.96,
      radius: const BorderRadius.all(Radius.circular(8)),
      pressColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c),
            ),
            if (icon != null) ...[
              const SizedBox(width: 4),
              UIIcon(icon!, size: 14, color: c),
            ],
          ],
        ),
      ),
    );
  }
}

/// 面包屑（12px，当前层用 ink3）
class Crumbs extends StatelessWidget {
  final List<String> parts;
  final void Function(int index)? onTap;

  const Crumbs({super.key, required this.parts, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0)
              Text('/', style: const TextStyle(fontSize: 12, color: Color(0xFFC2CCDA))),
            Press(
              onTap: onTap == null ? null : () => onTap!(i),
              scale: 0.96,
              radius: const BorderRadius.all(Radius.circular(8)),
              pressColor: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  parts[i],
                  style: TextStyle(
                    fontSize: 12,
                    color: i == parts.length - 1
                        ? const Color(0xFF7890AD)
                        : tone.ac,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 白色分组卡片（.src-group：圆角 18、1px 边、极淡投影，行间 1px 分隔线）
class GroupCard extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry? margin;

  const GroupCard({super.key, required this.children, this.margin});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Container(height: 1, color: tone.line2));
      }
      rows.add(children[i]);
    }
    return Container(
      margin: margin ?? const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: tone.surface,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: tone.line.withValues(alpha: 0.9)),
        boxShadow: [BoxShadow(color: tone.sh, blurRadius: 10, offset: const Offset(0, 2))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}

/// 通用「图标 + 主标题 + 副标题 + 右侧」行（源卡片 / 快捷操作 / 设置项都套这个）
class KitRow extends StatelessWidget {
  final String icon;
  final Color iconBg;
  final Color iconColor;
  final String title;
  final String? sub;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? titleColor;
  final Color? subColor;
  final double iconSize;
  final double iconRadius;
  final double minHeight;
  final bool highlight;

  const KitRow({
    super.key,
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.title,
    this.sub,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.titleColor,
    this.subColor,
    this.iconSize = 30,
    this.iconRadius = 9,
    this.minHeight = 52,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Press(
      onTap: onTap,
      onLongPress: onLongPress,
      scale: 1,
      pressColor: tone.surface2,
      child: Container(
        constraints: BoxConstraints(minHeight: minHeight),
        color: highlight ? tone.acw.withValues(alpha: 0.5) : null,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Container(
              width: iconSize,
              height: iconSize,
              decoration: BoxDecoration(
                // 深色下粉彩底会发亮：同色 20% 叠到 surface 上，前景提亮一点
                color: tone.dark
                    ? Color.alphaBlend(iconBg.withValues(alpha: 0.2), tone.surface)
                    : iconBg,
                borderRadius: BorderRadius.circular(iconRadius),
              ),
              alignment: Alignment.center,
              child: UIIcon(
                icon,
                size: iconSize * 0.6,
                color: tone.dark ? Color.lerp(iconColor, Colors.white, 0.18)! : iconColor,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0,
                      color: titleColor ?? tone.ink,
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      sub!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.3,
                          color: subColor ?? const Color(0xFF8795A8)),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
        ),
      ),
    );
  }
}

/// 右侧「在线/离线」小圆点（.src-st）
class StatusDot extends StatelessWidget {
  final bool on;

  const StatusDot({super.key, this.on = true});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: on ? const Color(0xFF34C759) : const Color(0xFFCCD4E0),
        shape: BoxShape.circle,
        boxShadow: on
            ? [BoxShadow(color: const Color(0xFF34C759).withValues(alpha: 0.12), spreadRadius: 3)]
            : null,
      ),
    );
  }
}

/// 右侧灰色箭头（.src-go）
class Chevron extends StatelessWidget {
  final double size;

  const Chevron({super.key, this.size = 18});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Icon(Icons.chevron_right_rounded, size: size, color: tone.ink3.withValues(alpha: 0.55));
  }
}

/// 小节标题（.home-h h2：14px / 650 / 灰）
class SectionHead extends StatelessWidget {
  final String text;
  final Widget? action;

  const SectionHead(this.text, {super.key, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                  color: const Color(0xFF8795A8)),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// 底部导航（.bottom-nav：4 等分、毛玻璃、10px 文字，选中变蓝加粗）
class NavBar extends StatelessWidget {
  final int index;
  final void Function(int) onSelect;

  /// 对话由服务端 /meta/sources 的 chat.enabled 决定，关掉时连入口都不出现
  final bool chatEnabled;

  const NavBar({
    super.key,
    required this.index,
    required this.onSelect,
    this.chatEnabled = true,
  });

  static List<(String, String)> itemsOf(bool chat) => [
    ('home', '首页'),
    ('folder', '文件'),
    if (chat) ('chat', '对话'),
    ('setting', '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final items = NavBar.itemsOf(chatEnabled);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: tone.dark ? tone.nav : const Color(0xEDFFFFFF),
            border: Border(top: BorderSide(color: tone.line)),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 58,
              child: Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: Press(
                        onTap: () => onSelect(i),
                        scale: 0.94,
                        radius: const BorderRadius.all(Radius.circular(12)),
                        pressColor: Colors.transparent,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            UIIcon(
                              items[i].$1,
                              size: 20,
                              color: index == i ? tone.ac : const Color(0xFF9AA7B8),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              items[i].$2,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: index == i ? FontWeight.w700 : FontWeight.w500,
                                color: index == i ? tone.ac : const Color(0xFF9AA7B8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 侧边导航（平板/桌面 ≥760）：底部栏在平板上太远，改成左侧竖排
class SideNav extends StatelessWidget {
  final int index;
  final void Function(int) onSelect;
  final bool chatEnabled;

  const SideNav({
    super.key,
    required this.index,
    required this.onSelect,
    this.chatEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final items = NavBar.itemsOf(chatEnabled);
    return Container(
      width: 96,
      decoration: BoxDecoration(
        color: tone.dark ? tone.nav : const Color(0xF7FFFFFF),
        border: Border(right: BorderSide(color: tone.line)),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            const SizedBox(height: 20),
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tone.ac.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: UIIcon('folder', size: 21, color: tone.ac),
            ),
            const SizedBox(height: 24),
            for (var i = 0; i < items.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                child: Press(
                  onTap: () => onSelect(i),
                  scale: 0.96,
                  radius: const BorderRadius.all(Radius.circular(13)),
                  pressColor: Colors.transparent,
                  child: AnimatedContainer(
                    duration: Shape.fast,
                    height: 60,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: index == i
                          ? tone.ac.withValues(alpha: tone.dark ? 0.22 : 0.10)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        UIIcon(
                          items[i].$1,
                          size: 21,
                          color: index == i ? tone.ac : const Color(0xFF9AA7B8),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          items[i].$2,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: index == i ? FontWeight.w700 : FontWeight.w500,
                            color: index == i ? tone.ac : const Color(0xFF9AA7B8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

/// 圆形放大镜按钮（文件页右下角那个，不是主操作 FAB）
class RoundFab extends StatelessWidget {
  final String icon;
  final VoidCallback? onTap;

  const RoundFab({super.key, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Press(
      onTap: onTap,
      scale: 0.94,
      radius: const BorderRadius.all(Radius.circular(99)),
      pressColor: tone.acw,
      child: Container(
        width: 50,
        height: 50,
        // 固定尺寸的 Container 一定要给 alignment，否则子图标被拉满整块
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(color: Color(0x262C5D92), blurRadius: 20, offset: Offset(0, 8))
          ],
          border: Border.all(color: tone.line),
        ),
        child: UIIcon(icon, size: 20, color: const Color(0xFF147BFF)),
      ),
    );
  }
}

/// 主操作按钮（渐变蓝，网页版 .fab / .primary）：55×55 圆角 19
class GradFab extends StatelessWidget {
  final String icon;
  final VoidCallback? onTap;

  const GradFab({super.key, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Press(
      onTap: onTap,
      scale: 0.95,
      radius: const BorderRadius.all(Radius.circular(19)),
      pressColor: Colors.transparent,
      child: Container(
        width: 55,
        height: 55,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1681FF), Color(0xFF0868E9)],
          ),
          borderRadius: BorderRadius.circular(19),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF1677F8).withValues(alpha: 0.3),
              blurRadius: 24,
              offset: const Offset(0, 9),
            ),
          ],
        ),
        // 固定 55×55 的 Container 必须给 alignment，否则图标被撑满整块（显示异常）
        alignment: Alignment.center,
        child: UIIcon(icon, size: 26, color: Colors.white),
      ),
    );
  }
}

/// 单行输入弹窗（在线播放贴直链、新建文件夹等都用它）
Future<String?> showTextSheet(
  BuildContext context, {
  required String title,
  String? hint,
  String initial = '',
  String confirm = '确定',
  bool obscure = false,
}) {
  final tone = Theme.of(context).extension<Tone>()!;
  final ctl = TextEditingController(text: initial);
  return showSheet<String>(
    context,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: tone.ink)),
        const SizedBox(height: 14),
        Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: tone.surface2,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: tone.line),
          ),
          alignment: Alignment.centerLeft,
          child: TextField(
            controller: ctl,
            autofocus: true,
            obscureText: obscure,
            style: TextStyle(fontSize: 14, color: tone.ink),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: hint,
              hintStyle: TextStyle(fontSize: 14, color: tone.ink3),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
        ),
        const SizedBox(height: 16),
        PrimaryButton(label: confirm, onTap: () => Navigator.of(ctx).pop(ctl.text)),
      ],
    ),
  );
}

/// 二次确认弹窗（删除 / 退出登录）
Future<bool?> showConfirmSheet(
  BuildContext context, {
  required String title,
  required String text,
  bool danger = false,
  String okText = '确定',
  String cancelText = '取消',
}) {
  final tone = Theme.of(context).extension<Tone>()!;
  return showSheet<bool>(
    context,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: tone.ink)),
        const SizedBox(height: 10),
        Text(text, style: TextStyle(fontSize: 13, height: 1.6, color: tone.ink2)),
        const SizedBox(height: 18),
        Press(
          onTap: () => Navigator.of(ctx).pop(true),
          scale: 0.98,
          pressColor: Colors.transparent,
          child: Container(
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: danger ? const Color(0xFFE45E53) : tone.ac,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Text(okText,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white)),
          ),
        ),
        const SizedBox(height: 8),
        Press(
          onTap: () => Navigator.of(ctx).pop(false),
          scale: 0.98,
          pressColor: tone.surface2,
          child: Container(
            height: 46,
            alignment: Alignment.center,
            child: Text(cancelText, style: TextStyle(fontSize: 14, color: tone.ink2)),
          ),
        ),
      ],
    ),
  );
}


/// 首页「来源」分组（旧版 .src-group：白卡、18 圆角、行间 1px）
class SrcGroup extends StatelessWidget {
  final List<Widget> children;
  const SrcGroup({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(Container(height: 1, color: tone.line2));
      rows.add(children[i]);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: tone.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: tone.line2),
        boxShadow: const [
          BoxShadow(color: Color(0x0A243E5D), blurRadius: 10, offset: Offset(0, 2))
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: rows),
    );
  }
}

/// 来源卡（旧版 .src-card：40 图标 r12、15.5/650 标题、12 副标题、状态点、chevron）
class SrcCard extends StatelessWidget {
  final String icon;
  final Color iconBg;
  final Color iconColor;
  final String title;
  final String sub;
  final bool on;
  final bool online;
  final VoidCallback? onTap;

  const SrcCard({
    super.key,
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.title,
    required this.sub,
    this.on = false,
    this.online = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Press(
      onTap: onTap,
      scale: 1,
      pressColor: tone.surface2,
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        color: on ? tone.acw.withValues(alpha: 0.55) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration:
                  BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(12)),
              alignment: Alignment.center,
              child: UIIcon(icon, size: 22, color: iconColor),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 15.5,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.15,
                          color: on ? tone.ac : tone.ink)),
                  const SizedBox(height: 2),
                  Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, height: 1.3, color: Color(0xFF94A1B3))),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: online ? const Color(0xFF34C759) : const Color(0xFFCCD4E0),
                shape: BoxShape.circle,
                boxShadow: online
                    ? [BoxShadow(color: const Color(0xFF34C759).withValues(alpha: 0.12), spreadRadius: 3)]
                    : null,
              ),
            ),
            const SizedBox(width: 10),
            UIIcon('chevron-right',
                size: 18, color: on ? tone.ac : const Color(0xFFC9D1DD)),
          ],
        ),
      ),
    );
  }
}

/// 动作行（旧版 .quick-row / .stat-row，两行合并成一张卡）
class QuickRow extends StatelessWidget {
  final String icon;
  final String title;
  final String sub;
  final VoidCallback? onTap;
  final bool dividerTop;

  const QuickRow({
    super.key,
    required this.icon,
    required this.title,
    required this.sub,
    this.onTap,
    this.dividerTop = false,
  });

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Press(
      onTap: onTap,
      scale: 1,
      pressColor: tone.surface2,
      child: Container(
        constraints: const BoxConstraints(minHeight: 58),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          border: dividerTop
              ? Border(top: BorderSide(color: tone.line2))
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: tone.acw,
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: UIIcon(icon, size: 15, color: tone.ac),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: tone.ink)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF9AA8BA))),
                  ),
                ],
              ),
            ),
            const UIIcon('chevron-right', size: 15, color: Color(0xFFC2CDDB)),
          ],
        ),
      ),
    );
  }
}

/// 首页小标题（旧版 .home-h h2：14 / 650 / #6b7280）
class HomeH extends StatelessWidget {
  final String text;
  const HomeH(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 10),
      child: Text(text,
          style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B7280))),
    );
  }
}


/// 写操作（上传/改名/删除/新建/移动）前先确保有口令。
/// 以前只有设置页能填口令，用户点上传只弹一句「先去设置填一次」就没了；
/// 现在原地问一次，填对了就把这次操作接着做完。
Future<bool> ensureWrite(BuildContext context, App app) async {
  if (app.canWrite) return true;
  final pw = await showTextSheet(
    context,
    title: '写入口令',
    hint: '填一次就能上传 / 改名 / 删除',
    confirm: '继续',
    obscure: true,
  );
  final v = (pw ?? '').trim();
  if (v.isEmpty) return false;
  final ok = await app.login(v);
  if (!ok) {
    app.toast('口令不对，再试一次');
    return false;
  }
  return app.canWrite;
}
