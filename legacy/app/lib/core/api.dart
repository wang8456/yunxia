import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ApiError implements Exception {
  final int status;
  final String message;
  ApiError(this.status, this.message);

  bool get isAuth => status == 401 || status == 403;

  @override
  String toString() => message;
}

/// 统一 API 客户端：一个入口、只带设备令牌，不带任何源口令。
class Api {
  /// 局域网地址会变，允许在设置页改；默认值来自编译期 --dart-define。
  static const defaultServer = String.fromEnvironment(
    'YUNXIA_SERVER',
    defaultValue: 'http://192.168.1.10:5007',
  );

  String server;
  String? token;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..idleTimeout = const Duration(seconds: 20);

  Api(this.server);

  String get origin {
    final s = server.endsWith('/')
        ? server.substring(0, server.length - 1)
        : server;
    return s;
  }

  String get base => '$origin/api/v1';

  Uri _uri(String path, [Map<String, String>? query]) {
    final u = Uri.parse('$base$path');
    if (query == null || query.isEmpty) return u;
    return u.replace(queryParameters: {...u.queryParameters, ...query});
  }

  /// 把服务端返回的相对地址（/f/… 或 /api/v1/fs/raw?…）补成绝对地址
  String absolute(String path) =>
      path.startsWith('http') ? path : '$origin$path';

  Future<Map<String, String>> _headers({bool json = false}) async {
    final h = <String, String>{};
    if (token != null) h['Authorization'] = 'Bearer $token';
    if (json) h['Content-Type'] = 'application/json; charset=utf-8';
    return h;
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final req = await _http.openUrl(method, _uri(path, query));
    final h = await _headers(json: body != null);
    h.forEach(req.headers.set);
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(timeout);
    final text = await utf8.decoder.bind(res).join();
    if (res.statusCode >= 400) {
      throw ApiError(res.statusCode, _reason(text, res.statusCode));
    }
    if (text.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : {'data': decoded};
  }

  // 继续观看
  Future<Map<String, dynamic>> playOne(String path) =>
      _send('GET', '/play/one', query: {'path': path});

  Future<void> playSave(String path, double pos, double dur, String name) =>
      _send(
        'PUT',
        '/play',
        body: {'path': path, 'pos': pos, 'dur': dur, 'name': name},
      );

  /// 取字幕原始字节（srt）
  Future<List<int>> subsSrt(String id) async {
    final req = await _http.openUrl('GET', _uri('/subs/$id/srt'));
    final h = await _headers();
    h.forEach(req.headers.set);
    final res = await req.close().timeout(const Duration(seconds: 30));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (res.statusCode >= 400) {
      throw ApiError(
        res.statusCode,
        _reason(utf8.decode(bytes, allowMalformed: true), res.statusCode),
      );
    }
    return bytes;
  }

  /// 同上，但直接给文本（实时任务边转边拉）
  Future<String> subsSrtText(String id) async {
    final b = await subsSrt(id);
    return utf8.decode(b, allowMalformed: true);
  }

  String _reason(String body, int code) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['detail'] != null) return '${j['detail']}';
    } catch (_) {}
    if (code == 401) return '登录已过期，请重新登录';
    return 'HTTP $code';
  }

  Future<Map<String, dynamic>> get(String path, [Map<String, String>? query]) =>
      _send('GET', path, query: query);

  // ---------- 业务方法 ----------

  Future<Map<String, dynamic>> login(String password, String device) => _send(
    'POST',
    '/auth/login',
    body: {'password': password, 'device': device},
  );

  Future<Map<String, dynamic>> healthz() =>
      _send('GET', '/healthz', timeout: const Duration(seconds: 6));

  Future<Map<String, dynamic>> list(
    String source,
    String path, {
    String sort = 'name',
    String order = 'asc',
  }) => _send(
    'GET',
    '/fs/list',
    query: {'source': source, 'path': path, 'sort': sort, 'order': order},
  );

  Future<Map<String, dynamic>> link(String source, String path) =>
      _send('GET', '/fs/link', query: {'source': source, 'path': path});

  /// 这个文件是不是杜比视界、哪个 profile —— 服务端用 ffprobe 读容器的
  /// DOVI configuration record（和 Emby/Kodi 同一份证据），不看文件名。
  /// 拿不到返回 null（＝没验证），杜比模式就别让选。
  Future<Map<String, dynamic>?> dovi(String source, String path) async {
    try {
      final r = await _send(
        'GET',
        '/fs/dovi',
        query: {"source": source, "path": path},
        timeout: const Duration(seconds: 90),
      );
      return r['dovi'] is bool ? r : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> mkdir(String source, String path, String name) =>
      _send(
        'POST',
        '/fs/mkdir',
        body: {'source': source, 'path': path, 'name': name},
      );

  Future<Map<String, dynamic>> move(String source, String src, String dst) =>
      _send(
        'POST',
        '/fs/move',
        body: {'source': source, 'src': src, 'dst': dst},
      );

  Future<Map<String, dynamic>> remove(String source, List<String> paths) =>
      _send('POST', '/fs/delete', body: {'source': source, 'paths': paths});

  Future<Map<String, dynamic>> search(
    String q, {
    String? source,
    String? kind,
    int limit = 50,
    int offset = 0,
  }) => _send(
    'GET',
    '/search',
    query: {
      'q': q,
      if (source != null) 'source': source,
      if (kind != null) 'kind': kind,
      'limit': '$limit',
      'offset': '$offset',
    },
  );

  Future<Map<String, dynamic>> searchStatus() => _send('GET', '/search/status');

  Future<Map<String, dynamic>> reindex() => _send('POST', '/search/reindex');


  // ---------- 对话记录同步（走 /hermes/api/log，服务端托管的那本账） ----------

  Future<Map<String, dynamic>> _logCall(
    String method,
    String path, {
    Object? body,
    required String basic,
    int timeoutSec = 20,
  }) async {
    final req = await _http.openUrl(method, Uri.parse('$origin/hermes/api/log$path'));
    req.headers.set('Authorization', 'Basic $basic');
    req.headers.set('Accept', 'application/json');
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      req.headers.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(Duration(seconds: timeoutSec));
    final text = await utf8.decoder.bind(res).join();
    if (res.statusCode >= 400) {
      throw ApiError(res.statusCode, _reason(text, res.statusCode));
    }
    if (text.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : {'data': decoded};
  }

  /// 拉增量：返回 {cursor, ops:[{seq, kind, msg?|id}]}
  Future<Map<String, dynamic>> logSince(int since, {required String basic}) =>
      _logCall('GET', '?since=$since', basic: basic);

  /// 把本机产生的消息推上去（用户发的那句要各端都能看到）
  Future<Map<String, dynamic>> logPush(
    List<Map<String, dynamic>> msgs, {
    required String basic,
    String device = 'android',
    int since = 0,
  }) => _logCall(
    'POST',
    '',
    basic: basic,
    body: {'device': device, 'msgs': msgs, 'since': since},
  );

  // ---------- 任务中心（磁力 / ed2k） ----------

  /// 数据源列表（nas / 115 / 电脑），带可写标记
  // ---- CloudDrive2：状态 / 令牌 / 云下载 ----
  Future<Map<String, dynamic>> cd2Status() => _send('GET', '/cd2/status');

  Future<Map<String, dynamic>> cd2Token(String token) =>
      _send('POST', '/cd2/token', body: {'token': token});

  /// path 是源内相对目录（后端补上 source.root），source 决定落到哪个网盘
  Future<Map<String, dynamic>> cd2Offline(
    List<String> urls,
    String path,
    String source,
  ) =>
      _send('POST', '/cd2/offline',
          body: {'urls': urls, 'path': path, 'source': source});

  /// 所有云下载任务（跨目录），任务中心用
  Future<Map<String, dynamic>> cd2OfflineAll() =>
      _send('GET', '/cd2/offline/all');

  /// 只把任务从列表里移除，默认不动网盘上的文件
  Future<Map<String, dynamic>> cd2OfflineDel(String hash,
          {String path = '/', String source = 'nas115', bool deleteFiles = false}) =>
      _send('POST', '/cd2/offline/del', body: {
        'hash': hash,
        'path': path,
        'source': source,
        'delete_files': deleteFiles,
      });

  Future<Map<String, dynamic>> cd2Tasks(String path, String source) =>
      _send('GET', '/cd2/offline', query: {'path': path, 'source': source});

  Future<Map<String, dynamic>> sources() =>
      _send('GET', '/meta/sources', timeout: const Duration(seconds: 10));

  Future<Map<String, dynamic>> tasks() =>
      _send('GET', '/tasks', timeout: const Duration(seconds: 12));

  Future<Map<String, dynamic>> addTask(
    String kind,
    List<String> urls, {
    String dir = '',
    String target = 'nas',
  }) => _send(
    'POST',
    '/tasks/add',
    body: {'kind': kind, 'urls': urls, 'dir': dir, 'target': target},
  );

  /// 听译任务（subs-hub 5092）
  /// 听译队列。实时听译（live）默认不在队列里显示，
  /// 只有播放器查自己那条任务时才带 includeLive: true。
  Future<Map<String, dynamic>> subs({bool includeLive = false}) => _send(
    'GET',
    includeLive ? '/subs?include_live=1' : '/subs',
    timeout: const Duration(seconds: 12),
  );

  /// 这个视频有没有现成字幕（听译结果）
  Future<Map<String, dynamic>> subsFor(String path, {String source = ''}) =>
      _send(
        'GET',
        '/subs/for?source=${Uri.encodeComponent(source)}'
            '&path=${Uri.encodeComponent(path)}',
        timeout: const Duration(seconds: 20),
      );

  /// 匿名直链取文本（同名字幕文件用，签名地址本身不需要鉴权）
  Future<String> fetchText(String url) async {
    final req = await _http.getUrl(Uri.parse(url));
    final res = await req.close();
    final bytes = await res.fold<List<int>>(<int>[], (p, c) => p..addAll(c));
    if (res.statusCode != 200) throw ApiError(res.statusCode, '取文件失败');
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<Map<String, dynamic>> subsAdd(
    String path, {
    String name = '',
    String model = 'turbo',
    bool live = false,
    double start = 0,
    String source = 'nas',
    String lang = 'zh',
    int? at,
    String session = '',
    String hot = '',
    double ahead = 0,
    bool again = false,
  }) => _send(
    'POST',
    '/subs/add',
    body: {
      'path': path,
      'name': name,
      'source': source,
      'model': model,
      'live': live,
      'start': start,
      'lang': lang,
      // 这一次打开播放器的会话号：实时听只活在这个会话里
      if (live && session.isNotEmpty) 'session': session,
      // 热词（片名、角色名）：喂给模型当提示，专有名词不容易听错
      if (hot.isNotEmpty) 'hot': hot,   // 队列听也要热词
      if (live && ahead > 0) 'ahead': ahead,
      // 听译抽哪条音轨（ffmpeg 绝对流序号）。不传＝服务端自己挑，
      // 挑错了就会出现「转出来的语言不是片子的原声语言」。
      if (at != null) 'at': at,
      // 重新转写：不带这个，服务端会把已有任务原样复用，一句都不重听
      if (again) 'again': true,
    },
    timeout: const Duration(seconds: 25),
  );

  /// 这个文件有哪些音轨（语言/标题/声道 + 听译要用的绝对流序号）
  Future<List<Map<String, dynamic>>> audios(String source, String path) async {
    final r = await _send(
      'GET',
      '/subs/audios',
      query: {'source': source, 'path': path},
      timeout: const Duration(seconds: 60),
    );
    return ((r['tracks'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
  }

  /// 这个文件里有哪些内封字幕轨（只有文字字幕能抽文本，图形字幕 text=false）
  Future<List<Map<String, dynamic>>> embeddedSubs(
    String source,
    String path,
  ) async {
    final r = await _send(
      'GET',
      '/subs/embedded',
      query: {'source': source, 'path': path},
      timeout: const Duration(seconds: 60),
    );
    return ((r['subs'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
  }

  /// 抽一条内封字幕轨。第一次要顺着读完整片（几分钟），所以是「边抽边给」：
  /// state=running 时 text 是已经抽到的部分，done 才是抽完。
  Future<Map<String, dynamic>> embeddedText(
    String source,
    String path,
    int idx,
  ) => _send(
    'GET',
    '/subs/embedded/text',
    query: {'source': source, 'path': path, 'idx': '$idx'},
    timeout: const Duration(seconds: 90),
  );

  /// 听译服务地址 + 并发上限（旧版设置页「听译服务地址」那一行）
  /// 首页储存卡：磁盘容量 + 当前来源按类型的文件分析（服务端带 6 小时缓存）
  Future<Map<String, dynamic>> storageAnalysis(String source) => _send(
        'GET',
        '/meta/storage/analysis',
        query: {'source': source},
      );

  Future<Map<String, dynamic>> subsConfig() =>
      _send('GET', '/subs/config', timeout: const Duration(seconds: 10));

  /// 同时听译几个（hub 的 max_active）
  Future<Map<String, dynamic>> subsSetMax(int n) => _send(
    'POST',
    '/subs/config',
    body: {'max_active': n},
    timeout: const Duration(seconds: 10),
  );

  /// [since] > 0 时只回这段时间之后新增/改动的字幕（实时听译用，省流量）
  /// 只换译文语言：服务端清旧译文，实时翻译按播放头补新的。
  Future<void> subsLang(String id, String to) => _send(
    'POST',
    '/subs/lang',
    body: {'id': id, 'to': to},
    timeout: const Duration(seconds: 12),
  );

  Future<Map<String, dynamic>> subsDetail(String id, {double since = 0}) =>
      _send(
        'GET',
        '/subs/${Uri.encodeComponent(id)}${since > 0 ? '?since=$since' : ''}',
        timeout: const Duration(seconds: 30),
      );

  /// 把 App 翻好的译文回写到任务里。
  ///
  /// 以前译文只躺在手机缓存里，换设备 / 清缓存 / 任务被删就全没了，
  /// 播放页于是显示「译文 0 句」。写回服务端以后，srt 导出、播放页、
  /// 换一台手机看到的是同一份译文。
  Future<Map<String, dynamic>> subsPushTr(
    String id,
    String lang,
    List<List<Object>> items,
  ) => _send(
    'POST',
    '/subs/tr',
    body: {'id': id, 'lang': lang, 'items': items},
    timeout: const Duration(seconds: 20),
  );

  /// 播放头上报：服务端的「译」只做实时，靠这个位置决定翻哪几句
  Future<void> subsAt(String id, double at) => _send(
    'POST',
    '/subs/at',
    body: {'id': id, 'at': at},
    timeout: const Duration(seconds: 8),
  );

  Future<Map<String, dynamic>> subsDelete(String id) => _send(
    'POST',
    '/subs/delete',
    body: {'id': id},
    timeout: const Duration(seconds: 15),
  );

  Future<Map<String, dynamic>> subsCancel(String id) => _send(
    'POST',
    '/subs/cancel',
    body: {'id': id},
    timeout: const Duration(seconds: 12),
  );

  /// 拖动进度条：让**同一条**实时听任务换起转点（不新建、不排队）。
  /// `skipFrom` = 落点往后第一段没有字幕的位置，服务端从这儿接着转。
  Future<Map<String, dynamic>> subsRelocate(
    String path, {
    String name = '',
    double at = 0,
    double? skipFrom,
    String source = 'nas',
    String lang = 'zh',
    int? track,
    String session = '',
    String hot = '',
    double ahead = 0,
  }) => _send(
    'POST',
    '/subs/relocate',
    body: {
      'path': path,
      'name': name,
      'source': source,
      'at': at,
      'skip_from': skipFrom ?? at,
      'lang': lang,
      if (track != null) 'track': track,
      if (session.isNotEmpty) 'session': session,
      if (hot.isNotEmpty) 'hot': hot,
      if (ahead > 0) 'ahead': ahead,
    },
    timeout: const Duration(seconds: 30),
  );

  /// 播放器开着就每 5 秒打一次：暂停时也算「人还在」，清扫器不会误杀。
  /// 只调预转窗口大小（暂停放大到 600 秒 / 恢复收回默认），**不换起转点**。
  /// 走这条路而不是 relocate：relocate 会 cancel 正在转的窗口，字幕断档几秒。
  Future<Map<String, dynamic>> subsAhead(
    String path, {
    String name = '',
    double ahead = 0,
  }) => _send(
    'POST',
    '/subs/ahead',
    body: {'path': path, 'name': name, 'ahead': ahead},
    timeout: const Duration(seconds: 8),
  );

  Future<Map<String, dynamic>> subsPing(String id) => _send(
    'POST',
    '/subs/ping',
    body: {'id': id},
    timeout: const Duration(seconds: 8),
  );

  /// 退出播放器：立刻结束这条实时听（任务、段落、记录一起清），不等清扫器。
  Future<Map<String, dynamic>> subsEnd(String id, {String session = ''}) =>
      _send(
        'POST',
        '/subs/end',
        body: {'id': id, if (session.isNotEmpty) 'session': session},
        timeout: const Duration(seconds: 12),
      );

  /// 按文件停掉**所有**实时听任务（关闭字幕、退出播放器都用这个）。
  /// 客户端自己记 id 一定会漏 —— 拖动进度条、重进播放器都会另起任务。
  Future<Map<String, dynamic>> subsCancelLive(
    String path, {
    String name = '',
  }) => _send(
    'POST',
    '/subs/cancel_all',
    body: {'path': path, 'name': name},
    timeout: const Duration(seconds: 20),
  );

  Future<Map<String, dynamic>> taskAct(String kind, String id, String act) =>
      _send('POST', '/tasks/act', body: {'kind': kind, 'id': id, 'act': act});

  /// 原始字节上传（PUT body = 文件）。onProgress 回调用于画进度条。
  Future<Map<String, dynamic>> upload(
    String source,
    String dir,
    String name,
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final total = await file.length();
    final req = await _http.openUrl(
      'PUT',
      _uri('/fs/upload', {'source': source, 'path': dir, 'name': name}),
    );
    final h = await _headers();
    h.forEach(req.headers.set);
    req.headers.contentLength = total;
    var sent = 0;
    final stream = file.openRead().transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          sent += chunk.length;
          onProgress?.call(sent, total);
          sink.add(chunk);
        },
      ),
    );
    await req.addStream(stream);
    final res = await req.close();
    final text = await utf8.decoder.bind(res).join();
    if (res.statusCode >= 400) {
      throw ApiError(res.statusCode, _reason(text, res.statusCode));
    }
    return text.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(text) as Map<String, dynamic>;
  }

  /// 掐断正在跑的那一轮（服务端关掉上游连接，不再烧 token）。
  /// 打断和「发新消息」是一回事：不掐断的话上一轮还在后台跑。
  Future<void> chatCancel(String respId, {required String basic}) async {
    if (respId.isEmpty) return;
    final req = await _http.openUrl(
      'GET',
      Uri.parse('$origin/hermes/api/cancel?id=${Uri.encodeQueryComponent(respId)}'),
    );
    req.headers.set('Authorization', 'Basic $basic');
    final resp = await req.close();
    await resp.drain<void>();
  }

  /// 对话附件上传：旧前端的 `POST /hermes/api/upload?name=&kind=`（原始字节体 + Basic）。
  /// 返回服务端落盘路径（`/mnt/g/hermes/云匣文件/<日期>/…`），要拼进消息里给模型看。
  Future<String?> chatUpload(
    File f, {
    required String basic,
    String kind = 'file',
    String? name,
    void Function(double p)? onProgress,
  }) async {
    final fname = (name != null && name.trim().isNotEmpty)
        ? name.trim()
        : (f.uri.pathSegments.isEmpty ? 'upload.bin' : f.uri.pathSegments.last);
    final url = Uri.parse(
      '$origin/hermes/api/upload?name=${Uri.encodeQueryComponent(fname)}&kind=$kind',
    );
    final req = await _http.postUrl(url);
    req.headers.set('Authorization', 'Basic $basic');
    req.headers.contentType = ContentType('application', 'octet-stream');
    final len = await f.length();
    // 和对话一样：不能走 chunked，5007 前置代理不吃
    req.contentLength = len;
    // 自己分块写：addStream 拿不到进度，30MB 大文件用户只能干等
    if (onProgress != null && len > 0) {
      final raf = await f.open();
      try {
        var sent = 0;
        const step = 64 * 1024;
        while (sent < len) {
          final buf = await raf.read(step);
          if (buf.isEmpty) break;
          req.add(buf);
          sent += buf.length;
          onProgress(sent / len);
          try {
            await req.flush();
          } catch (_) {
            /* 对端提前关连接，交给 close 报错 */
          }
        }
      } finally {
        await raf.close();
      }
      onProgress(1);
    } else {
      await req.addStream(f.openRead());
    }
    final resp = await req.close();
    final body = await utf8.decodeStream(resp).catchError((_) => '');
    if (resp.statusCode == 401) throw ApiError(401, '对话口令不对');
    if (resp.statusCode != 200) {
      throw ApiError(
        resp.statusCode,
        body.isEmpty ? 'HTTP ${resp.statusCode}' : body,
      );
    }
    final j = jsonDecode(body);
    return j is Map ? j['path'] as String? : null;
  }

  // ---------- 对话（Hermes 网页对话的 /hermes/api/chat，SSE 流式） ----------

  /// 发一条消息，按事件流逐条返回（response.output_text.delta 等）。
  /// [basic] 是 "hermes:口令" 的 base64，由调用方保存。
  ///
  /// 上下文（previous_response_id）会过期：服务重启、或者隔太久不用，
  /// 服务端会回 502 `Previous response not found`。这时候不带 id 自动重开一次，
  /// 否则用户会看到「每句话都发送失败」，必须退出页面重进才行。
  Stream<Map<String, dynamic>> chatStream({
    required String text,
    required String basic,
    String? prevId,
    void Function(String rid)? onRunId,
  }) async* {
    // 注意：不能用 yield* 包 try/catch —— Dart 里委派流的错误不会进这个 catch，
    // 必须 await for 手动转发，否则「上下文过期自动重开」永远不会触发。
    var attempt = prevId;
    while (true) {
      try {
        await for (final ev in _chatOnce(
          text: text,
          basic: basic,
          prevId: attempt,
          onRunId: onRunId,
        )) {
          yield ev;
        }
        return;
      } on ApiError catch (e) {
        // 前置代理会把上游 404 透成 502，所以三种码都认
        final stale =
            (e.status == 502 || e.status == 404 || e.status == 400) &&
            (e.message.contains('Previous response') ||
                e.message.contains('previous_response') ||
                e.message.contains('previous_response_id'));
        if (stale && attempt != null) {
          attempt = null; // 丢掉过期上下文，重开一轮
          yield {'type': 'hermes.context_reset'};
          continue;
        }
        rethrow;
      }
    }
  }

  Stream<Map<String, dynamic>> _chatOnce({
    required String text,
    required String basic,
    String? prevId,
    void Function(String rid)? onRunId,
  }) async* {
    final req = await _http.postUrl(Uri.parse('$origin/hermes/api/chat'));
    req.headers.set('Authorization', 'Basic $basic');
    req.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    final body = utf8.encode(
      jsonEncode({
        'input': [
          {'type': 'input_text', 'text': text},
        ],
        if (prevId != null && prevId.isNotEmpty) 'previous_response_id': prevId,
      }),
    );
    // 必须显式给 contentLength：不然 Dart 走 chunked，5007 前置代理不吃 chunked，
    // 转过去就是空 body，上游回 400「No user message found in input」——
    // 表现就是「对话怎么发都没反应」。
    req.contentLength = body.length;
    req.add(body);
    final resp = await req.close();
    if (resp.statusCode == 401) {
      await resp.drain<void>();
      throw ApiError(401, '对话口令不对');
    }
    if (resp.statusCode != 200) {
      final body = await utf8.decodeStream(resp).catchError((_) => '');
      throw ApiError(
        resp.statusCode,
        body.isEmpty ? 'HTTP ${resp.statusCode}' : body,
      );
    }
    // 服务端托管这一轮：它给的 run id 就是这条回复的全局 id，
    // 之后断线重连/换设备都只是同步同一条。
    final rid = resp.headers.value('x-run-id');
    if (rid != null && rid.isNotEmpty) onRunId?.call(rid);
    var carry = '';
    await for (final chunk in resp.transform(utf8.decoder)) {
      carry += chunk;
      var nl = carry.indexOf('\n');
      while (nl >= 0) {
        final line = carry.substring(0, nl).trimRight();
        carry = carry.substring(nl + 1);
        nl = carry.indexOf('\n');
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty || payload == '[DONE]') continue;
        try {
          final j = jsonDecode(payload);
          if (j is Map<String, dynamic>) yield j;
        } catch (_) {
          // 半行/坏行直接丢，别把整条消息搞崩
        }
      }
    }
  }
}
