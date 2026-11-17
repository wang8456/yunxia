import 'dart:convert';
import 'dart:io';

/// 本地会话：设备令牌 + 服务器地址 + 主题选择。
///
/// 故意不引 shared_preferences —— 只存一个 JSON 小文件，
/// 目录优先用应用私有 files（不会被系统清），退化到 cache 也能用。
class Session {
  static const _file = 'yunxia_session.json';

  String? token;
  String server;
  String toneId;
  String device;

  /// 文件页显示方式：false = 紧凑列表，true = 网格缩略图
  bool gridMode;

  /// 文件列表的排序：按什么排（name/size/time/type）+ 升序还是降序。
  /// 用户明确要求记住，重开 App 不能回到默认。
  String fileSort = 'name';
  String fileOrder = 'asc';

  /// 对话口令（base64 的 "hermes:口令"），只在本地存
  String chatBasic;

  /// 对话记录（最近几十条，退出 App 也在）：[{t: 秒, mine: bool, text: 内容}]
  List<Map<String, dynamic>> chatLog = const [];

  /// 上次停在哪个页签（进程被系统收掉后回来还停在原地，不会莫名跳回首页）
  int lastTab = 0;

  /// 首页「收藏」的文件夹：[{src, path, name}]
  List<Map<String, dynamic>> favorites = const [];

  /// 下载：同时几个 / 完成后提示
  int dlMaxActive = 2;
  bool dlNotify = true;

  Session({
    required this.server,
    this.token,
    this.toneId = 'blue',
    this.device = 'android',
    this.favorites = const [],
    this.chatBasic = '',
    this.chatLog = const [],
    this.lastTab = 0,
    this.gridMode = false,
    this.fileSort = 'name',
    this.fileOrder = 'asc',
    this.dlMaxActive = 2,
    this.dlNotify = true,
  });

  static Future<File> _fileHandle() async {
    final candidates = <Directory>[
      Directory('${Directory.systemTemp.parent.path}/files'),
      Directory.systemTemp,
    ];
    for (final d in candidates) {
      try {
        if (!d.existsSync()) d.createSync(recursive: true);
        final f = File('${d.path}/$_file');
        return f;
      } catch (_) {}
    }
    return File('${Directory.systemTemp.path}/$_file');
  }

  static Future<Session> load(String fallbackServer) async {
    try {
      final f = await _fileHandle();
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        return Session(
          server: j['server'] as String? ?? fallbackServer,
          token: j['token'] as String?,
          toneId: j['tone'] as String? ?? 'blue',
          device: j['device'] as String? ?? 'android',
          chatBasic: j['chatBasic'] as String? ?? '',
          lastTab: (j['lastTab'] as num?)?.toInt() ?? 0,
          chatLog: ((j['chatLog'] as List?) ?? const [])
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList(),
          gridMode: j['gridMode'] as bool? ?? false,
          fileSort: (j['fileSort'] as String?) ?? 'name',
          fileOrder: (j['fileOrder'] as String?) ?? 'asc',
          dlMaxActive: (j['dlMaxActive'] as num?)?.toInt() ?? 2,
          dlNotify: j['dlNotify'] as bool? ?? true,
          favorites: ((j['favorites'] as List?) ?? const [])
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList(),
        );
      }
    } catch (_) {}
    return Session(server: fallbackServer);
  }

  Future<void> save() async {
    try {
      final f = await _fileHandle();
      f.writeAsStringSync(jsonEncode({
        'server': server,
        'token': token,
        'tone': toneId,
        'device': device,
        'favorites': favorites,
        'chatBasic': chatBasic,
        'chatLog': chatLog,
        'lastTab': lastTab,
        'dlMaxActive': dlMaxActive,
        'dlNotify': dlNotify,
        'gridMode': gridMode,
        'fileSort': fileSort,
        'fileOrder': fileOrder,
      }));
    } catch (_) {}
  }

  Future<void> clear() async {
    token = null;
    await save();
  }
}
