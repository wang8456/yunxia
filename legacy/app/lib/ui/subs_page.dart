import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/langs.dart';
import '../core/subs_tr.dart';
import '../core/translator.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';
import 'subs_monitor.dart';
import 'subs_view_page.dart';
import 'widgets.dart';

/// 听监控：只显示「听」（转写）。译是播放时实时翻的，不排队，所以不在这里。
/// 对齐旧版网页设置里的那一屏 —— 中枢状态、同时转写、三个分页、
/// 每个任务一条（进度 / 导出 / 重新听译 / 删除）。
class SubsPage extends StatefulWidget {
  final App app;
  const SubsPage({super.key, required this.app});

  @override
  State<SubsPage> createState() => _SubsPageState();
}

class _SubsPageState extends State<SubsPage> {
  App get app => widget.app;

  List<SubJob> jobs = const [];
  bool loading = true;
  String err = '';
  int maxActive = 1;
  int queued = 0;
  bool online = false;
  int tab = 1; // 0 进行中 / 1 已完成 / 2 已停止
  Timer? _timer;
  bool _inflight = false;

  /// 翻译器挂在应用层（`translatorFor`），退出页面也继续翻；
  /// 这里只管「本页订阅了哪些」的监听，退页时摘掉监听、不打断任务。
  final Map<String, VoidCallback> _hooks = {};
  final Set<String> _hydrated = {};

  static const Color _blue = Color(0xFF007AFF);
  static const Color _red = Color(0xFFE45E53);
  static const Color _green = Color(0xFF0E9D78);

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    // 只摘监听：翻译继续在后台跑，回来还能看到进度
    _hooks.forEach((id, fn) {
      final t = translatorFor(id);
      t.removeListener(fn);
    });
    _hooks.clear();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (_inflight) return;
    _inflight = true;
    try {
      // 实时听是跟着播放走的一次性任务，不进队列；这里只列「加入队列听」的
      final list = await fetchJobs(app);
      Map<String, dynamic>? cfg;
      try {
        cfg = await app.api.subsConfig();
      } catch (_) {}
      if (!mounted) return;
      for (final j in list) {
        // 只在第一次见到这个任务时看缓存，别每 3 秒扫一次目录
        if (!_hydrated.contains(j.id)) unawaited(_hydrate(j));
      }
      setState(() {
        jobs = list;
        loading = false;
        err = '';
        online = cfg?['online'] == true;
        final m = (cfg?['max_active'] as num?)?.toInt();
        if (m != null) maxActive = m;
        queued = list
            .where((j) => j.state == 'queued' || j.state == 'probing')
            .length;
      });
    } catch (e) {
      if (mounted && !silent) {
        setState(() {
          loading = false;
          err = '$e';
        });
      }
    } finally {
      _inflight = false;
    }
  }

  SubTranslator _trOf(SubJob j) {
    final t = translatorFor(j.id, api: app.api);
    if (!_hooks.containsKey(j.id)) {
      void fn() {
        if (mounted) setState(() {});
      }

      t.addListener(fn);
      _hooks[j.id] = fn;
    }
    return t;
  }

  /// 进页面时看一眼磁盘上有没有翻好的缓存（换设备/重开 App 也是绿的）
  Future<void> _hydrate(SubJob j) async {
    if (_hydrated.contains(j.id) || j.segments == 0) return;
    _hydrated.add(j.id);
    try {
      final dir = SubTranslator.dir();
      if (!await dir.exists()) return;
      File? best;
      String lang = '';
      await for (final f in dir.list()) {
        if (f is! File) continue;
        final name = f.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('${j.id}_') || !name.endsWith('.json')) continue;
        final l = name.substring(j.id.length + 1, name.length - 5);
        if (best == null ||
            f.statSync().modified.isAfter(best.statSync().modified)) {
          best = f;
          lang = l;
        }
      }
      if (best == null || lang.isEmpty || !mounted) return;
      final t = _trOf(j);
      await t.loadCache(lang);
    } catch (_) {}
  }

  /// 翻译按钮：未翻 → 选语言开翻；翻译中 → 暂停；已暂停 → 继续；完成 → 提示
  Future<void> _translate(SubJob j) async {
    if (j.segments == 0) {
      app.toast('这个任务还没有字幕');
      return;
    }
    final t = _trOf(j);
    if (t.busy) {
      t.pause();
      return;
    }
    if (t.paused) {
      t.resume();
      return;
    }
    if (t.done) {
      await _trDone(j, t);
      return;
    }
    // 译在 App 里跑，没配源（密钥）就直接告诉用户去哪填，别让他看着转圈
    if (!TrSource.current.ready) {
      app.toast('还没配翻译源（设置 → 翻译源）');
      return;
    }
    final lang = await showSheet<String>(
      context,
      builder: (ctx) => SubLangSheet(current: t.lang),
    );
    if (lang == null || !mounted) return;
    unawaited(t.start(lang));
  }

  /// 已翻译之后：先看完整性，再决定补翻还是整片重翻
  Future<void> _trDone(SubJob j, SubTranslator t) async {
    final a = t.audit();
    final act = await showSheet<String>(
      context,
      builder: (ctx) => _TrAuditSheet(lang: subLangName(t.lang), audit: a),
    );
    if (act == null || !mounted) return;
    switch (act) {
      case 'view':
        _open(j);
        break;
      case 'redo':
        unawaited(t.redo());
        break;
      case 'all':
        unawaited(t.redo(all: true));
        break;
    }
  }

  /// 点开看：逐句字幕 + 导出（.srt / .txt）
  void _open(SubJob j, {bool askTranslate = false}) {
    if (j.segments == 0) {
      app.toast('这个任务还没有字幕');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            SubsViewPage(app: app, job: j, askTranslate: askTranslate),
        settings: const RouteSettings(name: 'subs_view'),
      ),
    );
  }

  Future<void> _export(SubJob j) async {
    final abs = app.api.absolute(
      '/api/v1/subs/${Uri.encodeComponent(j.id)}/srt',
    );
    final tok = app.session.token;
    final where = await app.transfers.downloadRaw(
      app.api,
      '${subStem(j.name)}.srt',
      abs,
      headers: {if ((tok ?? '').isNotEmpty) 'Authorization': 'Bearer $tok'},
    );
    app.toast(where == null ? '导出失败' : '已存到 $where');
  }

  /// 重新转写：整片重转（会覆盖现有字幕）
  ///
  /// 路径和源必须用任务里记的原始值：115 的片子写死成 nas 会 404，
  /// 拼 folder/name 也会因为文件夹名和文件名不一致而找不到。
  Future<void> _again(SubJob j) async {
    final path = j.path.isNotEmpty ? j.path : j.name;
    try {
      await app.api.subsAdd(
        path,
        name: j.name,
        model: app.session.subModel,
        live: false,
        source: j.source.isEmpty ? 'nas' : j.source,
        again: true,
      );
      app.toast('已重新排入转写');
      await _load();
    } catch (e) {
      final m = '$e';
      // 409 busy：这条正在转，服务端拒绝重排（老 worker 还在往里写段落）
      app.toast(m.contains('busy') ? '这个任务正在转写，先停止再重写' : '提交失败：$m');
    }
  }

  Future<void> _del(SubJob j) async {
    forgetTranslator(j.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除这条听任务？'),
        content: Text(j.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFE45E53))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await app.api.subsDelete(j.id);
      if (!mounted) return;
      setState(() => jobs = jobs.where((x) => x.id != j.id).toList());
      app.toast('已删除');
    } catch (e) {
      app.toast('删除失败：$e');
    }
  }

  List<SubJob> get _shown {
    if (tab == 0) return jobs.where((j) => j.running).toList();
    if (tab == 2) return jobs.where((j) => j.failed).toList();
    return jobs.where((j) => j.done).toList();
  }

  String _mmss(num sec) {
    final s = sec.round();
    if (s <= 0) return '00:00';
    final m = s ~/ 60;
    final r = s % 60;
    if (m >= 60) {
      return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final done = jobs.where((j) => j.done).length;
    final stopped = jobs.where((j) => j.failed).length;
    final running = jobs.where((j) => j.running).length;

    return Scaffold(
      backgroundColor: tone.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 14, 2),
              child: Row(
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
                  Text(
                    '听监控',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: tone.ink,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _load(),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: UIIcon('refresh', size: 19, color: tone.ink3),
                    ),
                  ),
                ],
              ),
            ),
            // 中枢状态
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
              child: Row(
                children: [
                  _pill(
                    tone,
                    online ? '中枢正常' : '中枢离线',
                    online ? const Color(0xFF0E9D78) : const Color(0xFFE45E53),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    err.isNotEmpty
                        ? '连不上听服务'
                        : '队列 $running 在转 · $queued 排队 · 实时听不进队列',
                    style: TextStyle(fontSize: 11.5, color: tone.ink3),
                  ),
                ],
              ),
            ),
            // 同时听译
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Text(
                    '同时转写',
                    style: TextStyle(fontSize: 13, color: tone.ink2),
                  ),
                  const Spacer(),
                  for (final n in const [1, 2, 3]) ...[
                    GestureDetector(
                      onTap: () async {
                        try {
                          await app.api.subsSetMax(n);
                          if (!context.mounted) return;
                          setState(() => maxActive = n);
                          app.toast('同时转写 $n 个');
                        } catch (e) {
                          app.toast('设置失败：$e');
                        }
                      },
                      child: Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: maxActive == n ? tone.ac : tone.surface2,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '$n 个',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: maxActive == n ? Colors.white : tone.ink2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // 分页
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: tone.surface2,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Row(
                  children: [
                    _tab(tone, 0, '进行中${running > 0 ? ' $running' : ''}'),
                    _tab(tone, 1, '已转好 $done'),
                    _tab(tone, 2, '已停止 $stopped'),
                  ],
                ),
              ),
            ),
            Expanded(
              child: loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : (_shown.isEmpty
                        ? Center(
                            child: Text(
                              tab == 0
                                  ? '队列是空的 · 实时听不占队列'
                                  : (tab == 2 ? '没有停掉的任务' : '还没有转好的字幕'),
                              style: TextStyle(
                                fontSize: 12.5,
                                color: tone.ink3,
                              ),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _load,
                            color: tone.ac,
                            backgroundColor: tone.surface,
                            child: ListView.separated(
                              padding: const EdgeInsets.fromLTRB(12, 2, 12, 40),
                              itemCount: _shown.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (c, i) => _card(tone, _shown[i]),
                            ),
                          )),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tab(Tone tone, int i, String label) => Expanded(
    child: GestureDetector(
      onTap: () => setState(() => tab = i),
      child: Container(
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tab == i ? tone.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: tab == i ? FontWeight.w700 : FontWeight.w500,
            color: tab == i ? tone.ink : tone.ink3,
          ),
        ),
      ),
    ),
  );

  Widget _pill(Tone tone, String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: color,
      ),
    ),
  );

  Widget _card(Tone tone, SubJob j) {
    final tr = _trOf(j);
    final pct = j.done
        ? 1.0
        : (j.dur > 0 ? (j.doneUntil / j.dur).clamp(0.0, 1.0) : 0.0);
    final color = j.done
        ? const Color(0xFF0E9D78)
        : (j.failed ? const Color(0xFFE45E53) : tone.ac);
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  j.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: tone.ink,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _pill(tone, j.hudLabel, color),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              UIIcon('folder', size: 12, color: tone.ink3),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  j.folder.isEmpty ? (j.lang.isEmpty ? '—' : j.lang) : j.folder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: tone.ink3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          // 绿条＝转写进度；开始翻译后蓝条压在上面，长度＝翻译进度
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: SizedBox(
              height: 5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LinearProgressIndicator(
                    value: (j.running && j.dur <= 0) ? null : pct.toDouble(),
                    minHeight: 5,
                    backgroundColor: tone.surface2,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                  if (tr.active || tr.done)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: tr.done ? 1 : tr.progress,
                        heightFactor: 1,
                        child: const ColoredBox(color: _blue),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            [
              j.done && j.dur > 0
                  ? '${_mmss(j.dur)} / ${_mmss(j.dur)}'
                  : j.dur > 0
                  ? '${_mmss(j.doneUntil)} / ${_mmss(j.dur)}'
                  : (j.doneUntil > 0 ? '已转至 ${_mmss(j.doneUntil)}' : '转写中'),
              j.state == 'probing'
                  ? '读取片长…'
                  : (j.dur > 0 ? '${(pct * 100).round()}%' : ''),
              '${j.segments} 段',
              if (tr.active)
                '译文 ${tr.pct}%'
              else if (tr.done)
                '译文 ${subLangName(tr.lang)}'
              // 本地翻译器没在跑（换设备/重装/缓存没了）也要如实显示任务里已有的译文
              else if (j.serverTr > 0)
                '译文 ${(j.serverTr * 100 / j.segments).round()}%',
              if (j.running && j.eta > 0)
                '剩 ${j.eta >= 3600 ? '${(j.eta / 3600).toStringAsFixed(1)} 小时' : '${(j.eta / 60).round()} 分钟'}',
            ].where((s) => s.isNotEmpty).join(' · '),
            style: TextStyle(
              fontSize: 11.5,
              color: tone.ink3,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 10),
          // 五个按钮，窄屏会换行（以前用 Row 会溢出 4px）
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _btn(tone, '查看', () => _open(j), disabled: j.segments == 0),
              // 翻译按钮只在「听完」之后才出现：转写没完就翻，翻到的是残缺稿，
              // 用户翻完再转完，译文和原文对不上，还得整片重翻。
              if (j.state == 'done')
                _btn(
                  tone,
                  !tr.active && !tr.done
                      ? '翻译'
                      : tr.busy
                      ? '翻译中 ${tr.pct}%'
                      : tr.paused
                      ? '已暂停 ${tr.pct}% · 继续'
                    : tr.audit().complete
                      ? '已翻译'
                      : '已译 ${tr.audit().ok}/${tr.audit().total}',
                  () => _translate(j),
                  disabled: j.segments == 0,
                  solid: tr.busy
                      ? _blue
                      : tr.paused
                      ? _red
                      : tr.done
                      ? _green
                      : null,
                ),
              _btn(
                tone,
                '导出 .srt',
                () => _export(j),
                disabled: j.segments == 0,
              ),
              _btn(tone, '重新转写', () => _again(j)),
              _btn(tone, '删除', () => _del(j), danger: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _btn(
    Tone tone,
    String label,
    VoidCallback onTap, {
    bool danger = false,
    bool disabled = false,
    Color? solid, // 实心底色：翻译中蓝 / 暂停红 / 完成绿
  }) => GestureDetector(
    onTap: disabled ? null : onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: solid ?? (danger ? const Color(0x14E45E53) : tone.surface2),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: disabled
              ? tone.ink3.withValues(alpha: 0.5)
              : solid != null
              ? Colors.white
              : (danger ? const Color(0xFFE45E53) : tone.ink2),
        ),
      ),
    ),
  );
}

/// 译文完整性面板：已译多少、哪些其实是原文，可直接补翻或整片重翻
class _TrAuditSheet extends StatelessWidget {
  final String lang;
  final TrAudit audit;
  const _TrAuditSheet({required this.lang, required this.audit});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final ok = audit.complete;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                UIIcon(
                  ok ? 'check' : 'info',
                  size: 16,
                  color: ok ? const Color(0xFF0E9D78) : const Color(0xFFE0A030),
                ),
                const SizedBox(width: 7),
                Text(
                  '译文完整性 · $lang',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: tone.ink,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              audit.summary,
              style: TextStyle(fontSize: 12.5, height: 1.5, color: tone.ink2),
            ),
            if (!ok && audit.sameAsSource.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '「仍是原文」多数是失败兜底的句子（人名、数字本来就不用翻也会命中）。',
                style: TextStyle(fontSize: 11, height: 1.5, color: tone.ink3),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!ok)
                  _SheetBtn(
                    label: '补翻 ${audit.missing.length} 句',
                    solid: const Color(0xFF007AFF),
                    onTap: () => Navigator.pop(context, 'redo'),
                  ),
                _SheetBtn(
                  label: '全部重翻',
                  onTap: () => Navigator.pop(context, 'all'),
                ),
                _SheetBtn(
                  label: '查看双语',
                  onTap: () => Navigator.pop(context, 'view'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color? solid;
  const _SheetBtn({required this.label, required this.onTap, this.solid});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: solid ?? tone.surface2,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: solid == null ? tone.ink2 : Colors.white,
          ),
        ),
      ),
    );
  }
}
