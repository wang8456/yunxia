import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';
import 'session.dart';
import 'transfer.dart';
import 'tokens.dart';

/// 全应用状态（ChangeNotifier，够用且不引依赖）。
class App extends ChangeNotifier {
  final Session session;
  late Api api;

  final Transfers transfers = Transfers();

  /// 由 Shell 注入：下载页点「在云匣打开」时跳过去
  void Function(String src, String path)? onOpenPath;

  /// 设置页改完就调它，把偏好灌进队列
  void applyTransferPrefs() {
    transfers
      ..maxActive = session.dlMaxActive
      ..notifyDone = session.dlNotify;
    transfers.notifyListeners();
  }

  Tone tone = Tokens.blue;
  bool booting = true;
  bool authed = false;
  bool busy = false;
  String? fatal;

  // 当前浏览
  String source = 'nas';
  List<Map<String, dynamic>> sources = const [];

  /// 服务端 /meta/sources 的 chat.enabled：关掉时「对话」入口一律不出现
  bool chatEnabled = false;

  // ---------- 听译（服务端本机转写 + 翻译） ----------

  /// 服务端 /meta/sources 的 subs.enabled：关掉时设置页、文件页、播放器
  /// 都不出现听译入口 —— 界面上不摆按不动的按钮。
  bool subsEnabled = false;

  /// 队列缓存（GET /subs 的 jobs 原样存着）：文件页判「有没有任务」、
  /// 队列页画卡片都读这一份，别各自发请求各说一套。
  List<Map<String, dynamic>> subsJobs = const [];

  /// 转写模型（只读展示）、同时转写几个、依赖与翻译配置
  String subsModel = '';
  int subsMaxActive = 2;
  Map<String, dynamic> subsDeps = const {};
  Map<String, dynamic> subsTranslate = const {};

  /// 拉过一次队列没有（文件页第一次打开操作面板时补一次）
  bool subsLoaded = false;

  /// 队列里正在跑的（排队 / 转写 / 翻译）任务数
  int get subsActive => subsJobs
      .where((j) => const {'queued', 'asr', 'translating'}.contains(j['state']))
      .length;

  /// 这个文件在队列里的任务（null = 还没生成过字幕）
  Map<String, dynamic>? subsJobFor(String src, String p) {
    for (final j in subsJobs) {
      if (j['source'] == src && j['path'] == p) return j;
    }
    return null;
  }

  /// 一次拉全队列。拿不到就返回 false（队列页自己给提示，别在这里弹 toast，
  /// 播放器每 2 秒轮询时不至于刷屏）。
  Future<bool> refreshSubs() async {
    try {
      final r = await api.subsList();
      subsJobs = ((r['jobs'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      subsEnabled = r['enabled'] as bool? ?? subsEnabled;
      subsModel = r['model'] as String? ?? subsModel;
      subsMaxActive = (r['max_active'] as num?)?.toInt() ?? subsMaxActive;
      subsDeps = ((r['deps'] as Map?) ?? const {}).cast<String, dynamic>();
      subsTranslate = ((r['translate'] as Map?) ?? const {}).cast<String, dynamic>();
      subsLoaded = true;
      notifyListeners();
      return true;
    } catch (_) {
      subsLoaded = true;
      return false;
    }
  }

  /// 给这个文件排一个听译任务
  Future<bool> addSubs(Entry e) async {
    if (!canWrite) {
      toast('先去「设置 → 写入口令」填一次');
      return false;
    }
    try {
      await api.subsAdd(
        source,
        e.path,
        name: e.name,
        lang: session.subsLang,
      );
      toast('已加入听译队列');
      await refreshSubs();
      return true;
    } catch (err) {
      toast('排不上听译：$err');
      return false;
    }
  }


  /// 当前源能不能写：115 中转与 webdav 只有读接口
  bool get writable =>
      (sources.firstWhere(
        (s) => s['id'] == source,
        orElse: () => const {'writable': true},
      )['writable']) ==
      true;

  String path = '/';
  Listing? listing;
  List<Entry> entries = const [];
  String sort = 'name';
  String order = 'asc';
  bool allowUpload = false;
  bool allowDelete = false;

  // 轻提示
  String? toastText;
  Timer? _toastTimer;

  /// [apiOverride] 可注入 —— 黄金截图测试用它喂假数据，不碰网络。
  App(this.session, {Api? apiOverride}) {
    // 排序偏好跟着会话走：上次按什么排的，这次打开还是它
    sort = session.fileSort;
    order = session.fileOrder;
    tone = Tokens.byId(session.toneId);
    api = apiOverride ?? (Api(session.server)..token = session.token);
  }

  // ---------- 启动 / 登录 ----------

  /// 候选地址：开源版留空 —— 不预置任何人的服务器。
  /// 想让它启动时自动试几个地址，就在这里加（顺序就是尝试顺序，第一个通的留下）。
  static const serverCandidates = <String>[];

  /// 只发一次 GET /，2.5 秒内没回应就当不通
  Future<bool> reachable(String url) async {
    final c = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 2500)
      ..idleTimeout = const Duration(seconds: 3)
      ..badCertificateCallback = (_, _, _) => true;
    try {
      final req = await c.getUrl(Uri.parse('$url/'));
      final res = await req.close().timeout(const Duration(seconds: 4));
      await res.drain<void>();
      return res.statusCode > 0;
    } catch (_) {
      return false;
    } finally {
      c.close(force: true);
    }
  }

  /// 当前地址不通就沿着候选表换一个；换了会写进 Session
  Future<bool> autoPickServer() async {
    if (await reachable(api.server)) return true;
    for (final u in serverCandidates) {
      if (u == api.server) continue;
      if (await reachable(u)) {
        await changeServer(u);
        return true;
      }
    }
    return false;
  }

  Future<void> boot() async {
    // 还没填服务器地址（开源版第一次启动）：不去连网络，界面直接停在「填地址」那一屏
    if (api.server.trim().isEmpty) {
      booting = false;
      fatal = null;
      notifyListeners();
      return;
    }
    booting = true;
    // 网络慢、或者人在外面（4G，探测 LAN 地址要等超时）时别把人卡在启动页：
    // 5 秒还没好就先放行，数据后台继续补，补上了界面会自己刷新。
    final guard = Timer(const Duration(seconds: 5), () {
      if (booting) {
        booting = false;
        notifyListeners();
      }
    });
    applyTransferPrefs();
    transfers.onDone = (m) => toast(m);
    // 下载队列要能跨进程活着：不解这一句，杀掉 App 再打开记录就全没了（文件还在手机里）
    transfers.bind(api);
    await transfers.load();
    notifyListeners();
    try {
      await autoPickServer();
      // 没有令牌也照常进来：文件能看能播（服务端只读接口不验令牌），
      // 只有写操作和对话才要口令 —— 口令在设置里填一次。
      if (api.token != null) {
        try {
          final me = await api.get('/auth/me');
          session.device = me['device'] as String? ?? session.device;
          authed = true;
        } on ApiError catch (e) {
          if (!e.isAuth) rethrow;
          await session.clear();
          api.token = null;
          authed = false;
        }
        // 令牌在、对话口令空了（老版本存的，或以前在对话页点过头像断开）：
        // 保留写权限，设置页会显示「对话口令缺失，点这里重填」，不让两边说法打架
      } else {
        authed = false;
      }
      await loadSources();
      await open('/');
      fatal = null;
    } on ApiError catch (e) {
      if (e.isAuth) {
        await session.clear();
        api.token = null;
        authed = false;
        fatal = null;
      } else {
        fatal = e.message;
      }
    } catch (e) {
      // 可能是换了网段：换地址再试最后一次
      final before = api.server;
      if (await autoPickServer() && api.server != before && api.token != null) {
        try {
          await api.get('/auth/me');
          authed = true;
          await loadSources();
          await open('/');
          fatal = null;
        } catch (e2) {
          fatal = '连不上服务器：$e2';
        }
      } else {
        fatal = '连不上 ${api.server}：$e';
      }
    } finally {
      guard.cancel();
      booting = false;
      notifyListeners();
    }
  }

  /// 能改东西吗：没填口令就是只读模式
  bool get canWrite => authed && api.token != null;

  Future<bool> login(String password) async {
    busy = true;
    notifyListeners();
    try {
      await autoPickServer();
      final r = await api.login(password, session.device);
      api.token = r['token'] as String?;
      session.token = api.token;
      // 同一个口令也给对话用：/hermes/api/chat 要的是 Basic hermes:口令
      session.chatBasic = base64Encode(utf8.encode('hermes:$password'));
      await session.save();
      authed = true;
      fatal = null;
      await open('/');
      toast('已连接');
      return true;
    } on ApiError catch (e) {
      fatal = e.message;
      return false;
    } catch (e) {
      fatal = '连不上服务器：$e';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await session.clear();
    api.token = null;
    session.chatBasic = '';
    authed = false;
    // 不清 entries / 不复位路径：退回只读模式，还能接着看
    notifyListeners();
  }

  Future<void> changeServer(String server) async {
    session.server = server;
    api.server = server;
    await session.save();
    notifyListeners();
  }

  // ---------- 主题 ----------

  void setTone(Tone t) {
    tone = t;
    session.toneId = t.id;
    session.save();
    notifyListeners();
  }

  // ---------- 目录 ----------

  /// 目录缓存：源|路径|排序，2 分钟内重进同一个目录直接就位。
  /// 进文件夹不再「卡一下」——有缓存立刻铺内容，没有缓存至少先把旧内容清掉、
  /// 让骨架屏顶上来，用户知道在加载，而不是界面冻住。
  final _cache = <String, (Listing, DateTime)>{};
  /// 每次 open 递增。切源/连点目录时会有多个请求在飞，
  /// 只有最后发出的那个允许改 entries / busy（旧实现是「谁慢谁说话」，
  /// 切源后偶尔会出现旧源的列表盖上来、或者列表空白一直不转圈）。
  int _gen = 0;
  String _ck(String p) => '$source|$p|$sort|$order';

  /// 增删改名之后调它，别让缓存的旧列表骗人

  Future<void> open(String p, {String? src}) async {
    final gen = ++_gen;
    path = p.isEmpty ? '/' : p;
    if (src != null) source = src;
    final key = _ck(path);
    final hit = _cache[key];
    final fresh =
        hit != null && DateTime.now().difference(hit.$2).inSeconds < 120;
    if (hit != null) {
      // 先把缓存铺上去，界面立刻有内容
      listing = hit.$1;
      entries = hit.$1.entries;
      allowUpload = hit.$1.allowUpload;
      allowDelete = hit.$1.allowDelete;
      fatal = null;
    } else {
      entries = const []; // 没缓存就清空，让骨架屏出现
    }
    busy = !fresh && hit == null; // 有缓存时不当成「正在打开」
    notifyListeners();
    try {
      final r = await api.list(source, path, sort: sort, order: order);
      final ls = Listing.fromJson(r);
      _cache[key] = (ls, DateTime.now());
      // 期间用户可能已经进了别的目录 / 换了源，别把旧结果盖上去
      if (gen != _gen || _ck(path) != key) return;
      listing = ls;
      entries = ls.entries;
      allowUpload = ls.allowUpload;
      allowDelete = ls.allowDelete;
      fatal = null;
    } on ApiError catch (e) {
      if (gen != _gen) return;
      if (e.isAuth) {
        authed = false;
      }
      if (hit == null) {
        toast(e.message);
        entries = const [];
      }
    } catch (e) {
      if (gen != _gen) return;
      if (hit == null) toast('打开失败：$e');
    } finally {
      if (gen == _gen) {
        busy = false;
        notifyListeners();
      }
    }
  }

  /// 强制重拉当前目录：增删改名/上传之后走这条，
  /// 先把缓存这条删掉，否则 refresh 会把旧列表当成新内容直接铺出来。
  Future<void> refresh() {
    _cache.remove(_ck(path));
    return open(path, src: source);
  }

  /// 拉一次源列表（nas / 115 / 电脑）。拿不到就当只有 nas，不影响用。
  Future<void> loadSources() async {
    try {
      final r = await api.sources();
      sources = ((r['sources'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      final chat = r['chat'];
      chatEnabled = chat is Map && chat['enabled'] == true;
      // 听译：/meta/sources 的 subs:{enabled,model}。关掉就整块不出现。
      final subs = r['subs'];
      subsEnabled = subs is Map && subs['enabled'] == true;
      if (subs is Map) {
        final m = subs['model'];
        if (m is String && m.isNotEmpty) subsModel = m;
      }
      final def = r['default'] as String?;
      if (sources.isNotEmpty && !sources.any((s) => s['id'] == source)) {
        source = def ?? sources.first['id'] as String;
      }
    } catch (_) {
      sources = const [];
      chatEnabled = false;
      subsEnabled = false;
    }
    notifyListeners();
  }

  /// 切源：回到根目录重新列。
  /// 旧列表必须当场清掉——否则新源还在加载时，屏幕上挂着上一个源的文件夹，
  /// 标题却已经是新源了，看着就是「列表乱了」。
  Future<void> switchSource(String id) async {
    if (id == source) return;
    source = id;
    path = '/';
    listing = null;
    entries = const [];
    allowUpload = false;
    allowDelete = false;
    fatal = null;
    busy = true;
    notifyListeners();
    await open('/');
  }

  void setSort(String s) {
    if (sort == s) {
      order = order == 'asc' ? 'desc' : 'asc';
    } else {
      sort = s;
      order = 'asc';
    }
    // 记住这一选择（写进本地会话文件，重开 App 生效）
    session.fileSort = sort;
    session.fileOrder = order;
    session.save();
    refresh();
  }

  // ---------- 写操作 ----------

  Future<bool> mkdir(String name) async {
    if (!canWrite) {
      toast('先去「设置 → 写入口令」填一次');
      return false;
    }
    try {
      await api.mkdir(source, path, name);
      toast('已创建 $name');
      await refresh();
      return true;
    } catch (e) {
      toast('创建失败：$e');
      return false;
    }
  }

  Future<bool> rename(Entry e, String newName) async {
    if (!canWrite) {
      toast('先去「设置 → 写入口令」填一次');
      return false;
    }
    final base = path == '/' ? '' : path;
    final dst = '$base/$newName';
    try {
      await api.move(source, e.path, dst);
      toast('已改名');
      await refresh();
      return true;
    } catch (err) {
      toast('改名失败：$err');
      return false;
    }
  }

  Future<bool> remove(Entry e) async {
    try {
      await api.remove(source, [e.path]);
      toast('已删除 ${e.name}');
      await refresh();
      return true;
    } catch (err) {
      toast('删除失败：$err');
      return false;
    }
  }

  /// 批量删除（多选后一次提交）
  Future<bool> removeMany(List<Entry> items) async {
    if (!canWrite) {
      toast('先去「设置 → 写入口令」填一次');
      return false;
    }
    if (items.isEmpty) return false;
    try {
      await api.remove(source, items.map((e) => e.path).toList());
      toast('已删除 ${items.length} 项');
      await refresh();
      return true;
    } catch (err) {
      toast('删除失败：$err');
      return false;
    }
  }

  /// 移到另一个目录（服务端 /fs/move）
  Future<bool> moveEntry(Entry e, String dstDir) async {
    if (!canWrite) {
      toast('先去「设置 → 写入口令」填一次');
      return false;
    }
    final dst = dstDir.endsWith('/') ? dstDir : '$dstDir/';
    final target = '$dst${e.name}';
    if (target == e.path) return false;
    try {
      await api.move(source, e.path, target);
      toast('已移到 $dstDir');
      await refresh();
      return true;
    } catch (err) {
      toast('移动失败：$err');
      return false;
    }
  }

  Future<String?> linkOf(Entry e) async {
    try {
      final r = await api.link(source, e.path);
      return api.absolute(r['url'] as String);
    } catch (err) {
      toast('取下载地址失败：$err');
      return null;
    }
  }

  Future<void> uploadFiles(List<File> files) async {
    if (!canWrite) {
      toast('先去「设置 → 写入口令」填一次');
      return;
    }
    if (!allowUpload) {
      toast('这个来源是只读的，传不上去');
      return;
    }
    if (files.isEmpty) return;
    await transfers.uploadMany(api, source, path, files);
    // 只看这一批（items 是新的在前）：以前按全部历史算，昨天的失败下载也会被算进来
    final batch = transfers.items.take(files.length).toList();
    final bad = batch.where((t) => t.state == 'error').toList();
    if (bad.isEmpty) {
      toast('上传完成 ${files.length} 个文件');
    } else {
      final why = (bad.first.error ?? '').replaceAll('ApiError', '').trim();
      toast('${bad.length} 个文件上传失败${why.isEmpty ? '' : '：$why'}');
    }
    await refresh();
  }

  /// 下载单个文件：进队列，进度在下载页看（旧版一点就下，这里排队但更快）
  Future<void> downloadEntry(Entry e) async {
    transfers.enqueue(api, source, e);
    toast('已加入下载队列：${e.name}');
  }

  // ---------- 显示方式（列表 / 网格，存本地会话） ----------

  bool get gridMode => session.gridMode;

  void setGridMode(bool v) {
    session.gridMode = v;
    session.save();
    notifyListeners();
  }

  // ---------- 收藏（首页那一栏，存本地会话） ----------

  List<Map<String, dynamic>> get favorites => session.favorites;

  bool isFav(String path) => favorites.any((f) => f['path'] == path);

  void toggleFavorite(String src, String path, String name) {
    final list = favorites.toList();
    final i = list.indexWhere((f) => f['path'] == path);
    if (i >= 0) {
      list.removeAt(i);
      toast('已取消收藏');
    } else {
      list.insert(0, {'src': src, 'path': path, 'name': name});
      toast('已收藏到首页');
    }
    session.favorites = list;
    session.save();
    notifyListeners();
  }

  Future<void> removeFavorite(String path) async {
    session.favorites = favorites.where((f) => f['path'] != path).toList();
    await session.save();
    notifyListeners();
  }

  // ---------- 轻提示 ----------

  void toast(String text) {
    toastText = text;
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 2200), () {
      toastText = null;
      notifyListeners();
    });
    notifyListeners();
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    super.dispose();
  }
}
