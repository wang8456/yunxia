import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';
import 'kit.dart';
import 'storage_card.dart';
import 'widgets.dart';

/// 首页「我的储存」—— 照旧版 home 视图：
/// 品牌栏 → 大标题 → 来源分组卡 → 收藏 → 储存占用大卡（磁盘 + 文件分析）。
class HomePage extends StatefulWidget {
  final App app;
  final void Function(String src) onOpenSource;
  final void Function(String src, String path) onOpenPath;
  final VoidCallback onAvatar;

  const HomePage({
    super.key,
    required this.app,
    required this.onOpenSource,
    required this.onOpenPath,
    required this.onAvatar,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  App get app => widget.app;

  /// 首页储存卡：磁盘占用 + 文件类型分析（服务端异步扫描，扫描中每 1.2s 再拉一次）
  Map<String, dynamic>? _ana;
  String? _anaErr;
  Timer? _anaTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAna());
  }

  @override
  void dispose() {
    _anaTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadAna() async {
    _anaTimer?.cancel();
    _anaTimer = null;
    try {
      final r = await app.api.storageAnalysis(app.source);
      if (!mounted) return;
      setState(() {
        _ana = r;
        _anaErr = null;
      });
      if (r['scanning'] == true) {
        _anaTimer = Timer(const Duration(milliseconds: 1200), _loadAna);
      }
    } catch (_) {
      if (mounted) setState(() => _anaErr = '读不到储存信息');
    }
  }

  /// 副标题/图标都以服务端 `/meta/sources` 为准（和网页 sources.json 同源），
  /// 只有老服务端没有 sub 字段时才退回本地兜底文案。
  static String _subOf(Map<String, dynamic> s) {
    final sub = (s['sub'] as String? ?? '').trim();
    if (sub.isNotEmpty) return sub;
    switch (s['kind'] as String? ?? '') {
      case 'local':
        return '本机磁盘';
      case 'dufs':
        return 'HTTP 文件服务';
      case 'webdav':
        return 'WebDAV 网盘 · 只读';
      default:
        return '远程目录';
    }
  }

  /// 图标形状区分来源，颜色一律跟主题（照 5020 的 .src-ico）
  static (String, Color, Color) _iconOf(Map<String, dynamic> s, Tone tone) {
    final kind = s['kind'] as String? ?? '';
    final id = s['id'] as String? ?? '';
    final icon = kind == 'webdav'
        ? 'src-cloud'
        : kind == 'dufs'
            ? 'src-pc'
            : (id == 'nas' || id == 'local')
                ? 'src-nas'
                : 'src-disk';
    return (icon, tone.acw, tone.ac);
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final sources = app.sources;
    final favs = app.favorites;
    // 平板：来源一栏 + 收藏/动作一栏并排，别把 1040 的宽度浪费成一条长列
    final wide = MediaQuery.of(context).size.width >= 760;

    final srcBlock = sources.isEmpty
        ? const SizedBox.shrink()
        : SrcGroup(
            children: [
              for (final s in sources)
                Builder(builder: (ctx) {
                  final id = s['id'] as String? ?? '';
                  final (icon, bg, fg) = _iconOf(s, tone);
                  return SrcCard(
                    icon: icon,
                    iconBg: bg,
                    iconColor: fg,
                    title: s['name'] as String? ?? id,
                    sub: _subOf(s),
                    on: app.source == id,
                    onTap: () => widget.onOpenSource(id),
                  );
                }),
            ],
          );

    final favBlock = favs.isEmpty
        ? Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: tone.tint(tone.ink3, 0.08, 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: UIIcon('star', size: 18, color: tone.ink3),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text('还没有收藏',
                          style: TextStyle(
                              fontSize: 13,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF8B95A3))),
                      SizedBox(height: 2),
                      Text('在「文件」里点文件夹的 ⋯ → 收藏到首页',
                          maxLines: 2,
                          style: TextStyle(
                              fontSize: 11.5,
                              height: 1.3,
                              color: Color(0xFFAAB3C0))),
                    ],
                  ),
                ),
              ],
            ),
          )
        : SrcGroup(
            children: [
              for (final f in favs)
                Press(
                  onTap: () => widget.onOpenPath(
                    f['src'] as String? ?? 'nas',
                    f['path'] as String,
                  ),
                  scale: 1,
                  pressColor: tone.surface2,
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 64),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: tone.tint(const Color(0xFFE2A33C), 0.14, 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: const UIIcon('folder', size: 19, color: Color(0xFFE2A33C)),
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                (f['name'] as String? ?? '').isEmpty
                                    ? f['path'] as String
                                    : f['name'] as String,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 15.5,
                                    height: 1.2,
                                    fontWeight: FontWeight.w600,
                                    color: tone.ink),
                              ),
                              const SizedBox(height: 2),
                              Text(f['path'] as String? ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF94A1B3))),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Press(
                          onTap: () => app.removeFavorite(f['path'] as String),
                          scale: 0.9,
                          radius: const BorderRadius.all(Radius.circular(10)),
                          pressColor: tone.tint(const Color(0xFFF0A92E), 0.10, 0.16),
                          child: const SizedBox(
                            width: 34,
                            height: 34,
                            child: Center(
                              child: UIIcon('star', size: 16, color: Color(0xFFF0A92E)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );

    // 磁盘占用 + 文件分析大卡（原来的「在线播放 / 听译服务」两行已按要求删掉）
    final actionBlock = StorageCard(ana: _ana, err: _anaErr, onRefresh: _loadAna);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(wide ? 28 : 19, 18, wide ? 28 : 19, 0),
          child: BrandBar(onAvatar: widget.onAvatar),
        ),
        // 磁盘占用 + 文件分析：放最上面（原来的在线播放 / 听译服务两行已删）
        Padding(
          padding: EdgeInsets.fromLTRB(wide ? 28 : 16, 16, wide ? 28 : 16, 0),
          child: actionBlock,
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: wide ? 24 : 16),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [srcBlock, const SizedBox(height: 90)],
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      flex: 4,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const HomeH('收藏'),
                          favBlock,
                          const SizedBox(height: 90),
                        ],
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    srcBlock,
                    const HomeH('收藏'),
                    favBlock,
                    const SizedBox(height: 90),
                  ],
                ),
        ),
      ],
    );
  }
}
