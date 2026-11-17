import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';

/// 听译任务在列表里的归一化视图（服务端 /subs 的 jobs 已经是这个口径）
class SubJob {
  final String id;
  final String name;
  final String folder;
  final String state;
  final double pct;
  final int segments;
  final String msg;
  final String lang;
  final String source; // nas / nas115 / pc…（重新转写要用）
  final String path; // 片子原始路径
  final double dur;
  final double doneUntil;
  final bool live;

  /// 拖动后正在换位置：服务端把 state 置成 cancelled 好让转写工放手，
  /// 但那不是「停了」——界面写「已停止」会让人以为听译被关掉。
  final bool relocating;

  /// 这条任务本来是「实时听」还是「整片队列听」。停了之后 live 会变 false，
  /// 只能靠这个字段区分（否则实时听跑完的片子在界面上显示成队列听）。
  final bool fromLive;
  final double speed; // 转写速度（倍速）
  final double eta; // 预计剩余秒数
  final int pending; // 还没译文的句数（服务端任务里的译文）

  const SubJob({
    required this.id,
    required this.name,
    required this.folder,
    required this.state,
    required this.pct,
    required this.segments,
    required this.msg,
    required this.lang,
    this.source = 'nas',
    this.path = '',
    this.dur = 0,
    this.doneUntil = 0,
    this.live = false,
    this.fromLive = false,
    this.relocating = false,
    this.speed = 0,
    this.eta = 0,
    this.pending = 0,
  });

  factory SubJob.from(Map<String, dynamic> j) => SubJob(
    id: j['id'] as String? ?? '',
    name: (j['name'] as String?)?.isNotEmpty == true
        ? j['name'] as String
        : (j['folder'] as String? ?? ''),
    folder: j['folder'] as String? ?? '',
    state: j['state'] as String? ?? '',
    pct: (j['pct'] as num?)?.toDouble() ?? 0,
    segments: (j['segments'] as num?)?.toInt() ?? 0,
    msg: j['msg'] as String? ?? '',
    lang: j['lang'] as String? ?? '',
    source: j['source'] as String? ?? 'nas',
    path: j['path'] as String? ?? '',
    dur: (j['dur'] as num?)?.toDouble() ?? 0,
    doneUntil: (j['done_until'] as num?)?.toDouble() ?? 0,
    live: j['live'] == true,
    relocating: j['relocating'] == true,
    fromLive: (j['mode'] as String? ?? '') == 'live' || j['live'] == true,
    pending: (j['pending'] as num?)?.toInt() ?? 0,
  );

  /// 服务端任务里已经有译文的句数（区别于手机本地翻译器的进度）
  int get serverTr => segments <= 0 ? 0 : (segments - pending).clamp(0, segments);

  /// 实时任务没有总时长（dur=0），只能报「已经转到哪儿」
  String get doneLabel {
    final t = doneUntil.round();
    final m = t ~/ 60, r = t % 60;
    return m >= 60
        ? '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}'
        : '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  bool get running =>
      relocating ||
      state == 'asr' ||
      state == 'translating' ||
      state == 'queued' ||
      state == 'probing';
  bool get done => state == 'done';
  bool get failed =>
      state == 'error' || state == 'cancelled' || state == 'cancel';

  /// 听只管转写；译是播放时实时做的，不进这个状态机
  String get stateLabel => switch (state) {
    'queued' => '排队中',
    'probing' => '读取片长',
    'asr' => '转写中',
    'translating' => '转写中',
    'done' => '已转好',
    'error' => '出错',
    'cancelled' || 'cancel' => '已停止',
    _ => state.isEmpty ? '未知' : state,
  };

  /// 播放页胶囊用的措辞：实时听有自己的几种临时状态，不能直接套 stateLabel
  /// （cancelled 会被说成「已停止」，done 会被说成「已转好」，都吓人）。
  String get hudLabel {
    if (relocating) return '换位置中';
    if (live) {
      if (state == 'done' || state == 'finished') return '本窗已转完';
      if (state == 'cancelled' || state == 'cancel') return '已停止';
      if (state == 'queued') return '排队中';
    }
    return stateLabel;
  }

  /// 实时任务没有总时长，进度条画不出来，只能显示「转到第几分钟」
  bool get noTotal => dur <= 0;
}

/// 文件名去扩展名，用来和任务的 name/folder 比对（照服务端 _match 的思路）
String subStem(String path) {
  final base = path.replaceAll('\\', '/').split('/').last;
  final dot = base.lastIndexOf('.');
  return (dot > 0 ? base.substring(0, dot) : base).toLowerCase();
}

/// 这个视频对应哪个听译任务
/// 同一部片可能同时有「队列听」和好几条「实时听」（每拖一次进度条就新开一条）。
/// 播放器必须能看到**全部**这些任务的段，只取一条的话拖回去就没字幕了。
List<SubJob> matchJobs(List<SubJob> jobs, String path) {
  final want = subStem(path);
  if (want.isEmpty) return const [];
  final scored = <(int, SubJob)>[];
  for (final j in jobs) {
    final jn = subStem(j.name);
    final folder = j.folder.toLowerCase();
    var sc = 0;
    if (jn.isNotEmpty && (jn == want || want.startsWith(jn))) {
      sc = 3;
    } else if (folder.isNotEmpty &&
        (folder == want ||
            want.startsWith(folder) ||
            folder.startsWith(want))) {
      sc = 2;
    } else if (jn.isNotEmpty && (jn.contains(want) || want.contains(jn))) {
      sc = 1;
    }
    if (sc > 0) scored.add((sc, j));
  }
  scored.sort((a, b) {
    if (a.$1 != b.$1) return b.$1.compareTo(a.$1);
    // 同分：正在跑的、实时的排前面，播放器优先跟着它们
    if (a.$2.running != b.$2.running) return a.$2.running ? -1 : 1;
    if (a.$2.live != b.$2.live) return a.$2.live ? -1 : 1;
    return b.$2.doneUntil.compareTo(a.$2.doneUntil);
  });
  return scored.map((e) => e.$2).toList();
}

SubJob? matchJob(List<SubJob> jobs, String path) {
  final all = matchJobs(jobs, path);
  return all.isEmpty ? null : all.first;
}

Future<List<SubJob>> fetchJobs(App app, {bool includeLive = false}) async {
  final r = await app.api.subs(includeLive: includeLive);
  final jobs = (r['jobs'] as List?) ?? const [];
  return jobs
      .map((e) => SubJob.from((e as Map).cast<String, dynamic>()))
      .toList();
}

/// 播放页的「听译监控」：2 秒轮询一次，有进度、能开始/停止/导出
class MonitorSheet extends StatefulWidget {
  final App app;
  final Entry entry;
  final double startAt;
  final void Function(List<List<dynamic>> cues) onAttach;

  const MonitorSheet({
    super.key,
    required this.app,
    required this.entry,
    required this.startAt,
    required this.onAttach,
  });

  @override
  State<MonitorSheet> createState() => _MonitorSheetState();
}

class _MonitorSheetState extends State<MonitorSheet> {
  SubJob? job;
  bool loading = true;
  String err = '';
  int maxActive = 1;
  bool busy = false;
  Timer? _timer;
  late String model;
  late bool live;
  bool _inflight = false;
  String note = '';

  @override
  void initState() {
    super.initState();
    model = widget.app.session.subModel;
    live = widget.app.session.subLive;
    _load();
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (_inflight) return;
    _inflight = true;
    try {
      final jobs = await fetchJobs(widget.app, includeLive: true);
      Map<String, dynamic>? cfg;
      try {
        cfg = await widget.app.api.subsConfig();
      } catch (_) {}
      if (!mounted) return;
      final hit = matchJob(jobs, widget.entry.path);
      setState(() {
        job = hit;
        loading = false;
        err = '';
        final m = (cfg?['max_active'] as num?)?.toInt();
        if (m != null) maxActive = m;
      });
      // 转完了就把字幕接上
      if (hit != null && hit.done && hit.segments > 0) _attach();
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

  Future<void> _attach() async {
    try {
      final r = await widget.app.api.subsFor(
        widget.entry.path,
        source: widget.app.source,
      );
      final segs = (r['segments'] as List?) ?? const [];
      if (segs.isEmpty) return;
      widget.onAttach(segs.map((e) => (e as List).cast<dynamic>()).toList());
    } catch (_) {}
  }

  Future<void> _start() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final r = await widget.app.api.subsAdd(
        widget.entry.path,
        name: widget.entry.name,
        model: model,
        live: live,
        start: (widget.startAt - 2).clamp(0, 1e9),
        source: widget.app.source,
        lang: widget.app.session.subsLang,
      );
      setState(
        () => note = r['ok'] == true
            ? (live ? '已开始实时听译，第一句约 10 秒出来' : '已提交整片听译，排队中')
            : '提交失败',
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      final m = '$e';
      setState(
        () =>
            note = m.contains('queue_full') ? '听译队列已满，把「同时听译」调大再试' : '提交失败：$m',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _stop() async {
    final id = job?.id;
    if (id == null) return;
    try {
      await widget.app.api.subsCancel(id);
      widget.app.toast('已停止');
      await _load();
    } catch (e) {
      widget.app.toast('停止失败：$e');
    }
  }

  Future<void> _delete() async {
    final j = job;
    if (j == null) return;
    try {
      await widget.app.api.subsDelete(j.id);
      if (!mounted) return;
      setState(() => job = null);
      widget.app.toast('已删除');
    } catch (e) {
      setState(() => note = '删除失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final j = job;
    final pct = j?.pct ?? 0;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.86,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '听译监控',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const UIIcon(
                      'close',
                      size: 18,
                      color: Color(0xFF9A9AA2),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 这一集的状态 + 进度
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
                decoration: BoxDecoration(
                  color: const Color(0x14FFFFFF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          loading
                              ? '读取中…'
                              : (j == null
                                    ? '还没有字幕'
                                    : '${j.hudLabel}${j.segments > 0 ? ' · ${j.segments} 句' : ''}'
                                        '${(j.segments > 0 && j.pending > 0) ? ' · 译文 ${j.serverTr}/${j.segments}' : ''}'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        if (j != null && j.running)
                          Text(
                            pct > 0
                                ? '${pct.toStringAsFixed(0)}%'
                                : (j.doneUntil > 0
                                      ? '已转至 ${j.doneLabel}'
                                      : '转写中'),
                            style: const TextStyle(
                              color: Color(0xFF7FB3FF),
                              fontSize: 12.5,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: j == null
                            ? 0
                            : (j.done
                                  ? 1
                                  : (j.running && pct <= 0
                                        ? null // 读片长 / 实时任务：还没有总时长，用滚动条表示在走
                                        : (pct / 100).clamp(0, 1).toDouble())),
                        minHeight: 5,
                        backgroundColor: const Color(0x1FFFFFFF),
                        valueColor: AlwaysStoppedAnimation(
                          j?.failed == true ? const Color(0xFFE45E53) : tone.ac,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      err.isNotEmpty
                          ? '连不上听译服务：$err'
                          : (note.isNotEmpty
                                ? note
                                : (j == null
                                      ? '点下面的「开始听译」，NAS 会拉流识别，好了自动挂到画面上。'
                                      : (j.msg.isNotEmpty ? j.msg : '—'))),
                      style: const TextStyle(
                        color: Color(0xFF9A9AA2),
                        fontSize: 11.5,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                '识别精度',
                style: TextStyle(color: Color(0xFF9A9AA2), fontSize: 11.5),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _chip('高质量', model == 'turbo', () {
                    setState(() => model = 'turbo');
                    widget.app.session
                      ..subModel = 'turbo'
                      ..save();
                  }),
                  const SizedBox(width: 8),
                  _chip('快速', model == 'small', () {
                    setState(() => model = 'small');
                    widget.app.session
                      ..subModel = 'small'
                      ..save();
                  }),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                '实时听译',
                style: TextStyle(color: Color(0xFF9A9AA2), fontSize: 11.5),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _chip('开（边播边转）', live, () {
                    setState(() => live = true);
                    widget.app.session
                      ..subLive = true
                      ..save();
                  }),
                  const SizedBox(width: 8),
                  _chip('关（整片转）', !live, () {
                    setState(() => live = false);
                    widget.app.session
                      ..subLive = false
                      ..save();
                  }),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                '同时听译',
                style: TextStyle(color: Color(0xFF9A9AA2), fontSize: 11.5),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final n in const [1, 2, 3]) ...[
                    _chip('$n 个', maxActive == n, () async {
                      try {
                        await widget.app.api.subsSetMax(n);
                        if (!context.mounted) return;
                        setState(() => maxActive = n);
                        widget.app.toast('同时听译 $n 个');
                      } catch (e) {
                        widget.app.toast('设置失败：$e');
                      }
                    }),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _Action(
                      icon: 'subs',
                      label: j == null ? '开始听译' : (j.running ? '重新听译' : '重新听译'),
                      onTap: _start,
                    ),
                  ),
                ],
              ),
              if (j != null) ...[
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: j.running ? _stop : _delete,
                  child: Container(
                    width: double.infinity,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0x1FE45E53),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Text(
                      j.running ? '停止听译' : '删除这条听译',
                      style: TextStyle(
                        color: Color(0xFFE45E53),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback tap) => GestureDetector(
    onTap: tap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: on ? const Color(0xFF1677F8) : const Color(0x1FFFFFFF),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: on ? Colors.white : const Color(0xFFCFCFD4),
        ),
      ),
    ),
  );
}

class _Action extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback onTap;
  const _Action({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
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
    );
  }
}
