import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/native.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';
import 'image_viewer_page.dart';
import 'kit.dart';
import 'markdown_lite.dart';
import 'widgets.dart';

/// 对话页 —— 与旧版前端同一个后端：`/hermes/api/chat`（Basic hermes:口令，SSE 流式）。
/// 口令只存这台设备，第一次进来要输一次。
class ChatPage extends StatefulWidget {
  final App app;
  const ChatPage({super.key, required this.app});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _dayLabel(DateTime d) {
  final n = DateTime.now();
  if (_sameDay(d, n)) return '今天';
  if (_sameDay(d, n.subtract(const Duration(days: 1)))) return '昨天';
  return '${d.year}/${d.month}/${d.day}';
}

String _hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// 一次工具调用（旧前端的 step）：名字 + 关键参数 + 运行状态 + 输出
class _Step {
  final String name;
  final String call;
  String arg;
  bool run = true;
  String out = '';
  bool bad = false;
  double? dur;
  final DateTime t0;
  _Step({required this.name, this.call = '', this.arg = '', DateTime? t0})
    : t0 = t0 ?? DateTime.now();
}

/// 参数太长只留一行给人看（和旧前端 shortArg 同规则）
/// 公开是为了能在 test/chat_steps_test.dart 里用真实 SSE 载荷验证
String chatShortArg(Object? raw) {
  Object? o = raw;
  if (raw is String) {
    try {
      o = jsonDecode(raw);
    } catch (_) {
      o = null;
    }
  }
  var v = '';
  if (o is Map) {
    const keys = [
      'command',
      'file_path',
      'path',
      'query',
      'pattern',
      'url',
      'goal',
      'prompt',
      'description',
      'skill',
      'name',
      'text',
      'code',
      'reason',
    ];
    for (final k in keys) {
      final x = o[k];
      if (x is String && x.isNotEmpty) {
        v = x;
        break;
      }
    }
    if (v.isEmpty) {
      for (final x in o.values) {
        if (x is String && x.isNotEmpty) {
          v = x;
          break;
        }
      }
    }
  }
  if (v.isEmpty && raw is String) v = raw;
  v = v.replaceAll(RegExp(r'\s+'), ' ').trim();
  return v.length > 140 ? '${v.substring(0, 140)}…' : v;
}

/// 工具输出：剥掉 JSON 壳，非 0 退出码算失败
({String text, bool bad}) chatStepOutput(Map it) {
  var raw = it['output'];
  if (raw is List) {
    raw = raw
        .map((p) => p is Map ? (p['text'] ?? p['content'] ?? '') : '')
        .join('\n');
  } else if (raw is Map) {
    raw = raw['text'] ?? jsonEncode(raw);
  }
  var s = '${raw ?? ''}';
  var bad = false;
  try {
    final o = jsonDecode(s);
    if (o is Map) {
      final code = o['exit_code'];
      var txt =
          o['output'] ??
          o['stdout'] ??
          o['text'] ??
          o['result'] ??
          o['message'] ??
          '';
      if ('$txt'.isEmpty && o['error'] != null) {
        txt = o['error'] is String ? o['error'] : jsonEncode(o['error']);
        bad = true;
      }
      if (txt is! String) txt = jsonEncode(txt);
      if ('$txt'.isNotEmpty) s = '$txt';
      if (code is num && code != 0) bad = true;
      if (o['error'] != null && code == null) bad = true;
    }
  } catch (_) {}
  s = s.replaceAll('\r', '').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  if (s.length > 1600) s = '${s.substring(0, 1600)}…';
  return (text: s, bad: bad);
}

class _Msg {
  /// 全局 id：用户消息本地生成，assistant 用服务端给的 run id
  String id;

  /// 服务端托管状态：running / done / failed / stopped / interrupted
  String status;

  String text;

  /// 思考增量（reasoning_summary_text.delta）：旧版前端是能展开的思考卡片
  String think;
  final bool mine;
  bool streaming;
  final DateTime t0;
  Duration? took;
  DateTime ts;
  final steps = <_Step>[];

  _Msg(
    this.text, {
    this.mine = true,
    this.streaming = false,
    String? id,
    this.status = 'done',
    DateTime? t0,
    DateTime? ts,
  }) : id = id ?? 'l${DateTime.now().microsecondsSinceEpoch}${_randId()}',
       think = '',
       t0 = t0 ?? DateTime.now(),
       ts = ts ?? DateTime.now();

  static String _randId() =>
      (DateTime.now().microsecond + (identityHashCode(_Msg) & 0xfff)).toRadixString(36);
}

/// 长按菜单的一行（图标 + 文字）
class _MenuRow extends StatelessWidget {
  final String icon;
  final String label;
  final bool danger;
  final VoidCallback onTap;
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final c = danger ? const Color(0xFFE5484D) : tone.ink;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 13, 18, 13),
        child: Row(
          children: [
            UIIcon(icon, size: 18, color: c),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(fontSize: 14, color: c)),
          ],
        ),
      ),
    );
  }
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final _ctl = TextEditingController();
  final _list = <_Msg>[];
  final _scroll = ScrollController();
  String? _prevId;
  bool _sending = false;

  /// 已上传到服务端的附件（path 要拼进消息正文，模型才看得见）
  final _attach = <Map<String, String>>[];
  /// 当前这一轮的 response id：打断时要拿它去 /hermes/api/cancel
  String _respId = '';
  /// 轮次号：打断后旧的 SSE 还会回调 onRunId，不能用它污染新一轮的 _respId
  int _epoch = 0;
  bool _uploading = false;
  StreamSubscription<Map<String, dynamic>>? _sub;

  /// 有步骤在跑时每秒重绘一次，让「运行中 Ns」真的跳
  Timer? _tick;

  App get app => widget.app;

  bool _lastLocked = false;

  /// 服务端那本对话账的游标（/hermes/api/log）
  int _cursor = 0;
  Timer? _syncTimer;
  bool _syncing = false;

  /// 上次把对话写盘的时间（流式回复时按 3 秒节流，别每来一个字都写文件）
  DateTime _savedAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    // 上次聊到哪儿接着聊：记录存在本机 session 里
    final log = app.session.chatLog;
    for (final e in log) {
      final m = _Msg(
        e['text'] as String? ?? '',
        mine: e['mine'] as bool? ?? false,
        id: e['id'] as String?,
        status: e['st'] as String? ?? 'done',
        ts: DateTime.fromMillisecondsSinceEpoch(
          ((e['t'] as num?)?.toInt() ?? 0) * 1000,
        ),
      )..think = e['think'] as String? ?? '';
      for (final x in ((e['steps'] as List?) ?? const []).whereType<Map>()) {
        m.steps.add(
          _Step(name: '${x['name'] ?? x['n'] ?? 'tool'}', arg: '${x['arg'] ?? x['a'] ?? ''}')
            ..out = '${x['out'] ?? x['o'] ?? ''}'
            ..bad = (x['bad'] ?? x['b']) == true
            ..run = false
            ..dur = ((x['dur'] ?? x['d']) as num?)?.toDouble(),
        );
      }
      _list.add(m);
    }
    _lastLocked = _isLocked;
    WidgetsBinding.instance.addObserver(this);
    app.addListener(_onApp);
    // 服务端是账本：进来先对一次全量，之后每 2.5 秒拉增量。
    // 别的设备发起的回复（或者你切后台期间跑完的那一轮）就这样同步过来。
    unawaited(_pullOps(full: true));
    _syncTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (mounted && !app.booting) unawaited(_pullOps());
    });
    if (app.session.chatBasic.isNotEmpty && _list.isNotEmpty) {
      // 上下文在服务端，重启后不一定还在；chatStream 会自己兜底重开
    }
  }


  // ---------- 与服务端的对话账同步 ----------

  Future<void> _pullOps({bool full = false}) async {
    final basic = app.session.chatBasic;
    if (basic.isEmpty || _syncing) return;
    _syncing = true;
    try {
      final j = await app.api.logSince(full ? 0 : _cursor, basic: basic);
      final ops = (j['ops'] as List?) ?? const [];
      if (ops.isNotEmpty && _applyOps(ops)) {
        _saveLog();
        if (mounted) setState(() {});
      }
      final c = (j['cursor'] as num?)?.toInt();
      if (c != null) _cursor = c;
    } catch (_) {
      // 断网就等下一轮，不弹提示（后台同步失败是常态）
    } finally {
      _syncing = false;
    }
  }

  /// 把服务端的 op 合并进来。返回 true 表示画面要刷新。
  bool _applyOps(List ops) {
    var touched = false;
    for (final raw in ops) {
      if (raw is! Map) continue;
      final kind = '${raw['kind'] ?? ''}';
      if (kind == 'clear') {
        if (_list.isNotEmpty) {
          _list.clear();
          touched = true;
        }
        continue;
      }
      if (kind == 'del') {
        final id = '${raw['id'] ?? ''}';
        final n = _list.length;
        _list.removeWhere((m) => m.id == id);
        if (_list.length != n) touched = true;
        continue;
      }
      if (kind != 'add' && kind != 'upd') continue;
      final m = raw['msg'];
      if (m is! Map) continue;
      final id = '${m['id'] ?? ''}';
      if (id.isEmpty) continue;
      final text = '${m['text'] ?? ''}';
      final think = '${m['think'] ?? ''}';
      final status = '${m['status'] ?? 'done'}';
      final tsSec = (m['ts'] as num?)?.toInt() ?? 0;
      final ts = DateTime.fromMillisecondsSinceEpoch(tsSec * 1000);
      final cur = _list.where((x) => x.id == id).firstOrNull;
      if (cur != null) {
        if (cur.text != text || cur.think != think || cur.status != status) {
          // 本机流式比服务端快半拍，服务端快照可能更短，别回退
          if (cur.streaming && text.length < cur.text.length) {
            cur.status = status;
            touched = true;
            continue;
          }
          cur.text = text;
          cur.think = think;
          cur.status = status;
          // 服务端说完成了，就不用再显示「更新中」的转圈
          if (status != 'running') cur.streaming = false;
          touched = true;
        }
        continue;
      }
      final isMine = '${m['role'] ?? ''}' == 'user';
      final twin = _list.where((x) {
        if (x.mine != isMine || x.text != text) return false;
        return x.ts.difference(ts).inSeconds.abs() <= 2;
      }).firstOrNull;
      if (twin != null && twin.id.startsWith('l')) {
        twin.id = id;
        twin.status = status;
        touched = true;
        continue;
      }
      final mm = _Msg(
        text,
        mine: isMine,
        id: id,
        status: status,
        ts: ts,
      )..think = think;
      for (final x in ((m['steps'] as List?) ?? const []).whereType<Map>()) {
        mm.steps.add(
          _Step(name: '${x['name'] ?? x['n'] ?? 'tool'}', arg: '${x['arg'] ?? x['a'] ?? ''}')
            ..out = '${x['out'] ?? x['o'] ?? ''}'
            ..bad = (x['bad'] ?? x['b']) == true
            ..run = false
            ..dur = ((x['dur'] ?? x['d']) as num?)?.toDouble(),
        );
      }
      _list.add(mm);
      touched = true;
    }
    if (touched) _list.sort((a, b) => a.ts.compareTo(b.ts));
    return touched;
  }

  /// 用户发的那句推给服务端：别的设备（网页 / 另一台手机）才看得到
  Future<void> _pushMine(_Msg m) async {
    final basic = app.session.chatBasic;
    if (basic.isEmpty) return;
    try {
      await app.api.logPush(
        [
          {
            'id': m.id,
            'ts': m.ts.millisecondsSinceEpoch ~/ 1000,
            'role': 'user',
            'text': m.text,
          },
        ],
        basic: basic,
        since: _cursor,
      );
    } catch (_) {}
  }

  void _saveLog() {
    _savedAt = DateTime.now();
    final keep = _list.length > 60 ? _list.sublist(_list.length - 60) : _list;
    // 只存有内容的气泡：刚发出去还没回的那条空回复不该占位，
    // 否则重启后会看到一条空气泡。
    final rows = keep
        .where(
          (m) =>
              m.text.trim().isNotEmpty ||
              m.think.trim().isNotEmpty ||
              m.steps.isNotEmpty,
        )
        .map(
          (m) => {
            'id': m.id,
            'st': m.status,
            't': m.ts.millisecondsSinceEpoch ~/ 1000,
            'mine': m.mine,
            'text': m.text.length > 4000 ? m.text.substring(0, 4000) : m.text,
            if (m.think.isNotEmpty)
              'think': m.think.length > 2000
                  ? m.think.substring(m.think.length - 2000)
                  : m.think,
            if (m.steps.isNotEmpty)
              'steps': m.steps
                  .map(
                    (x) => {
                      'n': x.name,
                      'a': x.arg,
                      'o': x.out.length > 1200
                          ? x.out.substring(0, 1200)
                          : x.out,
                      'b': x.bad,
                      'd': x.dur,
                    },
                  )
                  .toList(),
          },
        )
        .toList();
    app.session.chatLog = rows;
    app.session.save();
  }

  Future<void> _clear() async {
    final ok = await showConfirmSheet(
      context,
      title: '清空对话？',
      text: '只清这台设备上的记录，服务端上下文也会随之下次重开。',
      danger: true,
      okText: '清空',
    );
    if (ok != true) return;
    _sub?.cancel();
    setState(() {
      _list.clear();
      _prevId = null;
      _sending = false;
    });
    _saveLog();
  }

  /// 对话可用 = 有写权限 且 有对话口令；两个任何一个掉了都按「没填」处理
  bool get _isLocked => !app.canWrite || app.session.chatBasic.isEmpty;

  /// 口令是在「设置」里填的，本页常驻在 IndexedStack 里不会自己重建
  void _onApp() {
    if (!mounted) return;
    final locked = _isLocked;
    if (locked != _lastLocked) {
      _lastLocked = locked;
      setState(() {});
    }
  }

  /// 切后台/息屏时立刻落盘：安卓在这种情况下可能直接把进程收掉，
  /// 只在回复结束时保存的话，正在聊的这一轮会整段丢。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _saveLog();
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    app.removeListener(_onApp);
    _tick?.cancel();
    _sub?.cancel();
    _ctl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  /// 选附件 → 上传到「云匣文件/<今天>/」→ 记下来等发送
  /// TG 那样长按出菜单：复制 / 重发（仅自己）/ 删除
  Future<void> _msgMenu(int i) async {
    final m = _list[i];
    final tone = Theme.of(context).extension<Tone>()!;
    final act = await showSheet<String>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (m.text.trim().isNotEmpty)
            _MenuRow(
              icon: 'copy',
              label: '复制',
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
          if (m.mine)
            _MenuRow(
              icon: 'send',
              label: '重新发送',
              onTap: () => Navigator.pop(ctx, 'resend'),
            ),
          _MenuRow(
            icon: 'trash',
            label: '删除',
            danger: true,
            onTap: () => Navigator.pop(ctx, 'del'),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 18, right: 18, bottom: 4),
            child: Text(
              _hhmm(m.ts),
              style: TextStyle(fontSize: 11, color: tone.ink3),
            ),
          ),
        ],
      ),
    );
    if (act == null || !mounted) return;
    switch (act) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        if (mounted) app.toast('已复制');
      case 'resend':
        _ctl.text = m.text;
        await _send();
      case 'del':
        setState(() => _list.removeAt(i));
        _saveLog();
    }
  }

  Future<void> _pickAttach() async {
    if (_uploading) return;
    if (app.session.chatBasic.isEmpty) {
      app.toast('先填对话口令');
      return;
    }
    List<File> picked;
    try {
      picked = await Native.pickFiles();
    } catch (e) {
      app.toast('打不开选择器：$e');
      return;
    }
    if (picked.isEmpty) return;
    final room = 6 - _attach.length;
    if (room <= 0) {
      app.toast('一条消息最多带 6 个附件');
      return;
    }
    await _uploadInto(picked, room);
  }

  /// 从剪贴板粘贴：截图 / 文件管理器复制出来的文件，直接变成附件。
  /// Android 的输入框没法像桌面那样粘图片，这里是等价入口（同一个上传通路）。
  Future<void> _pasteAttach() async {
    if (_uploading) return;
    if (app.session.chatBasic.isEmpty) {
      app.toast('先填对话口令');
      return;
    }
    List<Map<String, String>> got;
    try {
      got = await Native.clipboardFiles();
    } catch (e) {
      app.toast('剪贴板里没有图片或文件');
      return;
    }
    if (got.isEmpty) {
      app.toast('剪贴板里没有图片或文件');
      return;
    }
    final room = 6 - _attach.length;
    if (room <= 0) {
      app.toast('一条消息最多带 6 个附件');
      return;
    }
    await _uploadInto(
      got.map((m) => File(m['path']!)).toList(),
      room,
      names: got.map((m) => m['name'] ?? '').toList(),
    );
  }

  /// 选中的文件 / 粘贴的文件：先占位进列表（st=up），再逐个上传
  /// st: up（上传中）/ ok（可用）/ err（失败，可点重试）
  Future<void> _uploadInto(
    List<File> files,
    int room, {
    List<String>? names,
  }) async {
    for (var i = 0; i < files.length && i < room; i++) {
      final f = files[i];
      final fallback = f.uri.pathSegments.last;
      final name = (names != null && i < names.length && names[i].isNotEmpty)
          ? names[i]
          : fallback;
      final asName = name.isNotEmpty ? name : fallback;
      try {
        final size = await f.length();
        if (size > 30 * 1024 * 1024) {
          app.toast('$asName 超过 30MB，先到「文件」里上传');
          continue;
        }
      } catch (_) {
        app.toast('$asName 读不出来');
        continue;
      }
      final item = <String, String>{
        'name': asName,
        'path': '',
        'local': f.path,
        'st': 'up',
        'pct': '0',
      };
      setState(() => _attach.add(item));
      await _uploadOne(item);
    }
  }

  /// 真正上传一个附件（失败留在列表里，点一下重试，不用重选文件）
  Future<void> _uploadOne(Map<String, String> item) async {
    final asName = item['name'] ?? '';
    final local = item['local'] ?? '';
    if (local.isEmpty) return;
    setState(() {
      item['st'] = 'up';
      item['pct'] = '0';
      _uploading = true;
    });
    try {
      final isImg = _imgExt.contains(asName.split('.').last.toLowerCase());
      final path = await app.api.chatUpload(
        File(local),
        basic: app.session.chatBasic,
        kind: isImg ? 'image' : 'file',
        name: asName,
        onProgress: (p) {
          if (!mounted) return;
          final pct = (p * 100).clamp(0, 100).round().toString();
          if (item['pct'] == pct) return;
          setState(() => item['pct'] = pct);
        },
      );
      if (path == null || path.isEmpty) throw '没拿到路径';
      if (!mounted) return;
      setState(() {
        item['path'] = path;
        item['st'] = 'ok';
        item['pct'] = '100';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        item['st'] = 'err';
        item['pct'] = '0';
      });
      app.toast('$asName 上传失败：$e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// 服务端说口令不对：只把对话口令作废，让页面回到「去设置填一次」，不动头像/写权限
  Future<void> _authFailed() async {
    app.session.chatBasic = '';
    await app.session.save();
    if (mounted) setState(() {});
  }

  /// 掐断当前这一轮：像 TG 一样，发新消息就是打断上一轮。
  Future<void> _interrupt() async {
    final rid = _respId;
    _sub?.cancel();
    _sub = null;
    _tick?.cancel();
    _tick = null;
    if (rid.isNotEmpty && app.session.chatBasic.isNotEmpty) {
      unawaited(
        app.api
            .chatCancel(rid, basic: app.session.chatBasic)
            .catchError((_) {}),
      );
    }
    // 提示语和 WSL 终端一字不差（agent/i18n: cli.chat.new_message_interrupting）
    app.toast('⚡ 检测到新消息，正在中断...');
    // 被打断的那条留在原地，状态改成「已中断」
    for (var i = _list.length - 1; i >= 0; i--) {
      final m = _list[i];
      if (m.mine) continue;
      if (m.streaming || m.status == 'running') {
        m.streaming = false;
        m.status = 'interrupted';
        if (m.text.trim().isEmpty) m.text = '（已中断）';
        for (final st in m.steps) {
          st.run = false;
        }
        break;
      }
    }
    _respId = '';
    if (mounted) setState(() => _sending = false);
    _saveLog();
  }

  Future<void> _send() async {
    final typed = _ctl.text.trim();
    if (typed.isEmpty && _attach.isEmpty) return;
    if (_attach.any((a) => (a['st'] ?? 'ok') == 'up')) {
      app.toast('还有附件在上传，稍等一下');
      return;
    }
    if (_attach.any((a) => (a['st'] ?? 'ok') == 'err')) {
      app.toast('有附件没传上去，点它重试，或先删掉');
      return;
    }
    // 上一轮还在跑：不拦着用户，先打断再发（以前这里直接 return，
    // 表现就是「回答中发不出去 / 只能点停止」）
    if (_sending) await _interrupt();
    _ctl.clear();

    // 附件：正文里只放「📎 名字」给人看，真正发给模型的是绝对路径
    final paths = _attach
        .map((a) => a['path'] ?? '')
        .where((p) => p.isNotEmpty)
        .toList();
    final names = _attach.map((a) => a['name'] ?? '').toList();
    var text = typed;
    if (names.isNotEmpty) {
      final line = names.map((n) => '📎 $n').join('\n');
      text = text.isEmpty ? line : '$text\n$line';
    }
    final payload = paths.isEmpty
        ? text
        : (typed.isEmpty ? '' : '$typed\n\n') + '【附件】\n${paths.join('\n')}';
    _attach.clear();

    final mine = _Msg(text);
    final bot = _Msg('', mine: false, streaming: true);
    setState(() {
      _list
        ..add(mine)
        ..add(bot);
      _sending = true;
    });
    _toBottom();
    _saveLog(); // 先把「我发的这句」写盘，进程被杀也不会整段消失
    unawaited(_pushMine(mine)); // 推到服务端账本，别的端才看得到
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_list.any((m) => m.steps.any((s) => s.run))) setState(() {});
    });

    final ctl = StreamController<Map<String, dynamic>>();
    final epoch = ++_epoch; // 这一轮的身份，旧的流再回调也认不到
    _sub = app.api
        .chatStream(
          text: payload,
          basic: app.session.chatBasic,
          prevId: _prevId,
          // 服务端托管这一轮：用它的 run id 当这条回复的全局 id
          onRunId: (rid) {
            if (epoch != _epoch) return; // 上一轮迟到的回调，丢掉
            _respId = rid;
            if (!mounted || bot.id == rid) return;
            bot.id = rid;
            bot.status = 'running';
            setState(() {});
          },
        )
        .listen(
          (ev) {
            final type = ev['type'] as String? ?? '';
            if (type == 'response.reasoning_summary_text.delta' ||
                type == 'response.reasoning_text.delta') {
              // 思考文字：旧版前端边流边显示，用户至少知道模型在动
              final d = ev['delta'] as String? ?? '';
              if (d.isNotEmpty) {
                bot.think += d;
                if (bot.think.length > 40000) {
                  bot.think = bot.think.substring(bot.think.length - 40000);
                }
                if (mounted) setState(() {});
                _toBottom();
              }
            } else if (type == 'response.output_item.added' ||
                type == 'response.output_item.done') {
              // 终端过程：工具调用/结果都在这里投影出来
              final it = ev['item'];
              if (it is Map) {
                final call = it['call_id'] as String? ?? '';
                _Step? find() {
                  for (var i = bot.steps.length - 1; i >= 0; i--) {
                    if (call.isNotEmpty
                        ? bot.steps[i].call == call
                        : bot.steps[i].run) {
                      return bot.steps[i];
                    }
                  }
                  return null;
                }

                if (it['type'] == 'function_call') {
                  final st = find();
                  if (st == null) {
                    bot.steps.add(
                      _Step(
                        name: (it['name'] as String?) ?? 'tool',
                        call: call,
                        arg: chatShortArg(it['arguments']),
                      ),
                    );
                  } else if (st.arg.isEmpty) {
                    st.arg = chatShortArg(it['arguments']);
                  }
                  if (mounted) setState(() {});
                  _toBottom();
                } else if (it['type'] == 'function_call_output') {
                  var st = find();
                  if (st == null) {
                    st = _Step(name: 'tool', call: call);
                    bot.steps.add(st);
                  }
                  final o = chatStepOutput(it);
                  st.out = o.text;
                  st.bad = o.bad;
                  st.run = false;
                  st.dur =
                      DateTime.now().difference(st.t0).inMilliseconds / 1000.0;
                  if (mounted) setState(() {});
                  _toBottom();
                }
              }
            } else if (type == 'response.output_text.delta') {
              final d = ev['delta'] as String? ?? '';
              if (d.isNotEmpty) {
                bot.text += d;
                if (mounted) setState(() {});
                _toBottom();
                final now = DateTime.now();
                if (now.difference(_savedAt).inSeconds >= 3) _saveLog();
              }
            } else if (type == 'hermes.context_reset') {
              // 上一条上下文在服务端已经不存在了，已经自动重开，这里只同步状态
              _prevId = null;
              if (mounted) app.toast('上下文已过期，重新开始');
            } else if (type == 'response.completed') {
              final r = ev['response'];
              if (r is Map && r['id'] is String) _prevId = r['id'] as String;
              // 有的回复只给 completed、不给 delta（或者 delta 全是空白），兜底从结果里取
              if (bot.text.trim().isEmpty && r is Map && r['output'] is List) {
                final b = StringBuffer();
                for (final item in (r['output'] as List)) {
                  if (item is! Map) continue;
                  final c = item['content'];
                  if (c is! List) continue;
                  for (final seg in c) {
                    if (seg is Map && seg['type'] == 'output_text') {
                      b.write(seg['text'] ?? '');
                    }
                  }
                }
                if (b.toString().trim().isNotEmpty) bot.text = b.toString();
              }
            }
          },
          onError: (Object e) async {
            bot.streaming = false;
            if (e.toString().contains('口令')) {
              await _authFailed();
              if (mounted) app.toast('对话口令不对，重新输一次');
            } else {
              bot.text = bot.text.isEmpty
                  ? '（没连上：$e）'
                  : '${bot.text}\n\n（中断：$e）';
              if (mounted) app.toast('发送失败');
            }
            if (mounted) {
              setState(() => _sending = false);
              _toBottom();
            }
            if (!ctl.isClosed) await ctl.close();
          },
          onDone: () async {
            bot.streaming = false;
            bot.took = DateTime.now().difference(bot.t0);
            if (bot.text.isEmpty) bot.text = '（空的回复）';
            _saveLog();
            if (mounted) {
              setState(() => _sending = false);
              _toBottom();
            }
            if (!ctl.isClosed) await ctl.close();
          },
        );
  }

  /// 日期胶囊 + 气泡展开成一张表，ListView.builder 只按需构建可见项
  List<(int, int)> get _rows {
    final out = <(int, int)>[];
    for (var i = 0; i < _list.length; i++) {
      if (i == 0 || !_sameDay(_list[i - 1].ts, _list[i].ts)) out.add((0, i));
      out.add((1, i));
    }
    return out;
  }

  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final locked = _isLocked;
    // 真实列宽：平板上左边有 96 的导航，列表左右各留 16
    final sw = MediaQuery.sizeOf(context).width;
    final colW = (sw >= 760 ? sw - 96.0 : sw) - 32.0;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(19, 18, 19, 14),
          child: const BrandBar(),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            // 0 = 标题，最后一项 = 底部留白；中间是日期胶囊 + 气泡
            itemCount: (locked || _list.isEmpty) ? 3 : 2 + _rows.length,
            itemBuilder: (_, k) {
              if (k == 0) {
                return PageTitle(
                  '对话',
                  action: _list.isEmpty ? null : TextButton2('清空', onTap: _clear),
                );
              }
              if (locked) return k == 1 ? const _NeedKeyCard() : const SizedBox(height: 70);
              if (_list.isEmpty) return k == 1 ? _IntroCard() : const SizedBox(height: 70);
              if (k == 2 + _rows.length - 1) return const SizedBox(height: 70);
              final r = _rows[k - 1];
              final i = r.$2;
              if (r.$1 == 0) return _DayPill(label: _dayLabel(_list[i].ts));
              return _Bubble(
                msg: _list[i],
                app: app,
                colW: colW,
                first:
                    i == 0 ||
                    _list[i - 1].mine != _list[i].mine ||
                    !_sameDay(_list[i - 1].ts, _list[i].ts) ||
                    _list[i].ts.difference(_list[i - 1].ts).inMinutes > 5,
                last:
                    i == _list.length - 1 ||
                    _list[i + 1].mine != _list[i].mine ||
                    !_sameDay(_list[i].ts, _list[i + 1].ts) ||
                    _list[i + 1].ts.difference(_list[i].ts).inMinutes > 5,
                onLongPress: () => _msgMenu(i),
              );
            },
          ),
        ),
        if (!locked)
          Container(
            decoration: BoxDecoration(
              color: tone.dark ? tone.surface : const Color(0xF2FFFFFF),
              border: Border(top: BorderSide(color: tone.line)),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_attach.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: SizedBox(
                          height: 30,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _attach.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 6),
                            itemBuilder: (_, i) {
                              final a = _attach[i];
                              final st = a['st'] ?? 'ok';
                              final bad = st == 'err';
                              return GestureDetector(
                                // 失败的附件点一下就重传，不用重新选文件
                                onTap: bad ? () => _uploadOne(a) : null,
                                child: Container(
                                padding: const EdgeInsets.fromLTRB(9, 4, 4, 4),
                                decoration: BoxDecoration(
                                  color: bad
                                      ? const Color(0x14E45E53)
                                      : tone.surface2,
                                  borderRadius: BorderRadius.circular(99),
                                  border: Border.all(
                                    color: bad
                                        ? const Color(0x55E45E53)
                                        : tone.line2,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    UIIcon(
                                      'attach',
                                      size: 12,
                                      color: bad ? const Color(0xFFE45E53) : tone.ink3,
                                    ),
                                    const SizedBox(width: 5),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 150,
                                      ),
                                      child: Text(
                                        a['name'] ?? '',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: tone.ink2,
                                        ),
                                      ),
                                    ),
                                    if (st == 'up')
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(left: 5),
                                        child: Text(
                                          '${a['pct'] ?? 0}%',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: tone.ac,
                                          ),
                                        ),
                                      ),
                                    if (bad)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(left: 5),
                                        child: const Text(
                                          '失败 · 重试',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFFE45E53),
                                          ),
                                        ),
                                      ),
                                    const SizedBox(width: 2),
                                    GestureDetector(
                                      onTap: () =>
                                          setState(() => _attach.removeAt(i)),
                                      child: Padding(
                                        padding: const EdgeInsets.all(4),
                                        child: UIIcon(
                                          'close',
                                          size: 11,
                                          color: tone.ink3,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              );
                            },
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        Press(
                          onTap: _pickAttach,
                          scale: 0.92,
                          radius: const BorderRadius.all(Radius.circular(99)),
                          pressColor: tone.icobg,
                          child: Padding(
                            padding: const EdgeInsets.all(9),
                            child: _uploading
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.8,
                                      color: tone.ink3,
                                    ),
                                  )
                                : UIIcon('attach', size: 20, color: tone.ink3),
                          ),
                        ),
                        Press(
                          onTap: _pasteAttach,
                          scale: 0.92,
                          radius: const BorderRadius.all(Radius.circular(99)),
                          pressColor: tone.icobg,
                          child: Padding(
                            padding: const EdgeInsets.all(9),
                            child: UIIcon('paste', size: 20, color: tone.ink3),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Container(
                            height: 42,
                            padding: const EdgeInsets.symmetric(horizontal: 13),
                            decoration: BoxDecoration(
                              color: tone.surface2,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: tone.line2),
                            ),
                            alignment: Alignment.centerLeft,
                            child: TextField(
                              controller: _ctl,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _send(),
                              style: TextStyle(fontSize: 14, color: tone.ink),
                              decoration: InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                hintText: '发消息…',
                                hintStyle: TextStyle(
                                  fontSize: 14,
                                  color: tone.ink3,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Press(
                          onTap: _send,
                          scale: 0.94,
                          radius: const BorderRadius.all(Radius.circular(99)),
                          pressColor: Colors.transparent,
                          child: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: tone.ac,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: tone.ac.withValues(alpha: 0.28),
                                  blurRadius: 14,
                                  offset: const Offset(0, 5),
                                ),
                              ],
                            ),
                            alignment: Alignment.center,
                            // 终端里没有暂停键：回答中发消息 = 打断上一轮。
                            // 以前这里会变成白色方块（看着像暂停），现在永远显示发送箭头。
                            child: const UIIcon(
                              'send',
                              size: 19,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _IntroCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 22),
      decoration: BoxDecoration(
        color: tone.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: tone.line),
        boxShadow: [
          BoxShadow(color: tone.sh, blurRadius: 10, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '在云匣里直接说话',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: tone.ink,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '让它帮你找文件、整理目录、查容量。\n'
            '说清楚要动哪个源、哪个文件夹就行，\n'
            '不确定的它会先问一句再动手。',
            style: TextStyle(fontSize: 12.5, height: 1.75, color: tone.ink2),
          ),
        ],
      ),
    );
  }
}

/// 没填口令时：只说明去哪儿填，本页不做第二遍口令输入
class _NeedKeyCard extends StatelessWidget {
  const _NeedKeyCard();

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
      decoration: BoxDecoration(
        color: tone.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: tone.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UIIcon('lock', size: 18, color: tone.ink3),
              const SizedBox(width: 8),
              Text(
                '对话要先填口令',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: tone.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '到「设置 → 写入口令」填一次，填完这里直接就能用，\n'
            '不用再输第二遍。文件预览、播放、字幕这些不填也能用。',
            style: TextStyle(fontSize: 12.5, height: 1.75, color: tone.ink2),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final _Msg msg;
  final App app;
  final bool first;
  final bool last;
  final double colW;
  final VoidCallback? onLongPress;
  const _Bubble({
    required this.msg,
    required this.app,
    required this.colW,
    this.first = true,
    this.last = true,
    this.onLongPress,
  });

  Future<void> _openLink(String url) async {
    try {
      await Native.openUrl(url);
    } catch (e) {
      app.toast('打不开链接：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final maxW = (colW * 0.92).clamp(240.0, 1200.0);
    final files = msg.mine
        ? const <_ChatFile>[]
        : chatAttachments(msg.text, app);
    final thinking = msg.streaming && msg.text.trim().isEmpty;

    // 圆角：同一个人连发的几条，只有最后一条把靠自己那侧的角收小
    const big = Radius.circular(20);
    final small = const Radius.circular(7);
    final radius = BorderRadius.only(
      topLeft: big,
      topRight: big,
      bottomLeft: !msg.mine && last ? small : big,
      bottomRight: msg.mine && last ? small : big,
    );

    Widget body;
    if (msg.mine) {
      body = Text(
        msg.text,
        style: TextStyle(fontSize: 15, height: 1.45, color: tone.onac),
      );
    } else {
      final parts = <Widget>[
        if (msg.steps.isNotEmpty) _StepsView(steps: msg.steps, tone: tone),
        if (msg.think.trim().isNotEmpty)
          _ThinkCard(think: msg.think.trim(), tone: tone, live: thinking),
        if (thinking && msg.think.trim().isEmpty)
          _Typing(text: '正在思考')
        else if (thinking)
          const SizedBox(height: 6),
        if (_stripMedia(msg.text).trim().isNotEmpty)
          MarkdownLite(
            _stripMedia(msg.text),
            ink: tone.ink,
            ink2: tone.ink2,
            codeBg: tone.surface2,
            line: tone.line,
            size: 15,
            onTapLink: _openLink,
          ),
        if (files.any((f) => f.isImage))
          _ChatImages(
            files: files.where((f) => f.isImage).take(6).toList(),
            app: app,
          ),
        for (final f in files.where((f) => f.isAudio))
          _ChatAudio(
                    file: f,
                    tone: tone,
                    onSave: () => saveChatFile(app, f),
                  ),
        for (final f in files.where((f) => !f.isImage && !f.isAudio).take(8))
          _ChatFileRow(file: f, app: app),
      ];
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            parts[i],
          ],
        ],
      );
    }

    final status = _statusText();
    return Align(
      alignment: msg.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          margin: EdgeInsets.only(bottom: last ? 10 : 3, top: first ? 6 : 0),
          padding: const EdgeInsets.fromLTRB(13, 9, 13, 6),
          constraints: BoxConstraints(maxWidth: maxW),
          decoration: BoxDecoration(
            color: msg.mine ? tone.ac : tone.surface,
            borderRadius: radius,
            border: msg.mine ? null : Border.all(color: tone.line),
          ),
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                body,
                // 时间压进气泡右下角
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (status != null) ...[
                        Text(
                          status,
                          style: TextStyle(
                            fontSize: 10,
                            color: msg.mine
                                ? tone.onac.withValues(alpha: 0.75)
                                : tone.ink3,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (msg.mine)
                        // 双勾用图标画：文本 ✓✓ 在安卓默认字体里是空方块
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: SizedBox(
                            width: 15,
                            height: 9,
                            child: Stack(
                              children: [
                                Positioned(
                                  left: 0,
                                  top: 0,
                                  child: UIIcon(
                                    'check',
                                    size: 9,
                                    color: tone.onac.withValues(alpha: 0.7),
                                  ),
                                ),
                                Positioned(
                                  left: 5,
                                  top: 0,
                                  child: UIIcon(
                                    'check',
                                    size: 9,
                                    color: tone.onac.withValues(alpha: 0.95),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Text(
                        _hhmm(msg.ts),
                        style: TextStyle(
                          fontSize: 10,
                          color: msg.mine
                              ? tone.onac.withValues(alpha: 0.75)
                              : tone.ink3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「正在输出 · 1.2k 字 · 12s」/「用时 34 秒」
  String? _statusText() {
    if (msg.mine) return null;
    // 服务端还在跑（可能本机已经断线）——像 TG 那样标「更新中」
    if (msg.status == 'running' && !msg.streaming) return '更新中…';
    if (msg.status == 'interrupted' && !msg.streaming) return '已中断';
    if (msg.streaming) {
      final sec = DateTime.now().difference(msg.t0).inSeconds;
      final n = msg.text.characters.length;
      final size = n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k 字' : '$n 字';
      return '正在输出 · $size · ${sec}s';
    }
    final d = msg.took;
    if (d == null) return null;
    final s = d.inSeconds;
    return s >= 60 ? '用时 ${s ~/ 60} 分 ${s % 60} 秒' : '用时 $s 秒';
  }
}

/// 画气泡：向下柔和阴影 + 内下角一道浅蓝小尾巴（参考 QQ 截图）
/// 自己发的在右侧，尾巴落在左下；对方在左侧，尾巴落在右下。
/// 终端过程：一步一行，跑着的转圈 + 秒数，点行看输出
class _StepsView extends StatefulWidget {
  final List<_Step> steps;
  final Tone tone;
  const _StepsView({required this.steps, required this.tone});

  @override
  State<_StepsView> createState() => _StepsViewState();
}

class _StepsViewState extends State<_StepsView> {
  final _open = <int>{};
  bool _folded = false;

  @override
  Widget build(BuildContext context) {
    final tone = widget.tone;
    final steps = widget.steps;
    final running = steps.where((s) => s.run).length;
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 7, 9, 7),
      decoration: BoxDecoration(
        color: tone.surface2,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: tone.line2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _folded = !_folded),
            child: Row(
              children: [
                UIIcon('code', size: 12, color: tone.ink3),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '终端过程 · ${steps.length} 步'
                    '${running > 0 ? ' · 运行中 $running' : ''}',
                    style: TextStyle(
                      fontSize: 11,
                      color: tone.ink3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  _folded ? '展开' : '收起',
                  style: TextStyle(fontSize: 10.5, color: tone.ink3),
                ),
              ],
            ),
          ),
          if (!_folded) ...[
            const SizedBox(height: 5),
            for (var i = 0; i < steps.length; i++) _row(steps[i], i, tone),
          ],
        ],
      ),
    );
  }

  Widget _row(_Step st, int i, Tone tone) {
    final open = _open.contains(i);
    final sec = st.run
        ? DateTime.now().difference(st.t0).inMilliseconds / 1000.0
        : st.dur;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() {
        if (open) {
          _open.remove(i);
        } else {
          _open.add(i);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (st.run)
                  SizedBox(
                    width: 9,
                    height: 9,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.3,
                      color: tone.ac,
                    ),
                  )
                else
                  UIIcon(
                    st.bad ? 'close' : 'check',
                    size: 9,
                    color: st.bad
                        ? const Color(0xFFE5484D)
                        : const Color(0xFF2F9E58),
                  ),
                const SizedBox(width: 6),
                Text(st.name, style: TextStyle(fontSize: 11, color: tone.ink)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    st.arg,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: tone.ink3),
                  ),
                ),
                if (sec != null)
                  Text(
                    st.run
                        ? '运行中 ${sec.toStringAsFixed(0)}s'
                        : '${sec.toStringAsFixed(1)}s',
                    style: TextStyle(fontSize: 10, color: tone.ink3),
                  ),
              ],
            ),
            if (st.out.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 15, top: 2),
                child: Text(
                  st.out,
                  maxLines: open ? null : 3,
                  overflow: open ? null : TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.45,
                    color: st.bad ? const Color(0xFFC0392B) : tone.ink2,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 日期分隔（TG 的居中胶囊：今天 / 昨天 / 2026/10/24）
class _DayPill extends StatelessWidget {
  final String label;
  const _DayPill({required this.label});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Align(
      alignment: Alignment.center,
      child: Container(
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: tone.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: tone.line),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: tone.ink3,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// 三个跳动的点（旧版 .cx-typing）
class _Typing extends StatefulWidget {
  final String text;
  const _Typing({required this.text});
  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.text, style: TextStyle(fontSize: 12, color: tone.ink3)),
        const SizedBox(width: 6),
        AnimatedBuilder(
          animation: _c,
          builder: (_, __) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++)
                Container(
                  margin: const EdgeInsets.only(right: 3),
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tone.ink3.withValues(
                      alpha:
                          0.35 +
                          0.65 *
                              (((_c.value + i / 3) % 1.0) < 0.5
                                  ? (1 - ((_c.value + i / 3) % 1.0) * 2)
                                  : 0),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 思考卡片：白底 + 细边，两行截断，点开看全文
class _ThinkCard extends StatefulWidget {
  final String think;
  final Tone tone;
  final bool live;
  const _ThinkCard({
    required this.think,
    required this.tone,
    this.live = false,
  });

  @override
  State<_ThinkCard> createState() => _ThinkCardState();
}

class _ThinkCardState extends State<_ThinkCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final tone = widget.tone;
    final t = widget.think;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: tone.surface2,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: tone.line2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => setState(() => _open = !_open),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                UIIcon('info', size: 13, color: tone.ink3),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    widget.live ? '思考中…' : '思考过程',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: tone.ink3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  _open ? '收起' : '展开',
                  style: TextStyle(fontSize: 11, color: tone.ink3),
                ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Text(
            t,
            maxLines: _open ? null : 2,
            overflow: _open ? null : TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, height: 1.5, color: tone.ink2),
          ),
        ],
      ),
    );
  }
}

/// 回复里提到的图片：横排缩略图，点开全屏
class _ChatImages extends StatelessWidget {
  final List<_ChatFile> files;
  final App app;
  const _ChatImages({required this.files, required this.app});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final f in files)
          GestureDetector(
            onTap: () {
              final entry = _chatEntry(f);
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ImageViewerPage(
                    url: f.url,
                    entry: entry,
                    tone: tone,
                    gallery: files.map(_chatEntry).toList(),
                    onLink: (e) async =>
                        files.firstWhere((x) => x.name == e.name, orElse: () => f).url,
                    onSave: (_) => saveChatFile(app, f),
                    headers: f.headers,
                  ),
                ),
              );
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 96,
                height: 96,
                child: Image.network(
                  f.thumbUrl,
                  headers: f.headers,
                  cacheWidth: 288,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: tone.surface2,
                    alignment: Alignment.center,
                    child: UIIcon('type-image', size: 18, color: tone.ink3),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 全屏看图（带缩放，点一下退出）
/// 回复里常见的 MEDIA:/path 只是投递指令，正文里不该出现这两个字
String _stripMedia(String t) => t.replaceAllMapped(
  // 注意：Dart 的 replaceAll 不认 $1，必须用 replaceAllMapped，
  // 否则正文里会留下字面量 "$1"（用户截图里那条就中过）。
  RegExp(r'(^|\n)[ \t]*MEDIA:[ \t]*'),
  (m) => m.group(1) ?? '',
);

/// 气泡里的文件行：名字 + 大小 + 下载
class _ChatFileRow extends StatelessWidget {
  final _ChatFile file;
  final App app;
  const _ChatFileRow({required this.file, required this.app});

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    return GestureDetector(
      onTap: () => saveChatFile(app, file),
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 7, 9, 7),
        decoration: BoxDecoration(
          color: tone.surface2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: tone.line2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            UIIcon('download', size: 15, color: tone.ac),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: tone.ac),
              ),
            ),
            const SizedBox(width: 8),
            Text('下载', style: TextStyle(fontSize: 11, color: tone.ink3)),
          ],
        ),
      ),
    );
  }
}

/// 对话里的音乐卡片：点一下就播，不用先下载。
///
/// 播放器按需创建（mpv 实例不便宜，一屏好几条消息不能每条都开一个），
/// 播完/离开页面自动销毁。
class _ChatAudio extends StatefulWidget {
  final _ChatFile file;
  final Tone tone;
  final VoidCallback onSave;
  const _ChatAudio({
    required this.file,
    required this.tone,
    required this.onSave,
  });

  @override
  State<_ChatAudio> createState() => _ChatAudioState();
}

class _ChatAudioState extends State<_ChatAudio> {
  Player? _p;
  StreamSubscription<Duration>? _sp;
  StreamSubscription<Duration>? _sd;
  StreamSubscription<bool>? _spl;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _playing = false;
  bool _opening = false;

  Future<void> _toggle() async {
    if (_opening) return;
    var p = _p;
    if (p == null) {
      setState(() => _opening = true);
      p = Player();
      _p = p;
      _sp = p.stream.position.listen((d) {
        if (mounted) setState(() => _pos = d);
      });
      _sd = p.stream.duration.listen((d) {
        if (mounted) setState(() => _dur = d);
      });
      _spl = p.stream.playing.listen((v) {
        if (mounted) setState(() => _playing = v);
      });
      try {
        await p.open(
          Media(widget.file.url, httpHeaders: widget.file.headers),
          play: true,
        );
      } catch (e) {
        if (mounted) {
          setState(() => _opening = false);
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(SnackBar(content: Text('放不出来：$e')));
        }
        return;
      }
      if (mounted) setState(() => _opening = false);
      return;
    }
    await p.playOrPause();
  }

  Future<void> _seekTo(double f) async {
    final p = _p;
    if (p == null || _dur.inMilliseconds == 0) return;
    await p.seek(Duration(milliseconds: (_dur.inMilliseconds * f).round()));
  }

  String _mmss(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _sp?.cancel();
    _sd?.cancel();
    _spl?.cancel();
    _p?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tone = widget.tone;
    final prog = _dur.inMilliseconds <= 0
        ? 0.0
        : (_pos.inMilliseconds / _dur.inMilliseconds).clamp(0.0, 1.0);
    return Container(
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
      padding: const EdgeInsets.fromLTRB(8, 7, 10, 7),
      decoration: BoxDecoration(
        color: tone.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.line2),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _toggle,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: tone.ac,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: _opening
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(tone.onac),
                        ),
                      )
                    : UIIcon(
                        _playing ? 'pause' : 'play',
                        size: 16,
                        color: tone.onac,
                      ),
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: tone.ink,
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) =>
                      _seekTo(d.localPosition.dx / 260),
                  child: SizedBox(
                    height: 4,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: prog,
                        minHeight: 4,
                        backgroundColor: tone.line2,
                        valueColor: AlwaysStoppedAnimation(tone.ac),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${_mmss(_pos)} / ${_dur.inMilliseconds > 0 ? _mmss(_dur) : '--:--'}',
                  style: TextStyle(fontSize: 10, color: tone.ink3),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: widget.onSave,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 30,
              height: 30,
              margin: const EdgeInsets.only(left: 4),
              decoration: BoxDecoration(
                color: tone.surface,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Center(
                child: UIIcon('download', size: 15, color: tone.ac),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 回复里提到的一个文件/图片（解析结果）
class _ChatFile {
  final String path; // 原始路径或 URL
  final String name;
  final String url; // 可直接取的地址（原图）
  final Map<String, String> headers;
  final bool isImage;
  final bool isAudio;
  const _ChatFile(
    this.path,
    this.name,
    this.url,
    this.headers,
    this.isImage, {
    this.isAudio = false,
  });

  /// 网格里的 96px 格子用它，服务端按 240 宽缩放并缓存
  String get thumbUrl {
    if (!url.contains('/hermes/api/dl?')) return url;
    return url.replaceFirst('/hermes/api/dl?', '/hermes/api/thumb?') + '&w=240';
  }
}

const _imgExt = {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'};

/// 音乐：在对话里直接给一个能听的卡片，不用先下载
const _audioExt = {
  'mp3',
  'm4a',
  'aac',
  'flac',
  'wav',
  'ogg',
  'opus',
  'ape',
  'wma',
};
const _fileExt = {
  'pdf',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'csv',
  'txt',
  'md',
  'json',
  'zip',
  'rar',
  '7z',
  'apk',
  'exe',
  'iso',
  'tar',
  'gz',
  'dll',
  'mp4',
  'mkv',
  'mp3',
  'wav',
  'srt',
  'ass',
  'html',
  'htm',
  'py',
  'sh',
  'log',
};

/// 对话里的图片包一个 Entry，好让文件页那套查看器原样复用
Entry _chatEntry(_ChatFile f) {
  final ext = f.name.contains('.') ? f.name.split('.').last.toLowerCase() : '';
  return Entry(
    name: f.name,
    path: f.path,
    isDir: false,
    size: 0,
    mtime: 0,
    kind: 'image',
    ext: ext,
  );
}

/// 从回复正文里挑出「能拿到的文件」：本地绝对路径 / G:\ 盘符 / 直接是图片 URL
List<_ChatFile> chatAttachments(String text, App app) {
  final origin = app.api.origin;
  final basic = app.session.chatBasic;
  final headers = basic.isEmpty
      ? const <String, String>{}
      : {'Authorization': 'Basic $basic'};
  final out = <_ChatFile>[];
  final seen = <String>{};

  void add(String raw, bool image) {
    var p = raw.trim();
    // 尾随标点不算路径
    while (p.isNotEmpty && '.,;:!?，。、；：！？'.contains(p[p.length - 1])) {
      p = p.substring(0, p.length - 1);
    }
    if (p.isEmpty || seen.contains(p)) return;
    seen.add(p);
    if (p.startsWith('http://') || p.startsWith('https://')) {
      final segs = Uri.tryParse(p)?.pathSegments ?? const <String>[];
      final name = segs.isNotEmpty ? segs.last : p;
      out.add(_ChatFile(p, name.isEmpty ? p : name, p, const {}, image));
      return;
    }
    // Windows 路径 → 同一台机器的 /mnt/<盘>
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p)) {
      p = '/mnt/${p[0].toLowerCase()}/${p.substring(3).replaceAll(RegExp(r'[\\/]'), '/')}';
    }
    if (p.startsWith('~/')) p = '/home/administrator/${p.substring(2)}';
    if (!p.startsWith('/')) return;
    final name = p.split('/').last;
    final url = '$origin/hermes/api/dl?path=${Uri.encodeComponent(p)}';
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    out.add(
      _ChatFile(p, name, url, headers, image, isAudio: _audioExt.contains(ext)),
    );
  }

  // 1) 图片 URL（URL 里不会有空格，正则安全）
  for (final m in RegExp(
    r'https?://[^\s"<>）)]+\.(?:png|jpe?g|webp|gif)(?:\?[^\s"<>）)]*)?',
  ).allMatches(text)) {
    add(m.group(0)!, true);
  }

  // 2) 本地路径：按「词」判断，不用贪婪正则（否则一句话里两个路径会被吞成一串）
  String clean(String v) {
    const head = '`"\'（(【[<';
    const tail = '`"\'）)】]>,.;:!?，。、；：！？';
    var t = v.trim();
    while (t.isNotEmpty && head.contains(t[0])) {
      t = t.substring(1);
    }
    while (t.isNotEmpty && tail.contains(t[t.length - 1])) {
      t = t.substring(0, t.length - 1);
    }
    return t;
  }

  // 2.5) 「MEDIA:」行：整行剩下的都算路径。
  // 这是投递约定，路径里常带空格和中文（例如
  // `/mnt/g/…/Being in Love - Synth Monsters 川岛三离.mp3`），
  // 按词切永远切不全，所以整行整取。
  for (final line in text.split('\n')) {
    final m = RegExp(r'^\s*MEDIA:[ \t]*(.+?)\s*$').firstMatch(line);
    if (m == null) continue;
    final v = clean(m.group(1)!);
    if (v.isEmpty) continue;
    final ext = v.contains('.') ? v.split('.').last.toLowerCase() : '';
    if (_imgExt.contains(ext)) {
      add(v, true);
    } else if (_fileExt.contains(ext)) {
      add(v, false);
    }
  }

  final toks = <String>[];
  // 反引号/引号里的整段优先（路径带空格时靠它）
  for (final m in RegExp(r'`([^`\n]+)`|"([^"\n]+)"').allMatches(text)) {
    final v = (m.group(1) ?? m.group(2) ?? '');
    if (v.trim().isNotEmpty) toks.add(v);
  }
  for (final tok in text.split(RegExp(r'\s+'))) {
    if (tok.isNotEmpty) toks.add(tok);
  }

  final isPath = RegExp(
    r'^(?:/home/[\w.@-]+|/tmp|/mnt/[A-Za-z]|[A-Za-z]:|~)[/\\]',
  );
  final extRe = RegExp(r'\.([A-Za-z0-9]{1,5})$');
  // 路径前面常贴着中文冒号/括号：「电脑本地：G:\\hermes\\…」整段
  // 是一个 token，路径并不在开头，得先把前缀切掉再判。
  final pathHead = RegExp(
    // 盘符前面不能是字母数字：否则 https://x 里的 "s:/" 会被当成 S 盘
    r'(?:/home/[\w.@-]+|/tmp|/mnt/[A-Za-z]|(?<![A-Za-z0-9])[A-Za-z]:[\\/]|~/)',
  );
  for (var i = 0; i < toks.length; i++) {
    var t = clean(toks[i]);
    final hp = pathHead.firstMatch(t);
    if (hp != null && hp.start > 0) t = t.substring(hp.start);
    if (t.isEmpty || !isPath.hasMatch(t)) continue;
    var ext = extRe.firstMatch(t)?.group(1)?.toLowerCase();
    // 路径里可能带空格：「/tmp/a b/c.srt」被切成两个词，最多再拼 3 个
    var k = i;
    while (ext == null && k + 1 < toks.length && k - i < 8 && t.length < 240) {
      k++;
      final nxt = clean(toks[k]);
      if (nxt.isEmpty || nxt.contains(' ')) break;
      t = '$t $nxt';
      ext = extRe.firstMatch(t)?.group(1)?.toLowerCase();
    }
    if (ext == null) continue;
    if (_imgExt.contains(ext)) {
      add(t, true);
    } else if (_fileExt.contains(ext)) {
      add(t, false);
    }
  }
  return out;
}

/// 下载/保存回复里的文件（走旧前端的 /hermes/api/dl，带 Basic 口令）
Future<void> saveChatFile(App app, _ChatFile f) async {
  if (f.path.startsWith('http')) {
    // 外链图片/文件：交给浏览器，别拿手机流量乱存
    try {
      await Native.openUrl(f.path);
    } catch (e) {
      app.toast('打不开：$e');
    }
    return;
  }
  app.toast('开始下载：${f.name}');
  final where = await app.transfers.downloadRaw(
    app.api,
    f.name,
    f.url,
    headers: f.headers,
  );
  // 失败别静默：把原因说出来（401 口令、404 文件没了、写入被拒都在这条里）
  if (where == null || where.isEmpty) {
    final t = app.transfers.items.isNotEmpty ? app.transfers.items.first : null;
    app.toast('下载失败：${t?.error ?? '未知原因'}');
  } else {
    app.toast('已保存到 $where');
  }
}
