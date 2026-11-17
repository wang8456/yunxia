import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';

/// 图片查看：双指缩放 / 双击放大 / 下滑关闭 / 存到本机。
/// 直连签名直链，不经 API 中转。
class ImageViewerPage extends StatefulWidget {
  final String url;
  final Entry entry;
  final Tone tone;
  final Future<void> Function(Entry) onSave;

  /// 同目录的其它图片（旧版「3 / 12」和左右翻页）
  final List<Entry> gallery;

  /// 取某张图的直链（翻页用）
  final Future<String?> Function(Entry) onLink;

  /// 需要鉴权的图（对话里的 /hermes/api/dl 要 Basic）；
  /// 文件页传的是签名直链，留空即可。
  final Map<String, String>? headers;

  const ImageViewerPage({
    super.key,
    required this.url,
    required this.entry,
    required this.tone,
    required this.onSave,
    this.gallery = const [],
    required this.onLink,
    this.headers,
  });

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage>
    with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _anim;
  Animation<Matrix4>? _tween;
  bool _zoomed = false;
  double _dragY = 0;
  double _dragX = 0;
  bool _chrome = true;

  /// 当前在图库里的位置（横滑和底部拖动条都改它）
  int _i = 0;

  /// 签名地址缓存，滑到下一张不用现取
  final Map<String, String> _cache = {};

  /// 原始指针跟踪：InteractiveViewer 会吃掉 GestureDetector 的拖动，所以用 Listener
  int _ptrs = 0;
  double _px = 0;
  double _py = 0;

  double get _scale => _transform.value.getMaxScaleOnAxis();

  late Entry _e;
  late String _u;

  int get _idx => widget.gallery.isEmpty ? 0 : _i;

  Entry? get _prevImg {
    final i = _idx;
    return i > 0 ? widget.gallery[i - 1] : null;
  }

  Entry? get _nextImg {
    final i = _idx;
    return (i >= 0 && i < widget.gallery.length - 1)
        ? widget.gallery[i + 1]
        : null;
  }

  Future<void> _switchTo(Entry e) async {
    final i = widget.gallery.indexWhere((x) => x.path == e.path);
    if (i >= 0) await _goto(i);
  }

  /// 切到第 i 张（旧版 show(k)：左右滑、底部拖动条、两侧箭头都走这里）
  Future<void> _goto(int i) async {
    if (i < 0 || i >= widget.gallery.length) return;
    if (i == _i && _u.isNotEmpty) return;
    final e = widget.gallery[i];
    var url = _cache[e.path];
    if (url == null) {
      url = await widget.onLink(e);
      if (url == null || !mounted) return;
      _cache[e.path] = url;
    }
    _anim.value = 0;
    _transform.value = Matrix4.identity();
    setState(() {
      _i = i;
      _e = e;
      _u = url!;
      _zoomed = false;
      _dragX = 0;
    });
    _prefetch();
  }

  /// 预取前后两张的地址，滑过去不转圈
  Future<void> _prefetch() async {
    for (final d in const [-1, 1, 2, -2]) {
      final i = _i + d;
      if (i < 0 || i >= widget.gallery.length) continue;
      final e = widget.gallery[i];
      if (_cache.containsKey(e.path)) continue;
      final u = await widget.onLink(e);
      if (u != null) _cache[e.path] = u;
    }
  }

  @override
  void initState() {
    super.initState();
    _e = widget.entry;
    _u = widget.url;
    _cache[widget.entry.path] = widget.url;
    final k = widget.gallery.indexWhere((x) => x.path == widget.entry.path);
    _i = k < 0 ? 0 : k;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetch();
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _anim = AnimationController(vsync: this, duration: Shape.base)
      ..addListener(() {
        if (_tween != null) _transform.value = _tween!.value;
      });
    _transform.addListener(() {
      final zoomed = _transform.value.getMaxScaleOnAxis() > 1.02;
      if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _transform.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// 松手时判断：横 > 45 切图；竖 > 110 关闭（旧版 iv-stage touchend 的阈值）
  void _endGesture() {
    if (_ptrs > 0) return;
    final dx = _dragX;
    final dy = _dragY;
    setState(() {
      _dragX = 0;
      _dragY = 0;
    });
    if (_zoomed) return;
    if (dy.abs() > 110 && dx.abs() < 80) {
      Navigator.pop(context);
      return;
    }
    if (dx.abs() > 45 && dy.abs() < 70) {
      _goto(dx < 0 ? _i + 1 : _i - 1);
    }
  }

  void _toggleZoom(TapDownDetails d) {
    final target = _zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(
              -d.localPosition.dx * 1.6,
              -d.localPosition.dy * 1.6,
              0,
              1,
            )
            ..scaleByDouble(2.5, 2.5, 1, 1));
    _tween = Matrix4Tween(
      begin: _transform.value,
      end: target,
    ).animate(CurvedAnimation(parent: _anim, curve: Shape.curve));
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Listener(
            onPointerDown: (ev) {
              _ptrs++;
              if (_ptrs == 1) {
                _px = ev.position.dx;
                _py = ev.position.dy;
              }
            },
            onPointerMove: (ev) {
              if (_zoomed || _ptrs != 1) return;
              final dx = ev.position.dx - _px;
              final dy = ev.position.dy - _py;
              // 轴锁定：横向优先切图，竖向优先关窗，别斜着两个都动
              if (dx.abs() > dy.abs() * 1.2) {
                setState(() => _dragX = dx);
              } else if (dy.abs() > dx.abs() * 1.2) {
                setState(() => _dragY = dy);
              }
            },
            onPointerUp: (ev) {
              _ptrs = _ptrs > 0 ? _ptrs - 1 : 0;
              _endGesture();
            },
            onPointerCancel: (ev) {
              _ptrs = _ptrs > 0 ? _ptrs - 1 : 0;
              if (_ptrs == 0) {
                setState(() {
                  _dragX = 0;
                  _dragY = 0;
                });
              }
            },
            child: GestureDetector(
              onTap: () => setState(() => _chrome = !_chrome),
              onDoubleTapDown: _toggleZoom,
              onDoubleTap: () {},
              child: AnimatedContainer(
                duration: _dragY == 0 ? Shape.base : Duration.zero,
                curve: Shape.curve,
                transform: Matrix4.translationValues(_dragX, _dragY, 0),
                child: InteractiveViewer(
                  transformationController: _transform,
                  minScale: 1,
                  maxScale: 5,
                  child: Center(
                    child: Image.network(
                      _u,
                      headers: widget.headers,
                      fit: BoxFit.contain,
                      loadingBuilder: (ctx, child, progress) {
                        if (progress == null) return child;
                        final pct = progress.expectedTotalBytes != null
                            ? progress.cumulativeBytesLoaded /
                                  progress.expectedTotalBytes!
                            : null;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 26,
                              height: 26,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white54,
                                value: pct,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              pct == null
                                  ? '加载中'
                                  : '${(pct * 100).toStringAsFixed(0)}%',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        );
                      },
                      errorBuilder: (ctx, e, st) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.broken_image_rounded,
                            color: Colors.white38,
                            size: 42,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '图片加载失败',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 顶栏：黑色渐变压顶，左返回、中间文件名、右下载（旧版 .iv-top / .iv-btn）
          AnimatedOpacity(
            opacity: _chrome ? 1 : 0,
            duration: Shape.base,
            child: IgnorePointer(
              ignoring: !_chrome,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xCC000000),
                      Color(0x6B000000),
                      Color(0x00000000),
                    ],
                    stops: [0, 0.6, 1],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(11, 9, 11, 14),
                    child: Row(
                      children: [
                        _IvBtn(
                          icon: 'arrow-left',
                          onTap: () => Navigator.pop(context),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _e.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                              height: 1.4,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (widget.gallery.length > 1) ...[
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
                              '${_idx + 1}/${widget.gallery.length}',
                              style: const TextStyle(
                                color: Color(0xFFE6E6EA),
                                fontSize: 12.5,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ],
                        _IvBtn(
                          icon: 'download',
                          onTap: () => widget.onSave(_e),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 左右翻页（旧版 .iv-nav，放大时隐藏）
          if (_chrome && !_zoomed && _prevImg != null)
            Positioned(
              left: 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: _IvNav(icon: 'prev', onTap: () => _switchTo(_prevImg!)),
              ),
            ),
          if (_chrome && !_zoomed && _nextImg != null)
            Positioned(
              right: 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: _IvNav(icon: 'next', onTap: () => _switchTo(_nextImg!)),
              ),
            ),
          // 底栏：文件大小 + 缩放滑杆 + 操作提示（旧版 .iv-bottom / .iv-range）
          AnimatedPositioned(
            duration: Shape.base,
            curve: Shape.curve,
            left: 0,
            right: 0,
            bottom: _chrome ? 0 : -140,
            child: IgnorePointer(
              ignoring: !_chrome,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xB3000000)],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            if (_e.size > 0)
                              Text(
                                humanSize(_e.size),
                                style: const TextStyle(
                                  color: Color(0xFFCFCFD4),
                                  fontSize: 12,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              )
                            else
                              const SizedBox.shrink(),
                            const Spacer(),
                            Text(
                              _zoomed
                                  ? '${(_scale * 100).round()}% · 双击还原 · 下滑关闭'
                                  : (widget.gallery.length > 1
                                        ? '左右滑动切图 · 双击放大'
                                        : '双击放大 · 下滑关闭'),
                              style: const TextStyle(
                                color: Color(0xFFCFCFD4),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 9),
                        if (widget.gallery.length > 1)
                          SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 4,
                              activeTrackColor: Colors.white,
                              inactiveTrackColor: const Color(0x47FFFFFF),
                              thumbColor: Colors.white,
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 15,
                              ),
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 11,
                              ),
                              trackShape: const RoundedRectSliderTrackShape(),
                            ),
                            child: Slider(
                              // 旧版 .iv-range：这条是切图的，不是缩放
                              value: _i.toDouble(),
                              min: 0,
                              max: (widget.gallery.length - 1).toDouble(),
                              divisions: widget.gallery.length - 1,
                              onChanged: (v) => _goto(v.round()),
                            ),
                          )
                        else
                          const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 旧版 .iv-btn：42×42、圆角 13、白色 14% 底
class _IvBtn extends StatelessWidget {
  final String icon;
  final VoidCallback onTap;
  const _IvBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: const Color(0x24FFFFFF),
          borderRadius: BorderRadius.circular(13),
        ),
        alignment: Alignment.center,
        child: UIIcon(icon, size: 19, color: Colors.white),
      ),
    );
  }
}

/// 左右翻页圆钮（旧版 .iv-nav：46 圆、白 13% 底）
class _IvNav extends StatelessWidget {
  final String icon;
  final VoidCallback onTap;
  const _IvNav({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: const BoxDecoration(
          color: Color(0x21FFFFFF),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: UIIcon(icon, size: 24, color: Colors.white),
      ),
    );
  }
}
