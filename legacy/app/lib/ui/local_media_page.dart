import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/native.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';

/// 本机已下载的图片：应用内看，不再跳到系统
class LocalImagePage extends StatefulWidget {
  final String name;
  final String uri;
  final String path;
  const LocalImagePage({
    super.key,
    required this.name,
    required this.uri,
    required this.path,
  });

  @override
  State<LocalImagePage> createState() => _LocalImagePageState();
}

class _LocalImagePageState extends State<LocalImagePage> {
  Uint8List? _bytes;
  String _err = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await Native.readBytes(widget.uri, widget.path);
      if (!mounted) return;
      setState(() => _bytes = b);
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.name,
            style: const TextStyle(fontSize: 14), overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: _err.isNotEmpty
            ? Text('打不开：$_err', style: const TextStyle(color: Colors.white70))
            : (_bytes == null
                ? const CircularProgressIndicator(strokeWidth: 2)
                : InteractiveViewer(
                    minScale: 1,
                    maxScale: 5,
                    child: Image.memory(_bytes!, fit: BoxFit.contain),
                  )),
      ),
    );
  }
}

/// 本机已下载的视频/音频：用 content:// 直接播
class LocalVideoPage extends StatefulWidget {
  final String name;
  final String uri;
  final String path;
  const LocalVideoPage({
    super.key,
    required this.name,
    required this.uri,
    required this.path,
  });

  @override
  State<LocalVideoPage> createState() => _LocalVideoPageState();
}

class _LocalVideoPageState extends State<LocalVideoPage> {
  VideoPlayerController? _vc;
  String _err = '';

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      // content:// 用 contentUri；file:// 和绝对路径必须用 file，
      // 混着用会直接抛「Invalid argument」，表现就是「下载好了但打不开」。
      final VideoPlayerController c;
      if (widget.uri.startsWith('content://')) {
        c = VideoPlayerController.contentUri(Uri.parse(widget.uri));
      } else if (widget.uri.startsWith('file://')) {
        c = VideoPlayerController.file(File(Uri.parse(widget.uri).path));
      } else if (widget.path.isNotEmpty) {
        c = VideoPlayerController.file(File(widget.path));
      } else {
        throw StateError('本地文件地址丢了，重新下一遍');
      }
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _vc = c);
      c.play();
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  @override
  void dispose() {
    _vc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final vc = _vc;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.name,
            style: const TextStyle(fontSize: 14), overflow: TextOverflow.ellipsis),
      ),
      body: _err.isNotEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const UIIcon('video', size: 40, color: Colors.white38),
                    const SizedBox(height: 12),
                    Text('播放器打不开这个文件：$_err',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Native.open(widget.uri, widget.path,
                          Native.mimeOf(widget.name)),
                      child: const Text('用系统播放器试'),
                    ),
                  ],
                ),
              ),
            )
          : (vc == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: vc.value.aspectRatio == 0
                              ? 16 / 9
                              : vc.value.aspectRatio,
                          child: VideoPlayer(vc),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      child: Column(
                        children: [
                          VideoProgressIndicator(vc,
                              allowScrubbing: true,
                              colors: VideoProgressColors(
                                playedColor: tone.ac,
                                bufferedColor: Colors.white24,
                                backgroundColor: Colors.white12,
                              )),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              IconButton(
                                onPressed: () {
                                  if (vc.value.isPlaying) {
                                    vc.pause();
                                  } else {
                                    vc.play();
                                  }
                                  setState(() {});
                                },
                                icon: Icon(
                                  vc.value.isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                '${_t(vc.value.position)} / ${_t(vc.value.duration)}',
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                )),
    );
  }

  String _t(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }
}
