import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_icons.dart';
import '../core/app_state.dart';
import '../core/models.dart';
import '../core/native.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';
import 'image_viewer_page.dart';
import 'kit.dart';
import 'player_page.dart';
import 'search_page.dart';
import 'subs_page.dart';
import 'widgets.dart';

/// 加载占位行：跟真实列表同样的行高和图标底座，避免「点进去先卡一下」
class _SkeletonRow extends StatelessWidget {
  final Tone tone;
  const _SkeletonRow({required this.tone});

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: tone.ink3.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(4),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: tone.ink3.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(11),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [bar(150, 11), const SizedBox(height: 7), bar(80, 9)],
            ),
          ),
          bar(46, 9),
        ],
      ),
    );
  }
}

/// 文件页 —— 结构照旧版前端：品牌栏 → 面包屑 → 大标题(排序) → 列表/网格。
/// 行高、图标底座、字号、右侧大小列全部按 theme.css 的值写。
class BrowsePage extends StatefulWidget {
  final App app;
  const BrowsePage({super.key, required this.app});

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  bool get _grid => widget.app.gridMode;

  /// 多选：长按进选择模式，再点就是勾选
  final _sel = <String>{};
  bool _selMode = false;

  /// 当前列表的归属（源 + 目录）。切源/换目录时多选必须归零，
  /// 否则勾选框会留在旧路径上，底部「已选 N 项」也是旧数字。
  String _scope = '';

  @override
  void initState() {
    super.initState();
    _scope = '${widget.app.source}|${widget.app.path}';
    widget.app.addListener(_onAppChanged);
  }

  @override
  void dispose() {
    widget.app.removeListener(_onAppChanged);
    super.dispose();
  }

  void _onAppChanged() {
    final s = '${widget.app.source}|${widget.app.path}';
    if (s == _scope) return;
    _scope = s;
    if (!mounted) return;
    if (_selMode || _sel.isNotEmpty) {
      setState(() {
        _selMode = false;
        _sel.clear();
      });
    }
  }

  Entry? _entryOf(String path) {
    for (final e in app.entries) {
      if (e.path == path) return e;
    }
    return null;
  }

  void _toggle(Entry e) {
    setState(() {
      if (_sel.contains(e.path)) {
        _sel.remove(e.path);
      } else {
        _sel.add(e.path);
      }
    });
  }

  void _enterSel(Entry e) {
    setState(() {
      _selMode = true;
      _sel.add(e.path);
    });
  }

  void _exitSel() {
    setState(() {
      _selMode = false;
      _sel.clear();
    });
  }

  Future<void> _deleteSel() async {
    final items = _sel.map(_entryOf).whereType<Entry>().toList();
    if (items.isEmpty) return;
    final ok = await showConfirmSheet(
      context,
      title: '删除 ${items.length} 项',
      text: items.length == 1
          ? '「${items.first.name}」删了就没了，NAS 上也不会有备份。'
          : '这 ${items.length} 项删了就没了，NAS 上也不会有备份。',
      danger: true,
    );
    if (ok != true) return;
    if (!mounted) return;
    if (!await ensureWrite(context, app)) return;
    final done = await app.removeMany(items);
    if (done) _exitSel();
  }

  App get app => widget.app;

  static String _mdTime(double mtime) {
    final t = DateTime.fromMillisecondsSinceEpoch((mtime * 1000).round());
    final mm = t.month.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    final hh = t.hour.toString().padLeft(2, '0');
    final mi = t.minute.toString().padLeft(2, '0');
    return '$mm/$dd $hh:$mi';
  }

  static String _kindLabel(Entry e) {
    if (e.isDir) return '文件夹';
    switch (e.kind) {
      case 'image':
        return '图片';
      case 'video':
        return '视频';
      case 'audio':
        return '音频';
      case 'pdf':
        return 'PDF';
      case 'code':
        return '代码';
      case 'archive':
        return '压缩包';
      case 'text':
        return '文本';
      default:
        return e.ext.isEmpty ? '文件' : e.ext.toUpperCase();
    }
  }

  static String _iconName(Entry e) {
    if (e.isDir) return 'type-folder';
    switch (e.kind) {
      case 'image':
        return 'type-image';
      case 'video':
        return 'type-video';
      case 'audio':
        return 'type-audio';
      case 'pdf':
        return 'type-pdf';
      case 'code':
        return 'type-code';
      case 'archive':
        return 'type-zip';
      case 'text':
        return 'type-doc';
      default:
        return 'type-file';
    }
  }

  void _open(Entry e) async {
    if (e.isDir) {
      await app.open(e.path);
      return;
    }
    if (e.kind == 'image') {
      final url = await app.linkOf(e);
      if (url == null || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ImageViewerPage(
            url: url,
            entry: e,
            tone: Theme.of(context).extension<Tone>()!,
            onSave: (x) => app.downloadEntry(x),
            onLink: app.linkOf,
            gallery: app.entries
                .where((x) => !x.isDir && x.kind == 'image')
                .toList(),
          ),
        ),
      );
      return;
    }
    if (e.kind == 'video' || e.kind == 'audio') {
      final url = await app.linkOf(e);
      if (url == null || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayerPage(
            app: app,
            url: url,
            entry: e,
            tone: Theme.of(context).extension<Tone>()!,
            playlist: app.entries
                .where(
                  (x) => !x.isDir && (x.kind == 'video' || x.kind == 'audio'),
                )
                .toList(),
          ),
        ),
      );
      return;
    }
    // 其它类型：本机没有能打开的 App，直接提示，别假装打开了
    app.toast('这类文件请用「下载到本机」或 … 里的菜单');
  }

  // ---------- 弹窗 ----------

  Future<void> _showSort() async {
    final tone = Theme.of(context).extension<Tone>()!;
    await showSheet<void>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '排序',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: tone.ink,
            ),
          ),
          const SizedBox(height: 14),
          for (final (id, label) in [
            ('name', '名称'),
            ('mtime', '修改时间'),
            ('size', '大小'),
          ])
            Press(
              onTap: () {
                Navigator.pop(ctx);
                app.setSort(id);
              },
              scale: 1,
              pressColor: tone.surface2,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 2,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(fontSize: 14.5, color: tone.ink),
                      ),
                    ),
                    if (app.sort == id)
                      UIIcon(
                        app.order == 'asc' ? 'arrow-right' : 'arrow-left',
                        size: 16,
                        color: tone.ac,
                      )
                    else
                      Text('', style: TextStyle(color: tone.ink3)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showActions(Entry e) async {
    final tone = Theme.of(context).extension<Tone>()!;
    final fav = app.isFav(e.path);
    // 字幕作业列表还没拉过：先补一次，否则「已存在任务」永远判不出来，
    // 有作业的文件也会显示成「生成字幕」（点了才发现已经有了）。
    // 只等 1.5 秒：服务器慢/不通时别把长按菜单卡在这儿，请求在后台继续跑，
    // 下次再点就是准的。
    if (app.subsEnabled && !app.subsLoaded) {
      await app
          .refreshSubs()
          .timeout(const Duration(milliseconds: 1500), onTimeout: () => false);
    }
    if (!mounted) return;
    final subsJob = app.subsEnabled && !e.isDir ? app.subsJobFor(app.source, e.path) : null;
    await showSheet<void>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              e.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: tone.ink,
              ),
            ),
          ),
          Text(
            '${_mdTime(e.mtime)} · ${_kindLabel(e)}',
            style: TextStyle(fontSize: 12, color: tone.ink3),
          ),
          const SizedBox(height: 14),
          _SheetRow(
            icon: e.isDir ? 'folder' : 'open-new',
            label: e.isDir ? '打开' : '打开 / 预览',
            onTap: () {
              Navigator.pop(ctx);
              _open(e);
            },
          ),
          if (!e.isDir)
            _SheetRow(
              icon: 'download',
              label: '下载到本机',
              onTap: () {
                Navigator.pop(ctx);
                app.downloadEntry(e);
              },
            ),
          // 视频/音频：排听译。已经有作业就变成「查看字幕作业」直接跳队列页
          if (!e.isDir &&
              (e.kind == 'video' || e.kind == 'audio') &&
              app.subsEnabled)
            _SheetRow(
              icon: 'translate',
              label: subsJob == null ? '生成字幕' : '查看字幕作业',
              onTap: () async {
                Navigator.pop(ctx);
                if (subsJob != null) {
                  _openSubs();
                  return;
                }
                if (!await ensureWrite(context, app)) return;
                await app.addSubs(e);
              },
            ),
          if (e.isDir)
            _SheetRow(
              icon: 'star',
              label: fav ? '取消收藏' : '收藏到首页',
              onTap: () {
                Navigator.pop(ctx);
                app.toggleFavorite(app.source, e.path, e.name);
              },
            ),
          if (app.writable) ...[
            _SheetRow(
              icon: 'edit',
              label: '重命名',
              onTap: () async {
                Navigator.pop(ctx);
                final name = await showTextSheet(
                  context,
                  title: '重命名',
                  initial: e.name,
                  confirm: '改名',
                );
                if (name != null && name.trim().isNotEmpty) {
                  if (!mounted) return;
                  if (!await ensureWrite(context, app)) return;
                  await app.rename(e, name.trim());
                }
              },
            ),
            _SheetRow(
              icon: 'move',
              label: '移到…',
              onTap: () {
                Navigator.pop(ctx);
                _showMove(e);
              },
            ),
            _SheetRow(
              icon: 'trash',
              label: '删除',
              danger: true,
              onTap: () async {
                Navigator.pop(ctx);
                await app.remove(e);
              },
            ),
          ],
        ],
      ),
    );
  }

  /// 听译队列页（文件页的「查看字幕作业」和设置页共用同一个页面）
  void _openSubs() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SubsPage(app: app)),
    );
  }

  /// 移到别的目录：先在本目录的子目录里点，也可以直接改路径
  Future<void> _showMove(Entry e) async {
    final tone = Theme.of(context).extension<Tone>()!;
    final ctl = TextEditingController(text: app.path);
    final dirs = app.entries.where((x) => x.isDir).toList();

    await showSheet<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '把「${e.name}」移到',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                  color: tone.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '现在在 ${app.path}',
                style: TextStyle(fontSize: 12, color: tone.ink3),
              ),
              const SizedBox(height: 12),
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: tone.surface2,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: tone.line),
                ),
                alignment: Alignment.centerLeft,
                child: TextField(
                  controller: ctl,
                  style: TextStyle(fontSize: 13.5, color: tone.ink),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '目标目录，如 /下载/电影',
                    hintStyle: TextStyle(fontSize: 13.5, color: tone.ink3),
                  ),
                ),
              ),
              if (dirs.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 38,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final d in dirs)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Press(
                            onTap: () => setSheet(
                              () => ctl.text =
                                  '${app.path == "/" ? "" : app.path}/${d.name}',
                            ),
                            scale: 0.96,
                            radius: const BorderRadius.all(Radius.circular(99)),
                            pressColor: Colors.transparent,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: tone.surface,
                                borderRadius: BorderRadius.circular(99),
                                border: Border.all(color: tone.line),
                              ),
                              child: Text(
                                d.name,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: tone.ink2,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              PrimaryButton(
                label: '移过去',
                icon: 'move',
                onTap: () async {
                  final dst = ctl.text.trim();
                  if (dst.isEmpty || dst == app.path) {
                    app.toast('目标目录没变');
                    return;
                  }
                  Navigator.pop(ctx);
                  if (!await ensureWrite(context, app)) return;
                  await app.moveEntry(e, dst);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _upload() async {
    List<File> files;
    try {
      files = await Native.pickFiles();
    } catch (e) {
      app.toast('打不开文件选择器：$e');
      return;
    }
    if (files.isEmpty) return;
    // 没填口令时以前只弹一句「先去设置填一次」，用户点了等于没反应 ——
    // 现在原地问一次口令，填对就接着把这批文件传上去
    if (!mounted) return;
    if (!await ensureWrite(context, app)) return;
    await app.uploadFiles(files);
  }

  // ---------- 界面 ----------

  /// 文件列表卡片（手机端一列；平板端拆成两列并排）
  Widget _entriesCard(List<Entry> es, Tone tone) {
    return Container(
      margin: const EdgeInsets.only(bottom: 110),
      decoration: BoxDecoration(
        color: tone.surface,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: tone.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < es.length; i++) ...[
            if (i > 0)
              Container(
                height: 1,
                color: tone.line2,
                margin: const EdgeInsets.only(left: 12),
              ),
            _FileRow(
              entry: es[i],
              icon: _iconName(es[i]),
              // 类型已经在左侧图标上（文件夹/图片/代码各有图标），文字再写一遍是重复
              meta: _mdTime(es[i].mtime),
              selected: _sel.contains(es[i].path),
              selecting: _selMode,
              onTap: () => _selMode ? _toggle(es[i]) : _open(es[i]),
              onMore: () => _showActions(es[i]),
              onLong: () => _enterSel(es[i]),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final segs = app.path.split('/').where((s) => s.isNotEmpty).toList();
    final title = segs.isEmpty ? '文件' : segs.last;
    // 面包屑只留「往上走」的层级：最后一段已经是 H1，根目录干脆不显示
    // （以前根目录是「云匣 / files / 文件」三条，还夹一个英文 files）
    // 注意 take(len-1)：根目录时 segs 为空，len-1 = -1 会让 take 直接抛 RangeError
    // （打包版就是整页变灰）。两个元素都得带守卫。
    final parts = <String>[
      if (segs.isNotEmpty) '云匣',
      if (segs.length > 1) ...segs.take(segs.length - 1),
    ];

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: app.refresh,
          color: tone.ac,
          backgroundColor: tone.surface,
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(19, 18, 19, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const BrandBar(),
                    if (parts.isNotEmpty)
                      Crumbs(
                        parts: parts,
                        onTap: (i) {
                          if (i == 0) {
                            app.open('/');
                          } else {
                            app.open('/${parts.sublist(1, i + 1).join('/')}');
                          }
                        },
                      ),
                    PageTitle(
                      _selMode ? '已选 ${_sel.length}' : title,
                      action: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_selMode) ...[
                            TextButton2(
                              _sel.length >= app.entries.length ? '全不选' : '全选',
                              onTap: () => setState(() {
                                if (_sel.length >= app.entries.length) {
                                  _sel.clear();
                                } else {
                                  _sel.addAll(app.entries.map((e) => e.path));
                                }
                              }),
                            ),
                            const SizedBox(width: 10),
                            TextButton2('取消', onTap: _exitSel),
                          ] else ...[
                            TextButton2('排序', icon: 'sort', onTap: _showSort),
                            const SizedBox(width: 10),
                            Press(
                              key: const ValueKey('grid-toggle'),
                              onTap: () => app.setGridMode(!app.gridMode),
                              scale: 0.92,
                              radius: const BorderRadius.all(
                                Radius.circular(99),
                              ),
                              pressColor: Colors.transparent,
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: UIIcon(
                                  _grid ? 'list' : 'grid',
                                  size: 17,
                                  color: tone.ink2,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (app.transfers.active.isNotEmpty) _UploadBox(app: app),
                    if (app.busy && app.entries.isEmpty)
                      // 进目录先铺骨架屏：行高、图标位跟真行一致，
                      // 内容一到就是「原地换词」，不是整页跳一下
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Column(
                          children: [
                            for (var i = 0; i < 7; i++)
                              _SkeletonRow(tone: tone),
                          ],
                        ),
                      )
                    else if (app.entries.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 56),
                        child: Column(
                          children: [
                            UIIcon(
                              'folder',
                              size: 30,
                              color: tone.ink3.withValues(alpha: 0.6),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '这个文件夹是空的',
                              style: TextStyle(fontSize: 13, color: tone.ink3),
                            ),
                          ],
                        ),
                      )
                    else if (_grid)
                      LayoutBuilder(
                        builder: (ctx, cons) {
                          // 旧版网格是 minmax(134px,1fr) 的方图 + 下面两行字，
                          // 这里按实际列宽算高度，别让文字被裁掉
                          const gap = 10.0;
                          final cols = ((cons.maxWidth + gap) / (134 + gap))
                              .floor()
                              .clamp(2, 6);
                          final tileW =
                              (cons.maxWidth - gap * (cols - 1)) / cols;
                          return GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            padding: const EdgeInsets.only(bottom: 110),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: cols,
                                  mainAxisSpacing: gap,
                                  crossAxisSpacing: gap,
                                  // 64 不够：两行文件名 + 大小行会差 2px（真机截断，测试里报 overflow）
                                mainAxisExtent: tileW + 72,
                                ),
                            itemCount: app.entries.length,
                            itemBuilder: (ctx, i) => _Tile(
                              entry: app.entries[i],
                              icon: _iconName(app.entries[i]),
                              meta: _kindLabel(app.entries[i]),
                              onTap: () => _open(app.entries[i]),
                              onMore: () => _showActions(app.entries[i]),
                            ),
                          );
                        },
                      )
                    else if (MediaQuery.of(context).size.width >= 900 &&
                        app.entries.length > 4)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _entriesCard(
                              app.entries.sublist(
                                0,
                                (app.entries.length + 1) ~/ 2,
                              ),
                              tone,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: _entriesCard(
                              app.entries.sublist(
                                (app.entries.length + 1) ~/ 2,
                              ),
                              tone,
                            ),
                          ),
                        ],
                      )
                    else
                      _entriesCard(app.entries, tone),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 多选时的底部工具条
        if (_selMode)
          Positioned(
            left: 14,
            right: 14,
            bottom: 14,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: tone.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: tone.line),
                boxShadow: [
                  BoxShadow(
                    color: tone.sh,
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '已选 ${_sel.length} 项 · 还能再多点几个',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: tone.ink3),
                    ),
                  ),
                  TextButton2(
                    '收藏',
                    icon: 'star',
                    onTap: () {
                      for (final e in _sel.map(_entryOf).whereType<Entry>()) {
                        if (!app.isFav(e.path)) {
                          app.toggleFavorite(app.source, e.path, e.name);
                        }
                      }
                      _exitSel();
                      app.toast('已收藏到首页');
                    },
                  ),
                  if (app.writable)
                    TextButton2(
                      '删除',
                      icon: 'trash',
                      danger: true,
                      onTap: _deleteSel,
                    ),
                ],
              ),
            ),
          ),
        // 右下角：搜索（旧版那个圆形放大镜）+ 可写时的上传 FAB
        if (!_selMode)
          Positioned(
            right: 18,
            bottom: 18,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 「+」：上传文件 / 新建文件夹。
                // 只读源也照常显示，点了直接把原因说清楚（按钮突然消失更糟）。
                GradFab(
                  icon: 'add',
                  onTap: () => _fabMenu(context, app, onUpload: _upload),
                ),
                const SizedBox(height: 12),
                RoundFab(
                  icon: 'search',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          SearchPage(app: app, onOpenDir: (p) => app.open(p)),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 悬浮「+」点开：上传文件 / 新建文件夹。
/// 默认落到当前目录。
void _fabMenu(
  BuildContext context,
  App app, {
  required Future<void> Function() onUpload,
}) {
  showSheet<void>(
    context,
    builder: (ctx) {
      final tone = Theme.of(ctx).extension<Tone>()!;
      final canUp = app.writable && app.allowUpload;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '当前目录  ${app.path}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: tone.ink3),
            ),
            const SizedBox(height: 10),
            const SizedBox(height: 8),
            _menuRow(
              ctx,
              icon: 'upload',
              title: '上传文件',
              sub: canUp ? '传到当前目录' : _readOnlyWhy(app),
              onTap: () {
                Navigator.of(ctx).pop();
                if (canUp) {
                  onUpload();
                } else {
                  app.toast(_readOnlyWhy(app));
                }
              },
            ),
            if (canUp) ...[
              const SizedBox(height: 8),
              _menuRow(
                ctx,
                icon: 'folder-add',
                title: '新建文件夹',
                sub: '在当前目录建一个',
                onTap: () async {
                  Navigator.of(ctx).pop();
                  final name = await showTextSheet(
                    context,
                    title: '新建文件夹',
                    hint: '文件夹名',
                    confirm: '创建',
                  );
                  if (name != null && name.trim().isNotEmpty) {
                    await app.mkdir(name.trim());
                  }
                },
              ),
            ],
          ],
        ),
      );
    },
  );
}

Widget _menuRow(
  BuildContext ctx, {
  required String icon,
  required String title,
  required String sub,
  required VoidCallback onTap,
}) {
  final tone = Theme.of(ctx).extension<Tone>()!;
  return Press(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
        color: tone.surface2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          UIIcon(icon, size: 18, color: tone.ac),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: tone.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: tone.ink3),
                ),
              ],
            ),
          ),
          UIIcon('chevron-right', size: 15, color: tone.ink3),
        ],
      ),
    ),
  );
}

/// 为什么不能传：把「网盘只读」和「这台电脑的共享没开写入」分开说，
/// 以前两种都提示 115，用户只会觉得功能坏了。
String _readOnlyWhy(App app) {
  if (!app.writable) {
    return '这个来源只读，换个来源再传';
  }
  if (!app.allowUpload) {
    return '这台电脑的共享没开写入权限（要在那台电脑上开着可写共享）';
  }
  return '现在不能上传';
}

class _FileRow extends StatelessWidget {
  final Entry entry;
  final String icon;
  final String meta;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final VoidCallback onLong;
  final bool selected;
  final bool selecting;

  const _FileRow({
    required this.entry,
    required this.icon,
    required this.meta,
    required this.onTap,
    required this.onMore,
    required this.onLong,
    this.selected = false,
    this.selecting = false,
  });

  /// 文件类型配色照 5020：八种色相 × 五套主题的明度（见 kTypeToneByTheme）
  static (Color, Color) _kindTone(String icon, Tone tone) {
    const map = {
      'type-folder': 'folder',
      'type-image': 'image',
      'type-video': 'video',
      'type-audio': 'audio',
      'type-zip': 'zip',
      'type-code': 'code',
      'type-pdf': 'pdf',
      'type-doc': 'doc',
    };
    final t = typeTone(map[icon] ?? 'doc', tone.id);
    return (t.bg, t.fg);
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final (bg, fg) = _kindTone(icon, tone);
    return Press(
      onTap: onTap,
      onLongPress: onLong,
      scale: 1,
      pressColor: tone.surface2,
      child: Container(
        color: selected ? tone.acw : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(12, 13, 8, 13),
        child: Row(
          children: [
            Container(
              width: 43,
              height: 43,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(13),
              ),
              alignment: Alignment.center,
              child: UIIcon(icon, size: 22, color: fg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: tone.ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      color: tone.ink3,
                    ),
                  ),
                ],
              ),
            ),
            if (!entry.isDir) ...[
              const SizedBox(width: 8),
              Text(
                humanSize(entry.size),
                style: TextStyle(
                  fontSize: 11,
                  color: tone.ink3,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
            if (selecting)
              Padding(
                padding: const EdgeInsets.only(
                  left: 8,
                  right: 4,
                  top: 4,
                  bottom: 4,
                ),
                child: _Check(on: selected),
              )
            else
              Press(
                onTap: onMore,
                scale: 0.9,
                radius: const BorderRadius.all(Radius.circular(99)),
                pressColor: Colors.transparent,
                child: const SizedBox(
                  width: 36,
                  height: 36,
                  child: Center(
                    child: UIIcon('more', size: 18, color: Color(0xFF9AA7B8)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final Entry entry;
  final String icon;
  final String meta;
  final VoidCallback onTap;
  final VoidCallback onMore;

  const _Tile({
    required this.entry,
    required this.icon,
    required this.meta,
    required this.onTap,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final (bg, fg) = _FileRow._kindTone(icon, tone);
    return Press(
      onTap: onTap,
      scale: 0.98,
      pressColor: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: tone.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: tone.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(
                      color: bg,
                      alignment: Alignment.center,
                      child: UIIcon(icon, size: 30, color: fg),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                      color: tone.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: tone.ink3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Check extends StatelessWidget {
  final bool on;
  const _Check({required this.on});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Container(
      width: 21,
      height: 21,
      decoration: BoxDecoration(
        color: on ? tone.ac : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(color: on ? tone.ac : tone.line, width: 1.4),
      ),
      child: on ? const UIIcon('check', size: 13, color: Colors.white) : null,
    );
  }
}

class _SheetRow extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  const _SheetRow({
    required this.icon,
    required this.label,
    this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final c = danger ? const Color(0xFFE45E53) : tone.ink;
    return Press(
      onTap: onTap,
      scale: 1,
      pressColor: tone.surface2,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          children: [
            UIIcon(icon, size: 19, color: danger ? c : tone.ink2),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(fontSize: 14.5, color: c)),
          ],
        ),
      ),
    );
  }
}

/// 上传进度框（旧版 .upload-box）
class _UploadBox extends StatelessWidget {
  final App app;
  const _UploadBox({required this.app});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return AnimatedBuilder(
      animation: app.transfers,
      builder: (ctx, _) {
        final items = app.transfers.active;
        if (items.isEmpty) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: tone.surface,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: tone.line),
          ),
          child: Column(
            children: [
              for (final t in items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, color: tone.ink),
                            ),
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(9),
                              child: Container(
                                height: 4,
                                color: tone.line2,
                                child: FractionallySizedBox(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: t.pct.clamp(0.01, 1.0),
                                  child: Container(color: tone.ac),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        t.state == 'error'
                            ? '失败'
                            : t.state == 'done'
                            ? '完成'
                            : '${(t.pct * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: t.state == 'error'
                              ? const Color(0xFFE45E53)
                              : (t.state == 'done'
                                    ? const Color(0xFF0D9C7A)
                                    : tone.ac),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
