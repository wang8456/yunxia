import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_icons.dart';
import '../core/app_state.dart';
import '../core/models.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';
import 'kit.dart';
import 'widgets.dart';

/// 搜索页 —— 视觉照旧版：顶部一条白色圆角搜索框（带放大镜和清除），
/// 下面是「按目录收」的胶囊，再往下是与文件页同款的结果行。
class SearchPage extends StatefulWidget {
  final App app;
  final void Function(String path) onOpenDir;

  const SearchPage({super.key, required this.app, required this.onOpenDir});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _ctl = TextEditingController();
  Timer? _debounce;

  List<Entry> _hits = const [];
  bool _busy = false;
  String _activeDir = '';
  String _q = '';

  App get app => widget.app;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 320), () => _run(v));
  }

  Future<void> _run(String q) async {
    final text = q.trim();
    setState(() {
      _q = text;
      _activeDir = '';
    });
    if (text.isEmpty) {
      setState(() {
        _hits = const [];
        _busy = false;
      });
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await app.api.search(text, limit: 80);
      final items = ((r['items'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      if (!mounted) return;
      setState(() {
        _hits = items
            .map(
              (j) => Entry(
                name: j['name'] as String? ?? '',
                path: j['path'] as String? ?? '/',
                isDir: j['is_dir'] as bool? ?? false,
                size: (j['size'] as num?)?.toInt() ?? 0,
                mtime: (j['mtime'] as num?)?.toDouble() ?? 0,
                kind: j['kind'] as String? ?? 'file',
                ext: j['ext'] as String? ?? '',
              ),
            )
            .toList();
      });
    } catch (e) {
      app.toast('搜索失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 目录 facet：按父目录计数，降序取前 8，只有一个目录时不显示
  Map<String, int> get _dirs {
    final m = <String, int>{};
    for (final e in _hits) {
      final i = e.path.lastIndexOf('/');
      final d = i <= 0 ? '/' : e.path.substring(0, i);
      m[d] = (m[d] ?? 0) + 1;
    }
    return m;
  }

  List<Entry> get _shown {
    if (_activeDir.isEmpty) return _hits;
    return _hits
        .where(
          (e) =>
              (e.path.lastIndexOf('/') <= 0
                  ? '/'
                  : e.path.substring(0, e.path.lastIndexOf('/'))) ==
              _activeDir,
        )
        .toList();
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

  /// 与文件页同一套类型配色（照 5020 的 --k-*，随主题变）
  static (Color, Color) _toneOf(String icon, Tone tone) {
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
    final dirs = _dirs;
    final shown = _shown;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(19, 18, 19, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BrandBar(),
              const PageTitle('搜索'),
              Container(
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 13),
                decoration: BoxDecoration(
                  color: tone.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: tone.line),
                  boxShadow: [
                    BoxShadow(
                      color: tone.sh,
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    UIIcon('search', size: 18, color: tone.ink3),
                    const SizedBox(width: 9),
                    Expanded(
                      child: TextField(
                        controller: _ctl,
                        autofocus: true,
                        onChanged: _onChanged,
                        onSubmitted: _run,
                        style: TextStyle(fontSize: 15, color: tone.ink),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '搜文件、文件夹',
                          hintStyle: TextStyle(fontSize: 15, color: tone.ink3),
                        ),
                      ),
                    ),
                    if (_ctl.text.isNotEmpty)
                      Press(
                        onTap: () {
                          _ctl.clear();
                          _run('');
                        },
                        scale: 0.9,
                        pressColor: Colors.transparent,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: UIIcon('close', size: 17, color: tone.ink3),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (dirs.length > 1)
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _DirChip(
                  label: '全部 ${_hits.length}',
                  on: _activeDir.isEmpty,
                  onTap: () => setState(() => _activeDir = ''),
                ),
                for (final e
                    in (dirs.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value))))
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _DirChip(
                      label:
                          '${e.key == '/' ? '根目录' : e.key.split('/').last} ${e.value}',
                      on: _activeDir == e.key,
                      onTap: () => setState(() => _activeDir = e.key),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: _busy && _hits.isEmpty
              ? const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 60,
                    horizontal: 24,
                  ),
                  child: Column(
                    children: [
                      UIIcon(
                        'search',
                        size: 30,
                        color: tone.ink3.withValues(alpha: 0.6),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _q.isEmpty ? '输入关键词开始搜' : '没有找到「$_q」',
                        style: TextStyle(fontSize: 13, color: tone.ink3),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                  itemCount: shown.length,
                  itemBuilder: (ctx, i) {
                    final e = shown[i];
                    final dir = e.path.lastIndexOf('/') <= 0
                        ? '/'
                        : e.path.substring(0, e.path.lastIndexOf('/'));
                    final ic = _iconName(e);
                    final (ibg, ifg) = _toneOf(ic, tone);
                    return Press(
                      onTap: () {
                        Navigator.of(context).pop();
                        if (e.isDir) {
                          widget.onOpenDir(e.path);
                        } else {
                          widget.onOpenDir(dir);
                        }
                      },
                      scale: 1,
                      pressColor: tone.surface2,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 4,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: ibg,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              alignment: Alignment.center,
                              child: UIIcon(ic, size: 20, color: ifg),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    e.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: tone.ink,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    dir,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: tone.ink3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!e.isDir)
                              Text(
                                humanSize(e.size),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: tone.ink3,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _DirChip extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback onTap;

  const _DirChip({required this.label, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Press(
      onTap: onTap,
      scale: 0.96,
      radius: const BorderRadius.all(Radius.circular(99)),
      pressColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: on ? tone.ac : tone.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: on ? tone.ac : tone.line),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: on ? tone.onac : tone.ink2,
          ),
        ),
      ),
    );
  }
}
