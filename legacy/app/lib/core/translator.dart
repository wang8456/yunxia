import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'langs.dart';

/// 翻译源：**听**（转写）还在 NAS 上跑，**译**全在 App 里跑。
///
/// 以前译是 NAS 调 DeepSeek 做的（hub 的翻译线程 + `/tr` 接口，密钥在 NAS 的
/// .env 里）。现在改成 App 自己直连：用户在「设置 → 翻译源」里选源、填模型和
/// 密钥，翻译不经过服务器，也不花服务器的额度。
///
/// 兼容 OpenAI 的 `/chat/completions`：DeepSeek 是预设，另外允许自定义地址，
/// 所以硅基流动、月之暗面、自己搭的 one-api 都能直接填。
class TrSource {
  TrSource({
    this.provider = deepseek,
    this.base = '',
    this.model = '',
    this.key = '',
  });

  /// App 里只有这一份：启动时从 Session 灌进来，设置里改完立刻同步回去。
  static final TrSource current = TrSource();

  static const String deepseek = 'deepseek';
  static const String custom = 'custom';

  /// 预设地址（选 DeepSeek 时不用填）
  static const Map<String, String> presets = {
    deepseek: 'https://api.deepseek.com',
  };

  static const String defaultModel = 'deepseek-flash';

  /// 里常用的几个，做成快捷选项，不给用户背模型名
  static const List<String> deepseekModels = [
    'deepseek-flash',
    'deepseek-chat',
    'deepseek-reasoner',
  ];

  String provider;

  /// 自定义源的根地址，例如 `https://api.siliconflow.cn/v1`
  String base;
  String model;
  String key;

  bool get ready => key.trim().isNotEmpty;

  bool get isCustom => provider == custom;

  String get providerName => isCustom ? '自定义' : 'DeepSeek';

  String get shownModel => model.trim().isEmpty ? defaultModel : model.trim();

  String get shownBase =>
      isCustom ? (base.trim().isEmpty ? '还没填地址' : base.trim()) : presets[deepseek]!;

  /// 拼 chat/completions 地址。用户填的东西三种都可能：
  /// `https://api.deepseek.com`、`…/v1`、整条 `…/v1/chat/completions`。
  String get endpoint {
    var b = (isCustom ? base.trim() : presets[deepseek]!).trim();
    if (b.isEmpty) b = presets[deepseek]!;
    if (!b.startsWith('http://') && !b.startsWith('https://')) {
      b = 'https://$b';
    }
    if (b.endsWith('/chat/completions')) return b;
    b = b.replaceAll(RegExp(r'/+$'), '');
    final path = Uri.tryParse(b)?.path ?? '';
    // 只给了域名 → 补 /v1；已经带路径（/v1、/openai/v1 …）就直接接上
    if (path.isEmpty || path == '/') return '$b/v1/chat/completions';
    return '$b/chat/completions';
  }

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'base': base,
    'model': model,
    'key': key,
  };

  void apply(Map<String, dynamic> j) {
    provider = (j['provider'] as String?)?.trim().isNotEmpty == true
        ? j['provider'] as String
        : deepseek;
    base = (j['base'] as String?) ?? '';
    model = (j['model'] as String?) ?? '';
    key = (j['key'] as String?) ?? '';
  }

  /// 密钥只露头尾：设置页里不会把整串摊在屏幕上
  String get maskedKey {
    final k = key.trim();
    if (k.isEmpty) return '';
    if (k.length <= 10) return '${k.substring(0, 2)}••••';
    return '${k.substring(0, 6)}••••${k.substring(k.length - 4)}';
  }
}

/// 翻译源报出来的错（能直接显示给用户）
class TrError implements Exception {
  TrError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// App 内置翻译器。
///
/// 三件事必须守住：
/// 1. **一行进一行出**——译文错位比没译文更糟，条数对不上就重来、再不行逐句翻；
/// 2. 同一句不重复花钱（进程内缓存，按 模型+语言+原文 命中）；
/// 3. 不给用户看天书——所有失败都抛 [TrError]，消息是中文人话。
class Translator {
  /// 测试注入：给定 url/key/body 返回模型回复的正文
  static Future<String> Function(String url, String key, String body)? post;

  /// 也许以后要在设置里给「自定义请求头」，先留个钩子
  static Map<String, String> extraHeaders = const {};

  static final Map<String, String> _cache = {};
  static const int _cacheMax = 4000;

  static int get cacheSize => _cache.length;

  static void clearCache() => _cache.clear();

  /// 翻一组字幕。返回的数组与输入等长（空行原样空串，不会挪位）。
  static Future<List<String>> translate(
    List<String> lines,
    String to, {
    TrSource? source,
  }) async {
    final src = source ?? TrSource.current;
    final out = List<String>.filled(lines.length, '');
    if (lines.isEmpty) return out;
    if (!src.ready) throw TrError('还没配置翻译源（设置 → 翻译源 · 填 API 密钥）');

    final todo = <int>[];
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.isEmpty) continue;
      final hit = _cache[_ck(src, to, t)];
      if (hit != null) {
        out[i] = hit;
        continue;
      }
      todo.add(i);
    }
    if (todo.isEmpty) return out;

    final texts = [for (final i in todo) lines[i].trim()];
    var res = await _ask(src, texts, to);
    if (res.length != texts.length) {
      // 模型合并/拆分了句子：换成 JSON 数组再要一次
      res = await _ask(src, texts, to, json: true);
    }
    if (res.length != texts.length) {
      // 还对不上就逐句翻 —— 慢一点，但绝不会把译文挪到别人身上
      final one = <String>[];
      for (final t in texts) {
        final r = await _ask(src, [t], to);
        one.add(r.isEmpty ? '' : r.first);
      }
      res = one;
    }

    for (var k = 0; k < todo.length; k++) {
      final t = k < res.length ? res[k].trim() : '';
      if (t.isEmpty) continue;
      out[todo[k]] = t;
      if (_cache.length < _cacheMax) _cache[_ck(src, to, texts[k])] = t;
    }
    return out;
  }

  /// 设置页的「测试」按钮：真发一句，回来告诉用户通没通
  static Future<String> test(TrSource src) async {
    final src2 = TrSource(
      provider: src.provider,
      base: src.base,
      model: src.model,
      key: src.key,
    );
    if (!src2.ready) throw TrError('先填 API 密钥');
    final r = await _ask(src2, ['It works.', 'Nice to meet you.'], 'zh');
    if (r.isEmpty) throw TrError('翻译源没有返回内容');
    return r.join(' / ');
  }

  static String _ck(TrSource s, String to, String text) =>
      '${s.provider}|${s.shownModel}|$to|$text';

  static Future<List<String>> _ask(
    TrSource src,
    List<String> texts,
    String to, {
    bool json = false,
  }) async {
    final lang = subLangName(to);
    final sys = json
        ? '你是字幕翻译器。把输入里的每条字幕译成$lang，只输出 JSON：'
              '{"lines":["译文1","译文2"]}。条数和顺序必须与输入完全一致：'
              '一行对一条，不合并、不拆分、不加解释。'
        : '你是字幕翻译器。把下面每一行字幕译成$lang。'
              '严格一行对一行：输入几行就输出几行，顺序不变；'
              '不要合并、不要拆分、不要编号、不要解释、不要加引号。只输出译文。';
    final user = json ? jsonEncode({'lines': texts}) : texts.join('\n');
    final body = jsonEncode({
      'model': src.shownModel,
      'temperature': 0.2,
      'stream': false,
      'messages': [
        {'role': 'system', 'content': sys},
        {'role': 'user', 'content': user},
      ],
    });

    final content = await (post?.call(src.endpoint, src.key, body) ??
        _httpPost(src.endpoint, src.key, body));

    if (json) {
      final got = _fromJson(content);
      if (got != null) return got;
    }
    return _splitLines(content);
  }

  static List<String>? _fromJson(String raw) {
    try {
      final t = _stripFence(raw).trim();
      final i = t.indexOf('{');
      final j = t.lastIndexOf('}');
      if (i < 0 || j <= i) return null;
      final d = jsonDecode(t.substring(i, j + 1));
      final arr = d is Map ? (d['lines'] ?? d['segments']) : d;
      if (arr is! List) return null;
      return arr.map((e) => e.toString().trim()).toList();
    } catch (_) {
      return null;
    }
  }

  static String _stripFence(String s) {
    var t = s.trim();
    if (t.startsWith('```')) {
      final nl = t.indexOf('\n');
      if (nl > 0) t = t.substring(nl + 1);
      if (t.endsWith('```')) t = t.substring(0, t.length - 3);
    }
    return t.trim();
  }

  static List<String> _splitLines(String raw) => _stripFence(raw)
      .split('\n')
      .map((e) => e.replaceFirst(RegExp(r'^\s*\d+\s*[.、)）]\s*'), '').trim())
      .where((e) => e.isNotEmpty)
      .toList();

  static HttpClient? _hcKeep;

  static HttpClient get _hc => _hcKeep ??= (HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 6);

  static Future<String> _httpPost(String url, String key, String body) async {
    try {
      return await _postOnce(url, key, body);
    } on StateError {
      // 复用的连接池被关掉了（老版本在 finally 里 close 了共享 client）：
      // 重建一次再来，别让用户看到「Bad state: Client is closed」。
      _hcKeep = null;
      return _postOnce(url, key, body);
    }
  }

  static Future<String> _postOnce(String url, String key, String body) async {
    // 复用同一个 HttpClient：以前每批都新建一个，等于每个请求都重新做一次
    // TCP + TLS 握手（对 api.deepseek.com 是 200–400ms），批越碎这笔开销越
    // 显眼 —— 用户体感就是「翻译变慢了」。长连接之后只有第一批付这个代价。
    final client = _hc;
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType.json;
      req.headers.set('Authorization', 'Bearer ${key.trim()}');
      for (final e in extraHeaders.entries) {
        req.headers.set(e.key, e.value);
      }
      req.add(utf8.encode(body));
      final resp = await req.close().timeout(const Duration(seconds: 40));
      final raw = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        throw TrError('翻译源返回 ${resp.statusCode}：${_errText(raw)}');
      }
      final j = jsonDecode(raw);
      final ch = (j is Map ? j['choices'] : null) as List?;
      if (ch == null || ch.isEmpty) throw TrError('翻译源没有返回译文');
      final msg = (ch.first as Map)['message'];
      final content = (msg is Map ? msg['content'] : null)?.toString() ?? '';
      if (content.trim().isEmpty) throw TrError('翻译源返回空内容');
      return content;
    } on TrError {
      rethrow;
    } on SocketException {
      throw TrError('连不上翻译源：检查网络或地址');
    } on HandshakeException {
      throw TrError('翻译源证书有问题（https 握手失败）');
    } on TimeoutException {
      throw TrError('翻译源超时（40 秒没回）');
    } on FormatException {
      throw TrError('翻译源返回的不是 JSON（地址可能填错了）');
    }
    // 这里**不能** close：这是全局复用的长连接 client。
    // 以前每批结束都 close(force: true)，第一批之后就一直是「已关闭」状态，
    // 第二批复用就抛 Bad state: Client is closed —— 测试按钮直接红字。
  }

  static String _errText(String raw) {
    final t = raw.trim();
    try {
      final j = jsonDecode(t);
      if (j is Map) {
        final e = j['error'];
        if (e is Map && e['message'] != null) return e['message'].toString();
        if (e != null) return e.toString();
        if (j['message'] != null) return j['message'].toString();
      }
    } catch (_) {}
    if (t.isEmpty) return '没有说明';
    return t.length > 160 ? '${t.substring(0, 160)}…' : t;
  }
}
