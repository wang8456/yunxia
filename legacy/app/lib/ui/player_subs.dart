part of 'player_page.dart';

/// 听译与字幕：实时听会话、队列听拉取、内封字幕、翻译、cue 窗口。
///
/// 这些逻辑只依赖下面声明的那几个宿主成员（播放器控制器、当前条目、页面），
/// 所以整块搬到 part 文件里，`_PlayerPageState` 里不再堆 1000 行听译代码。
mixin _SubsMixin<T extends StatefulWidget> on State<T> {
  /// 播放器控制器（宿主提供）
  MKPlayback get vc;

  /// 当前播放的条目
  Entry get entry;

  /// 宿主页面（取 app / url）
  PlayerPage get page;

  /// 播放器是否已初始化（宿主维护）
  bool get ready;

  /// 当前音轨的 ffprobe 序号（宿主按音轨列表算）
  int? get asrTrack;

  // —— 实时听/听译相关的状态（跟着这套逻辑一起搬过来）——
  List<Map<String, dynamic>> _embSubs = const [];
  int? _mpvSid;
  bool _aiDone = false;
  bool _queueBusy = false;
  DateTime _liveRestartAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _liveRelocAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _jumpInflight = false;
  bool _liveOn = false;
  bool _liveLocating = false;

  // cue 结构统一 [[起, 止, 原文, 译文], ...]
  List<List<dynamic>> _fileCues = const [];
  List<List<dynamic>> _aiCues = const [];
  String _subW = ''; // '' | 'file' | 'ai'
  String? _subFileName;
  bool _subsOn = true;
  // 旧版 SUBP 的三项：延迟（秒）/ 字号倍率 / 纵向偏移
  double _subDelay = 0;
  double _subSize = 1;
  double _subPos = 0;
  double? _resumedFrom;

  // 这一集的听译任务（有就显示进度，转完自动挂字幕）
  SubJob? _subJob;
  Timer? _jobPoll;
  bool _jobInflight = false;

  /// 每条听译任务已经拉到哪个时间点（拖进度条会新开任务，各拉各的）
  final Map<String, double> _pulledTo = {};

  /// 每条任务自己的段落：整片重拉时只替换这一条，别把别的任务（别的窗口）冲掉
  final Map<String, List<List<dynamic>>> _byJob = {};
  final Map<String, int> _seenSegs = {};

  /// 这一次「打开播放器」的会话号。实时听只活在这个会话里：
  /// 退出播放器 / 被系统杀掉 / 断网，服务端都会把这条会话连段落一起清掉。
  String _liveSession = '';

  /// 播放器开着就每 5 秒给服务端打一次心跳（暂停也算活着）
  Timer? _livePing;

  /// 刚刚起的这条实时听任务的 id。实时听不列在 /subs 列表里，
  /// 起完必须靠这个 id 直接拉 /subs/{id}，否则永远拿不到句数和状态
  /// （界面卡在「转写中 0%」，而且没有心跳 → 15 秒后被清扫器当成遗孤杀掉）。
  String _liveWantId = '';

  /// 正在退出/切后台：这之后不许再起实时听。
  /// 退出时是先「结束会话」再拆控制器，这中间 _tick 还可能跑一轮，
  /// 一旦看到「没任务 + 听字幕」就又把任务建回来 —— 用户看到的就是「退了还在转」。
  bool _closing = false;

  /// 这个播放器开过的每一条实时听任务（拖动一次就多一条）。
  /// 关的时候必须全部撤掉 —— 只撤界面显示的那条，剩下的会一直转到片尾。
  final Set<String> _liveIds = {};

  /// 拖动/快进之后强制拉一次（不然要等 6 秒那一轮）
  bool _forcePull = false;
  int _aiTick = 0;

  void _startJobPoll() {
    _jobPoll?.cancel();
    _jobPoll = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _pollJob(),
    );
    _pollJob();
  }

  Future<void> _pollJob() async {
    if (_jobInflight) return;
    _jobInflight = true;
    try {
      if (_subJob == null && _liveWantId.isNotEmpty) {
        try {
          final d = await page.app.api.subsDetail(_liveWantId);
          if (!mounted) return;
          setState(() => _subJob = SubJob.from(d));
          await _pullLiveSrt(_liveWantId);
          _startPingLoop();
          return;
        } catch (_) {
          // 还没建好/已经被清掉：下一轮再看
        }
      }
      final jobs = await fetchJobs(page.app, includeLive: true);
      if (!mounted) return;
      _queueBusy = jobs.any((j) =>
          !j.live && (j.state == 'asr' || j.state == 'translating' || j.running));
      // 一部片可能有好几条任务（队列听 + 每次拖动新开的实时听），
      // 全都拉，合并成一条时间线，拖回去才还有字幕。
      final hits = matchJobs(jobs, entry.path);
      final pos0 = vc.value.position.inMilliseconds / 1000.0;
      if (hits.isEmpty) {
        // /subs 列表里没有不代表这条片子没听过：实时任务停了之后登记记录会被清掉
        // （点关、播放器关 60 秒收工），但 hub 里那条还在。这时候要按 id 继续拉，
        // 不能把 _subJob 清空 —— 一清空画面上的字幕会整片消失，用户以为「字幕没了」。
        final cur = _subJob;
        if (cur != null && cur.id.isNotEmpty) {
          // 只有「任务本身查不到」才算死。SRT 那一步单独 try：新任务还没出
          // 第一段时它可能 404 —— 把这两个混在一个 catch 里，就会把正常在转
          // 的会话当成幽灵任务反复重开（用户实测：「实时听变慢了」，其实每
          // 30–50 秒被重启一次，每次都要重新热身、重推窗口）。
          Map<String, dynamic>? detail;
          try {
            detail = await page.app.api.subsDetail(cur.id);
          } catch (e) {
            final msg = '$e';
            final dead = msg.contains('404') ||
                msg.contains('no such job') ||
                msg.contains('not found');
            if (!dead) return; // 网络抖一下：这一轮什么都别做
            if (mounted) setState(() => _subJob = null);
            final liveIntent = _liveOn || (_subsOn && _subW == 'ai');
            if (liveIntent && !_closing) {
              unawaited(_jumpLive(pos0)); // 任务没了就按当前位置重开
            }
            return;
          }
          // 任务不在 /subs 列表里时（实时听本来就不入列），这里要把状态刷回去，
          // 否则 _subJob 冻在最后一次的值，界面永远显示「排队中」。
          if (mounted) {
            final fresh = SubJob.from(detail);
            if (fresh.state != cur.state ||
                fresh.running != cur.running ||
                (fresh.doneUntil - cur.doneUntil).abs() > 0.5) {
              setState(() => _subJob = fresh);
            }
          }
          try {
            await _pullLiveSrt(cur.id);
          } catch (_) {
            // 还没出段：下一轮再拉，别动会话
          }
          if (!_aiDone) {
            unawaited(
              page.app.api.subsAt(cur.id, pos0).catchError((Object _) {}),
            );
          }
          return;
        }
        return;
      }
      // 界面上跟着「实时/正在转」的那条；没有就跟着第一条
      final hit = hits.firstWhere(
        (h) => h.live || h.running,
        orElse: () => hits.first,
      );
      for (final h in hits) {
        if (h.live && (h.running || h.state == 'queued')) _liveIds.add(h.id);
      }
      // 只有「真的在转」的实时任务才能把开关重新打开。以前只看 live 标记：
      // 用户点过关之后，服务端那条记录还挂着 live=1，这里又把它拉起来 ——
      // 表现就是「点了关闭没真关」。
      if (!_liveOn &&
          hits.any((h) => h.live && (h.running || h.state == 'queued'))) {
        _liveOn = true;
      }
      if (_subJob?.id != hit.id || _subJob?.running != hit.running) {
        setState(() => _subJob = hit);
      }
      if (_liveLocating && hit.running) {
        _liveLocating = false;
        if (mounted) setState(() {});
      }
      // 播放头必须报给**每一条**在转的任务：转写工靠它决定往前转多少（LIVE_AHEAD）
      // 和跳到哪儿。只报给 UI 显示的那条，另一条（比如队列听）就永远不动，
      // 拖动之后那条的字幕就再也不更新了。
      final pos = vc.value.position.inMilliseconds / 1000.0;
      for (final h in hits) {
        if (!h.live && !h.running) continue;
        unawaited(page.app.api.subsAt(h.id, pos).catchError((Object _) {}));
      }
      // 实时任务的段落在 hub 里是不断追加的，/subs/for 只给「完成」的整片；
      // 这里直接拉 /subs/{id}/srt（实时任务也能拉到），段落变多就重挂一次。
      _aiTick++;
      // 译是实时补的：整片听的任务也得边播边把新译文拿回来，
      // 所以除了「段数变了」，每 4 次轮询（约 6 秒）也强制刷一遍。
      final due = _aiTick % 4 == 0;
      var anyLive = false;
      final force = _forcePull;
      _forcePull = false;
      for (final h in hits) {
        if (h.segments <= 0) continue;
        if (h.running || h.live) anyLive = true;
        final grew = h.segments != _seenSegs[h.id];
        if (!grew && !due && !force) continue;
        _seenSegs[h.id] = h.segments;
        await _pullLiveSrt(h.id);
      }
      // 以前只要「没在转」就停轮询。换位置那一两秒 state=cancelled、live=false，
      // 于是轮询把自己停了，字幕和领先秒数冻住，直到用户再拖一次 —— 看着像没反应。
      if (!anyLive && !(_liveOn && _liveWantId.isNotEmpty)) _jobPoll?.cancel();
    } catch (_) {
      /* 网络抖一下继续轮询 */
    } finally {
      _jobInflight = false;
    }
  }

  void _newLiveSession() {
    _liveSession =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '-${identityHashCode(this).toRadixString(36)}';
  }

  void _startPingLoop() {
    _livePing?.cancel();
    _livePing = Timer.periodic(const Duration(seconds: 5), (_) {
      final id = _subJob?.id ?? '';
      if (id.isEmpty) return;
      page.app.api.subsPing(id).catchError((Object _) => <String, dynamic>{});
    });
  }

  Future<void> _endLiveSession() async {
    _livePing?.cancel();
    _livePing = null;
    _liveWantId = '';
    final ids = <String>{..._liveIds};
    // 只有实时听的会话才收尾。队列听（含「已听完」整片字幕）是后台任务，
    // 退出播放器把它 end 掉 = 用户已转好/已译好的字幕被删（用户报的 bug）。
    final shown = _subJob;
    if (shown != null && (shown.live || shown.fromLive)) ids.add(shown.id);
    _liveIds.clear();
    // 按会话清一次：退出这一刻可能还不知道任务 id（刚点开就退、或者拖完
    // 那发换位置还在路上），服务端会把这个会话起的实时任务全抹掉。
    try {
      await page.app.api.subsEnd(
        ids.isEmpty ? '-' : ids.first,
        session: _liveSession,
      );
    } catch (e) {
      // 结束失败 = 服务端留一条幽灵实时任务，下次开播会撞上
      debugPrint('实时听：结束会话失败 $e');
    }
    for (final id in ids.skip(1)) {
      try {
        await page.app.api.subsEnd(id, session: _liveSession);
      } catch (e) {
        debugPrint('实时听：结束会话 $id 失败 $e');
      }
    }
    // 兜底：这条片子上万一还有别的实时任务（老版本留下的），一并撤掉
    try {
      await page.app.api.subsCancelLive(entry.path, name: entry.name);
    } catch (_) {}
  }

  Future<void> _stopLiveSubs({bool keepCues = false}) async {
    final wasOn =
        _liveOn ||
        _liveIds.isNotEmpty ||
        (_subJob?.live ?? false) ||
        (_subJob?.running ?? false);
    _liveOn = false;
    await _killLiveJobs();
    _jobPoll?.cancel();
    _jobPoll = null;
    if (!mounted) return;
    setState(() {
      // keepCues 时保留队列任务引用：播放页的译文缓存是按任务 id 找的，
      // 引用一丢，关一下字幕回来译文就成 0 了。
      if (!(keepCues && _subJob != null && !(_subJob!.live))) {
        _subJob = null;
      }
      if (!keepCues) {
        _aiCues = const <List<dynamic>>[];
        _byJob.clear();
        _pulledTo.clear();
        _seenSegs.clear();
      }
    });
    if (wasOn) {
      final left = await _liveStillRunning();
      page.app.toast(
        left
            ? '还有任务没停掉，再点一次「关」'
            : (keepCues ? '实时听已停 · 切回「听字幕」会接着转' : '已关闭实时听'),
      );
    }
  }

  Future<void> _killLiveJobs() async {
    // 1) 先按文件让服务端全撤（它自己维护登记表，比客户端记 id 靠得住）
    try {
      await page.app.api.subsCancelLive(entry.path, name: entry.name);
    } catch (_) {}
    // 2) 客户端记过的 id 再补一刀（服务端版本旧、没有 cancel_all 时兜底）
    final ids = <String>{..._liveIds};
    final shown = _subJob;
    if (shown != null && (shown.live || shown.running)) ids.add(shown.id);
    _liveIds.clear();
    for (final id in ids) {
      try {
        await page.app.api.subsCancel(id);
      } catch (_) {}
    }
    // 3) 回读确认：还真在转就再撤一轮，最多两轮
    for (var round = 0; round < 2; round++) {
      List<SubJob> live;
      try {
        final jobs = await fetchJobs(page.app, includeLive: true);
        live = matchJobs(
          jobs,
          entry.path,
        ).where((h) => h.live && (h.running || h.state == 'queued')).toList();
      } catch (_) {
        return;
      }
      if (live.isEmpty) return;
      for (final h in live) {
        try {
          await page.app.api.subsCancel(h.id);
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<bool> _liveStillRunning() async {
    try {
      final jobs = await fetchJobs(page.app, includeLive: true);
      return matchJobs(
        jobs,
        entry.path,
      ).any((h) => h.live && (h.running || h.state == 'queued'));
    } catch (_) {
      return false;
    }
  }

  bool _cuesCover(double t) => cuesCover(_aiCues, t);

  Future<List<Map<String, dynamic>>> _probeEmbSubs() async {
    try {
      final list = await page.app.api.embeddedSubs(
        page.app.source,
        entry.path,
      );
      if (mounted && list.isNotEmpty) setState(() => _embSubs = list);
      return list;
    } catch (e) {
      debugPrint('内封字幕探测失败 $e');
      return const [];
    }
  }

  /// mpv 的 sid 是「字幕轨序号」（1-based），服务端返回的 s 才是它；
  /// i 是 ffprobe 的绝对流序号（中间还夹着视频/音频轨），直接当 sid 用会开到
  /// 不存在的轨上 —— 这就是图形字幕点了没反应的根因。
  int _sidOf(Map<String, dynamic> e) =>
      (e['s'] as num?)?.toInt() ?? (e['i'] as num?)?.toInt() ?? 0;

  List<Map<String, dynamic>> get _imgSubs =>
      [for (final e in _embSubs) if (e['text'] != true) e];

  String _embLabel(Map<String, dynamic> e) {
    final t = (e['title'] as String? ?? '').trim();
    if (t.isNotEmpty) return t;
    final l = (e['lang'] as String? ?? '').trim();
    return l.isEmpty ? '字幕${(e['i'] as num?)?.toInt() ?? 0}' : l;
  }

  Future<void> _pickEmbSub(int? idx) async {
    setState(() {
      _mpvSid = idx;
      // 开图形字幕时收起 App 自己那层，别两层叠在一起
      if (idx != null) _subsOn = false;
    });
    await vc.setEmbeddedSub(idx);
    page.app.toast(
      idx == null ? '已关内封字幕' : '内封图形字幕（画面自带，不能翻译）',
    );
  }

  Future<void> _loadEmbeddedSubs() async {
    try {
      final list = await _probeEmbSubs();
      if (!mounted) return;
      final text = list.where((e) => e['text'] == true).toList();
      if (text.isEmpty) return;
      bool zh(Map<String, dynamic> e) =>
          zhSubTag('${e['lang'] ?? ''}${e['title'] ?? ''}');
      final pick = text.firstWhere(
        zh,
        orElse: () => text.firstWhere(
          (e) => e['default'] == true,
          orElse: () => text.first,
        ),
      );
      final idx = (pick['i'] as num?)?.toInt() ?? 0;
      final label = '内封 ${(pick['lang'] as String? ?? '').trim()}'.trim();
      // 长片抽得慢：最多盯 3 分钟，抽到多少先用多少
      for (var i = 0; i < 60; i++) {
        if (_closing || !mounted) return;
        final r = await page.app.api.embeddedText(
          page.app.source,
          entry.path,
          idx,
        );
        final body = (r['text'] as String?) ?? '';
        final st = (r['state'] as String?) ?? 'running';
        if (body.trim().isNotEmpty) {
          final cues = parseSubtitle(body);
          if (cues.isNotEmpty && mounted && cues.length != _fileCues.length) {
            setState(() {
              _fileCues = cues;
              _subFileName = label;
              if (_subW.isEmpty) _subW = 'file';
            });
            _trAt = DateTime.fromMillisecondsSinceEpoch(0);
          }
        }
        if (st == 'done' || st == 'error') return;
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    } catch (_) {
      /* 抽不了就退回听译：不算错 */
    }
  }

  Future<void> _liveGuard({bool userSeek = false}) async {
    if (_closing || !mounted) return;
    // 判断依据只有两个：这个播放器里开过实时听（_liveOn），或者当前字幕来源
    // 就是「听字幕」。**不能**看 j.live —— 任务这一窗转完 hub 会降成 done，
    // 拿它当条件的话第一次转完就再也不重开，用户看到「拖一下字幕就没了」。
    final liveIntent = _liveOn || (_subsOn && _subW == 'ai');
    if (!liveIntent) return;
    // 刚换过位置就别再发：hub 收到第二发会把第一发刚立起来的窗口 cancel 掉，
    // 表现就是「拖完任务变 done、一句都没有」。
    if (DateTime.now().difference(_liveRelocAt).inMilliseconds < 1500) {
      return;
    }
    // 冷却只挡「自动巡检」反复换位置；用户亲手拖的这一次必须立刻响应，
    // 否则拖过去要等二十几秒才动，看起来就是「拖了没反应」。
    if (!userSeek &&
        DateTime.now().difference(_liveRelocAt) < const Duration(seconds: 45)) {
      return; // 刚换过起转点，等 worker 把新窗口转出来
    }
    if (vc.value.duration <= Duration.zero) return;
    final t = vc.value.position.inMilliseconds / 1000.0;
    final j = _subJob;
    final until = j?.doneUntil ?? 0;
    final anchor = until > 0 ? until : cuesUntil(_aiCues);
    final now = DateTime.now();
    final go = shouldRestartLive(
      t: t,
      covered: _cuesCover(t),
      running: j?.running ?? false,
      anchor: anchor,
      since: userSeek
          ? const Duration(seconds: 30)
          : now.difference(_liveRestartAt),
    );
    if (!go) return;
    _liveRestartAt = now;
    _liveOn = true; // 接管了这条任务，后面的轮询/停止都按「在听」处理
    page.app.toast('换了位置，重新实时听译…');
    await _jumpLive(t);
  }

  Future<void> _jumpLive(double t, {double ahead = 0}) async {
    if (_closing) return;
    // 同一时刻只允许一发换位置：拖一次可能同时触发「跳变检测 + 手势回调」，
    // 两发 relocate 挨着到达会让 hub 把刚立起来的窗口再 cancel 掉，
    // 结果就是「拖完任务变 cancelled、一句都没有」。
    if (_jumpInflight) return;
    _jumpInflight = true;
    try {
      await _jumpLiveInner(t, ahead: ahead);
    } finally {
      _jumpInflight = false;
    }
  }

  Future<void> _jumpLiveInner(double t, {double ahead = 0}) async {
    // 只看「听」出来的句子：同名字幕是另一条链，拿它的覆盖范围当依据会跳错地方
    var start = nextUncovered(_aiCues, t);
    // 已经转过的「静音段」没有句子，nextUncovered 会把它当成没转，原地再来一遍：
    // 每 9 秒重开一次、每次都 0 句，字幕永远不动。用 done_until 把起点顶过去。
    // 只在「起点就在最远处附近」时才往最远处顶（静音段原地重开的场景）。
    // 倒带时 start 远小于最远处，绝不能顶 —— 顶过去就等于「拖回开头却从 34 分
    // 接着转」，实时听看起来彻底不动。
    final dn = _subJob?.doneUntil ?? 0;
    if (_subJob?.state == 'done' && dn > start && dn - start <= 30) start = dn;
    if ((start - t).abs() > 0.5) {
      page.app.toast('这段已有字幕，从 ${_mmss(start)} 接着转');
    }
    if (start < 0) start = 0;
    setState(() => _liveLocating = true);
    // 兜底：25 秒还没跑起来就别再显示「定位中」了
    Future<void>.delayed(const Duration(seconds: 25)).then((_) {
      if (mounted && _liveLocating) setState(() => _liveLocating = false);
    });
    try {
      final rel = await page.app.api.subsRelocate(
        entry.path,
        name: entry.name,
        at: t,
        skipFrom: start,
        source: page.app.source,
        lang: page.app.session.subsLang,
        track: asrTrack,
        session: _liveSession,
        hot: _hotWords,
        ahead: ahead,
      );
      final rid = (rel['id'] as String?) ?? '';
      if (rid.isNotEmpty) {
        _liveWantId = rid;
        _liveIds.add(rid);
      }
      _liveRelocAt = DateTime.now();
      _startPingLoop();
      _seenSegs.clear(); // 强制下一次轮询拉一遍
      _forcePull = true;
      _startJobPoll(); // cancelled / error 时轮询被停过，唤醒后必须拉回来
      await _pollJob();
    } catch (_) {
      if (mounted) setState(() => _liveLocating = false);
    }
  }

  Future<void> _loadSubs() async {
    final prefs = page.app.session;
    if (mounted) {
      setState(() {
        _subsOn = prefs.subOn;
        _subDelay = prefs.subDelay;
        _subSize = prefs.subSize;
        _subPos = prefs.subPos;
      });
    }
    // ① 同目录同名字幕文件
    try {
      final path = entry.path;
      final dir = path.contains('/')
          ? path.substring(0, path.lastIndexOf('/'))
          : '';
      final r = await page.app.api.list(
        page.app.source,
        dir.isEmpty ? '/' : dir,
      );
      final entries = (r['entries'] as List?) ?? const [];
      final names = entries
          .map((e) => (e as Map)['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .toList();
      final hit = sameNameSubtitle(path, names);
      if (hit != null) {
        final subPath = '${dir}/$hit';
        final l = await page.app.api.link(page.app.source, subPath);
        final text = await page.app.api.fetchText(
          page.app.api.absolute(l['url'] as String),
        );
        final cues = parseSubtitle(text);
        if (mounted && cues.isNotEmpty) {
          setState(() {
            _fileCues = cues;
            _subFileName = hit;
            if (_subW.isEmpty) _subW = 'file';
          });
          _trAt = DateTime.fromMillisecondsSinceEpoch(0);
        }
      } else {
        // 没有外挂同名文件 → 看内封（用户说的「同名字幕」也包括内封）
        unawaited(_loadEmbeddedSubs());
      }
    } catch (_) {
      /* 没文件字幕不算错 */
    }
    // ② 听译字幕
    try {
      final r = await page.app.api.subsFor(
        entry.path,
        source: page.app.source,
      );
      if (!mounted) return;
      final segs = (r['segments'] as List?) ?? const [];
      final id = (r['id'] as String?) ?? '';
      // 实时听不跨会话继承：上次那条属于已经结束的会话，服务端也清掉了；
      // 就算查到了也一律不认，这一集从当前位置重新听。
      final wasLive = (r['mode'] as String? ?? '') == 'live';
      if (id.isNotEmpty && !wasLive) {
        // 队列听：整片字幕已经在服务端了，这里接上并开始轮询
        // （翻译要按播放头实时补，轮询里那条 /subs/at 就是干这个的）
        try {
          final d = await page.app.api.subsDetail(id);
          if (mounted) setState(() => _subJob = SubJob.from(d));
          await _pullLiveSrt(id);
          if (mounted && _aiCues.isNotEmpty) {
            _startJobPoll();
            // 整片听完的判据：done + 不是 live + 真转到了片尾。
            // 只看 state 会被「中途停掉的队列任务」骗到（那种也标 done）。
            final j = _subJob!;
            final lastEnd = (_aiCues.last[1] as num? ?? 0).toDouble();
            setState(() {
              _aiDone = j.state == 'done' &&
                  !j.live &&
                  (j.dur <= 0 || lastEnd >= j.dur * 0.95);
            });
            // 队列听的译文是和任务同生共死的（存 <files>/subs_tr/<id>_<lang>.json）。
            // 打开这部片就直接套用，不用重翻；没有才现翻。
            // 条件只看「缓存里有没有」——以前卡 `_aiDone` + 句数严格相等，
            // 转写到 97% 或者多一条空段就整片重译（用户报的就是这个）。
            if (mounted) {
              final hit = await applyCachedTr(
                id,
                page.app.session.subsLang,
                _aiCues,
              );
              if (hit > 0 && mounted) setState(() {});
            }
            // 整片都带译文了吗？带了就记住，播放时连 /tr 都不再发
            _aiTrFull = _aiCues.isNotEmpty &&
                _aiCues.every(
                  (c) => c.length > 3 && '${c[3]}'.trim().isNotEmpty,
                );
          }
        } catch (e) {
          // 整片译文套不上（文件读坏/句数对不上），至少留个痕迹
          debugPrint('已听完：套用队列译文失败 $e');
        }
      } else if (segs.isNotEmpty) {
        setState(() {
          _applyRows(
            '_for',
            segs.map((e) => (e as List).cast<dynamic>()).toList(),
            full: true,
          );
        });
      }
    } catch (_) {
      /* 没字幕不影响播放 */
    }
    if (!mounted) return;
    // 打开时的来源优先级（用户 2026-11-02 定的，别再自作聪明）：
    //   ① 同名字幕（外挂同名 / 内封）
    //   ② 队列听已经整片听完的字幕
    //   ③ 都没有 → 字幕关着。**不许一打开就自动开实时听**。
    setState(() {
      if (_fileCues.isNotEmpty) {
        _subsOn = true;
        _subW = 'file';
      } else if (_aiDone && _aiCues.isNotEmpty) {
        _subsOn = true;
        _subW = 'ai';
      } else {
        _subsOn = false;
        _subW = '';
      }
    });
  }

  List<List<dynamic>> get _activeCues =>
      _subW == 'file' ? _fileCues : (_subW == 'ai' ? _aiCues : const []);

  void _saveSubPrefs() {
    final s = page.app.session;
    s
      ..subOn = _subsOn
      ..subSrc = _subW
      ..subDelay = _subDelay
      ..subSize = _subSize
      ..subPos = _subPos;
    s.save();
  }

  List<dynamic>? get _currentCue {
    final cues = _activeCues;
    if (!_vcReady || cues.isEmpty) return null;
    final t = vc.value.position.inMilliseconds / 1000.0;
    return cueAt(cues, t, delay: _subDelay);
  }

  bool get _vcReady => vc.value.isInitialized;

  bool get _trShown => _subsOn && page.app.session.subTr;

  bool get _hasDual {
    final c = _currentCue;
    if (c == null) return false;
    final or = (c[2] as String?) ?? '';
    final zh = (c[3] as String?) ?? '';
    return or.isNotEmpty && zh.isNotEmpty && or != zh;
  }

  DateTime _trAt = DateTime.fromMillisecondsSinceEpoch(0);
  // 允许两批并行 + 逐句去重：同一句在飞时不重发（以前会重复花 token）。
  int _trInFlight = 0;
  final Set<String> _trInFlightKeys = <String>{};
  bool _trLiveFlag = false; // 已经告诉翻译总线「实时翻译活跃」
  /// 队列听的字幕整片都已经有译文：播放时不许再按播放头实时翻译。
  bool _aiTrFull = false;
  String _trErrMsg = ''; // 最近一次译文失败的原因（显示在状态行，别让用户猜）
  bool _trWarned = false; // 翻译源没配这种问题只提醒一次


  DateTime _trCacheAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _trCacheJob = '';

  /// 把后台队列翻译写进磁盘的译文补到正在播的字幕上。
  /// 既覆盖「打开时缓存还没写到 / 只译了一部分」，也覆盖「看着看着后台译完了」。
  Future<void> _pullSavedTr() async {
    final j = _subJob;
    if (j == null || _aiCues.isEmpty || _subW != 'ai') return;
    final now = DateTime.now();
    if (_trCacheJob == j.id && now.difference(_trCacheAt).inMilliseconds < 3000) {
      return;
    }
    _trCacheJob = j.id;
    _trCacheAt = now;
    final hit = await applyCachedTr(j.id, page.app.session.subsLang, _aiCues);
    if (!mounted || hit == 0) return;
    setState(() {});
  }

  Future<void> _trPull() async {
    final ss = page.app.session;
    if (!_subsOn) return;
    if (_subW != 'file' && _subW != 'ai') return;
    if (!_vcReady) return;
    // 队列听：先把已经译好的套上去（本地缓存，不发请求）。
    // 放在 subTr 判断之前：字幕面板上「译文 N 句」就算双语关着也得是真实数字，
    // 打开双语时也就不用等一轮。
    // 实时听还在跑 = 句子还会一直往下长：这时候绝不能认定「整片译完了」。
    // 以前这里在实时听期间也会打上 _aiTrFull=true（手上那几句恰好都译完了），
    // 之后新出来的句子就再也进不了翻译队列 —— 用户看到的就是
    // 「实时翻译开头有，几秒后全是原文」。
    final _liveJob =
        _liveOn || (_subJob?.live ?? false) || (_subJob?.fromLive ?? false);
    if (_subW == 'ai') {
      await _pullSavedTr();
      // 全都译好了就别再触发实时翻译（用户定的）—— 只对「不会再生长的整片」成立
      if (!_liveJob &&
          !_aiTrFull &&
          _aiCues.isNotEmpty &&
          _aiCues.every((c) => c.length > 3 && '${c[3]}'.trim().isNotEmpty)) {
        setState(() => _aiTrFull = true);
      }
    }
    if (!ss.subTr) return;
    if (_subW == 'ai' && _aiTrFull && !_liveJob) return;
    // 实时听的译文本来由听译中枢按播放头补，但中枢那条实时任务收尾后
    // （hub 把 live 降级、或者拖到没转过的位置之前）屏幕上剩下的句子
    // 就永远等不到译文，显示成「只有原文」。所以两个来源都兜底翻，
    // /tr 有进程内缓存，同一句不会重复花 token。
    final src = _subW == 'ai' ? _aiCues : _fileCues;
    if (src.isEmpty) return;
    final now = DateTime.now();
    // 每 0.4 秒就能发下一批，最多两批同时在飞；积压时会连续发，不会等一轮
    if (_trInFlight >= 2 ||
        now.difference(_trAt).inMilliseconds < 600) {
      return;
    }
    if (!_trLiveFlag) {
      _trLiveFlag = true;
      TrBus.beginLive(); // 队列翻译让位
    }
    final t = vc.value.position.inMilliseconds / 1000.0;
    // 拖动之后按「离播放头最近」优先翻，回来第一句马上有译文
    // 整句才翻：还没说完的句子先等它说完（半句翻译质量断崖，各家都这么做）
    // 「说完」= 播放头已经过了句尾，或者下一句跟这句之间有明显停顿（≥0.4 秒）
    // 往前看 60 秒（回跳、拖动后能补上），一轮最多 20 句（跟不上时自己会追）
    final want = pickTrCandidates(
      src,
      t,
      max: 20,
      back: 60,
    ).where((c) => _cueClosed(src, c, t)).toList();
    // 同一句还在飞就别重发（去重）；首包优先：先发最近的 3 句小包，
    // 剩下的下一轮再发 —— 以前 20 句一整包，第一句要等整包回来。
    want.removeWhere(
      (c) => _trInFlightKeys.contains(cueStart(c).toStringAsFixed(2)),
    );
    if (want.isEmpty) return;
    final firstPack = _trInFlight == 0 && want.length > 5;
    final take = firstPack ? 5 : (want.length > 10 ? 10 : want.length);
    if (want.length > take) want.removeRange(take, want.length);
    // 相邻短句先合并再翻：一句「嗯」「什么？」单独翻质量差，拼成一段
    // 模型有上下文（研究里各家都这么做）。用换行分隔，回来按行拆。
    final groups = <List<List<dynamic>>>[];
    for (final c in want) {
      final last = groups.isEmpty ? null : groups.last.last;
      if (last != null) {
        final gap = (c[0] as num).toDouble() - (last[1] as num).toDouble();
        final joined = groups.last.fold<int>(
          0,
          (a, x) => a + ((x[2] as String?) ?? '').length,
        );
        final len = ((c[2] as String?) ?? '').length;
        if (gap >= 0 && gap <= 0.4 && joined + len <= 70) {
          groups.last.add(c);
          continue;
        }
      }
      groups.add([c]);
    }

    _trAt = now;
    _trInFlight++;
    for (final g in groups) {
      for (final c in g) {
        _trInFlightKeys.add(cueStart(c).toStringAsFixed(2));
      }
    }
    final _t0 = DateTime.now();
    try {
      // 译在 App 里做（DeepSeek / 自定义 OpenAI 兼容源，密钥在本地）
      final out = await Translator.translate(
        groups.map((g) => g.map((c) => (c[2] as String)).join('\n')).toList(),
        ss.subsLang,
      );
      if (!mounted) return;
      // 先按「起点」攒成补丁，再写回**当前**的句子列表。
      // 翻译这一两秒里 _jobPoll 可能整份换了 _aiCues（每次 /subs/detail 都
      // 重建列表），直接写 g[k][3] 是写进已经被换掉的老对象 —— 用户看到的就是
      // 「有的句子一直只有原文」。按起点找回当前那句才写得进去。
      final patch = <String, String>{};
      String keyOf(List<dynamic> c) => cueStart(c).toStringAsFixed(2);
      for (var i = 0; i < groups.length && i < out.length; i++) {
        final g = groups[i];
        final txt = out[i].trim();
        if (txt.isEmpty) continue;
        if (g.length == 1) {
          patch[keyOf(g.first)] = txt;
          continue;
        }
        final parts = txt
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (parts.length == g.length) {
          for (var k = 0; k < g.length; k++) {
            if (parts[k].isNotEmpty) patch[keyOf(g[k])] = parts[k];
          }
        } else {
          // 拆不回原句数就把整段挂第一句，至少不缺译文
          patch[keyOf(g.first)] = txt;
        }
      }
      if (patch.isNotEmpty) {
        setState(() {
          _trErrMsg = '';
          void put(List<dynamic> c) {
            final t = patch[keyOf(c)];
            if (t != null && (c[3] as String? ?? '').trim().isEmpty) c[3] = t;
          }

          for (final c in _subW == 'ai' ? _aiCues : _fileCues) {
            put(c);
          }
          // 存底也写一份：整份重拉时靠它把译文搬回来
          for (final v in _byJob.values) {
            for (final c in v) {
              put(c);
            }
          }
        });
      }
    } on TrError catch (e) {
      // 原因留在状态行上：用户不用猜「为什么没中文」
      if (mounted && _trErrMsg != e.message) {
        setState(() => _trErrMsg = e.message);
      }
      // 没配密钥这种是「配置问题」，反复重试没意义：提醒一次就停
      if (!_trWarned) {
        _trWarned = true;
        if (mounted) page.app.toast('$e');
      }
    } catch (_) {
      // 网络抖一下：别每 1.2 秒空撞一次，退 3 秒再来
      _trAt = DateTime.now().add(const Duration(seconds: 3));
    } finally {
      _trInFlight = _trInFlight > 0 ? _trInFlight - 1 : 0;
      for (final g in groups) {
        for (final c in g) {
          _trInFlightKeys.remove(cueStart(c).toStringAsFixed(2));
        }
      }
      // 埋点：一批「发出去 → 回来」多久，用来判断慢在请求还是慢在排队
      final ms = DateTime.now().difference(_t0).inMilliseconds;
      if (groups.isNotEmpty) trLatencyLog(groups.length, ms);
    }
  }

  String get _liveStatus {
    if (!ready) return '';
    // 这行只报「事实」，不堆术语：
    //   听了多少句、转写跑到哪儿、跟画面差几秒。
    // 以前写「转写中 · 领先画面 N 秒」——「转写中」永远在、「画面」属于废话，
    // 暂停时还会挂着「转写中」，看着就是错的。
    final n = _aiCues.length;
    final cnt = n > 0 ? ' · $n 句' : '';
    if (_aiDone && !_liveOn) return '听译 · 已听完$cnt';
    final lg = _langZh(_subJob?.lang ?? '');
    final head = lg.isEmpty ? '实时听' : '实时听 · $lg';
    final j = _subJob;
    final liveOn = _liveOn || (j?.live ?? false);
    if (!liveOn && j == null) return '';
    if (_liveLocating || (j?.relocating ?? false)) return '$head · 换位置中…$cnt';
    if (j == null) return _liveOn ? '$head · 正在起…$cnt' : '';
    if (j.state == 'cancelled' || j.state == 'error') {
      return '$head · 已停止$cnt';
    }
    final pos = vc.value.position.inMilliseconds / 1000.0;
    // 「领先/落后」按**真实覆盖**算：这一轮转写到哪（doneUntil）和已经听出来的
    // 句子的最远端取大。换位置后 doneUntil 会往回跳，只看它会把「明明有字幕」
    // 报成落后二十几秒（实测用户就是这么被绕晕的）。
    final cov = math.max(j.doneUntil, cuesUntil(_aiCues));
    final lead = cov - pos;
    // 说人话：不写「领先/落后 N 秒」（用户看不出这是余量还是延迟），
    // 直接报「已备好多少字幕」——播到那儿之前都有中文。
    final readyTxt = _fmtReady(lead);
    // 排队中只在**一句字幕都没有**的时候才说。已经有句子了还写「排队中」
    // 是误导：画面有字幕、状态却像卡住（用户实测截图 35 句 + 排队中）。
    if ((j.state == 'queued' || j.state == 'probing') && n == 0) {
      return '$head · 排队中${_queueBusy ? '（整片转写占着槽）' : '（等转写工接单）'}';
    }
    if (!j.running) {
      // 这一窗转完、转写工在挂起：报备好多少，并说明播过去会自动续
      if (lead > 1) return '$head · $readyTxt · 播过就续$cnt';
      if (lead < -2) return '$head · $readyTxt$cnt';
      return '$head · 已跟上$cnt';
    }
    if (!vc.value.isPlaying) {
      return '$head · 预听中 · $readyTxt$cnt';
    }
    if (lead < -2) {
      return '$head · $readyTxt · 正在追$cnt';
    }
    final trErr = _trShown && _trErrMsg.isNotEmpty
        ? ' · 译文失败：${_trErrMsg.length > 22 ? '${_trErrMsg.substring(0, 22)}…' : _trErrMsg}'
        : '';
    return '$head · $readyTxt$cnt$trErr';
  }

  String _fmtReady(double s) {
    final r = s.round();
    if (r >= 60) {
      final m = r ~/ 60;
      final sec = r % 60;
      return '已备好 $m:${sec.toString().padLeft(2, '0')}';
    }
    if (r > 2) return '已备好 $r 秒';
    if (r >= -2) return '跟上画面';
    return '落后 ${-r} 秒';
  }

  String _langZh(String l) {
    final k = l.toLowerCase();
    if (k.startsWith('ja') || k == 'jpn') return '日语';
    if (k.startsWith('en') || k == 'eng') return '英语';
    if (k.startsWith('zh') || k == 'chi' || k == 'zho') return '中文';
    if (k.startsWith('ko') || k == 'kor') return '韩语';
    return '';
  }

  String get _hotWords => hotWordsFor(entry.path, entry.name);

  bool _cueClosed(List<List<dynamic>> src, List<dynamic> c, double t) {
    final end = (c[1] as num?)?.toDouble() ?? 0;
    if (end <= t + 0.2) return true;
    // 不用等播放头：只要这句已经落在「转完的区间」里（done_until 之前），
    // 句子就定型了，可以提前翻。等播到了再翻，观众会先看到 1-3 秒的英文 ——
    // 观感上就是「漏翻」。只往前预翻 60 秒，再远可能被拖走，白花 token。
    final done = _subJob?.doneUntil ?? 0;
    if (done > 0 && end <= done + 0.3 && (c[0] as num).toDouble() <= t + 60) {
      return true;
    }
    // 外挂/内封字幕、以及整片听完的字幕都是定稿的：提前 60 秒翻好
    if ((_subW == 'file' || _aiDone) && (c[0] as num).toDouble() <= t + 60) {
      return true;
    }
    for (final o in src) {
      final st = (o[0] as num?)?.toDouble() ?? 0;
      if (st > end - 0.01 && st - end >= 0.4) return true;
    }
    return false;
  }

  void _applyRows(String id, List<List<dynamic>> rows, {required bool full}) {
    final prev = _byJob[id] ?? const <List<dynamic>>[];
    List<List<dynamic>> next;
    if (full) {
      // 整份重拉（拖动后游标归零）时，服务端这几行只有原文（译在 App 里做）：
      // 直接替换会把已翻好的译文擦掉，回到前面就「只有原文」。
      next = keepTrByStart(prev, rows);
    } else {
      next = mergeCues(prev, rows);
    }
    _byJob[id] = next;
    var all = <List<dynamic>>[];
    for (final v in _byJob.values) {
      all = mergeCues(all, v);
    }
    _aiCues = all;
    if (_subW.isEmpty) _subW = 'ai';
  }

  Future<void> _pullLiveSrt(String id) async {
    // 优先用 /subs/{id} 的 segments_list：一次请求拿到结构化段落，
    // 不用再下载整份 SRT 重新解析（旧版也是直接吃 segments）。
    //
    // since 按「这条任务自己」拉到哪儿算：服务端是 `end > since` 过滤，
    // 拖回前面之后新转出来的早期段会被它挡掉 —— 所以拖动时游标会归零，
    // 归零就是整份重拉，重拉只替换这一条任务的段落（别的窗口的还在）。
    final since = _pulledTo[id] ?? 0.0;
    final full = since <= 0;
    try {
      final d = await page.app.api.subsDetail(
        id,
        // 译文比原文晚 1~5 秒；回看 60 秒，让补译能进来
        since: full ? 0.0 : (since - 60).clamp(0.0, double.infinity),
      );
      final segs = (d['segments_list'] as List?) ?? const [];
      if (segs.isNotEmpty && mounted) {
        final rows = segs.map((e) => (e as List).cast<dynamic>()).toList();
        var maxEnd = since;
        for (final r in rows) {
          final b = r[1].toDouble();
          if (b > maxEnd) maxEnd = b;
        }
        _pulledTo[id] = maxEnd;
        setState(() => _applyRows(id, rows, full: full));
        return;
      }
      if (full && mounted) {
        // 整份重拉但这条任务现在没段（刚开、还没出结果）：把它清掉，
        // 免得残留上一次窗口的旧文字挂在错的位置
        setState(() => _applyRows(id, const [], full: true));
      }
    } catch (_) {
      /* 落到 SRT 兜底 */
    }
    try {
      final text = await page.app.api.subsSrtText(id);
      if (text.isEmpty || !mounted) return;
      final cues = parseSubtitle(text);
      if (cues.isEmpty) return;
      final rows = cues.map((c) => <dynamic>[c[0], c[1], c[2], c[3]]).toList();
      _pulledTo[id] = cues.last[1].toDouble();
      setState(() => _applyRows(id, rows, full: true));
    } catch (e) {
      debugPrint('实时听：拉字幕失败 $e');
    }
  }

}
