import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' show AudioTrack;

import '../core/mk_playback.dart';
import '../core/native.dart';
import '../core/tr_bus.dart';
import '../core/subs_tr.dart';

import '../core/app_state.dart';
import '../core/gestures.dart';
import '../core/app_icons.dart';
import '../core/langs.dart';
import '../core/models.dart';
import '../core/subtitles.dart';
import '../core/subs_util.dart';
import '../core/translator.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';
import 'subs_monitor.dart';

part 'player_subs.dart';
part 'player_widgets.dart';

/// 播放页：直连签名直链（Range 由 dufs 处理），不走 API 中转。
/// 手势：单击显隐控件、双击左右两侧 ±10 秒、横向拖动调进度。
String _mmss(double sec) {
  final t = sec.floor();
  final h = t ~/ 3600;
  final m = (t % 3600) ~/ 60;
  final x = t % 60;
  return '${h > 0 ? '$h:' : ''}${h > 0 ? m.toString().padLeft(2, '0') : m}:${x.toString().padLeft(2, '0')}';
}

class PlayerPage extends StatefulWidget {
  final App app;
  final String url;
  final Entry entry;
  final Tone tone;
  final bool resumeFromServer;

  /// 同一目录里的其它视频（旧版「本目录的视频」和上一集/下一集）
  final List<Entry> playlist;

  const PlayerPage({
    super.key,
    required this.app,
    required this.url,
    required this.entry,
    required this.tone,
    this.resumeFromServer = false,
    this.playlist = const [],
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with WidgetsBindingObserver, _SubsMixin<PlayerPage> {
  @override
  MKPlayback get vc => _vc;

  @override
  Entry get entry => _entry;

  @override
  PlayerPage get page => widget;

  @override
  bool get ready => _ready;

  @override
  int? get asrTrack => _asrAt;

  late MKPlayback _vc;
  bool _soft = false; // 软解开关：硬解不支持的格式用这个
  bool _dolby = false; // 杜比直通（mediacodec_embed）
  bool _dvTried = false; // 杜比提示只弹一次
  /// 杜比转换没起来时顶部常驻的那条「点这里重试」
  bool _dvNote = false;

  /// 当前正在播的地址。换集之后 widget.url 还是第一集的，
  /// 切解码/重试若用它就成了「界面是第 3 集，画面回到第 1 集」。
  String _url = '';

  /// 播放器代数：每次重建 _vc 自增，旧的初始化回调看到代数变了就闭嘴
  int _gen = 0;
  bool _ready = false;
  String? _error;
  bool _controls = true;
  Timer? _hideTimer;
  double _speed = 1.0;
  Duration _dragPos = Duration.zero;
  bool _dragging = false;

  // 字幕两路（旧版 SUBW）：同名字幕文件优先，其次是听译字幕

  late Entry _entry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _newLiveSession();
    _entry = widget
        .entry; // 之前写成自赋值（late 未初始化）→ 一打开就 LateInitializationError，播放器整个打不开
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _open(widget.url);
    // 起手就读系统当前音量/亮度，别一进来就显示 100%
    () async {
      final v = await Native.getVolume();
      final b = await Native.getBrightness();
      if (mounted) {
        setState(() {
          _vol = v / 100;
          _bri = b / 100;
        });
      }
    }();
  }

  /// 这个文件到底是不是杜比视界：由服务端扫容器里的标记（dvh1/dvhe/dvcC…）来判断，
  /// 不看文件名 —— 名字里写 DV 不代表真带杜比，反过来也一样。
  /// null = 还没检测完，此时杜比模式一律不可选。
  bool? _dvKnown;

  // ---- 音轨 ----
  List<Map<String, dynamic>> _audios = const [];
  int _aord = 0; // 当前选的音轨序号（跟 ffprobe 的 tracks 同序）

  /// 这个文件里的内封字幕轨（ffprobe 探测结果，含图形字幕）
  /// 正在用 mpv 直接画的图形字幕轨序号（null = 没开）
  bool _audioPicked = false; // 用户手动选过没有
  bool _audioResolved = false; // 默认轨（跟耳朵一致的那条）算出来没有

  /// 这个片子已经整片听完过（队列听跑完，服务端有全片字幕）。
  /// 有它就不再开实时听：直接把整片字幕挂上，按钮显示「已听完」。
  /// 有没有整片转写在占着转写工（决定「排队中」到底在等谁）

  /// 听译该抽哪条音轨（ffmpeg 绝对流序号）。空 = 让服务端自己挑。
  int? get _asrAt {
    if (_audios.isEmpty) return null;
    final t = _audios[_aord.clamp(0, _audios.length - 1)];
    return (t['i'] as num?)?.toInt();
  }

  String _audioLabel(int k) => audioTrackLabel(_audios[k], k);

  /// mpv 轨道 → 「英语 5.1」；认不出语言才退回「音轨N」
  String _mpvAudioLabel(AudioTrack t, int k) {
    final lang = (t.language ?? '').toLowerCase();
    final title = (t.title ?? '').trim();
    final known = title.isNotEmpty ? title : kAudioLangZh[lang];
    if (known == null || known.isEmpty) return '音轨${k + 1}';
    final ch = t.channelscount ?? 0;
    final sfx = ch >= 6
        ? ' 5.1'
        : ch == 2
        ? ' 立体声'
        : '';
    return '$known$sfx';
  }

  /// 播放设置里显示的音轨选项。服务端 ffprobe 探测失败（115/网络盘常见）时，
  /// 退回用 mpv 自己的音轨列表 —— 否则「多音轨却没有任何切换入口」。
  List<String> get _audioOpts {
    if (_audios.length > 1) {
      return [for (var k = 0; k < _audios.length; k++) _audioLabel(k)];
    }
    // ffprobe 拿不到就用 mpv 自己的轨道信息：它通常带 language/title，
    // 能认出「英语 / 西语 / 意语 / 韩语」就不该只剩「音轨1/2/3」。
    final ts = _vc.audioTracks;
    if (ts.length > 1) {
      return [for (var k = 0; k < ts.length; k++) _mpvAudioLabel(ts[k], k)];
    }
    return const [];
  }

  Future<void> _probeAudios() async {
    try {
      final ts = await widget.app.api.audios(widget.app.source, _entry.path);
      if (!mounted || ts.isEmpty) return;
      setState(() {
        _audios = ts;
        if (_aord >= ts.length) _aord = 0;
      });
      _applyAudio();
    } catch (_) {
      /* 探测失败就当单音轨，不影响播放 */
    }
  }

  /// 把播放器的音轨对齐到用户选的那条（mpv 的顺序＝容器音频流顺序）
  void _applyAudio() {
    final tracks = _vc.audioTracks;
    if (tracks.isEmpty) return;
    if (!_audioPicked) return; // 没选过就跟着播放器当前那条走，见 _resolveAudio
    if (_aord >= tracks.length) return;
    final want = tracks[_aord];
    if (_vc.audioId == want.id) return; // 已经是这条，别每个 tick 重复设
    _vc.setAudioTrack(want);
  }

  /// 默认音轨＝播放器正在播的那条。听译必须跟耳朵一致，
  /// 否则会出现「字幕是一种语言、声音是另一种」——比没有字幕更糟。
  void _resolveAudio() {
    final tracks = _vc.audioTracks;
    if (tracks.isEmpty) return;
    // 用户选过就一直钉在那条（切解码/重建播放器后也要接回来）
    if (_audioPicked) {
      _applyAudio();
      return;
    }
    if (_audioResolved) return;
    _audioResolved = true;
    final cur = _vc.audioId;
    final idx = tracks.indexWhere((t) => t.id == cur);
    if (idx >= 0 && idx != _aord) {
      setState(() => _aord = idx);
    }
  }

  /// 换音轨：播放器和「听」都跟着换；正在实时听译就按新音轨重开
  Future<void> _pickAudio(int ord) async {
    if (ord == _aord) return;
    _audioPicked = true;
    setState(() => _aord = ord);
    _applyAudio();
    final at = _asrAt;
    if (_liveOn) {
      widget.app.toast('换了音轨，实时听译按新音轨重来');
      _liveRestartAt = DateTime.fromMillisecondsSinceEpoch(0);
      try {
        await widget.app.api.subsAdd(
          _entry.path,
          name: _entry.name,
          model: widget.app.session.subModel,
          live: true,
          start: (_vc.value.position.inMilliseconds / 1000.0 - 2).clamp(
            0.0,
            1000000000.0,
          ),
          source: widget.app.source,
          lang: widget.app.session.subsLang,
          at: at,
          session: _liveSession,
          hot: _hotWords,
        );
        _startJobPoll();
        _startPingLoop();
      } catch (_) {}
    }
  }

  bool get _dvPickable => _dvKnown == true || _vc.dolbyDetected;

  /// 杜比 profile（5 / 7 / 8），null = 不是杜比或没测出来
  int? _dvProfile;

  /// P5 的片源没有 HDR 兼容层（compat=0），色彩是 IPT，必须 libplacebo 转；
  /// P8 有 HDR10 底层，P7 是双层（Android 基本无解，只能按底层播）。
  String get _dvLabel {
    if (_dvKnown != true) return '普通';
    final p = _dvProfile;
    return p == null ? '杜比视界' : '杜比视界 P$p';
  }

  Future<void> _probeDolby() async {
    final src = widget.app.source;
    final r = await widget.app.api.dovi(src, _entry.path);
    if (!mounted) return;
    final dv = r?['dovi'] == true;
    setState(() {
      _dvKnown = r == null ? null : dv;
      _dvProfile = (r?['profile'] as num?)?.toInt();
    });
    if (dv && !_dolby && !_soft) {
      _dvTried = true;
      setState(() => _dolby = true);
      widget.app.toast('检测到${_dvLabel} · 已切杜比模式');
      // 还没起播就重开一次（带杜比参数），已经播着才换引擎；
      // 直接 switch 会 dispose 掉一个正在 initialise 的播放器，黑屏
      if (_ready) {
        unawaited(_switchDecoder(false));
      } else {
        _open(_url);
      }
    } else if (dv && _dvProfile == 7) {
      widget.app.toast('这片是杜比视界 P7（双层），本机只能按底层 HDR10 播');
    } else if (r != null && !dv && _dolby) {
      // 上一集是杜比、这集不是：不退出杜比模式就等于拿软解放普通 4K
      _dvTried = true;
      setState(() {
        _dolby = false;
        _soft = false;
      });
      widget.app.toast('这条不是杜比视界，已回硬解');
      if (_ready) {
        unawaited(_switchDecoder(false));
      } else {
        _open(_url);
      }
    }
  }

  void _open(String url) {
    // 换集：上一条片的听译段落/游标全部丢掉，否则新的一集开头会闪上一集的字幕
    _byJob.clear();
    _pulledTo.clear();
    _seenSegs.clear();
    _aiCues = const [];
    _seenSegs.clear();
    _liveOn = false;
    _dvKnown = null;
    _dvTried = false; // 每集各自判定，上一集的杜比结论不能带过来
    _dvNote = false;
    _audios = const [];
    _aord = 0;
    _audioPicked = false;
    _audioResolved = false;
    _url = url;
    final gen = ++_gen;
    _ready = false;
    _oriented = false;
    _orientManual = false; // 换片重新按新片的比例定方向
    _vc = MKPlayback.network(url, software: _soft, dolby: _dolby);
    _vc.addListener(_tick);
    _vc
        .initialize()
        .then((_) async {
          // 期间可能换了集或切了解码，旧回调一律作废，别去动新播放器
          if (!mounted || gen != _gen) return;
          setState(() => _ready = true);
          await _resume(); // 上次播到哪就从哪接着看
          _vc.play();
          // 杜比片起播时给一句提示，不然没人知道转换已经生效、状态在哪看
          if (_dolby) {
            widget.app.toast('杜比视界片源 · 已用 gpu-next 转换颜色');
          }
          _scheduleHide();
        })
        .catchError((Object e) {
          if (mounted && gen == _gen) setState(() => _error = '$e');
        });
    _loadSubs();
    _startJobPoll();
    _probeDolby(); // 真实码流说了算，检测完再决定能不能开杜比
    _probeAudios(); // 音轨列表：既给「换音轨」用，也决定听译抽哪条流
    // 内封轨清单：跟有没有外挂同名文件无关，面板里都要能选
    unawaited(_probeEmbSubs());
  }

  /// 每 3 秒看一眼这一集有没有听译任务、转到哪了


  /// 换一个新的会话号。切后台回来、或者手动重开实时听时必须换 ——
  /// 旧会话号在服务端已经记成「已关闭」，同一个号再起任务会被当成废请求忽略。


  /// 退出播放器 / 切后台：实时听「彻底停」—— 任务、段落、记录一起清，
  /// 不等服务端清扫器的 15 秒。句子也一起丢（实时听只存在于播放时）。

  /// 关掉实时听：把**所有**实时任务从中枢撤掉，并和服务器对一次账。
  /// 队列听（整片转写）不动 —— 那是后台任务，不该跟着字幕开关一起死。

  /// 撤掉所有实时任务，并且**回读确认**真的没了。
  ///
  /// 以前只 `subsCancel(_subJob.id)`：拖过几次进度条就有好几条 live 任务，
  /// 界面只跟其中一条，其余的一直在转（用户看到的「点了关闭没真关」）。
  /// 现在按 id 集合撤 + 按文件路径对账，最多两轮，撤不干净也不至于卡住界面。

  /// 停完之后回读一次，把真实结果告诉用户（不再"点了就算停"）

  // ---------------- 旧版 subsLiveGuard 的等价实现 ----------------
  // 实时听译只覆盖「播放位置之后的一个窗口」。用户拖到没转过的位置时，
  // 旧前端会用新位置重新开一个 /live 任务（8 秒内不重复触发）。
  // 没有这段，拖过去就一直空白，得等转写追上来。

  /// 最近一次「换起转点」的时间。换位置之后 worker 要重开窗口，
  /// 这期间 job 会短暂 cancelled / live=0，如果守卫还按「没覆盖」判断就会
  /// 每 8 秒再换一次 —— 实测能把任务打成原地打转（live_from 一直往前跳，
  /// 一句字幕都留不下）。所以换完先静默一段时间，让 worker 把窗口跑起来。

  /// 拖动去抖 + 跳变检测（研究结论：seek 必须事件驱动，不能靠冷却猜）
  bool _lastPlaying = false;
  Timer? _pfTimer;
  DateTime _seekHandledAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _seekDebounce;
  int _seekEpoch = 0;
  Duration _lastPos = Duration.zero;
  DateTime _lastTickAt = DateTime.now();

  /// 用户在这个播放器里开过「实时听」——拖动后要不要重开只看它，不看 hub 的 live 标记

  /// 刚拖完、正在换起转点（UI 上显示「定位中」）


  /// 问服务端这个文件里有哪些内封字幕轨（文本 + 图形都算），填进面板

  /// 只有图形（PGS / DVD）的内封轨

  /// 「CHS」/「中文」——标题优先，没有就用语言码

  /// 选/关内封图形字幕（PGS / DVD）。文本轨不走这里。

  /// 内封字幕：先问有哪些字幕轨（中文优先），再边抽边用。
  ///
  /// 抽轨是顺着读完整片（远端几分钟很正常），所以每 3 秒要一次「抽到哪儿了」，
  /// 有句子就先挂上去 —— 观众不用等整份抽完，翻译也跟着句子走。


  /// 没字幕不许播。
  ///
  /// 用户定的规矩（2026-11-02）：「开启实时听的状态下，没有听到的字幕，
  /// 视频就不能播放，直到确保有字幕了视频才会播放。」
  /// 三条放行：字幕来源不是「听字幕」、字幕关了、或者当前位置已经有句子。
  /// 兜底：转写工挂了/断网了不能把播放器焊死 —— 60 秒还没字幕就放行并说明。
  /// 要不要按停等字幕。
  ///
  /// 千万别拿「覆盖」当标准：VAD 会把静音切掉，句子之间本来就有几秒空隙，
  /// 按覆盖卡会在每句之间把视频按停（实测 75:15 那句和下一句差 4.2 秒，
  /// 播放头正好落在空隙里 → 视频就停那儿了，看上去像死了）。
  ///
  /// 跳到新位置重新开实时窗。
  ///
  /// 转写工只在**领任务那一刻**看 live_from，正在转的时候你改 live_from 它不理，
  /// 会继续顺着原来的位置往前转（实测：请求 start=2400，段还是从 1720 往后长）。
  /// 所以必须先 cancel 让它放手，等它真的退出（state 不再是 asr/queued），
  /// 再发 /live —— 立刻发会被它「还在跑」吞掉，然后被 /finish 标成 done，
  /// 客户端看到的就是「重开了一次，但一句字幕都没有」。
  /// 拖到新位置：让**同一条**实时听任务换起转点。
  ///
  /// 用户定的语义（2026-11）：
  /// - 一个文件永远只有一条实时听任务，不再 cancel 一条再新建一条
  /// - 拖到哪就从哪往后转；落点已经有字幕就跳到后面第一段空缺接上
  /// - A 方案：立刻打断当前窗口，不等它转完


  /// 切到后台就停轮询，回到前台立刻补一次（旧版 visibilitychange）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _closing = false;
      if (_subJob != null) {
        _pollJob();
        if (_subJob!.running) _startJobPoll();
        _startPingLoop();
      } else if (_subsOn && _subW == 'ai' && _vcReady) {
        // 切后台时任务停了、句子留着；回来换一个新会话号，从第一段空缺接着转
        _newLiveSession();
        unawaited(_startLiveSubs());
      }
    } else if (state == AppLifecycleState.paused) {
      _jobPoll?.cancel();
      // 切后台 = 实时听彻底停（用户定的：实时听只存在于播放时）。
      // 回来重新起一条新的，从当前播放位置开转，不续。
      // 切后台也要松手实时翻译的标记：dispose 不一定会跑到，
      // 漏一次队列翻译就永远卡在「翻译中 X%」（用户报的 93% 就是它）。
      if (_trLiveFlag) {
        _trLiveFlag = false;
        TrBus.endLive();
      }
      if (_liveOn || _liveIds.isNotEmpty || _subJob != null) {
        _closing = true;
        _liveOn = false;
        unawaited(_endLiveSession());
        if (mounted) {
          // 停的是任务，不是字幕：句子留在本地，回来从第一段空缺接着转。
          // （用户定的语义：切后台 = 停但保留）
          setState(() {
            _subJob = null;
            _liveWantId = '';
            _byJob.clear();
            _pulledTo.clear();
            _seenSegs.clear();
          });
        }
      }
    }
  }

  /// 旧版顺序：**同名字幕文件优先**，没有才用听译字幕（SUBF → SUBR）



  /// 当前时间点该显示的那一句


  /// 原文和译文都有、且不一样，才显示成双轨
  /// 「显示译文」开关：关了就不许出现任何译文（双轨、主行都一样）


  void _tick() {
    if (!mounted) return;
    // mpv 的报错（连不上、解不了码、超时）以前只在日志里，界面永远是黑屏 ——
    // 用户只会说「这个视频播不了」，抄下来我才能修
    // 认出杜比视界就自动切一次杜比模式：用户看到的是「发绿的视频」，
    // 不该让他自己去猜是解码问题
    if (!_dvTried && !_dolby && _vc.dolbyDetected && _dvKnown != false) {
      _dvTried = true;
      setState(() {
        _dolby = true;
        _soft = false;
      });
      widget.app.toast('杜比视界片源 · 已切杜比模式转换颜色');
      unawaited(_switchDecoder(false));
      return;
    }
    if (_error == null && _vc.hasError) {
      final msg = _vc.errorDescription ?? '解码失败';
      setState(() => _error = msg);
    }
    setState(() {});
    // 画面尺寸一出来就按比例定方向（横片横屏、竖片竖屏），一次片只定一次
    if (!_oriented && _vc.hasSize) {
      _oriented = true;
      unawaited(_autoOrient());
    }
    _resolveAudio(); // 默认音轨对齐播放器，听译才跟耳朵一致
    _savePos(); // 内部按 5 秒节流
    // 位置跳变 = 一次 seek（用户拖了、或者播放器自己跳了）：
    // 位置变化量远大于墙钟时间就是跳转，别等 45 秒冷却慢慢猜。
    final np = _vc.value.position;
    final nowTick = DateTime.now();
    final dwall = nowTick.difference(_lastTickAt).inMilliseconds / 1000.0;
    final dpos = (np - _lastPos).inMilliseconds / 1000.0;
    if (dwall > 0 &&
        dwall < 5 &&
        (dpos - dwall).abs() > 2.0 &&
        // 手势那边已经报过一次了，同一次跳转别报两遍
        nowTick.difference(_seekHandledAt).inMilliseconds > 2000) {
      _onUserSeek();
    }
    _lastPos = np;
    _lastTickAt = nowTick;
    // 暂停 = 空闲预转：把往前转的窗口放大到 10 分钟，用户回来拖动基本不用等；
    // 恢复播放就收回默认窗口，别白烧 CPU。
    final playing = _vc.value.isPlaying;
    if (playing != _lastPlaying) {
      _lastPlaying = playing;
      _prefetchAhead(!playing);
    }
    _liveGuard(); // 拖到没转过的位置就重开实时听（内部限流，代价极小）
    _trPull(); // 读到哪句翻哪句（同名字幕也翻）
  }

  // ---------------- 译：与听完全解耦 ----------------
  // 不管字幕是「同名字幕」还是「实时听」出来的，只要画面上要显示，
  // 就把播放头附近还没译的句子发给 /subs/tr，翻完直接写回 cue[3]。

  /// 热词：片名 + 文件名（去规格标记），清单见 subs_util.hotWordsFor。
  /// 标题下面那行灰字。实时听的状态只说真话：
  /// - 转写中 ⇒ 报「领先/落后」多少秒（相对播放头，不是相对片头）
  /// - 暂停 ⇒ 报「已预转到哪」（暂停会往后预转，报领先几百秒会吓人）
  /// - 转完这一窗 ⇒ 报「等续转」，不报「已转好」（整片没转完）

  /// 「已备好 2:31」/「已备好 45 秒」/「跟上画面」/「落后 12 秒」
  ///
  /// 先把秒数取整再拆分钟：以前用 `(s % 60).round()`，119.7 秒会算成
  /// 「已备好 1:60」。负余量（转写还没跟上）也不再谎报「跟上画面」。



  /// 这句「说完了」没有：句尾已经过了播放头，或者后面有明显的停顿。

  // ---- 继续观看 ----
  DateTime? _lastSave;

  /// 上次看到哪（秒）。播放真正起来之后还要拿它再核一次位置。
  double? _resumeTarget;

  /// 胶囊上「从 X 继续」那个位置。和 _resumeTarget 分开存：
  /// _resumeTarget 只管「别把进度存成 0」，胶囊只管「还挂着没跳成」。
  double? _jumpTarget;

  /// 用户已经点过胶囊：缓冲就绪那一刻自动落地，不用再点第二下
  bool _jumpArmed = false;

  Future<void> _resume() async {
    try {
      final r = await widget.app.api.playOne(_entry.path);
      final pos = (r['pos'] as num?)?.toDouble() ?? 0;
      final dur = (r['dur'] as num?)?.toDouble() ?? 0;
      if (!r['found'] as bool? ?? false) return;
      if (pos < 10) return;
      if (dur > 0 && pos > dur - 30) return;
      _resumeTarget = pos;
      if (!mounted) return;
      setState(() {
        _resumedFrom = pos;
        _jumpTarget = pos;
      });
      // 以前这里发一次 seek 就完事，7 秒后胶囊自己消失 —— 可 115 的 4K 片
      // 首包要缓冲十几秒，这期间 mpv 会把 seek 全丢掉，用户就是「点了没反应，
      // 胶囊还自己跑了」。现在改成一直盯着，真跳到了才收。
      unawaited(_jumpToTarget(pos));
    } catch (_) {
      /* 没记录就正常从头播 */
    }
  }

  /// 真的跳过去。mpv 在文件还没打开（首包还在缓冲）时会把 seek 丢掉，
  /// 所以不能「发一次就完事」，也不能只等两秒：这里一直盯到位置真的到目标，
  /// 最多盯 40 秒；期间用户自己拖过进度条（_jumpTarget 被清）就立刻让位。
  /// 盯着一个目标位置，等播放器就绪就跳过去 —— 用户点了胶囊之后就算还在
  /// 缓冲也不用再点第二下：意图记在 _jumpTarget 里，就绪那一刻自动落地。
  ///
  /// 判定「就绪」= mpv 已经探测出时长（duration > 0）。在那之前发 seek 100% 被丢，
  /// 所以干脆一次都不发；就绪之后每 3 秒最多补一次（连续 seek 会让 mpv
  /// 不停重建解封装，越催越卡），落到目标 ±5 秒内才算成功。
  Future<void> _jumpToTarget(double target, {bool talk = false}) async {
    final t = Duration(milliseconds: (target * 1000).round());
    final t0 = DateTime.now();
    var lastSent = DateTime.fromMillisecondsSinceEpoch(0);
    // 用户点过 = 等到就绪为止（最多 5 分钟）；自己起播的只等 90 秒，
    // 而且位置过了 30 秒就当他想从头看，不再拽他。
    final limit = talk ? 300 : 90;
    while (mounted && !_closing && _jumpTarget == target) {
      if ((_vc.value.position - t).abs() <= const Duration(seconds: 5)) {
        _resumeTarget = null;
        if (mounted) {
          setState(() {
            _jumpTarget = null;
            _resumedFrom = null;
            _jumpArmed = false;
          });
        }
        if (talk) widget.app.toast('已回到 ${_mmss(target)}');
        return;
      }
      if (_vc.value.duration > Duration.zero &&
          DateTime.now().difference(lastSent).inMilliseconds >= 3000) {
        lastSent = DateTime.now();
        await _vc.seekTo(t);
      }
      if (!talk && _vc.value.position.inSeconds > 30) break;
      if (DateTime.now().difference(t0).inSeconds > limit) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // 没跳成也把胶囊留着（_jumpTarget 不清），缓冲好了再点一下就行
    if (talk && mounted && _jumpTarget == target) {
      setState(() => _jumpArmed = false);
      widget.app.toast('还没就绪，胶囊留着，缓冲好了再点一下');
    }
  }

  /// 点顶部胶囊：记下位置 + 立刻尝试，缓冲没就绪就等它自己跳
  Future<void> _tapResume() async {
    final target = _jumpTarget ?? _resumedFrom ?? _resumeTarget;
    if (target == null) return;
    unawaited(_vc.play()); // 先播起来：暂停/未打开时 mpv 丢 seek 的概率更高
    setState(() {
      _resumedFrom = target;
      _jumpTarget = target;
      _jumpArmed = true;
    });
    final ready = _vc.value.duration > Duration.zero;
    widget.app.toast(
      ready ? '跳回 ${_mmss(target)}' : '记下了 ${_mmss(target)}，缓冲就绪后自动跳过去',
    );
    await _jumpToTarget(target, talk: true);
  }

  void _savePos({bool force = false}) {
    if (!_ready) return;
    final v = _vc.value;
    // 续播的 seek 还没落地时，position 会停在 0 —— 这时候存盘等于把真实进度抹掉，
    // 下次打开就只能从头看。等跳到目标附近再允许写。
    final target = _resumeTarget;
    if (!force &&
        target != null &&
        target > 60 &&
        v.position.inSeconds < target - 30) {
      return;
    }
    final dur = v.duration.inMilliseconds / 1000;
    if (dur <= 0) return;
    final now = DateTime.now();
    if (!force && _lastSave != null && now.difference(_lastSave!).inSeconds < 5)
      return;
    _lastSave = now;
    widget.app.api
        .playSave(
          _entry.path,
          v.position.inMilliseconds / 1000,
          dur,
          _entry.name,
        )
        .catchError((_) {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 窗口亮度交回系统（系统亮度如果改过就保留，那是用户自己要的）
    Native.resetBrightness();
    // 关播放器就把实时听译停掉：实时任务是「从起点一路读到片尾」，
    // 不停会一直占着转写槽，下一次听译就得排队（用户看到的"不够实时"就是这个）。
    // 退出播放器：实时听彻底停（任务 + 段落 + 记录全清，不等清扫器）
    _closing = true;
    _liveOn = false;
    _livePing?.cancel();
    if (_trLiveFlag) {
      _trLiveFlag = false;
      TrBus.endLive(); // 队列翻译可以继续了
    }
    // 实时翻译的缓存只在这次播放里有效（用户定的）：退出播放器清空
    Translator.clearCache();
    unawaited(_endLiveSession());
    // 还原成「允许所有方向」：以前这里写死 portraitUp，
    // 平板横着退出播放器就被强制转竖，界面跟着崩掉
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _savePos(force: true); // 退出时记一次，别丢最后几秒
    _hideTimer?.cancel();
    _jobPoll?.cancel();
    _seekDebounce?.cancel();
    _pfTimer?.cancel();
    _vc.removeListener(_tick);
    _vc.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _vc.value.isPlaying) setState(() => _controls = false);
    });
  }

  void _toggleControls() {
    setState(() => _controls = !_controls);
    if (_controls) _scheduleHide();
  }

  /// 任何一次跳转（拖进度条 / 快进快退 / 续播）之后都要走这里：
  /// 1) 把这条任务的拉取游标归零 —— 服务端按 `end > since` 过滤，不归零的话
  ///    拖回去之后新转出来的「前面的段」永远被过滤掉，表现就是一片空白；
  /// 2) 立刻拉一次 + 报播放头，别等下一轮轮询（1.5 秒的延迟用户能感觉到）；
  /// 3) 位置落在没转过的区域时重开实时窗口（内部有限流）。
  void _afterSeek() {
    // 用户自己动了进度条：别再拿「从 X 继续」去拽他
    _jumpTarget = null;
    _jumpArmed = false;
    _trAt = DateTime.fromMillisecondsSinceEpoch(0);
    final id = _subJob?.id;
    if (id != null) _pulledTo[id] = 0;
    _forcePull = true;
    _pollJob();
    _onUserSeek();
  }

  /// 暂停时往前多转一段（空闲预转）：从已经转到的位置往后接着转，
  /// 这样用户回来往前提进度条时，字幕已经在手上了。
  void _prefetchAhead(bool paused) {
    if (_closing || !_subsOn || _subW != 'ai') return;
    _pfTimer?.cancel();
    if (!paused) {
      // 恢复播放：只把窗口收回默认，**不 relocate** —— relocate 会 cancel
      // 正在转的那一块，用户看到的是字幕断档几秒。
      unawaited(_resetAhead());
      return;
    }
    _pfTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || _closing) return;
      final pos = _vc.value.position.inMilliseconds / 1000.0;
      final j = _subJob;
      final done = j?.doneUntil ?? 0;
      // 已经有窗口在往后转：**千万别 relocate**。relocate 会把正在跑的那一窗
      // 打掉，而重开窗从 3 秒首窗起 —— 暂停期间实测 11 秒才拿到 3 秒字幕，
      // 等于根本没在预转。
      if (j != null && j.running && done > pos + 10) return;
      // 已经预转到位（10 分钟余量）也不用再来一次
      if (done - pos >= 560) return;
      // 常驻会话（2026-11-02）：暂停只把「领先上限」放大到 600 秒，
      // **不再 relocate**。relocate = 重开 ffmpeg + 缓冲从 0 爬到 45 秒，
      // 正是「假预转」的根因（实测 11 秒才拿到 3 秒字幕）。
      unawaited(widget.app.api
          .subsAhead(_entry.path, name: _entry.name, ahead: 600));
    });
  }

  /// 把预转窗口收回默认（不换起转点、不打断当前窗口）。
  Future<void> _resetAhead() async {
    try {
      await widget.app.api.subsAhead(_entry.path, name: _entry.name, ahead: 0);
    } catch (e) {
      // 没收回预听：转写工会一直在后台往前转，白烧 CPU
      debugPrint('实时听：收回预听失败 $e');
    }
  }

  /// 用户拖动（或系统跳转）——去抖 350ms 只发一次，
  /// 连续拖、快速来回拖都不会把服务端拖进「换位置风暴」。
  void _onUserSeek() {
    _seekHandledAt = DateTime.now();
    final epoch = ++_seekEpoch;
    _seekDebounce?.cancel();
    _seekDebounce = Timer(const Duration(milliseconds: 350), () {
      // 只认最后一次：中间被后来的拖动顶掉的回调直接作废
      if (!mounted || _closing || epoch != _seekEpoch) return;
      _liveGuard(userSeek: true);
    });
  }

  /// 用户主动跳转：mpv 会把 seek 丢掉（文件还没打开、缓存刚重建、追流中），
  /// 表现就是「点了进度条/点了快进，画面没跳过去」。这里跳完核一次位置，
  /// 差得远就再补一次，最多补三次。
  Future<void> _seekToChecked(Duration target) async {
    final total = _vc.value.duration;
    var t = target;
    if (t.isNegative) t = Duration.zero;
    if (total > Duration.zero && t > total) t = total;
    _seekTarget = t;
    await _vc.seekTo(t);
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted || _closing) return;
      if (_seekTarget != t) return; // 用户又跳了一次，别跟人抢
      if ((_vc.value.position - t).abs() <= const Duration(seconds: 5)) {
        _seekTarget = null;
        return;
      }
      await _vc.seekTo(t);
    }
    _seekTarget = null;
  }

  void _seekRelative(int seconds) {
    final target = _vc.value.position + Duration(seconds: seconds);
    unawaited(_seekToChecked(target));
    _afterSeek();
    _scheduleHide();
  }

  // 旧版播放设置里的三项 + 锁屏 + 音量
  double _vol = 1;
  double _bri = 1; // 0.05~1.0，应用内亮度（不动系统设置）
  bool _briHint = false;
  bool _briPermTold = false;
  bool _briSystem = false; // 上次改亮度用的是系统亮度还是只改窗口
  DateTime _lastVolAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _lpRate = 1; // 长按期间滑动出来的倍速
  double _lpBase = 1; // 按下那一刻正在播的倍数（滑动的起算点）
  Duration _dragFrom = Duration.zero; // 拖动起点（锚定用，不能拿实时位置累加）
  Duration? _seekTarget;              // 刚跳到的位置：用来核对 mpv 有没有真的跳
  double _dragDx = 0;
  DateTime _lastSeekAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _swipe = 1; // 0 低 / 1 中 / 2 高
  bool _locked = false;
  bool _lpOn = false;

  // ---- 一根手指同一时刻只做一件事：调进度 / 调音量 / 调亮度 / 长按倍速 ----
  // 以前四个手势挂在同一个 GestureDetector 上，靠竞技场决胜负，谁先到 500ms
  // 或谁先过 slop 谁赢 —— 用户按住稍久再拖，赢的是长按（倍速），不是进度条。
  Timer? _gTimer;
  int _gPtr = -1; // 正在跟踪的手指；第二根手指按下来不打断第一根
  GestMode _gMode = GestMode.none;
  Offset _gStart = Offset.zero;
  Offset _gDelta = Offset.zero;
  double _gWidth = 1;
  Duration? _seekHint;
  bool _volHint = false;

  int get _idx {
    if (widget.playlist.isEmpty) return -1;
    final i = widget.playlist.indexWhere((e) => e.path == _entry.path);
    return i;
  }

  Entry? get _prevEp {
    final i = _idx;
    return i > 0 ? widget.playlist[i - 1] : null;
  }

  Entry? get _nextEp {
    final i = _idx;
    return (i >= 0 && i < widget.playlist.length - 1)
        ? widget.playlist[i + 1]
        : null;
  }

  /// 当前是否横屏（跟屏幕真实方向一致，不再靠自增的布尔值猜）
  bool get _isLand =>
      MediaQuery.of(context).orientation == Orientation.landscape;

  /// 锁定到一个方向。竖屏时用的是 `portraitUp` —— 不锁的话手一歪又转回去，
  /// 用户会觉得「点了没反应」。
  Future<void> _setOrient(bool landscape) async {
    if (_orientBusy) return;
    _orientBusy = true;
    try {
      if (landscape) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown, // 跟系统旋转一致：同一轴两个朝向都放行
        ]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    } finally {
      _orientBusy = false;
    }
    if (mounted) setState(() {});
  }

  /// 按钮：横屏 ↔ 竖屏循环（按真实方向判断，不会出现「已经是横的还去转横」）
  Future<void> _toggleOrient() async {
    _orientManual = true;
    await _setOrient(!_isLand);
  }

  bool _orientBusy = false;

  /// 用户手动点过方向按钮：这一部片子里自动定方向就不再插手（mpv 的 manual 模式）
  bool _orientManual = false;

  /// 打开就按视频本身的比例定方向：横的视频直接转横屏，竖的保持竖屏。
  ///
  /// 以前是 `initialize()` 之后等 2 秒，等不到就放弃 —— 4K/网络盘首帧经常
  /// 要 5–10 秒（杜比片实测 9.7s），于是「打开还是竖的」。
  /// 现在改成在 `_tick` 里盯着：尺寸一出来就定方向，一次片只定一次。
  bool _oriented = false;

  /// 不指定方向，交给系统（正方形素材、探测失败时用）
  Future<void> _setFree() async {
    if (_orientBusy) return;
    _orientBusy = true;
    try {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    } finally {
      _orientBusy = false;
    }
  }

  Future<void> _autoOrient() async {
    if (_orientManual) return;
    final ar = _vc.value.aspectRatio;
    if (ar.isFinite == false || ar <= 0) return;
    if (ar > 1.05) {
      await _setOrient(true); // 横屏视频
    } else if (ar < 0.95) {
      await _setOrient(false); // 竖屏视频
    }
    // 方形/拿不到比例：交给系统（mpv 的 UNSPECIFIED 做法），别硬锁一个方向
    if (ar <= 1.05 && ar >= 0.95) await _setFree();
    if (mounted) setState(() {});
  }

  /// 已缓冲到的位置（旧版那条灰白层）
  Duration get _bufferEnd => _vc.bufferEnd;

  // ---------- 旧版那套：播放设置 / 本目录视频 / 锁屏 ----------

  Future<void> _setSpeed(double v) async {
    _speed = v;
    await _vc.setPlaybackSpeed(v);
    if (mounted) setState(() {});
  }

  void _restart() {
    _vc.seekTo(Duration.zero);
    _vc.play();
    setState(() {});
  }

  Future<void> _showRateMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16181C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget grid(
            List<(String, double?)> opts,
            double? cur,
            void Function(double?) pick, {
            List<bool>? enabled,
            String? disabledHint,
          }) {
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var gi = 0; gi < opts.length; gi++)
                  () {
                    final (label, v) = opts[gi];
                    final can =
                        enabled == null ||
                        (gi < enabled.length ? enabled[gi] : true);
                    return GestureDetector(
                      onTap: () {
                        if (!can) {
                          widget.app.toast(disabledHint ?? '这一项当前不可选');
                          return;
                        }
                        pick(v);
                        setSheet(() {});
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: cur == v
                              ? const Color(0xFF1677F8)
                              : const Color(0x1FFFFFFF),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: !can
                                ? const Color(0xFF5C5C66)
                                : (cur == v
                                      ? Colors.white
                                      : const Color(0xFFCFCFD4)),
                          ),
                        ),
                      ),
                    );
                  }(),
              ],
            );
          }

          Widget row(String title, Widget child) => Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFF9A9AA2),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                child,
              ],
            ),
          );

          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '播放设置',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => Navigator.pop(ctx),
                        child: const UIIcon(
                          'close',
                          size: 18,
                          color: Color(0xFF9A9AA2),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${_vc.engine}｜片源：${_dvKnown == null ? '检测中' : _dvLabel}'
                    '｜${_vc.dvInfo.isEmpty ? '还没拿到画面信息' : _vc.dvInfo}',
                    style: const TextStyle(
                      color: Color(0xFF8E8E96),
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  row(
                    '播放速度',
                    grid(
                      [
                        for (final v in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0])
                          ('${v}x', v),
                      ],
                      _speed,
                      (v) {
                        if (v != null) _setSpeed(v);
                      },
                    ),
                  ),
                  row(
                    '解码方式',
                    grid(
                      const [('硬解', 0.0), ('软解', 1.0), ('杜比', 2.0)],
                      _dolby ? 2.0 : (_soft ? 1.0 : 0.0),
                      (v) {
                        final i = (v ?? 0).round();
                        final dolby = i == 2;
                        final soft = i == 1;
                        if (dolby == _dolby && soft == _soft) return;
                        setSheet(() {
                          _dolby = dolby;
                          _soft = soft;
                        });
                        _switchDecoder(soft);
                        widget.app.toast(
                          dolby
                              ? '已切杜比模式（杜比视界片用这个）'
                              : (soft ? '已切换软解（兼容性最好）' : '已切换硬解（更省电）'),
                        );
                      },
                      enabled: [true, true, _dvPickable],
                      disabledHint: _dvKnown == null
                          ? '还在检测片源，等一下再看'
                          : '这个文件不是杜比视界（服务端已用 ffprobe 验过码流），不需要杜比模式',
                    ),
                  ),

                  // 音轨：多音轨才显示。听译抽的就是这里选中的那条，
                  // 选错了会出现「听出来的语言不是片子原声」。
                  // 只有一条音轨时也显示（灰掉 + 提示），免得看起来像功能没了
                  if (_audioOpts.isNotEmpty)
                    row(
                      '音轨',
                      grid(
                        [
                          for (var k = 0; k < _audioOpts.length; k++)
                            (_audioOpts[k], k.toDouble()),
                        ],
                        _aord.toDouble(),
                        (v) {
                          if (_audioOpts.length > 1) _pickAudio((v ?? 0).round());
                        },
                        enabled: [
                          for (var k = 0; k < _audioOpts.length; k++)
                            _audioOpts.length > 1,
                        ],
                        disabledHint: '这个文件只有一条音轨',
                      ),
                    ),
                  row(
                    '滑动灵敏度',
                    grid(
                      const [('低', 0.0), ('中', 1.0), ('高', 2.0)],
                      _swipe.toDouble(),
                      (v) {
                        setSheet(() => _swipe = (v ?? 1).toInt());
                      },
                    ),
                  ),
                  Row(
                    children: [
                      _MenuAction(
                        icon: 'pip',
                        label: '画中画',
                        onTap: () {
                          Navigator.pop(ctx);
                          widget.app.toast('这版还不支持画中画，得等插件支持');
                        },
                      ),
                      const SizedBox(width: 10),
                      _MenuAction(
                        icon: 'rotate',
                        label: '从头播放',
                        onTap: () {
                          Navigator.pop(ctx);
                          _restart();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '左右滑＝快进快退 · 长按＋左右滑＝调速（松手保持） · 左竖滑＝亮度 · 右竖滑＝音量 · 双击＝全屏',
                    style: TextStyle(
                      color: Color(0xFF7C7C86),
                      fontSize: 11,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 亮度：优先改系统屏幕亮度（需要「修改系统设置」权限），
  /// 没权限时原生侧退到窗口亮度，至少画面能立刻变。
  Future<void> _setBrightness(double v) async {
    final pct = (v.clamp(0.05, 1.0) * 100).round();
    final r = await Native.setBrightness(pct);
    _briSystem = r.startsWith('system');
    if (!_briSystem && !_briPermTold) {
      _briPermTold = true;
      widget.app.toast('改的是窗口亮度；要改系统亮度去 设置→更多→系统亮度权限');
    }
  }

  /// 起一个实时听译任务：从当前播放位置开始（旧版 subsStart 的 start-2s）
  Future<void> _startLiveSubs({bool silent = false}) async {
    if (_closing) return;
    final pos = _vc.value.position.inMilliseconds / 1000.0;
    // 这一段已经听过了就从它后面接着听：不然服务端一看「播放头已被覆盖」
    // 就直接返回，界面上就是「点了实时听却什么都没发生」。
    var start = nextUncovered(_aiCues, pos > 2 ? pos - 2 : 0.0);
    final dn0 = _subJob?.doneUntil ?? 0;
    if (_subJob?.state == 'done' && dn0 > start && dn0 - start <= 30) {
      start = dn0;
    }
    if (!silent) {
      widget.app.toast(
        (start - pos).abs() > 3
            ? '开始实时听 · 跳过已有字幕，从 ${_mmss(start)} 接着听'
            : '开始实时听 · 约 10 秒出第一句',
      );
    }
    try {
      final r = await widget.app.api.subsRelocate(
        _entry.path,
        name: _entry.name,
        at: start,
        skipFrom: start,
        source: widget.app.source, // 115 的片子必须带 nas115，写死 nas 会 404
        lang: widget.app.session.subsLang,
        track: _asrAt, // 听的就是画面里这条音轨，别再让服务端猜
        session: _liveSession,
        hot: _hotWords,
      );
      if (r['error'] == 'queue_full') {
        widget.app.toast('听任务太多了，先等一会儿');
        return;
      }
      final nid = (r['id'] as String?) ?? '';
      if (nid.isNotEmpty) {
        _liveIds.add(nid);
        _liveWantId = nid;
      }
      _seenSegs.clear(); // 强制下一次轮询拉一遍
      _liveOn = true;
      // 起来就切到「实时译」，别让用户再点一次来源
      setState(() {
        _subsOn = true;
        _subW = 'ai';
      });
      _startJobPoll();
      _startPingLoop();
    } catch (e) {
      widget.app.toast('起任务失败：$e');
    }
  }

  Future<void> _switchLang(String code) async {
    if (widget.app.session.subsLang == code || _langBusy) return;
    _langBusy = true;
    widget.app.session.subsLang = code;
    await widget.app.session.save();
    if (!mounted) return;
    setState(() {
      // 只清译文、保留原文：换语言不该让画面空一下，也不该丢掉已经听到的句子
      for (final c in _aiCues) {
        if (c.length > 3) c[3] = '';
      }
      for (final c in _fileCues) {
        if (c.length > 3) c[3] = '';
      }
      _seenSegs.clear();
      // 换了语言就等于整片没译过：重新允许按播放头翻
      _aiTrFull = false;
    });
    _trAt = DateTime.fromMillisecondsSinceEpoch(0);
    final j = _subJob;
    if (j != null) {
      try {
        await widget.app.api.subsLang(j.id, code); // 服务端作废旧译文，按播放头重翻
      } catch (_) {}
    }
    _langBusy = false;
    if (mounted) setState(() {});
    widget.app.toast('译文改成 ${subLangName(code)}');
  }

  bool _langBusy = false;

  /// 字幕面板：来源（关/同名/译）+ 听（实时/队列）+ 译（语言）+ 显示微调，都在一块里
  Future<void> _showSubMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF16181C),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void commit(void Function() f) {
            setSheet(f);
            setState(() {});
            _saveSubPrefs();
          }

          final j = _subJob;
          final hasFile = _fileCues.isNotEmpty;
          final hasAi = _aiCues.isNotEmpty;
          final liveOn = _liveOn || (j?.live ?? false);

          // 来源三段：关 / 同名 / 译
          Widget src(String label, String code, {required bool can}) {
            final on = code.isEmpty ? !_subsOn : (_subsOn && _subW == code);
            return Expanded(
              child: GestureDetector(
                onTap: () async {
                  // 切到 App 自己画的字幕时，把 mpv 那层图形字幕关掉
                  if (_mpvSid != null) unawaited(_pickEmbSub(null));
                  if (code == 'ai') {
                    // 一个入口：已经有字幕（队列听转好的 / 实时听出来的）就切轨，
                    // 一条都没有才现开实时听。
                    if (hasAi || liveOn) {
                      commit(() {
                        _subsOn = true;
                        _subW = 'ai';
                      });
                      // 之前切成同名字幕/关字幕时把实时听停了：这里重新打开开关，
                      // _liveGuard 会从当前播放位置继续（已听到的部分不重转）。
                      // 但整片已经转好（_aiDone）就别再开实时听了 —— 那是白跑一趟，
                      // 还会把已经转好的段落拿去做实时补丁。
                      if (!_liveOn && !_aiDone) {
                        _liveOn = true;
                        _liveRestartAt = DateTime.fromMillisecondsSinceEpoch(0);
                        unawaited(_liveGuard());
                      }
                      return;
                    }
                    // 点「已听完」但内存里没有 cue（关过字幕、或刚被清过）：
                    // 从服务端把整片字幕重新拉一遍，别让按钮点了没反应。
                    if (_aiDone && _subJob != null) {
                      final id = _subJob!.id;
                      try {
                        await _pullLiveSrt(id);
                        await _pullSavedTr();
                        if (mounted && _aiCues.isNotEmpty) {
                          commit(() {
                            _subsOn = true;
                            _subW = 'ai';
                          });
                          widget.app.toast('已加载整片字幕 · ${_aiCues.length} 句');
                          return;
                        }
                      } catch (_) {}
                      widget.app.toast('这条任务的字幕拉不回来，去听监控里看看');
                      return;
                    }
                    Navigator.pop(ctx);
                    if (_aiDone) {
                      widget.app.toast('已加载整片字幕 · ${_aiCues.length} 句');
                    } else {
                      await _startLiveSubs();
                    }
                    return;
                  }
                  if (!can) {
                    widget.app.toast('这个目录里没有同名字幕');
                    return;
                  }
                  if (code.isEmpty) {
                    // 关字幕 = 同时停掉实时听（用户要的就是「关掉就别再转了」）。
                    // keepCues：整片听译的字幕是服务端转好的，关掉只是不显示，
                    // 不能连 cue 一起清 —— 否则再点「已听完」按钮就点不动了
                    // （用户报的：关掉字幕后点不回已听完）。
                    commit(() {
                      _subsOn = false;
                      _subW = '';
                    });
                    unawaited(_stopLiveSubs(keepCues: true));
                    return;
                  }
                  // 从「听字幕」切到别的来源：实时听该停了 —— 不然面板上写着
                  // 「转写中」，用户却在看同名字幕，中枢那边还一直占着资源。
                  final leavingLive = _liveOn && code != 'ai';
                  commit(() {
                    _subsOn = true;
                    _subW = code;
                  });
                  if (leavingLive) unawaited(_stopLiveSubs(keepCues: true));
                },
                child: Container(
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on
                        ? const Color(0xFF1677F8)
                        : const Color(0x14FFFFFF),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      color: on
                          ? Colors.white
                          : (can
                                ? const Color(0xFFC9D3E0)
                                : const Color(0xFF6E6E76)),
                    ),
                  ),
                ),
              ),
            );
          }

          Widget row({
            required String icon,
            required String title,
            required String sub,
            required VoidCallback? onTap,
            Widget? trailing,
            Color? tint,
          }) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Row(
                children: [
                  UIIcon(
                    icon,
                    size: 17,
                    color:
                        tint ??
                        (onTap == null
                            ? const Color(0xFF6E6E76)
                            : Colors.white),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            color: onTap == null
                                ? const Color(0xFF6E6E76)
                                : Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (sub.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF9A9AA2),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) trailing,
                ],
              ),
            ),
          );

          Widget adj(
            String label,
            String value,
            VoidCallback minus,
            VoidCallback plus,
          ) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            child: Row(
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFFCFCFD4),
                    fontSize: 12.5,
                  ),
                ),
                const Spacer(),
                _adjBtn('−', minus),
                SizedBox(
                  width: 62,
                  child: Text(
                    value,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                _adjBtn('+', plus),
              ],
            ),
          );

          Widget cap(String t) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(
              t,
              style: const TextStyle(
                color: Color(0xFF8E9BAC),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
          );

          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
                    child: Row(
                      children: [
                        const Text(
                          '字幕',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _subW == 'file'
                              ? '同名字幕'
                              : _subW == 'ai'
                              ? '听字幕'
                              : '关',
                          style: const TextStyle(
                            color: Color(0xFF7C7C86),
                            fontSize: 12,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.pop(ctx),
                          child: const UIIcon(
                            'close',
                            size: 18,
                            color: Color(0xFF9A9AA2),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ---- 来源 ----
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                    child: Row(
                      children: [
                        src('关', '', can: true),
                        const SizedBox(width: 8),
                        src('同名字幕', 'file', can: hasFile),
                        const SizedBox(width: 8),
                        src(_aiDone ? '已听完' : '听字幕', 'ai', can: true),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                    child: Text(
                      _subW == 'file' && _subFileName != null
                          ? _subFileName!
                          : (_subW == 'ai'
                                ? (_aiCues.isEmpty
                                      ? '还没有句子'
                                      : '${_aiCues.length} 句 · 译文 ${_aiCues.where((c) => (c[3] as String?)?.isNotEmpty == true).length} 句')
                                : '字幕已关闭'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF6E6E76),
                        fontSize: 11,
                      ),
                    ),
                  ),

                  // ---- 音轨 ----
                  // 放在字幕面板里：用户在同一个面板调「听哪条声音、看什么字」，
                  // 不用再退出到「播放设置」。只有一条音轨时也列出来（标灰），
                  // 否则看起来像「切换音轨的功能没了」（用户反馈）。
                  if (_audioOpts.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: Row(
                        children: [
                          const Text(
                            '音轨',
                            style: TextStyle(
                              color: Color(0xFFCFCFD4),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (_audioOpts.length == 1)
                            const Text(
                              '这个文件只有一条',
                              style: TextStyle(
                                color: Color(0xFF6E6E76),
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var k = 0; k < _audioOpts.length; k++)
                            GestureDetector(
                              onTap: _audioOpts.length < 2
                                  ? null
                                  : () async {
                                      await _pickAudio(k);
                                      if (!ctx.mounted) return;
                                      setSheet(() {});
                                      setState(() {});
                                    },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: _aord == k
                                      ? const Color(0xFF1677F8)
                                      : const Color(0x14FFFFFF),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Text(
                                  _audioOpts[k],
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: _aord == k
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: _aord == k
                                        ? Colors.white
                                        : (_audioOpts.length < 2
                                              ? const Color(0xFF6E6E76)
                                              : const Color(0xFFC9D3E0)),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],

                  // ---- 内封（图形字幕）----
                  // 蓝光片的字幕多是 PGS：抽不出文本、也不能翻译，但 mpv
                  // 能直接画到画面上。以前这类片子「同名字幕」是空的，用户
                  // 以为没识别到内封（比如 小楼的奇幻生活 CHS/CHT 两条 PGS）。
                  if (_imgSubs.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Row(
                        children: [
                          const Text(
                            '内封',
                            style: TextStyle(
                              color: Color(0xFFCFCFD4),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '图形字幕 · 不能翻译',
                            style: TextStyle(
                              color: Color(0xFF6E6E76),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final e in _imgSubs)
                            GestureDetector(
                              onTap: () async {
                                // mpv 的 sid 是「字幕轨序号」，不是 ffprobe 的绝对流序号
                                final i = _sidOf(e);
                                await _pickEmbSub(_mpvSid == i ? null : i);
                                if (!ctx.mounted) return;
                                setSheet(() {});
                                setState(() {});
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color:
                                      _mpvSid == _sidOf(e)
                                      ? const Color(0xFF1677F8)
                                      : const Color(0x14FFFFFF),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Text(
                                  '内封 ${_embLabel(e)}',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight:
                                        _mpvSid == _sidOf(e)
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color:
                                        _mpvSid == _sidOf(e)
                                        ? Colors.white
                                        : const Color(0xFFC9D3E0),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],

                  // ---- 译 ----
                  cap('译 · 出字就翻'),
                  row(
                    icon: 'translate',
                    title: '显示译文',
                    sub: widget.app.session.subTr
                        ? '原文 + 译文双语 · ${subLangName(widget.app.session.subsLang)}'
                        : '只显示原文',
                    onTap: () {
                      commit(
                        () => widget.app.session.subTr =
                            !widget.app.session.subTr,
                      );
                      widget.app.session.save();
                      _trAt = DateTime.fromMillisecondsSinceEpoch(0);
                      _trPull();
                    },
                    trailing: Switch(
                      value: widget.app.session.subTr,
                      activeThumbColor: const Color(0xFF1677F8),
                      onChanged: (v) {
                        commit(() => widget.app.session.subTr = v);
                        widget.app.session.save();
                        _trAt = DateTime.fromMillisecondsSinceEpoch(0);
                        _trPull();
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SizedBox(
                      height: 30,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: kSubLangs.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 6),
                        itemBuilder: (_, i) {
                          final l = kSubLangs[i];
                          final on = widget.app.session.subsLang == l.code;
                          return GestureDetector(
                            onTap: () async {
                              await _switchLang(l.code);
                              setSheet(() {});
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                              ),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: on
                                    ? const Color(0xFF1677F8)
                                    : const Color(0x14FFFFFF),
                                borderRadius: BorderRadius.circular(99),
                                border: Border.all(
                                  color: on
                                      ? const Color(0xFF1677F8)
                                      : const Color(0x22FFFFFF),
                                ),
                              ),
                              child: Text(
                                l.name,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: on
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: on
                                      ? Colors.white
                                      : const Color(0xFFC9D3E0),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),

                  // ---- 显示 ----
                  cap('显示'),
                  adj(
                    '字号',
                    '${(_subSize * 100).round()}%',
                    () => commit(
                      () => _subSize = (_subSize - 0.05).clamp(0.75, 1.7),
                    ),
                    () => commit(
                      () => _subSize = (_subSize + 0.05).clamp(0.75, 1.7),
                    ),
                  ),
                  adj(
                    '位置',
                    '${_subPos >= 0 ? '+' : ''}${_subPos.round()}',
                    () =>
                        commit(() => _subPos = (_subPos - 15).clamp(-90, 240)),
                    () =>
                        commit(() => _subPos = (_subPos + 15).clamp(-90, 240)),
                  ),
                  adj(
                    '延迟',
                    '${_subDelay >= 0 ? '+' : ''}${_subDelay.toStringAsFixed(1)}s',
                    () => commit(
                      () => _subDelay =
                          ((_subDelay - 0.5).clamp(-5, 5) * 100).round() / 100,
                    ),
                    () => commit(
                      () => _subDelay =
                          ((_subDelay + 0.5).clamp(-5, 5) * 100).round() / 100,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => commit(() {
                      _subSize = 1;
                      _subPos = 0;
                      _subDelay = 0;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                      child: Container(
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0x14FFFFFF),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Text(
                          '恢复默认',
                          style: TextStyle(
                            color: Color(0xFFCFCFD4),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Text(
                      '听只转字幕，译只管翻译，两件事互不依赖。'
                      '实时听只跟播放头走，拖进度条不会丢已听到的句子；整片转写请到文件列表用「加入队列听」。',
                      style: TextStyle(
                        color: Color(0xFF7C7C86),
                        fontSize: 11,
                        height: 1.6,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _adjBtn(String t, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 34,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0x1FFFFFFF),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        t,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );

  /// 听译监控（旧版 vp-mon）：本集听译 / 精度 / 导出 srt / 停止
  /// 拉实时任务的 srt，解析成 cue 叠到画面上
  /// 把某条任务的段落写进 _byJob，再把所有任务合并成一条时间线


  Future<void> _showPlaylist() async {
    if (widget.playlist.isEmpty) {
      widget.app.toast('这个目录里只有这一个视频');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF16181C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 12, 8),
              child: Row(
                children: [
                  const Text(
                    '本目录的视频',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${widget.playlist.length}',
                    style: const TextStyle(
                      color: Color(0xFF7C7C86),
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx),
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: UIIcon(
                        'close',
                        size: 18,
                        color: Color(0xFF9A9AA2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.playlist.length,
                itemBuilder: (c, i) {
                  final e = widget.playlist[i];
                  final on = e.path == _entry.path;
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      if (!on) _switchTo(e);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      color: on ? const Color(0x1A1677F8) : Colors.transparent,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              e.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: on
                                    ? const Color(0xFF7FB6FF)
                                    : Colors.white,
                                fontSize: 13,
                                fontWeight: on
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          if (on)
                            const Text(
                              '正在播',
                              style: TextStyle(
                                color: Color(0xFF7FB6FF),
                                fontSize: 11,
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
        ),
      ),
    );
  }

  /// 换一集：新链接、重置字幕和进度，继续记播放位置
  Future<void> _switchTo(Entry e) async {
    final url = await widget.app.linkOf(e);
    if (url == null || !mounted) return;
    _savePos(force: true);
    final old = _vc;
    setState(() {
      _ready = false;
      _error = null;
      _fileCues = const [];
      _aiCues = const [];
      _liveOn = false;
      _subFileName = null;
      _resumedFrom = null;
      _resumeTarget = null;
      _jumpTarget = null;
      _jumpArmed = false;
      _entry = e;
    });
    await old.pause();
    old.removeListener(_tick);
    await old.dispose();
    _open(url);
  }

  /// 硬解 / 软解切换：换引擎重开，位置和播放状态接着原来的
  Future<void> _switchDecoder(bool soft) async {
    final pos = _vc.value.position;
    final playing = _vc.value.isPlaying;
    final old = _vc;
    old.removeListener(_tick);
    setState(() => _ready = false);
    await old.dispose();
    final gen = ++_gen;
    _vc = MKPlayback.network(_url, software: soft, dolby: _dolby);
    _vc.addListener(_tick);
    try {
      await _vc.initialize();
      if (!mounted || gen != _gen) return;
      if (pos > Duration.zero) await _vc.seekTo(pos);
      // 换引擎会把速度/音轨重置成默认值，用户选过的得接回来
      if ((_speed - 1.0).abs() > 0.01) await _vc.setPlaybackSpeed(_speed);
      _applyAudio();
      if (playing) await _vc.play();
      if (mounted) setState(() => _ready = true);
      // 杜比直通不是每台机都支持（vo=mediacodec_embed 建不起来就黑屏），
      // 3 秒没画面就自己退回硬解，别把人卡死
      if (_dolby) {
        Future.delayed(const Duration(seconds: 3), () {
          if (!mounted || !_dolby) return;
          if (_vc.hasError || _vc.value.duration == Duration.zero) {
            setState(() {
              _dolby = false;
              _soft = false;
            });
            _switchDecoder(false);
            setState(() => _dvNote = true);
            widget.app.toast('杜比转换没起来，已回硬解（画面可能发绿）');
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // ---------------------------------------------------------------- 指针仲裁
  // 规则（跟主流播放器一致，重点是「互斥」）：
  //   按下 → 500ms 内手指没超过 14px → 长按倍速（固定倍数，不滑动、不锁定）
  //        → 越过 14px 且横向位移大 → 调进度
  //        → 越过 14px 且竖向位移大 → 左半屏亮度 / 右半屏音量
  // 定性之后这一根手指就只做那件事，直到抬起；松手才结算。
  void _gDown(PointerDownEvent e) {
    if (_locked) return;
    if (_gPtr != -1) return; // 多指只跟第一根，避免第二根把状态清掉
    _gPtr = e.pointer;
    _gTimer?.cancel();
    _gTimer = null;
    _gMode = GestMode.none;
    _gStart = e.localPosition;
    _gDelta = Offset.zero;
    _gWidth = MediaQuery.of(context).size.width;
    _gTimer = Timer(const Duration(milliseconds: kLongPressMs), () {
      if (!mounted || _gMode != GestMode.none) return;
      _speedStart();
    });
  }

  void _gMove(PointerMoveEvent e) {
    if (_locked || e.pointer != _gPtr) return;
    _gDelta += e.delta;
    if (_gMode == GestMode.speed) {
      _speedMove();
      return;
    }
    if (_gMode == GestMode.none) {
      final m = advanceMode(_gMode, _gDelta, _gStart.dx, _gWidth);
      if (m == GestMode.none) return; // 手指抖动，先不定性
      _gTimer?.cancel();
      _gTimer = null;
      _gMode = m;
      if (_gMode == GestMode.seek) {
        _dragFrom = _vc.value.position;
        _dragDx = 0;
      }
    }
    switch (_gMode) {
      case GestMode.seek:
        _seekMove();
        break;
      case GestMode.bri:
        _briMove(e.delta);
        break;
      case GestMode.vol:
        _volMove(e.delta);
        break;
      case GestMode.none:
      case GestMode.speed:
        break;
    }
  }

  void _gUp(PointerEvent? e, {bool cancel = false}) {
    if (e != null && e.pointer != _gPtr) return;
    _gPtr = -1;
    _gTimer?.cancel();
    _gTimer = null;
    final mode = _gMode;
    _gMode = GestMode.none;
    switch (mode) {
      case GestMode.speed:
        if (cancel) {
          // 被系统打断（来电、多指、滑出边缘）：直接回原速
          if (_lpOn) {
            _lpOn = false;
            _speed = _lpRate; // 被打断也停在当前倍数，不弹回
            _vc.setPlaybackSpeed(_speed);
            setState(() {});
          }
        } else {
          _speedEnd();
        }
        break;
      case GestMode.seek:
        final t = _seekHint;
        if (t != null) unawaited(_seekToChecked(t)); // 最后一跳落到松手位置
        setState(() => _seekHint = null);
        _afterSeek();
        _scheduleHide();
        break;
      case GestMode.vol:
      case GestMode.bri:
        Native.setVolume((_vol * 100).round());
        setState(() {
          _volHint = false;
          _briHint = false;
        });
        _scheduleHide();
        break;
      case GestMode.none:
        break; // 只是点了一下，交给外层 GestureDetector 的 onTap
    }
    _gDelta = Offset.zero;
  }

  void _seekMove() {
    _dragDx = _gDelta.dx;
    final total = _vc.value.duration;
    // 起点锚定在按下时的位置：mpv 的 position 更新有延迟，用实时位置累加会「拖不动」
    final p =
        _dragFrom +
        Duration(milliseconds: (_dragDx * (2 + _swipe * 2) * 12).round());
    final clamped = p.isNegative
        ? Duration.zero
        : (total > Duration.zero && p > total ? total : p);
    setState(() => _seekHint = clamped);
    final now = DateTime.now();
    if (now.difference(_lastSeekAt).inMilliseconds >= 120) {
      _lastSeekAt = now;
      _vc.seekTo(clamped);
    }
  }

  void _briMove(Offset d) {
    _bri = (_bri - d.dy / 260).clamp(0.05, 1.0);
    _setBrightness(_bri);
    setState(() => _briHint = true);
  }

  void _volMove(Offset d) {
    _vol = (_vol - d.dy / 260).clamp(0.0, 1.0);
    final now = DateTime.now();
    if (now.difference(_lastVolAt).inMilliseconds >= 80) {
      _lastVolAt = now;
      Native.setVolume((_vol * 100).round());
    }
    setState(() => _volHint = true);
  }

  /// 长按 = 抓住倍速旋钮：从**当前正在播的倍数**开始，左右滑调整，松手就停在那。
  /// 不跳到固定值、不回到原速 —— 用户要的是「按住拖一下，松手就是这个速度」。
  void _speedStart() {
    _gMode = GestMode.speed;
    _lpOn = true;
    _lpBase = _speed; // 起算点＝当前倍数，不是设置里的 2.0
    _lpRate = _speed;
    setState(() {});
  }

  /// 长按期间手指左右滑 = 调速（110px 一级，0.5x–4x）。
  void _speedMove() {
    if (!_lpOn) return;
    final r = lpRateAt(_lpBase, _gDelta.dx);
    if ((r - _lpRate).abs() < 0.02) return;
    _lpRate = r;
    _vc.setPlaybackSpeed(r);
    setState(() {});
  }

  /// 松手：停在这个倍数上（不恢复原速）。
  void _speedEnd() {
    if (!_lpOn) return;
    _lpOn = false;
    _speed = _lpRate;
    _vc.setPlaybackSpeed(_speed);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // 只留单击显隐、双击全屏。
        // 拖动和长按不放在这里：Flutter 的手势竞技场里，长按和横向/纵向拖动
        // 会互抢（按住 0.4 秒想拖进度条，先触发的是长按倍速；
        // 慢慢竖起手指调音量，也先被判成长按）。统一交给下面那层指针仲裁器。
        onTap: _toggleControls,
        onDoubleTap: () => _vc.playOrPause(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_dvNote)
              Positioned(
                top: 40,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _dvNote = false;
                        _dolby = true;
                        _soft = false;
                      });
                      _switchDecoder(false);
                      widget.app.toast('重试杜比模式');
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        '杜比视界 · 转换没起来，点这里重试',
                        style: TextStyle(
                          color: Color(0xFFE8C37A),
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const AppIcon('help', color: Colors.white54, size: 40),
                      const SizedBox(height: 14),
                      Text(
                        '播不了\n$_error',
                        textAlign: TextAlign.center,
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!_soft)
                            TextButton(
                              onPressed: () async {
                                setState(() {
                                  _soft = true;
                                  _dolby = false;
                                  _error = null;
                                });
                                await _switchDecoder(true);
                              },
                              child: const Text(
                                '用软解重试',
                                style: TextStyle(
                                  color: Color(0xFF7FB6FF),
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          TextButton(
                            onPressed: () async {
                              setState(() => _error = null);
                              _open(_url);
                            },
                            child: const Text(
                              '再试一次',
                              style: TextStyle(
                                color: Color(0xFFB9C6D8),
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () =>
                                widget.app.downloadEntry(widget.entry),
                            child: const Text(
                              '下载到本机',
                              style: TextStyle(
                                color: Color(0xFFB9C6D8),
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )
            else if (!_ready)
              const Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white54,
                  ),
                ),
              )
            else
              Center(
                child: AspectRatio(
                  aspectRatio: _vc.value.aspectRatio == 0
                      ? 16 / 9
                      : _vc.value.aspectRatio,
                  child: _vc.render(),
                ),
              ),
            if (_ready && _subsOn && _currentCue != null)
              Positioned(
                left: 24,
                right: 24,
                bottom: (_controls ? 96 : 44) + _subPos,
                child: IgnorePointer(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 旧版双轨：上原文（小、偏灰），下译文（大、白）
                      // 「显示译文」关掉时一律只显示原文 —— 以前这里没看开关，
                      // 结果关了译还是满屏译文（用户：关闭翻译之后还会显示翻译）
                      if (_hasDual && _trShown)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            _currentCue![2] as String,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12.5 * _subSize,
                              height: 1.35,
                              color: Colors.white.withValues(alpha: 0.72),
                              shadows: const [
                                Shadow(blurRadius: 8, color: Colors.black87),
                              ],
                            ),
                          ),
                        ),
                      Text(
                        _trShown &&
                                ((_currentCue![3] as String?)?.isNotEmpty ??
                                    false)
                            ? _currentCue![3] as String
                            : _currentCue![2] as String,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 17 * _subSize,
                          height: 1.4,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          shadows: [
                            Shadow(blurRadius: 10, color: Colors.black87),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // 手势反馈：拖进度 / 长按倍速 / 调音量
            if (_ready && (_seekHint != null || _lpOn || _volHint || _briHint))
              IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x9E000000),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_lpOn) ...[
                          const UIIcon('speed', size: 16, color: Colors.white),
                          const SizedBox(width: 6),
                          Text(
                            '${_lpRate.toStringAsFixed(1)}x · 左右滑调速 · 松手保持',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                        ] else if (_briHint) ...[
                          const Icon(
                            Icons.brightness_6,
                            size: 16,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '亮度 ${(_bri * 100).round()}%${_briSystem ? '' : ' · 仅本应用'}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                        ] else if (_volHint) ...[
                          UIIcon(
                            _vol <= 0.01 ? 'mute' : 'volume',
                            size: 16,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '音量 ${(_vol * 100).round()}%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                        ] else ...[
                          Text(
                            '${_fmt(_seekHint ?? _vc.value.position)} / ${_fmt(_vc.value.duration)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            // 中央播放键：只在暂停时出现（旧版 #vp.paused .vp-center 才 opacity:1）
            if (_ready && !_locked && !_vc.value.isPlaying)
              Center(
                child: GestureDetector(
                  onTap: () {
                    _vc.play();
                    setState(() {});
                    _scheduleHide();
                  },
                  child: Container(
                    width: 68,
                    height: 68,
                    decoration: const BoxDecoration(
                      color: Color(0x66000000),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x73000000),
                          blurRadius: 18,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 3),
                      child: UIIcon('play', size: 25, color: Colors.white),
                    ),
                  ),
                ),
              ),
            // 上一集 / 下一集（旧版 .vp-prev / .vp-next）
            if (_ready && _controls && _prevEp != null)
              Positioned(
                left: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _NavBtn(
                    icon: 'prev',
                    onTap: () => _switchTo(_prevEp!),
                  ),
                ),
              ),
            if (_ready && _controls && _nextEp != null)
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _NavBtn(
                    icon: 'next',
                    onTap: () => _switchTo(_nextEp!),
                  ),
                ),
              ),
            // 锁屏态：只剩右下角的小锁
            if (_locked)
              Positioned(
                right: 14,
                bottom: 104,
                child: GestureDetector(
                  onTap: () => setState(() => _locked = false),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: Color(0x8010141C),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const UIIcon(
                      'unlock',
                      size: 18,
                      color: Color(0xCCFFFFFF),
                    ),
                  ),
                ),
              ),
            // 手势层：盖在画面之上、控件之下。
            // 控件（顶部栏、底部进度条、按钮）在同一 Stack 里更靠后，
            // 点到它们时指针先被它们吃掉，这里收不到 —— 所以拖进度条不会又拖一遍画面。
            if (_ready && !_locked)
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _gDown,
                  onPointerMove: _gMove,
                  onPointerUp: (e) => _gUp(e),
                  onPointerCancel: (e) => _gUp(e, cancel: true),
                ),
              ),
            if (_ready)
              AnimatedOpacity(
                opacity: _controls && !_locked ? 1 : 0,
                duration: Shape.base,
                child: IgnorePointer(
                  ignoring: !_controls || _locked,
                  child: Column(
                    children: [
                      // 顶栏：旧版 #vp .iv-top（.78 → .42@52% → 透明），padding 8/11/26
                      Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0xC7000000),
                              Color(0x6B000000),
                              Color(0x00000000),
                            ],
                            stops: [0, 0.52, 1],
                          ),
                        ),
                        child: SafeArea(
                          bottom: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(11, 8, 11, 26),
                            child: Row(
                              children: [
                                _VpBtn(
                                  icon: 'close',
                                  small: true,
                                  onTap: () => Navigator.pop(context),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _entry.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13.5,
                                          height: 1.35,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      // 听的状态就一行灰字挂在标题下面：播的时候看
                                      // 「领先/落后几秒」，暂停时看「已预转到哪」
                                      if (_liveStatus.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          _liveStatus,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Color(0xFFB9B9C2),
                                            fontSize: 11,
                                            height: 1.3,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          Text(
                                            '${humanSize(_entry.size)} · ${_entry.ext.toUpperCase()}',
                                            style: const TextStyle(
                                              color: Color(0xFFB9B9C2),
                                              fontSize: 11,
                                            ),
                                          ),
                                          // 杜比转换生效时顶栏直接挂个标，不用翻设置去找
                                          if (_dolby) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 1,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: const Color(0x337B61FF),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                '${_dvLabel} · gpu-next',
                                                style: TextStyle(
                                                  color: Color(0xFFC7B9FF),
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                if (widget.playlist.length > 1)
                                  Container(
                                    margin: const EdgeInsets.only(right: 8),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0x29FFFFFF),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      '${_idx + 1}/${widget.playlist.length}',
                                      style: const TextStyle(
                                        color: Color(0xFFE6E6EA),
                                        fontSize: 12.5,
                                        fontFeatures: [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  ),
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: _VpBtn(
                                    icon: 'subs',
                                    small: true,
                                    active: _subsOn && _subW.isNotEmpty,
                                    onTap: _showSubMenu,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: _VpBtn(
                                    icon: _locked ? 'lock' : 'unlock',
                                    small: true,
                                    active: _locked,
                                    onTap: () =>
                                        setState(() => _locked = !_locked),
                                  ),
                                ),
                                _VpBtn(
                                  icon: 'download',
                                  small: true,
                                  onTap: () => widget.app.downloadEntry(_entry),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      // 底栏：旧版 #vp .iv-bottom（0 → .62@38% → .92），padding 38/14/10
                      Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0x00000000),
                              Color(0x9E000000),
                              Color(0xEB000000),
                            ],
                            stops: [0, 0.38, 1],
                          ),
                        ),
                        child: SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 38, 14, 10),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    SizedBox(
                                      width: 42,
                                      child: Text(
                                        _fmt(
                                          _dragging
                                              ? _dragPos
                                              : _vc.value.position,
                                        ),
                                        style: const TextStyle(
                                          color: Color(0xFFE9E9EE),
                                          fontSize: 11.5,
                                          fontFeatures: [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: _ScrubBar(
                                        position: _vc.value.position,
                                        duration: _vc.value.duration,
                                        buffered: _bufferEnd,
                                        dragging: _dragging,
                                        dragPos: _dragPos,
                                        onDrag: (d) => setState(() {
                                          _dragging = true;
                                          _dragPos = d;
                                        }),
                                        onSeek: (d) {
                                          unawaited(_seekToChecked(d));
                                          setState(() => _dragging = false);
                                          _afterSeek();
                                          _scheduleHide();
                                        },
                                      ),
                                    ),
                                    SizedBox(
                                      width: 42,
                                      child: Text(
                                        _fmt(_vc.value.duration),
                                        textAlign: TextAlign.right,
                                        style: const TextStyle(
                                          color: Color(0xFFB9B9C2),
                                          fontSize: 11.5,
                                          fontFeatures: [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                Row(
                                  children: [
                                    _VpBtn(
                                      icon: 'back10',
                                      iconSize: 22,
                                      onTap: () => _seekRelative(-10),
                                    ),
                                    const SizedBox(width: 8),
                                    _VpBtn(
                                      icon: _vc.value.isPlaying
                                          ? 'pause'
                                          : 'play',
                                      gradient: true,
                                      iconSize: 20,
                                      onTap: () {
                                        _vc.value.isPlaying
                                            ? _vc.pause()
                                            : _vc.play();
                                        setState(() {});
                                        _scheduleHide();
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    _VpBtn(
                                      icon: 'fwd10',
                                      iconSize: 22,
                                      onTap: () => _seekRelative(10),
                                    ),
                                    const Spacer(),
                                    // 入口用齿轮，倍速只是面板里的一项，
                                    // 拿「1.0×」当按钮没人看得出这是设置
                                    _VpBtn(
                                      icon: 'setting',
                                      iconSize: 21,
                                      small: true,
                                      onTap: _showRateMenu,
                                    ),
                                    const SizedBox(width: 8),
                                    _VpBtn(
                                      icon: 'playlist',
                                      small: true,
                                      onTap: _showPlaylist,
                                    ),
                                    const SizedBox(width: 8),
                                    _VpBtn(
                                      icon: 'rotate-screen',
                                      small: true,
                                      onTap: _toggleOrient,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // 续播胶囊放最后一层：上面那些图层（顶栏渐变、字幕、手势层）都会盖住它、
            // 把点击吃掉，所以必须是自己画在最上面，位置也压到顶栏下方。
            if (_jumpTarget != null)
              Positioned(
                top: MediaQuery.of(context).padding.top + 76,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: _tapResume,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xE6101014),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: const Color(0x33FFFFFF)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const AppIcon(
                            'play',
                            color: Color(0xFFFFFFFF),
                            size: 12,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _jumpArmed
                                ? '就绪后自动跳到 ${_mmss(_jumpTarget!)}'
                                : '从 ${_mmss(_jumpTarget!)} 继续',
                            style: const TextStyle(
                              color: Color(0xFFF2F2F5),
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _jumpArmed ? '等待缓冲' : '点此跳转',
                            style: const TextStyle(
                              color: Color(0xFF8FA8C8),
                              fontSize: 11,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
