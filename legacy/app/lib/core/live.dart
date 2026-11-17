import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// WebSocket 实时通道：连上收 hello → 断线用 since 补发，25s 心跳。
/// 只用 dart:io，不引第三方包。
class LiveSocket {
  final String server;
  final String Function() tokenOf;

  WebSocket? _ws;
  int _seq = 0;
  int _retry = 0;
  bool _closed = false;
  Timer? _pinger;

  final _events = StreamController<FsEvent>.broadcast();
  final _state = StreamController<LiveState>.broadcast();

  LiveSocket({required this.server, required this.tokenOf});

  Stream<FsEvent> get events => _events.stream;
  Stream<LiveState> get state => _state.stream;
  int get seq => _seq;

  String get _wsUrl {
    final s = server.endsWith('/') ? server.substring(0, server.length - 1) : server;
    final u = Uri.parse(s.replaceFirst(RegExp(r'^http'), 'ws'));
    return u.replace(
      path: '/ws',
      queryParameters: {'t': tokenOf(), 'since': '$_seq'},
    ).toString();
  }

  Future<void> connect() async {
    if (_closed) return;
    _retry++;
    _state.add(LiveState.connecting);
    try {
      final ws = await WebSocket.connect(_wsUrl)
          .timeout(const Duration(seconds: 10));
      _ws = ws;
      _retry = 0;
      _state.add(LiveState.open);
      ws.listen(
        (data) {
          try {
            final j = jsonDecode(data as String) as Map<String, dynamic>;
            final type = j['type'] as String? ?? '';
            if (type == 'hello') {
              final s = (j['seq'] as num?)?.toInt() ?? 0;
              if (s > _seq) _seq = s;
              return;
            }
            if (type == 'ping') {
              ws.add('pong');
              return;
            }
            if (type == 'fs.changed') {
              final ev = FsEvent.fromJson(j);
              if (ev.seq > _seq) _seq = ev.seq;
              _events.add(ev);
            }
          } catch (_) {}
        },
        onDone: _reconnect,
        onError: (_) => _reconnect(),
        cancelOnError: true,
      );
      _pinger?.cancel();
      _pinger = Timer.periodic(const Duration(seconds: 20), (_) {
        if (_ws?.readyState == WebSocket.open) _ws!.add('ping');
      });
    } catch (_) {
      _reconnect();
    }
  }

  void _reconnect() {
    _pinger?.cancel();
    _ws = null;
    if (_closed) return;
    _state.add(LiveState.closed);
    final delay = Duration(seconds: (1 << (_retry.clamp(0, 5))).clamp(1, 30));
    Timer(delay, connect);
  }

  void close() {
    _closed = true;
    _pinger?.cancel();
    _ws?.close();
    _events.close();
    _state.close();
  }
}

enum LiveState { connecting, open, closed }
