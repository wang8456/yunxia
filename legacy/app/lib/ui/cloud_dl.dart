import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';
import 'widgets.dart';

/// 云下载：磁力 / ed2k / http 丢给 CloudDrive 的离线下载。
/// 入口是文件页那个悬浮的「+」，默认落在当前浏览目录，可自己改。
Future<void> showCloudDl(
  BuildContext context,
  App app, {
  String dir = '/',
}) =>
    showSheet<void>(
      context,
      builder: (_) => _CloudDlSheet(app: app, dir: dir),
    );

class _CloudDlSheet extends StatefulWidget {
  final App app;
  final String dir;
  const _CloudDlSheet({required this.app, required this.dir});

  @override
  State<_CloudDlSheet> createState() => _CloudDlSheetState();
}

class _CloudDlSheetState extends State<_CloudDlSheet> {
  App get app => widget.app;

  late String _target = widget.dir.isEmpty ? '/' : widget.dir;
  final _text = TextEditingController();
  bool _busy = false;
  String _msg = '';
  List<dynamic> _tasks = const [];

  bool _picking = false;
  late String _pickPath = _target;
  List<dynamic> _dirs = const [];
  bool _pickBusy = false;

  @override
  void initState() {
    super.initState();
    _loadTasks();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  int _pct(dynamic t) {
    final v = (t is Map ? t['percent'] : null);
    final n = v is num ? v : 0;
    return n.clamp(0, 100).round();
  }

  Future<void> _loadTasks() async {
    try {
      final r = await app.api.cd2Tasks(_target, app.source);
      if (!mounted) return;
      setState(() {
        final list = (r['tasks'] as List?) ?? const [];
        _tasks = list.take(6).toList();
      });
    } catch (_) {
      if (mounted) setState(() => _tasks = const []);
    }
  }

  Future<void> _loadDirs(String path) async {
    setState(() {
      _pickBusy = true;
      _pickPath = path;
    });
    try {
      final r = await app.api.list(app.source, path);
      if (!mounted) return;
      setState(() {
        _dirs = ((r['entries'] as List?) ?? const [])
            .where((e) => e is Map && e['is_dir'] == true)
            .toList();
      });
    } catch (_) {
      if (mounted) setState(() => _dirs = const []);
    } finally {
      if (mounted) setState(() => _pickBusy = false);
    }
  }

  Future<void> _submit() async {
    final urls = _text.text
        .split(RegExp(r'\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (urls.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _msg = '';
    });
    try {
      await app.api.cd2Offline(urls, _target, app.source);
      _text.clear();
      app.toast('已提交 ${urls.length} 个云下载任务');
      setState(() => _msg = '已提交 ${urls.length} 个任务');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await _loadTasks();
    } catch (e) {
      setState(() => _msg = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final h = MediaQuery.of(context).size.height;

    return Container(
      constraints: BoxConstraints(maxHeight: h * 0.86),
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  _picking ? '选择目录' : '云下载',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: tone.ink,
                  ),
                ),
                const SizedBox(width: 8),
                if (!_picking)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: tone.surface2,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('115 网盘',
                        style: TextStyle(fontSize: 11, color: tone.ink3)),
                  ),
                const Spacer(),
                Press(
                  onTap: () {
                    if (_picking) {
                      setState(() => _picking = false);
                    } else {
                      Navigator.of(context).maybePop();
                    }
                  },
                  scale: 0.92,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: UIIcon(
                      _picking ? 'arrow-left' : 'close',
                      size: 18,
                      color: tone.ink2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_picking) ..._picker(tone) else ..._form(tone),
          ],
        ),
      ),
    );
  }

  List<Widget> _form(Tone tone) => [
        Press(
          onTap: () {
            setState(() {
              _picking = true;
              _pickPath = _target;
            });
            _loadDirs(_target);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: tone.surface2,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                UIIcon('folder', size: 17, color: tone.ink2),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _target,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: tone.ink),
                  ),
                ),
                const SizedBox(width: 8),
                Text('更改', style: TextStyle(fontSize: 12, color: tone.ac)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: tone.surface2,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: tone.line),
          ),
          child: TextField(
            controller: _text,
            minLines: 3,
            maxLines: 5,
            style: TextStyle(fontSize: 13, color: tone.ink),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: '磁力 / ed2k / http，一行一个',
              hintStyle: TextStyle(fontSize: 13, color: tone.ink3),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                _msg.isEmpty ? '走 CloudDrive 的离线下载' : _msg,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: tone.ink3),
              ),
            ),
            const SizedBox(width: 10),
            PrimaryButton(
              label: _busy ? '提交中…' : '开始下载',
              onTap: _busy || _text.text.trim().isEmpty ? null : _submit,
            ),
          ],
        ),
        if (_tasks.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final t in _tasks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      (t is Map ? (t['name'] ?? t['hash'] ?? '') : '').toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: tone.ink2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 84,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: _pct(t) / 100,
                        minHeight: 5,
                        backgroundColor: tone.surface2,
                        valueColor: AlwaysStoppedAnimation(tone.ac),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${_pct(t)}%',
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 11, color: tone.ink3),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ];

  List<Widget> _picker(Tone tone) => [
        Row(
          children: [
            Press(
              onTap: _pickPath == '/'
                  ? null
                  : () {
                      final p = _pickPath.replaceFirst(RegExp(r'/[^/]+$'), '');
                      _loadDirs(p.isEmpty ? '/' : p);
                    },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                decoration: BoxDecoration(
                  color: tone.surface2,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text('上一级',
                    style: TextStyle(fontSize: 12, color: tone.ink2)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _pickPath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: tone.ink3),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 外层是 SingleChildScrollView，内层 ListView 必须给死高度，
        // 否则 "Vertical viewport was given unbounded height" 直接红屏
        SizedBox(
          height: (_dirs.length * 46.0).clamp(96.0, 340.0),
          child: _pickBusy
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: Text('读取中…',
                        style: TextStyle(fontSize: 12, color: tone.ink3)),
                  ),
                )
              : _dirs.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Text('这一层没有子目录',
                            style: TextStyle(fontSize: 12, color: tone.ink3)),
                      ),
                    )
                  // 用 builder 而不是一次性铺开：115 的目录动辄上千个
                  : ListView.builder(
                      itemCount: _dirs.length,
                      itemBuilder: (_, i) {
                        final d = _dirs[i];
                        return Press(
                          onTap: () => _loadDirs(
                              (d is Map ? d['path'] : '/').toString()),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Row(
                              children: [
                                UIIcon('folder', size: 17, color: tone.ink2),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Text(
                                    (d is Map ? d['name'] : '').toString(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        TextStyle(fontSize: 13, color: tone.ink),
                                  ),
                                ),
                                UIIcon('chevron-right',
                                    size: 15, color: tone.ink3),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
        const SizedBox(height: 10),
        PrimaryButton(
          label: '下载到这个目录',
          onTap: () {
            setState(() {
              _target = _pickPath;
              _picking = false;
            });
            _loadTasks();
          },
        ),
      ];
}
