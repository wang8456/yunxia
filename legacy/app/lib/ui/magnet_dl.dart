import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/tokens.dart';
import 'widgets.dart';

/// 磁力 / ed2k：交给 NAS 上的下载器（5093 / 5094）。
/// 入口跟云下载同一个「+」面板——有云下载的源（115）用云下载，
/// 没有云下载的源（NAS / 本机）用这条。
Future<void> showMagnetDl(
  BuildContext context,
  App app, {
  String dir = '/',
}) =>
    showSheet<void>(
      context,
      builder: (_) => _MagnetSheet(app: app, dir: dir),
    );

class _MagnetSheet extends StatefulWidget {
  final App app;
  final String dir;
  const _MagnetSheet({required this.app, required this.dir});

  @override
  State<_MagnetSheet> createState() => _MagnetSheetState();
}

class _MagnetSheetState extends State<_MagnetSheet> {
  App get app => widget.app;
  final _text = TextEditingController();
  bool _busy = false;
  String _msg = '';

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final links = _text.text
        .split(RegExp(r'\s+'))
        .map((s) => s.trim())
        .where((s) => s.startsWith('magnet:') || s.toLowerCase().startsWith('ed2k://'))
        .toList();
    if (links.isEmpty || _busy) {
      setState(() => _msg = '贴上 magnet: 或 ed2k:// 链接');
      return;
    }
    final dir = widget.dir.replaceFirst(RegExp(r'^/+'), '');
    setState(() {
      _busy = true;
      _msg = '';
    });
    var ok = 0;
    try {
      final magnets = links.where((l) => l.startsWith('magnet:')).toList();
      final ed2ks = links
          .where((l) => l.toLowerCase().startsWith('ed2k://'))
          .toList();
      if (magnets.isNotEmpty) {
        await app.api.addTask('magnet', magnets, dir: dir);
        ok += magnets.length;
      }
      if (ed2ks.isNotEmpty) {
        await app.api.addTask('ed2k', ed2ks, dir: dir);
        ok += ed2ks.length;
      }
      _text.clear();
      app.toast('已交给下载器：$ok 个任务');
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      setState(() => _msg = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '磁力 / ed2k',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: tone.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '下到 ${widget.dir.isEmpty ? '/' : widget.dir} · 进度在「下载」页看',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: tone.ink3),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: tone.surface2,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: tone.line),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: TextField(
              controller: _text,
              minLines: 3,
              maxLines: 6,
              autofocus: true,
              style: TextStyle(fontSize: 13, color: tone.ink),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: '一行一条：magnet:?xt=… 或 ed2k://|file|…',
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
                  _msg.isEmpty ? '下载器在 NAS 上跑' : _msg,
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
        ],
      ),
    );
  }
}
