// 播放引擎：media_kit（libmpv）
//
// 为什么换：原来的 video_player 走 ExoPlayer，只认 H.264/H.265/VP9/AV1 这几样，
// rmvb、wmv、flv、mpeg2、老 DivX/Xvid、DTS 音轨这类一律放不出来。
// libmpv 自带全套解复用 + 解码器，配 hwdec=auto-safe 时优先硬解、
// 硬解不支持的格式自动退回软解，等于「所有视频都能播」。
//
// 下面的门面刻意做成跟 VideoPlayerController 一样的形状（value / play / pause /
// seekTo / setPlaybackSpeed / setVolume / addListener），播放页几乎不用改。

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 播放器对外暴露的状态快照（字段对齐 VideoPlayerValue 里真正用到的那些）
class MKValue {
  const MKValue({
    required this.isInitialized,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.aspectRatio,
    required this.volume,
  });

  final bool isInitialized;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final double aspectRatio;
  final double volume;
}

class MKPlayback {
  MKPlayback.network(this.url, {this.software = false, this.dolby = false}) {
    _player = Player(
      configuration: const PlayerConfiguration(
        // 不走 mpv 自带 OSC，界面全由播放页自己画
        osc: false,
        // 播放中别让系统休眠
        title: '云匣',
        // 网络缓存 64MB：默认值偏小，115 这种远端源会一阵一阵卡
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    _video = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        // 杜比视界必须 gpu-next（libplacebo 里才有 dovi 的 IPT→BT.2020）
        vo: dolby ? 'gpu-next' : null,
        // 硬解 + 回拷 CPU：零拷贝拿不到可转换的帧
        // 必须是软解：MediaCodec 回拷的帧不带 DoVi RPU，libplacebo 拿不到
        // 元数据就无从做 IPT→BT.2020，画面仍旧发绿。ffmpeg 软解才解析 RPU。
        hwdec: dolby ? 'no' : (software ? 'no' : 'auto-safe'),
        enableHardwareAcceleration: dolby ? true : !software,
      ),
    );
    _bind();
  }

  final String url;
  final bool software;

  /// 杜比视界模式：`vo=gpu-next`（libplacebo 的 DoVi RPU 转换）+ 硬解回拷。
  ///
  /// 前提是 libmpv 带 libplacebo —— media_kit 自带那颗是 `-Dlibplacebo=disabled`
  /// 编的（APK 里搜不到 "gpu-next"），已在 android/app/src/main/jniLibs 里
  /// 换成 mpv-android 官方构建（带 libplacebo）。
  /// `mediacodec-copy` 把硬解结果拷回内存，gpu-next 才能对它做 IPT→BT.2020；
  /// 零拷贝的 `mediacodec` 只有 GPU 纹理，转换不了。
  final bool dolby;

  late final Player _player;
  late final VideoController _video;

  final List<VoidCallback> _listeners = [];
  final List<StreamSubscription> _subs = [];

  bool _init = false;
  bool _sized = false;
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  Duration _buf = Duration.zero;
  double _ar = 16 / 9;
  double _vol = 1;
  String? _error;

  MKValue get value => MKValue(
    isInitialized: _init,
    isPlaying: _playing,
    position: _pos,
    duration: _dur,
    aspectRatio: _ar,
    volume: _vol,
  );

  /// 是否已经拿到真实画面尺寸（决定要不要自动转横屏，别用 16:9 的默认值瞎转）
  bool get hasSize => _sized;

  bool get hasError => _error != null;

  // ---- 音轨 ----
  String? _audioId;

  /// 正在播的那条音轨的 mpv id（切轨后 mpv 会自己更新）
  String? get audioId => _audioId;

  /// mpv 认出这是杜比视界片源（gamma/primaries 报 dolbyvision）
  bool get dolbyDetected => _dvSeen;

  /// 最后一次拿到的 video-params 摘要，播放界面的「解码方式」里直接显示，
  /// 用来判断杜比转换到底有没有生效（gamma 不是 dolbyvision 就是没认出来）。
  String dvInfo = '';
  bool _dvSeen = false;
  String? get errorDescription => _error;
  String get engine => dolby
      ? '杜比视界 · libmpv+placebo'
      : (software ? '软解 · libmpv' : '硬解 · libmpv');

  /// 已缓冲到的位置（进度条上的灰白层；mpv 不给区间，用播放位置 + 缓存时长近似）
  Duration get bufferEnd {
    if (_buf > Duration.zero && _buf > _pos)
      return _buf > _dur && _dur > Duration.zero ? _dur : _buf;
    final guess = _pos + const Duration(seconds: 20);
    return _dur > Duration.zero && guess > _dur ? _dur : guess;
  }

  void _bind() {
    _subs.add(
      _player.stream.position.listen((p) {
        _pos = p;
        _notify();
      }),
    );
    _subs.add(
      _player.stream.duration.listen((d) {
        _dur = d;
        _notify();
      }),
    );
    _subs.add(
      _player.stream.tracks.listen((_) {
        _audioId = _player.state.track.audio.id;
        _notify();
      }),
    );
    _subs.add(
      _player.stream.playing.listen((p) {
        _playing = p;
        _notify();
      }),
    );
    _subs.add(
      _player.stream.buffer.listen((b) {
        _buf = b;
        _notify();
      }),
    );
    _subs.add(
      _player.stream.width.listen((w) {
        final h = _player.state.height;
        if (w != null && h != null && w > 0 && h > 0) {
          _ar = w / h;
          _sized = true;
          _notify();
        }
      }),
    );
    _subs.add(
      _player.stream.error.listen((e) {
        _error = e;
        _notify();
      }),
    );
    _subs.add(
      _player.stream.videoParams.listen((p) {
        dvInfo =
            'gamma=${p.gamma ?? '-'} primaries=${p.primaries ?? '-'} '
            'sig=${p.gamma == null ? '-' : (p.sigPeak == null ? '-' : '${p.sigPeak!.round()}')}';
        final g = (p.gamma ?? '').toLowerCase();
        final pr = (p.primaries ?? '').toLowerCase();
        if (g.contains('dolby') || pr.contains('dolby')) {
          if (!_dvSeen) {
            _dvSeen = true;
            _notify();
          }
        }
      }),
    );
  }

  void _notify() {
    for (final l in List<VoidCallback>.of(_listeners)) {
      l();
    }
  }

  void addListener(VoidCallback l) => _listeners.add(l);
  void removeListener(VoidCallback l) => _listeners.remove(l);

  Future<void> initialize() async {
    // 网络源的播放参数：115 是边下边播，默认缓存太小会一阵一阵卡，
    // 片源一断线（clouddrive 抽风）默认直接放弃，这里让它多等一会儿
    // media_kit 没暴露 setProperty，原生播放器的 command 是公开的，
    // 直接发 mpv 的 set 命令（平台不支持时静默跳过）
    final raw = _player.platform;
    final opts = <String, String>{
      'cache': 'yes',
      // 缓存开大一点：听译那条线可能在读同一个 115 文件，网络会一阵一阵紧
      'cache-secs': '60',
      'demuxer-readahead-secs': '20',
      'network-timeout': '60',
      // 缓冲一空就「暂停等数据」是 mpv 的默认脾气，听译一抢带宽画面就自己停住。
      // cache-pause=no 是把这条掐掉：宁可掉几帧，也绝不替用户按暂停。
      'cache-pause': 'no',
      'cache-pause-wait': '0',
      if (dolby) ...{
        'vd-lavc-threads': '8',
        // DV 的 RPU 里带峰值信息，按片子自身亮度映射
        'target-colorspace-hint': 'yes',
        'hdr-compute-peak': 'yes',
        'tone-mapping': 'bt.2446a',
      },
    };
    for (final kv in opts.entries) {
      try {
        await (raw as dynamic).command(<String>['set', kv.key, kv.value]);
      } catch (_) {
        /* 这个 mpv 版本没这个选项，跳过 */
      }
    }
    await _player.open(Media(url), play: false);
    // 字幕由 App 自己的覆盖层绘制，别让 mpv 再画一份
    unawaited(_player.setSubtitleTrack(SubtitleTrack.no()));
    await _player.setVolume(_vol * 100);
    _init = true;
    _notify();
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();

  /// 单击播放/暂停（双击画面用）
  Future<void> playOrPause() => _player.playOrPause();

  Future<void> seekTo(Duration d) => _player.seek(d);

  Future<void> setPlaybackSpeed(double v) => _player.setRate(v);

  Future<void> setVolume(double v) {
    _vol = v.clamp(0.0, 1.0);
    return _player.setVolume(_vol * 100);
  }

  /// 音轨列表（libmpv 才有这个能力，video_player 完全没有）
  List<AudioTrack> get audioTracks => _player.state.tracks.audio;

  Future<void> setAudioTrack(AudioTrack t) => _player.setAudioTrack(t);

  /// 内封字幕轨。图形字幕（PGS / DVD）抽不出文本，只能让 mpv 自己
  /// 画进画面；文本轨仍走 App 的覆盖层（能翻译）。null = 关。
  Future<void> setEmbeddedSub(int? sid) {
    if (sid == null) return _player.setSubtitleTrack(SubtitleTrack.no());
    // 优先用 mpv 自己枚举出来的轨（顺序和 sid 一致），免得编号口径对不上
    final list = _player.state.tracks.subtitle;
    if (sid >= 1 && sid <= list.length) {
      return _player.setSubtitleTrack(list[sid - 1]);
    }
    return _player.setSubtitleTrack(SubtitleTrack('$sid', null, null));
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _listeners.clear();
    await _player.dispose();
  }

  /// 播放页把这个塞进 Stack 里
  Widget render() =>
      Video(controller: _video, controls: NoVideoControls, fit: BoxFit.contain);
}
