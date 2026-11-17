import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_state.dart';
import '../core/native.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';
import 'kit.dart';
import 'player_subs_layer.dart';
import 'widgets.dart';

/// 听译队列：转写任务都在服务端本机跑（faster-whisper），
/// 这个页面只是一扇窗 —— 看状态、看段落、取消/删除、导出 SRT。
///
/// 状态来源就是 App.subsJobs（一次 GET /subs），
/// 有任务在跑时每 2 秒刷新一次，退出页面就停。
class SubsPage extends StatefulWidget {
  final App app;
  const SubsPage({super.key, required this.app});

  @override
  State<SubsPage> createState() => _SubsPageState();
}

class _SubsPageState extends State<SubsPage> {
  App get app => widget.app;

  Timer? _timer;
  bool _loading = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    if (_loading) return;
    _loading = true;
    final ok = await app.refreshSubs();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _err = ok ? null : '拿不到队列（服务端没响应，或听译没开）';
    });
    _arm();
  }

  /// 有任务在跑才轮询：全都停下了就别再空转
  void _arm() {
    final any = app.subsActive > 0;
    if (!any) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(seconds: 2), (_) async {
      await app.refreshSubs();
      if (!mounted) return;
      setState(() {});
      if (app.subsActive == 0) _arm();
    });
  }

  // ---------------- 操作 ----------------

  Future<void> _cancel(Map<String, dynamic> job) async {
    final id = job['id'] as String? ?? '';
    if (id.isEmpty) return;
    try {
      await app.api.subsCancel(id);
      app.toast('已取消');
      await _reload();
    } catch (e) {
      app.toast('取消失败：$e');
    }
  }

  Future<void> _delete(Map<String, dynamic> job) async {
    final id = job['id'] as String? ?? '';
    if (id.isEmpty) return;
    final ok = await showConfirmSheet(
      context,
      title: '删除这个字幕作业？',
      text: '字幕文件会一起删掉，视频本身不动。',
      okText: '删除',
      danger: true,
    );
    if (ok != true) return;
    try {
      await app.api.subsDelete(id);
      app.toast('已删除');
      await _reload();
    } catch (e) {
      app.toast('删除失败：$e');
    }
  }

  Future<void> _retry(Map<String, dynamic> job) async {
    final id = job['id'] as String? ?? '';
    if (id.isEmpty) return;
    try {
      // 重新转写 = 先删掉旧的再按原路径排一次，避免同路径两份作业打架
      await app.api.subsDelete(id);
    } catch (_) {
      // 删不掉也照排：服务端按路径去重，最多是「已经有了」
    }
    try {
      await app.api.subsAdd(
        job['source'] as String? ?? app.source,
        job['path'] as String? ?? '',
        name: job['name'] as String? ?? '',
        lang: app.session.subsLang,
      );
      app.toast('重新排队');
      await _reload();
    } catch (e) {
      app.toast('重排失败：$e');
    }
  }

  Future<void> _translate(Map<String, dynamic> job) async {
    final id = job['id'] as String? ?? '';
    if (id.isEmpty) return;
    try {
      await app.api.subsTranslate(id);
      app.toast('开始翻译');
      await _reload();
    } on ApiError catch (e) {
      // 409：还没转完，或服务端没配翻译 —— 说清楚，别只说「失败」
      app.toast(e.status == 409 ? '还没转完（或没配翻译），等会儿再点' : '翻译失败：${e.message}');
    } catch (e) {
      app.toast('翻译失败：$e');
    }
  }

  String _baseName(Object? name) {
    final n = (name as String? ?? '').trim();
    if (n.isEmpty) return 'subs';
    final dot = n.lastIndexOf('.');
    final base = dot > 0 ? n.substring(0, dot) : n;
    return base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  /// 导出 SRT：先写进应用缓存，再交给原生「下载/云匣」目录
  Future<void> _export(Map<String, dynamic> job) async {
    final id = job['id'] as String? ?? '';
    if (id.isEmpty) return;
    final wantTrans =
        (app.subsTranslate['ready'] == true) &&
        ((job['segments'] as num?) ?? 0) > 0;
    File? f;
    try {
      String text;
      try {
        text = await app.api.subsSrtText(id, trans: wantTrans);
      } catch (_) {
        // 译文版拿不到（没翻译 / 服务端 404）：退回原文，别让导出直接失败
        text = await app.api.subsSrtText(id);
      }
      if (text.trim().isEmpty) {
        app.toast('这条还没有字幕内容');
        return;
      }
      final name = '${_baseName(job['name'])}${wantTrans ? '.双语' : ''}.srt';
      f = File('${Directory.systemTemp.path}/$name');
      await f.writeAsString(text);
      final saved = await Native.saveToDownloads(
        f,
        name: name,
        mime: 'application/x-subrip',
      );
      app.toast('已导出到 ${saved.isEmpty ? f.path : saved}');
    } catch (e) {
      // 没有原生通道（非 Android）时至少留在缓存里，路径告诉用户
      if (f != null) {
        app.toast('已存到 ${f.path}（$e）');
      } else {
        app.toast('导出失败：$e');
      }
    }
  }

  /// 查看段落：拉全量段落，滚着看
  Future<void> _openSegments(Map<String, dynamic> job) async {
    final id = job['id'] as String? ?? '';
    if (id.isEmpty) return;
    final tone = Theme.of(context).extension<Tone>()!;
    List<SubLine> lines = const [];
    try {
      final r = await app.api.subsDetail(id);
      lines = parseSubLines(r['segments_list']);
    } catch (e) {
      app.toast('拿不到段落：$e');
      return;
    }
    if (!mounted) return;
    final name = (job['name'] as String? ?? '字幕').trim();
    await showSheet<void>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: tone.ink,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${lines.length} 句',
                style: TextStyle(fontSize: 12, color: tone.ink3),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (lines.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text('还没有段落，转完再来',
                    style: TextStyle(fontSize: 12.5, color: tone.ink3)),
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.55,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: lines.length,
                separatorBuilder: (_, _) => Container(height: 1, color: tone.line2),
                itemBuilder: (c, i) {
                  final l = lines[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 52,
                          child: Text(
                            _clock(l.start),
                            style: TextStyle(
                              fontSize: 11,
                              color: tone.ink3,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (l.hasTrans)
                                Text(
                                  l.trans,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    height: 1.45,
                                    color: tone.ink,
                                  ),
                                ),
                              if (l.text.isNotEmpty)
                                Text(
                                  l.text,
                                  style: TextStyle(
                                    fontSize: l.hasTrans ? 12 : 13.5,
                                    height: 1.45,
                                    color: l.hasTrans ? tone.ink3 : tone.ink,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  // ---------------- 界面 ----------------

  static String _clock(double sec) {
    final t = sec.floor();
    final h = t ~/ 3600;
    final m = (t % 3600) ~/ 60;
    final s = t % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  static String _stateLabel(Object? st) => switch (st) {
    'queued' => '排队中',
    'asr' => '转写中',
    'translating' => '翻译中',
    'done' => '已完成',
    'error' => '失败',
    'cancelled' => '已取消',
    _ => '未知',
  };

  static (Color, Color) _stateColor(Tone tone, Object? st) => switch (st) {
    'done' => (const Color(0xFF0E9D78), tone.tint(const Color(0xFF0E9D78))),
    'error' => (const Color(0xFFE45E53), tone.tint(const Color(0xFFE45E53))),
    'cancelled' => (tone.ink3, tone.surface2),
    'translating' => (const Color(0xFF7C5CF0), tone.tint(const Color(0xFF7C5CF0))),
    'queued' => (const Color(0xFFC78218), tone.tint(const Color(0xFFC78218))),
    _ => (tone.ac, tone.acw),
  };

  bool _alive(Object? st) =>
      st == 'queued' || st == 'asr' || st == 'translating';

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final jobs = app.subsJobs;
    return Scaffold(
      backgroundColor: tone.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _head(tone, jobs),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _reload,
                color: tone.ac,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 40),
                  children: [
                    if (_err != null) _note(tone, _err!),
                    if (jobs.isEmpty && _err == null)
                      Padding(
                        padding: const EdgeInsets.only(top: 90),
                        child: Column(
                          children: [
                            UIIcon('translate', size: 44, color: tone.ink3),
                            const SizedBox(height: 12),
                            Text('还没有听译作业',
                                style: TextStyle(fontSize: 13, color: tone.ink3)),
                            const SizedBox(height: 6),
                            Text(
                              '视频行的「生成字幕」或播放器字幕面板里排一个',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 11.5, color: tone.ink3),
                            ),
                          ],
                        ),
                      ),
                    for (final j in jobs) ...[
                      _card(tone, j),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _note(Tone tone, String text) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: tone.tint(const Color(0xFFE45E53), 0.08, 0.14),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        const UIIcon('info', size: 15, color: Color(0xFFE45E53)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: const TextStyle(fontSize: 12, color: Color(0xFFE45E53))),
        ),
      ],
    ),
  );

  Widget _head(Tone tone, List<Map<String, dynamic>> jobs) {
    final active = app.subsActive;
    final done = jobs.where((j) => j['state'] == 'done').length;
    final summary = jobs.isEmpty
        ? '还没有任务'
        : [
            '${jobs.length} 个作业',
            if (active > 0) '$active 个在跑',
            if (done > 0) '$done 个完成',
            if (app.subsMaxActive > 0) '同时最多 ${app.subsMaxActive} 个',
          ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 14, 4),
      child: Column(
        children: [
          Row(
            children: [
              Press(
                onTap: () => Navigator.pop(context),
                scale: 0.94,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: UIIcon('arrow-left', size: 22, color: tone.ink),
                ),
              ),
              const SizedBox(width: 4),
              Text('听译队列',
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700, color: tone.ink)),
              const Spacer(),
              GestureDetector(
                onTap: _reload,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: tone.surface2,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Row(
                    children: [
                      UIIcon('refresh', size: 13, color: tone.ink2),
                      const SizedBox(width: 5),
                      Text('刷新',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: tone.ink2)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 0, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(summary,
                  style: TextStyle(fontSize: 12, color: tone.ink3)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(Tone tone, Map<String, dynamic> job) {
    final st = job['state'];
    final (fg, bg) = _stateColor(tone, st);
    final pct = ((job['pct'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
    final segs = (job['segments'] as num?)?.toInt() ?? 0;
    final lang = (job['lang'] as String? ?? '').trim();
    final msg = (job['msg'] as String? ?? job['error'] as String? ?? '').trim();
    final name = (job['name'] as String? ?? '').trim();
    final trans = _hasTranslated(job);

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(child: UIIcon('translate', size: 18, color: fg)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? (job['path'] as String? ?? '—') : name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                        color: tone.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        _stateLabel(st),
                        if (lang.isNotEmpty) lang,
                        if (trans) '含译文',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: tone.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  _stateLabel(st),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
          if (_alive(st)) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: pct,
                      minHeight: 5,
                      backgroundColor: tone.line2,
                      valueColor: AlwaysStoppedAnimation(tone.ac),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(pct * 100).round()}%',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: tone.ink2,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            if (msg.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(msg,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, height: 1.4, color: tone.ink3)),
            ],
          ] else ...[
            const SizedBox(height: 8),
            Text(
              [
                '$segs 句',
                if (msg.isNotEmpty) msg,
                if (st == 'cancelled') '点「重新转写」可以再来一遍',
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: st == 'error' ? const Color(0xFFE45E53) : tone.ink3,
              ),
            ),
          ],
          Container(height: 1, color: tone.line2, margin: const EdgeInsets.only(top: 9)),
          Wrap(
            spacing: 2,
            runSpacing: 2,
            children: [
              if (segs > 0)
                TextButton2(
                  '查看段落',
                  icon: 'list',
                  onTap: () => _openSegments(job),
                ),
              TextButton2(
                '导出 SRT',
                icon: 'download',
                onTap: () => _export(job),
              ),
              if (_alive(st))
                TextButton2('取消', onTap: () => _cancel(job))
              else
                TextButton2('重新转写', onTap: () => _retry(job)),
              if (app.subsTranslate['ready'] == true && st == 'done' && !trans)
                TextButton2('翻译', icon: 'translate', onTap: () => _translate(job)),
              TextButton2('删除', onTap: () => _delete(job), danger: true),
            ],
          ),
        ],
      ),
    );
  }

  /// 服务端对「有没有译文」的字段名可能不同，认几个常见的
  bool _hasTranslated(Map<String, dynamic> job) {
    if (job['translated'] == true) return true;
    final t = job['translate'];
    if (t is Map && t['done'] == true) return true;
    return (job['pending_translate'] as num?) == 0;
  }
}
