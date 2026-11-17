/* ============================================================
   dufs 网页界面 —— 按 mobile_file_manager.html 的设计稿实现
   界面：设计稿原样（顶栏/搜索/目录卡/分类/文件夹卡/文件列表/
         底部导航/FAB/Toast/底部弹窗）
   功能：全部接到 dufs 真实数据与真实操作上 ——
         浏览目录、分类筛选、对话、排序、搜索、图片查看器、
         上传（带进度）、新建文件夹、重命名、删除、复制链接、登录
   ============================================================ */
(function () {
  'use strict';

  var $ = function (s, r) { return (r || document).querySelector(s); };
  /* 图标：Hugeicons 内联 SVG（icons.js 里的 ic()）。取不到就留空，绝不让界面抛错 */
  function icn(name, size) {
    try { return (typeof ic === 'function') ? ic(name, size) : ''; } catch (e) { return ''; }
  }
  function srcIco(s) {                       // 来源图标：sources.json 里可以写槽位名，也兼容老的 emoji
    var k = String((s && s.icon) || '');
    var m = { '🗄️': 'src-nas', '🟦': 'src-cloud', '💻': 'src-pc', 'Nas': 'src-nas' };
    var key = (typeof ICO !== 'undefined' && ICO[k]) ? k : (m[k] || 'type-folder');
    return icn(key, 22);
  }
  var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };
  function dec(b64) {
    var bin = atob(b64), bytes = new Uint8Array(bin.length), i;
    for (i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new TextDecoder().decode(bytes);
  }
  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function fmt(n) {
    if (n === null || n === undefined || n < 0) return '—';
    if (n < 1024) return n + ' B';
    if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
    if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB';
    return (n / 1073741824).toFixed(2) + ' GB';
  }
  function pad(x) { return x < 10 ? '0' + x : '' + x; }
  function dayOf(ms) {
    if (!ms) return '—';
    var d = new Date(ms);
    return pad(d.getMonth() + 1) + '/' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }
  function ext(n) { return (String(n).split('.').pop() || '').toLowerCase(); }
  function encPath(p) { return String(p).split('/').map(encodeURIComponent).join('/'); }

  /* ---------------- 数据 ---------------- */
  var DATA = null;
  try { DATA = JSON.parse(dec($('#index-data').innerHTML)); } catch (e) { return; }
  if (DATA.kind !== 'Index') return;

  var BASE = location.href.split(/[?#]/)[0];
  if (!/\/$/.test(BASE)) BASE += '/';
  var ROOT = location.origin + '/';
  var Q = safeDecode((location.search.match(/[?&]q=([^&]*)/) || [])[1] || '').replace(/\+/g, ' ');

  // 资源目录（tree.json / list/*.json 就放在这里）
  var ASSETS = (function () {
    var u = (document.currentScript && document.currentScript.src) || '';
    if (!u) {
      var l = document.querySelector('link[href*="index.css"]');
      u = l ? l.href : location.href;
    }
    return u.replace(/[^/]*(\?[^/]*)?$/, '');
  })();

  // 整个共享库的统计（电脑侧 统计.py 定期写进 assets\tree.json）
  var SOURCES = null;          // assets/sources.json：储存来源清单
  // 共享库根地址：全库分类浏览里的文件要靠它拼出可点的链接
  var ROOTURL = (function () {
    var pfx = String((typeof DATA !== 'undefined' && DATA.uri_prefix) || '/');
    if (pfx.charAt(0) !== '/') pfx = '/' + pfx;
    if (pfx.slice(-1) !== '/') pfx += '/';
    return location.origin + pfx;
  })();
  // 列表当前渲染的是哪一组数据（本地目录 ITEMS / 远程来源的条目）
  var CUR = [];
  // 上一次真正渲染出来的列表（过滤/排序之后）—— 图片查看器和视频播放器按它翻页
  var LAST_SHOWN = [];

  /* ---------------- 登录（HTTP Basic，凭据只存在这台手机上） ----------------
     dufs 官方登录是 fetch(..., {method:'CHECKAUTH'}) 等浏览器弹系统账号密码框：
     Chrome 会弹（但会打断页面），Safari 对 fetch 的 401 根本不弹 —— 不可靠。
     这里自己存凭据、自己带 Authorization；验证就是「拿凭据请求一次目录 JSON」，
     服务端认了会返回 user=admin + allow_upload=true，不认就是 401。 */
  /* ---------------- 外观主题 ----------------
     主流配色（每套都取自原项目官方色板）：默认蓝 + 4 套浅色 + 5 套深色。
     只改 <html data-theme>，样式全在 theme.css 末尾的主题层里。 */
  var THEMES = [
    { id: 'light', n: '浅色', d: '白灰底 · 石墨黑', bg: '#f2f3f5', sf: '#ffffff', ac: '#3a3a3c' },
    { id: 'dark', n: '深色', d: '夜间用 · 不刺眼', bg: '#121417', sf: '#1a1d21', ac: '#4c9aff' },
    { id: '', n: '蓝色', d: '默认 · 清亮', bg: '#f4f7fc', sf: '#ffffff', ac: '#1677f8' },
    { id: 'green', n: '绿色', d: '护目绿 · 偏冷', bg: '#f2f9f4', sf: '#ffffff', ac: '#16a34a' },
    { id: 'sepia', n: '护眼', d: '暖米色 · 少蓝光', bg: '#f4efe3', sf: '#fbf7ee', ac: '#b07d3a' }
  ];
  var THEME_OLD = {   // 上一版 9 套的 id → 现在归到哪一套
    'github-light': 'light', 'notion': 'light', 'solarized': 'sepia', 'latte': 'light',
    'github-dark': 'dark', 'nord': 'dark', 'dracula': 'dark', 'tokyo-night': 'dark', 'mocha': 'dark'
  };
  function themeName(id) {
    var t = THEMES.filter(function (x) { return x.id === id; })[0];
    return t ? t.n : '蓝色';
  }
  function themeNow() {
    var v = '';
    try { v = localStorage.getItem('mfm_theme') || ''; } catch (e) { return ''; }
    if (v && THEME_OLD[v]) {                 // 老版本存下的主题名，自动归到新的一套
      v = THEME_OLD[v];
      try { localStorage.setItem('mfm_theme', v); } catch (e) { }
      if (v) document.documentElement.setAttribute('data-theme', v);
      else document.documentElement.removeAttribute('data-theme');
    }
    return v;
  }
  function applyTheme(id) {
    try {
      if (id) document.documentElement.setAttribute('data-theme', id);
      else document.documentElement.removeAttribute('data-theme');
      localStorage.setItem('mfm_theme', id || '');
    } catch (e) { }
  }
  function themeSheet() {
    var cur = themeNow();
    sheet('主题', THEMES.map(function (t) {
      return '<button class="row th-row' + (t.id === cur ? ' on' : '') + '" data-act="themeset" data-val="' + t.id + '">' +
        '<span class="ico th-sw"><i style="background:' + t.bg + '"></i>' +
        '<i class="ac" style="background:' + t.ac + '"></i></span>' +
        '<span>' + t.n + '</span>' +
        '<span class="sub">' + (t.id === cur ? '✓ 当前' : esc(t.d)) + '</span></button>';
    }).join('') + row('×', '取消', 'cancel'));
  }

  /* 每个储存来源各自一套凭据：本机沿用 mfm_auth，其它来源存在 mfm_authmap 里。
     来源之间账号互不通用（NAS 的 admin 在电脑那份 dufs 上是无效的），所以必须分开存。 */
  var AUTHMAP = {};
  try { AUTHMAP = JSON.parse(localStorage.getItem('mfm_authmap') || '{}') || {}; } catch (e) { AUTHMAP = {}; }
  function saveAuthMap() { try { localStorage.setItem('mfm_authmap', JSON.stringify(AUTHMAP)); } catch (e) { } }
  function srcById(id) {
    var arr = (SOURCES && SOURCES.sources) || [];
    for (var i = 0; i < arr.length; i++) if (arr[i].id === id) return arr[i];
    return null;
  }
  function srcAuth(id) {
    if (!id || id === 'nas') return AUTH;
    return AUTHMAP[id] || '';
  }
  function setSrcAuth(id, h) {
    if (!id || id === 'nas') {
      AUTH = h || '';
      try { h ? localStorage.setItem('mfm_auth', h) : localStorage.removeItem('mfm_auth'); } catch (e) { }
      return;
    }
    if (h) AUTHMAP[id] = h; else delete AUTHMAP[id];
    saveAuthMap();
  }
  function userOf(h) {
    try {
      var s2 = decodeURIComponent(escape(atob(h)));        // base64 → utf8
      return s2.split(':')[0] || '';
    } catch (e) { return ''; }
  }
  function authHeadersFor(id, extra) {
    var h = extra || {};
    var a = srcAuth(id);
    if (a) h.Authorization = 'Basic ' + a;
    return h;
  }
  /* 当前这个目录能不能写：本机看服务端返回的 allow_upload，
     远程 dufs 看这个来源有没有登录过（dufs 的匿名是只读） */
  function canWrite() {
    if (isRemoteDufs()) return !!srcAuth((activeSrc() || {}).id);
    if (isDav()) return false;
    return CAN_WRITE;
  }

  var AUTH = '';
  try { AUTH = localStorage.getItem('mfm_auth') || ''; } catch (e) { }
  function authHeaders(extra) { return authHeadersFor('nas', extra); }
  function b64(s) {
    try { return btoa(unescape(encodeURIComponent(s))); } catch (e) { return ''; }
  }
  function fetchListing(headers) {
    return fetch(BASE + '?json', { cache: 'no-store', credentials: 'omit', headers: headers || authHeaders() })
      .then(function (r) {
        if (!r.ok) {
          throw new Error(r.status === 401 || r.status === 403
            ? '用户名或密码不对（服务端说 ' + r.status + '）'
            : '取目录失败：服务端返回 ' + r.status);
        }
        return r.json();
      });
  }
  function applyListing(d) {           // 用服务端最新的一份目录数据重建列表和权限
    DATA = d;
    ITEMS = (DATA.paths || []).map(function (p) {
      var isDir = String(p.path_type).indexOf('Dir') >= 0;
      return {
        name: p.name, isDir: isDir, size: p.size, mtime: p.mtime,
        kind: kindOf(p.name, isDir),
        url: BASE + p.name.split('/').map(encodeURIComponent).join('/') + (isDir ? '/' : '')
      };
    });
    CAN_WRITE = !!DATA.allow_upload;
    CAN_DELETE = !!(DATA.allow_upload && DATA.allow_delete);
    render();
    return d;
  }
  function refreshListing() {          // 启动/登录/退出后：把权限和用户名重新拉一遍
    return fetchListing().then(applyListing)['catch'](function (err) {
      // 存在手机上那份凭据失效了（比如 NAS 上改了密码）：别再每次加载都拿它去撞 401
      if (AUTH && /401|403/.test(String(err && err.message))) {
        AUTH = '';
        try { localStorage.removeItem('mfm_auth'); } catch (e) { }
        toast('保存的登录已失效，已恢复匿名只读');
      }
      return false;
    });
  }

  /* ---------------- 本地目录的「软打开」 ----------------
     CloudFS（CloudDrive 挂 115）上，列一个目录要 30-50 秒：每个条目的 metadata 都是一次网络
     往返。整页跳转（location.href）在这段时间里页面一动不动，用户只看到自己在等的那个旧画面。
     所以本地目录改成软打开：立刻画骨架 + 「已等待 N 秒」，异步取同一个 ?json，回来就地重画并
     pushState（不再重新请求整页 HTML）；15 秒还没回来给「取消 / 重试」。底部导航和返回全程可点。 */
  var NAV = { seq: 0, ctl: null, timer: 0, url: '', name: '', t0: 0, active: false };
  function navFinish() {                       // 结束一次加载，并作废所有在途回调
    NAV.seq++;
    NAV.active = false;
    if (NAV.timer) { clearInterval(NAV.timer); NAV.timer = 0; }
    if (NAV.ctl) { try { NAV.ctl.abort(); } catch (e) { } NAV.ctl = null; }
  }
  function navTipTxt() {
    var s = Math.max(0, Math.round((Date.now() - NAV.t0) / 1000));
    return '正在读取「' + NAV.name + '」… 已等待 ' + s + ' 秒';
  }
  function navPaint() {                        // 骨架 + 每秒跳秒 + 15 秒后的取消/重试
    if (!NAV.active) return;
    el.listSec.style.display = 'block';
    el.fileList.className = 'file-list';
    var tip = document.getElementById('navTip');
    if (!tip) {
      var bars = '', i;
      for (i = 0; i < 5; i++) bars += '<i></i>';
      el.fileList.innerHTML = '<div class="empty nav-load" id="navLoad">' +
        '<div class="nav-skel">' + bars + '</div>' +
        '<div class="nav-tip" id="navTip">' + esc(navTipTxt()) + '</div>' +
        '<div class="nav-acts" id="navActs"></div></div>';
    } else {
      tip.textContent = navTipTxt();
    }
    var acts = document.getElementById('navActs');
    if (acts && !acts.childNodes.length && Date.now() - NAV.t0 >= 15000) {
      acts.innerHTML = '<button class="btn" id="navCancelBtn" style="margin:8px 4px 0">取消</button>' +
        '<button class="btn" id="navRetryBtn" style="margin:8px 4px 0">重试</button>';
      document.getElementById('navCancelBtn').onclick = function () { navCancel(); };
      document.getElementById('navRetryBtn').onclick = function () { navOpen(NAV.url, NAV.name, NAV.noPush); };
    }
  }
  function navCancel() {                       // 取消 = 断请求、退回原来那段列表
    var was = NAV.active;
    navFinish();
    render();
    if (was) toast('已取消打开');
  }
  function navFail(url, name, msg) {
    el.listSec.style.display = 'block';
    el.fileList.className = 'file-list';
    el.fileList.innerHTML = '<div class="empty"><b>' + icn('info', 30) + '</b>' +
      '打不开「' + esc(name || '这个目录') + '」<br><span class="hint">' + esc(msg) + '</span>' +
      '<br><button class="btn" id="navFBack" style="margin:12px 4px 0">回到列表</button>' +
      '<button class="btn" id="navFTry" style="margin:12px 4px 0">重试</button></div>';
    document.getElementById('navFBack').onclick = function () { render(); };
    document.getElementById('navFTry').onclick = function () { navOpen(url, name, false); };
  }
  function navCommit(url, d, push) {           // 拿到目录数据：换 BASE、重画、改地址（不刷新页面）
    NAV.seq++;
    BASE = url;
    DATA = d;
    ITEMS = (d.paths || []).map(function (p) {
      var isDir = String(p.path_type).indexOf('Dir') >= 0;
      return {
        name: p.name, isDir: isDir, size: p.size, mtime: p.mtime,
        kind: kindOf(p.name, isDir),
        url: BASE + p.name.split('/').map(encodeURIComponent).join('/') + (isDir ? '/' : '')
      };
    });
    CAN_WRITE = !!d.allow_upload;
    CAN_DELETE = !!(d.allow_upload && d.allow_delete);
    ST.path = ''; ST.davItems = []; ST.davErr = null; ST.davLoading = false; ST.davNeedAuth = false;
    // 整页跳转时这些都会随着新页面一起清掉，软打开要手动对齐：搜索词、分类、分页
    Q = ''; ST.q = ''; ST.qOpen = false; ST.cat = null; LIMIT = 500;
    try { el.q.value = ''; } catch (e) { }
    try { if (push) history.pushState({ mfmDir: 1 }, '', url); } catch (e) { }
    render();
    try { window.scrollTo({ top: 0, behavior: SMOOTH }); } catch (e) { }
  }
  function navOpen(url, name, noPush) {
    navFinish();
    var stale = document.getElementById('navLoad');       // 上一次（重试前）的骨架，别让旧按钮留着
    if (stale && stale.parentNode) stale.parentNode.removeChild(stale);
    var seq = NAV.seq;                        // 本次加载的代号；被顶掉后所有回调作废
    NAV.url = url; NAV.name = name || '目录'; NAV.t0 = Date.now(); NAV.active = true; NAV.noPush = !!noPush; try { el.title.textContent = name || '目录'; } catch (e) { }
    navPaint();
    NAV.timer = setInterval(navPaint, 250);
    var ctl = (typeof AbortController !== 'undefined') ? new AbortController() : null;
    NAV.ctl = ctl;
    fetch(url + '?json', {
      cache: 'no-store', credentials: 'omit',
      signal: ctl ? ctl.signal : undefined, headers: authHeaders()
    })
      .then(function (r) {
        if (r.status === 401 || r.status === 403) throw new Error('需要登录（服务端说 ' + r.status + '）');
        if (!r.ok) throw new Error('服务端返回 ' + r.status);
        return r.json();
      })
      .then(function (d) {
        if (seq !== NAV.seq) return;
        if (!d || d.kind !== 'Index' || d.dir_exists === false) {
          navFinish();
          navFail(url, name, d && d.dir_exists === false
            ? '服务端说这个目录不存在（挂载可能断了）' : '返回的不是目录数据');
          return;
        }
        navFinish();
        navCommit(url, d, !noPush);
      })
      ['catch'](function (e) {
        if (seq !== NAV.seq) return;          // 已经被取消或换成别的目录了
        var m = String((e && e.message) || e);
        if ((e && e.name === 'AbortError') || /abort/i.test(m)) return;
        navFinish();
        navFail(url, name, errText(m));
      });
  }
  /* 每个来源一套凭据（各台机器的 dufs 账号不一定相同，存在这台设备上）。
     用户名不是机密，密码永远只留在用户自己的设备上 —— 绝不写进这份代码。 */
  var DEFAULT_USER = 'wang8456';
  function lastUserOf(id) {
    try {
      return localStorage.getItem('mfm_last_user_' + id) || localStorage.getItem('mfm_last_user') || DEFAULT_USER;
    } catch (e) { return DEFAULT_USER; }
  }
  function rememberUser(id, u) {
    try {
      localStorage.setItem('mfm_last_user_' + id, u);
      localStorage.setItem('mfm_last_user', u);
    } catch (e) { }
  }
  /* 每个来源一个登录面板：只登录当前这个来源 */
  function srcAuthSheet(id) {
    id = id || ((activeSrc() || {}).id || 'nas');
    var sx = srcById(id) || { id: 'nas', name: '云匣', kind: 'dufs' };
    if (sx.kind === 'webdav') { davAuthSheet(id); return; }
    var cur = srcAuth(id);
    var hint = '登录后能<b>上传 / 改名 / 删除</b>；浏览、播放、下载不用登录就能用。' +
      '<br>凭据只保存在这台设备上。';
    var body = '<div class="note">' + hint + '</div>';
    if (cur) body += '<div class="note" style="margin:-6px 0 10px">当前保存的是 <b>' + esc(userOf(cur) || '已登录') + '</b> 的凭据。</div>';
    body += '<div class="lf"><label for="lgUser">用户名</label>' +
      '<input id="lgUser" type="text" autocomplete="username" autocapitalize="off" autocorrect="off" ' +
      'spellcheck="false" value="' + esc(lastUserOf(id)) + '"></div>' +
      '<div class="lf"><label for="lgPass">密码</label>' +
      '<input id="lgPass" type="password" autocomplete="current-password"></div>' +
      '<div class="err" id="lgErr"></div>' +
      '<div id="lgRes"></div>' +
      '<div class="sheet-buttons">' +
      (cur ? '<button id="lgOut">退出登录</button>' : '') +
      '<button id="lgCancel">取消</button>' +
      '<button class="primary" id="lgOk">登录</button></div>';
    sheet('登录 · ' + esc(sx.name), body);

    $('#lgCancel').onclick = closeSheet;
    $('#lgPass').onkeydown = function (e) { if (e.key === 'Enter') $('#lgOk').click(); };
    if ($('#lgOut')) {
      $('#lgOut').onclick = function () {
        setSrcAuth(id, '');
        closeSheet();
        toast('已退出「' + sx.name + '」，恢复只读');
        refreshAfterAuth(id);
      };
    }
    $('#lgOk').onclick = function () {
      var u = ($('#lgUser').value || '').trim(), p = $('#lgPass').value;
      var err = $('#lgErr');
      if (!u || !p) { err.textContent = '用户名和密码都要填'; return; }
      var h = b64(u + ':' + p);
      if (!h) { err.textContent = '用户名或密码里有浏览器不支持的字符'; return; }
      err.textContent = '正在验证…';
      verifySrc(id, h).then(function (who) {
        setSrcAuth(id, h);
        rememberUser(id, u);
        closeSheet();
        toast('已登录 「' + sx.name + '」' + (who ? ' · ' + who : ''));
        refreshAfterAuth(id);
      })['catch'](function (e) { err.textContent = (e && e.message) || '登录失败（网络错误）'; });
    };
    setTimeout(function () { var f = $('#lgPass'); if (f) f.focus(); }, 100);
  }

  function loginSheet() { srcAuthSheet('nas'); }

  function verifySrc(id, h) {
    var sx = srcById(id) || { kind: 'dufs' };
    if (!id || id === 'nas') {
      return fetchListing({ Authorization: 'Basic ' + h }).then(function (d) {
        if (!d || !d.user) throw new Error('用户名或密码不对');
        return d.user;
      });
    }
    var base = (otherHost(sx, 'base', 'baseWan') || sx.base || '').replace(/\/$/, '');
    return fetch(base + '/?json', { cache: 'no-store', credentials: 'omit', headers: { Authorization: 'Basic ' + h } })
      .then(function (r) {
        if (r.status === 401 || r.status === 403) throw new Error('用户名或密码不对');
        if (!r.ok) throw new Error('这个来源没响应（' + r.status + '）');
        return r.json().then(function (d) { return (d && d.user) || ''; }, function () { return ''; });
      });
  }

  /* 登录 / 退出之后：把当前正在看的那个来源重新取一遍 */
  function refreshAfterAuth(id) {
    if (isRemote()) { loadDav(ST.path, true); return; }
    if (!id || id === 'nas' || (activeSrc() || {}).id === id) { refreshListing(); return; }
    render();
  }

  /* 115 网盘：账号在 NAS 的 CloudDrive 里，网页端没有可填的东西，只做状态检查 */
  function davAuthSheet(id) {
    var sx = srcById(id) || {};
    var relay = sameHost(sx.relay || '');
    sheet('115 网盘', '<div class="note">这个来源由 NAS 上的转发服务托管：<b>账号密码在 NAS 的 CloudDrive 里</b>，网页这里不用再填一遍。</div>' +
      '<div class="kv"><span>转发服务</span><span id="davPing">检查中…</span></div>' +
      '<div class="kv"><span>网盘账号</span><span id="davUser">—</span></div>' +
      '<div class="kv"><span>权限</span><span>只读 · 浏览 / 播放 / 下载</span></div>' +
      '<div class="note" style="margin-top:8px">要上传或删除，请用 115 官方客户端；网页端只做浏览和播放。</div>' +
      '<div class="sheet-buttons"><button id="davRecheck">重新检查</button>' +
      '<button class="primary" id="davClose">好</button></div>');
    $('#davClose').onclick = closeSheet;
    var ping = function () {
      var p = $('#davPing'), u = $('#davUser');
      if (p) { p.textContent = '检查中…'; p.style.color = ''; }
      fetch(relay + 'ping', { cache: 'no-store' })
        .then(function (r) { return r.json(); })
        .then(function (d) {
          if (p) { p.textContent = (d && d.ok) ? '正常' : '异常'; p.style.color = (d && d.ok) ? '#0d9c7a' : '#c0392b'; }
          if (u) u.textContent = (d && d.source) || '—';
        })
        ['catch'](function () {
          if (p) { p.textContent = '连不上'; p.style.color = '#c0392b'; }
        });
    };
    $('#davRecheck').onclick = ping;
    ping();
  }

  function doLogin(u, p) {
    var h = b64(u + ':' + p);
    var setErr = function (m) { var e = $('#lgErr'); if (e) e.textContent = m; };
    if (!h) { setErr('用户名或密码里有浏览器不支持的字符'); return; }
    verifySrc('nas', h).then(function (who) {
      setSrcAuth('nas', h);
      try { localStorage.setItem('mfm_last_user', u); } catch (e) { }
      closeSheet();
      toast('已登录 ' + who + '，现在可以上传了');
      refreshListing();
    })['catch'](function (err) { setErr((err && err.message) || '登录失败（网络错误）'); });
  }

  function doLogout() {
    setSrcAuth('nas', '');
    toast('已退出登录，恢复匿名只读');
    refreshListing();
  }

  var IMG = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'avif', 'ico', 'tif', 'tiff'];
  var VID = ['mp4', 'mov', 'mkv', 'webm', 'avi', 'flv', 'wmv', 'm4v', 'ts', 'rmvb'];
  var AUDX = ['mp3', 'wav', 'ogg', 'flac', 'm4a', 'aac', 'ape', 'wma'];   // 音频扩展名（别叫 AUD：那是外挂音轨的元素）
  var DOC = ['txt', 'md', 'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'csv', 'log', 'rtf', 'epub'];
  var ZIP = ['zip', 'rar', '7z', 'tar', 'gz', 'iso', 'apk', 'jar'];
  var CODE = ['html', 'htm', 'js', 'css', 'json', 'py', 'bat', 'cmd', 'sh', 'ps1', 'xml', 'yml', 'yaml', 'ini', 'toml', 'sql', 'java', 'c', 'cpp', 'cs', 'go', 'rs', 'php', 'rb', 'lua'];

  function kindOf(name, isDir) {
    if (isDir) return 'folder';
    var e = ext(name);
    if (IMG.indexOf(e) >= 0) return 'image';
    if (VID.indexOf(e) >= 0) return 'video';
    if (AUDX.indexOf(e) >= 0) return 'audio';
    if (DOC.indexOf(e) >= 0) return 'document';
    if (ZIP.indexOf(e) >= 0) return 'zip';
    if (CODE.indexOf(e) >= 0) return 'code';
    return 'other';
  }
  function iconOf(it) {
    var k = it.kind, e = ext(it.name);
    if (k === 'folder') return icn('type-folder', 22);
    if (k === 'image') return icn('type-image', 22);
    if (k === 'video') return icn('type-video', 22);
    if (k === 'audio') return icn('type-audio', 22);
    if (k === 'zip') return icn('type-zip', 22);
    if (k === 'code') return icn('type-code', 22);
    if (k === 'document') return e === 'pdf' ? icn('type-pdf', 22) : icn('type-doc', 22);
    return icn('type-file', 22);
  }
  window.__icoFall = function (el, kind) {     // 网格缩略图加载失败 → 退回类型图标
    try { el.parentNode.innerHTML = iconOf({ kind: kind, name: '' }); } catch (e) { }
  };
  function fiOf(it) {
    var k = it.kind;
    if (k === 'folder') return 'fi-folder';
    if (k === 'image') return 'fi-img';
    if (k === 'audio') return 'fi-audio';
    if (k === 'video') return 'fi-video';
    if (k === 'zip' || k === 'other') return 'fi-zip';
    if (k === 'code') return 'fi-code';
    return ext(it.name) === 'pdf' ? 'fi-pdf' : 'fi-doc';
  }
  function kindLabel(k) {
    return { image: '图片', video: '视频', audio: '音频', document: '文档', zip: '压缩包', code: '代码', other: '其他', folder: '文件夹' }[k] || '文件';
  }
  // 大数好看点：83452 -> 8.3 万，4811 -> 4,811
  function nfmt(n) {
    n = n || 0;
    if (n >= 10000) return (n / 10000).toFixed(1).replace(/\.0$/, '') + ' 万';
    return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  }
  function hmOf(ms) {
    var d = new Date(ms || 0);
    return ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2);
  }

  var ITEMS = (DATA.paths || []).map(function (p) {
    var isDir = String(p.path_type).indexOf('Dir') >= 0;
    return {
      name: p.name,
      isDir: isDir,
      size: p.size,
      mtime: p.mtime,
      kind: kindOf(p.name, isDir),
      url: BASE + p.name.split('/').map(encodeURIComponent).join('/') + (isDir ? '/' : '')
    };
  });
  var CAN_WRITE = !!DATA.allow_upload;
  var CAN_DELETE = !!(DATA.allow_upload && DATA.allow_delete);
  var THUMBS = false;
  var curItem = null;

  /* ---------------- 状态 ---------------- */
  var ST = {
    view: 'home', cat: null, q: '', sort: 'name', order: 'asc', mode: 'list', qOpen: false,
    src: null, path: '', davItems: [], davLoading: false, davErr: null
  };
  try {
    var sv = JSON.parse(localStorage.getItem('mfm_state') || '{}');
    ['sort', 'order', 'mode'].forEach(function (k) { if (sv[k]) ST[k] = sv[k]; });
    // 记住本次浏览在哪个标签：在「文件」里点进文件夹后还是「文件」，不会自己跳回首页；
    // 用 sessionStorage（关掉标签页就恢复默认首页），避免下次打开直接停在「文件」上
    var lv = sessionStorage.getItem('mfm_view');
    if (lv === 'files' || lv === 'recent' || lv === 'home') ST.view = lv;
    if (Q) ST.view = 'files';          // ?q= 搜索结果页 = 文件列表，搜索球照常出现
    // 直接在文件夹里刷新/打开链接（或从浏览器历史回来）：就该看这个文件夹，而不是来源选择页
    if (DATA && DATA.href && DATA.href !== '/' && !Q) ST.view = 'files';
  } catch (e) { }
  function saveState() {
    try {
      localStorage.setItem('mfm_state', JSON.stringify({ sort: ST.sort, order: ST.order, mode: ST.mode }));
      sessionStorage.setItem('mfm_view', ST.view === 'settings' ? 'home' : ST.view);
    } catch (e) { }
  }

  function filtered() {
    var arr = ITEMS.slice();
    if (ST.view === 'recent') arr = arr.filter(function (x) { return !x.isDir; });
    else if (ST.cat) arr = arr.filter(function (x) { return x.kind === ST.cat; });
    if (ST.q) {
      var q = ST.q.toLowerCase();
      arr = arr.filter(function (x) { return x.name.toLowerCase().indexOf(q) >= 0; });
    }
    var dir = ST.order === 'desc' ? -1 : 1;
    arr.sort(function (a, b) {
      if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
      if (ST.sort === 'mtime') return (a.mtime - b.mtime) * dir;
      if (ST.sort === 'size') return ((a.isDir ? -1 : a.size) - (b.isDir ? -1 : b.size)) * dir;
      return a.name.localeCompare(b.name, 'zh-CN') * dir;
    });
    if (ST.view === 'recent') arr = arr.slice(0, 30);
    return arr;
  }

  /* ---------------- 壳 ---------------- */
  var el = {};
  var LIMIT = 500;                            // 每屏最多画多少行；「加载更多」每次 +500
  var SMOOTH = (function () {                 // 「减弱动态效果」时别再做平滑滚动
    try { return window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth'; }
    catch (e) { return 'smooth'; }
  })();
  function buildShell() {
    var app = document.createElement('div');
    app.className = 'app';
    app.innerHTML =
      '<header class="header">' +
        '<div class="topline">' +
          '<div class="brand"><div class="brand-icon">' + BRAND_GLYPH + '</div>云匣</div>' +
          '<button class="avatar" id="avatarBtn" title="登录状态">我</button>' +
        '</div>' +
        '<div class="crumbs" id="crumbs"></div>' +
        '<div class="title-row"><h1 class="page-title" id="pageTitle">云匣</h1>' +
          '<button class="text-btn" id="sortBtn">排序 ' + icn('sort', 14) + '</button></div>' +
      '</header>' +
      '<main class="content">' +
        '<section class="section" id="srcSec"></section>' +
        '<section class="section" id="listSec">' +
          '<div class="section-head" id="listHead"><h2 id="listTitle">文件</h2></div>' +
          '<div class="upload-box" id="uploadBox" style="display:none"></div>' +
          '<div class="file-list" id="fileList"></div>' +
        '</section>' +
      '</main>' +
      '<button class="fab" id="fab" aria-label="添加">' + icn('add', 26) + '</button>' +
      '<button class="search-fab" id="searchFab" aria-label="搜索" title="搜索">' + icn('search', 22) + '</button>' +
      '<div class="search-bar" id="searchBar">' +
        '<div class="sbox"><i>' + icn('search', 18) + '</i><input id="q" placeholder="搜索当前目录（回车在整个共享里搜）" autocomplete="off"></div>' +
        '<button class="sclose" id="qClose" aria-label="收起搜索">' + icn('close', 18) + '</button>' +
      '</div>' +
      '<nav class="bottom-nav" id="nav">' +
        '<button class="nav-item" data-nav="home"><span class="nav-ico">' + icn('home', 22) + '</span>首页</button>' +
        '<button class="nav-item" data-nav="files"><span class="nav-ico">' + icn('folder', 22) + '</span>文件</button>' +
        '<button class="nav-item" data-nav="recent"><span class="nav-ico">' + icn('chat', 22) + '</span>对话</button>' +
        '<button class="nav-item" data-nav="settings"><span class="nav-ico">' + icn('setting', 22) + '</span>设置</button>' +
      '</nav>';
    document.body.appendChild(app);

    var toast = document.createElement('div');
    toast.className = 'toast'; toast.id = 'toast';
    document.body.appendChild(toast);

    var sb = document.createElement('div');
    sb.className = 'sheet-back'; sb.id = 'sheetBack';
    sb.innerHTML = '<div class="sheet"><div class="sheet-handle"></div><div id="sheetContent"></div></div>';
    document.body.appendChild(sb);

    el = {
      app: app, crumbs: $('#crumbs'), title: $('#pageTitle'), q: $('#q'),
      srcSec: $('#srcSec'),
      listSec: $('#listSec'), listTitle: $('#listTitle'), fileList: $('#fileList'),
      uploadBox: $('#uploadBox'), nav: $('#nav'), fab: $('#fab'),
      searchFab: $('#searchFab'), searchBar: $('#searchBar'),
      toast: toast, sheetBack: sb, sheetContent: $('#sheetContent'), avatar: $('#avatarBtn')
    };

    document.documentElement.classList.remove('mfm-boot');
    document.body.classList.add('mfm-index');
    var sp = document.getElementById('mfmSplash');   // 界面已就绪，撤掉加载指示
    if (sp && sp.parentNode) sp.parentNode.removeChild(sp);
  }

  function toast(t) {
    // 播放器开着时，页面级 toast 会被它整屏盖住（用户看到的就是"点了没反应"），
    // 所以这时改用播放器自己的提示条。
    var vp = document.getElementById('vp');
    if (vp && !vp.hidden) {
      var pt = vp.querySelector('.vp-toast');
      if (pt) {
        pt.textContent = t;
        pt.classList.add('on');
        clearTimeout(toast.pt);
        toast.pt = setTimeout(function () { pt.classList.remove('on'); }, 2300);
        return;
      }
    }
    el.toast.textContent = t;
    el.toast.classList.add('show');
    clearTimeout(toast.t);
    toast.t = setTimeout(function () { el.toast.classList.remove('show'); }, 2300);
  }
  function sheet(title, html) {
    el.sheetContent.innerHTML = '<h3>' + title + '</h3>' + html;
    el.sheetBack.classList.add('show');
  }
  function closeSheet() {
    el.sheetBack.classList.remove('show');
    if (typeof monSheetStop === 'function') monSheetStop();
    if (typeof magnetStop === 'function') magnetStop();
    if (typeof ed2kStop === 'function') ed2kStop();
    if (typeof dlStop === 'function') dlStop();
  }
  function row(ico, label, act, sub, danger) {
    return '<button class="row' + (danger ? ' danger' : '') + '" data-act="' + act + '">' +
      '<span class="ico">' + ico + '</span><span>' + label + '</span>' +
      (sub ? '<span class="sub">' + esc(sub) + '</span>' : '') + '</button>';
  }

  /* ---------------- 渲染 ---------------- */
  function safeDecode(s) {                  // URL 里出现畸形的 % 时 decodeURIComponent 会抛错，别让它整页崩掉
    try { return decodeURIComponent(s || ''); } catch (e) { return String(s || ''); }
  }
  function errText(m) {
    m = String(m || '');
    if (/Failed to fetch|NetworkError|Load failed|fetch failed|Network request failed/i.test(m)) return '网络请求失败';
    if (/timed? ?out|timeout/i.test(m)) return '请求超时';
    if (/404/.test(m)) return '这个地址不存在（404）';
    return m;
  }
  function curDirName() {
    return safeDecode((location.pathname || '/').split('/').filter(Boolean).pop() || '') || '云匣';
  }
  function pathParts() {
    var prefix = DATA.uri_prefix && DATA.uri_prefix !== '/' ? DATA.uri_prefix.replace(/\/$/, '') : '';
    var path = decodeURIComponent((location.pathname || '/').replace(prefix, ''));
    return path.split('/').filter(function (s) { return s.length > 0; });
  }
  function isRoot() { return pathParts().length === 0; }
  function crumbsHtml() {
    var prefix = DATA.uri_prefix && DATA.uri_prefix !== '/' ? DATA.uri_prefix.replace(/\/$/, '') : '';
    var parts = pathParts();
    if (!parts.length) return '';   // 根目录不重复写标题，改在 render() 里显示服务信息
    var out = ['<a href="' + esc(ROOT + encPath(prefix.replace(/^\//, ''))) + (prefix ? '/' : '') + '">云匣</a>'];
    var acc = prefix;
    parts.forEach(function (p, i) {
      acc += '/' + p;
      out.push('<span class="sep">/</span>');
      if (i === parts.length - 1) out.push('<span class="now">' + esc(p) + '</span>');
      else out.push('<a href="' + esc(ROOT + encPath(acc.slice(1)) + '/') + '">' + esc(p) + '</a>');
    });
    return out.join('');
  }

  /* ---------------- 首页：储存来源 ---------------- */
  function srcById(id) {
    if (!SOURCES || !id) return null;
    for (var i = 0; i < SOURCES.sources.length; i++) {
      if (SOURCES.sources[i].id === id) return SOURCES.sources[i];
    }
    return null;
  }
  function activeSrc() { return srcById(ST.src); }

  /* ---------------- 快捷收藏夹 ----------------
     收藏的是「来源 + 文件夹路径」，跨来源共用一份，存在本机。
     首页只做一个入口列表，点一下直接进那个目录。 */
  function favGet() {
    try {
      var a = JSON.parse(localStorage.getItem('mfm_fav') || '[]');
      if (!Array.isArray(a)) return [];
      return a.filter(function (x) { return x && x.s && typeof x.p === 'string'; }).slice(0, 20);
    } catch (e) { return []; }
  }
  function favSave(a) { try { localStorage.setItem('mfm_fav', JSON.stringify((a || []).slice(0, 20))); } catch (e) { } }
  function favKey(sid, p) { return sid + '|' + (p || ''); }
  function favHas(sid, p) {
    var k = favKey(sid, p);
    return favGet().some(function (x) { return favKey(x.s, x.p) === k; });
  }
  function favToggle(sid, p, n) {
    var a = favGet(), k = favKey(sid, p), hit = -1;
    for (var i = 0; i < a.length; i++) if (favKey(a[i].s, a[i].p) === k) { hit = i; break; }
    if (hit >= 0) { a.splice(hit, 1); favSave(a); return false; }
    a.unshift({ s: sid, p: p || '', n: n || '', at: Date.now() });
    favSave(a);
    return true;
  }
  function favDel(i) {
    var a = favGet();
    if (i < 0 || i >= a.length) return;
    var nm = a[i].n || a[i].p || '根目录';
    a.splice(i, 1); favSave(a);
    renderSources();
    toast('已取消收藏「' + nm + '」');
  }
  function favPathOf(it) {
    var p = it && (it.davPath || it.path);
    if (p == null) p = ((ST.path ? String(ST.path).replace(/^\/+|\/+$/g, '') + '/' : '') + (it ? it.name : ''));
    return String(p).replace(/^\/+|\/+$/g, '');
  }
  function openFav(f) {
    if (!f) return;
    var s = srcById(f.s);
    if (!s) { toast('这个来源已经不在了'); return; }
    ST.src = s.id;
    try { localStorage.setItem('mfm_src', s.id); } catch (e) { }
    ST.view = 'files'; ST.cat = null; ST.q = ''; if (el.q) el.q.value = '';
    var p = String(f.p || '').replace(/^\/+|\/+$/g, '');
    if (s.kind === 'dufs') {           // 本机共享：目录本身就是个地址，直接跳过去
      location.href = location.origin + '/' + p.split('/').filter(Boolean).map(encodeURIComponent).join('/') + (p ? '/' : '');
      return;
    }
    if (s.kind === 'webdav' || s.kind === 'dufs-remote') loadDav(p, true);
    else { ST.path = p; render(); }
    window.scrollTo({ top: 0, behavior: SMOOTH });
  }

  function pickSource(id) {
    var s = srcById(id);
    if (!s) return;
    ST.src = s.id;
    try { localStorage.setItem('mfm_src', s.id); } catch (e) { }
    ST.q = ''; if (el.q) el.q.value = '';
    ST.view = 'files'; ST.cat = null;
    if (s.kind === 'webdav' || s.kind === 'dufs-remote') loadDav('', true);
    else render();
    window.scrollTo({ top: 0, behavior: SMOOTH });
  }

  function renderSources() {
    if (!SOURCES) {
      el.srcSec.innerHTML = '<div class="empty"><b>⏳</b>正在读取储存来源…</div>';
      return;
    }
    var last = null;
    try { last = localStorage.getItem('mfm_src'); } catch (e) { }
    var lastSrc = srcById(last);
    /* 「继续浏览」曾经单独占一张卡，但它指向的地方就在下面第一个卡片里 —— 纯重复，去掉。
       来源只有三四个，点一下的成本比读一张多余的卡还低。 */
    var favs = favGet();
    var srcRows = (SOURCES.sources || []).map(function (s) {
      return '<button class="src-card k-' + esc(s.kind || 'dufs') + (ST.src === s.id ? ' on' : '') + '" data-src="' + esc(s.id) + '">' +
        '<div class="src-ico">' + srcIco(s) + '</div>' +
        '<div class="src-txt"><b>' + esc(s.name) + '</b><i>' + esc(s.subtitle || '') + '</i></div>' +
        '<span class="src-st" title="在线"></span>' +
        '<div class="src-go">' + icn('chevron-right', 17) + '</div></button>';
    }).join('');
    var html = '<div class="src-group">' + srcRows + '</div>';
    html += '<div class="home-side">';
    /* 收藏：只存「来源 + 文件夹路径」，点一下直接进那个目录 */
    html += '<div class="home-h"><h2>收藏</h2>' +
      (favs.length ? '<span class="text-btn">点 ★ 取消</span>' : '') + '</div>';
    if (favs.length) {
      html += '<div class="src-group fav-group">' + favs.map(function (f, i) {
        var s2 = srcById(f.s);
        var sn = s2 ? s2.name : '来源已删除';
        var sub = sn + (f.p && f.p !== f.n ? ' · ' + f.p : '');
        return '<div class="src-card fav-row" data-fav="' + i + '">' +
          '<div class="src-ico">' + icn('folder', 19) + '</div>' +
          '<div class="src-txt"><b>' + esc(f.n || f.p || '根目录') + '</b><i>' + esc(sub) + '</i></div>' +
          '<button class="fav-star" data-favdel="' + i + '" aria-label="取消收藏">' + icn('star', 16) + '</button>' +
          '</div>';
      }).join('') + '</div>';
    } else {
      html += '<div class="rec-empty one"><span class="re-ico">' + icn('star', 18) + '</span>' +
        '<span class="re-txt"><b>还没有收藏</b><i>在「文件」里点文件夹的 ⋯ → 收藏到首页</i></span></div>';
    }
    html += '</div>';                       /* /home-side */
    /* 动作 + 状态：一个分组，两行，比原来各占一块干净 */
    html += '<div class="src-group act-group">';
    html += '<button class="quick-row" data-act="online">' +
      '<span class="qr-ico">' + icn('play', 15) + '</span>' +
      '<span class="qr-txt"><b>在线播放</b><i>粘贴直链 mp4 / mkv / webm</i></span>' +
      '<span class="qr-go">' + icn('chevron-right', 15) + '</span></button>';
    html += '<button class="stat-row" data-act="subsmon">' +
      '<span class="sr-ico">' + icn('monitor', 18) + '</span>' +
      '<span class="sr-txt"><b>听译服务</b><i id="hubStat">正在检查…</i></span>' +
      '<span class="sr-go">' + icn('chevron-right', 15) + '</span></button>';
    html += '</div>';
    el.srcSec.innerHTML = html;
    probeHub();
    probeAllSrc();
  }

  /* 听译中枢探活：首页那条状态 */
  var hubT = 0;
  function hubAgain() {                 // 首页挂着就隔 30 秒再探一次，连上了会自动变回来
    clearTimeout(hubT);
    hubT = setTimeout(function () {
      if (document.hidden) { hubAgain(); return; }
      if (document.getElementById('hubStat')) probeHub();
    }, 30000);
  }
  function probeHub() {
    var elx = document.getElementById('hubStat');
    if (!elx) return;
    var ctl = null, tm = setTimeout(function () { try { ctl && ctl.abort(); } catch (e) { } }, 3500);
    try { ctl = new AbortController(); } catch (e) { ctl = null; }
    fetch(subsBase() + '/health', ctl ? { signal: ctl.signal, credentials: 'omit' } : { credentials: 'omit' })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        clearTimeout(tm);
        var q = d.queued || 0, a = d.asr || 0, tr = d.translating || 0;
        var txt, cls;
        if (a) { txt = '正在转写 ' + a + ' 个' + (q ? ' · 排队 ' + q + ' 个' : ''); cls = 'busy'; }
        else if (tr) { txt = '正在翻译 ' + tr + ' 个' + (q ? ' · 排队 ' + q + ' 个' : ''); cls = 'busy'; }
        else if (q) { txt = '排队 ' + q + ' 个 · 等转写工'; cls = 'busy'; }
        else { txt = '空闲 · 随时可以听译'; cls = 'ok'; }
        var st = document.getElementById('hubStat');
        if (st) { st.textContent = txt; st.className = cls; }
        hubAgain();
      })
      ['catch'](function () {
        clearTimeout(tm);
        var st = document.getElementById('hubStat');
        if (st) { st.textContent = '连不上中枢（NAS 那边可能没起来）'; st.className = 'bad'; }
        hubAgain();
      });
  }

  /* ---------------- 来源在线状态 ---------------- */
  function srcProbeUrl(s) {
    if (!s) return null;
    if (s.kind === 'dufs') return null;                       // 本机：页面都打开了，肯定在线
    if (s.kind === 'webdav') return s.relay ? sameHost(s.relay) : null;
    if (s.kind === 'dufs-remote') {
      var b = otherHost(s, 'base', 'baseWan');
      return b ? b.replace(/\/$/, '') + '/?json' : null;
    }
    return null;
  }
  function paintSrcHealth(id, ok) {
    var nodes = document.querySelectorAll('.src-card[data-src="' + id + '"]');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      el.classList.toggle('off', !ok);
      var sub = el.querySelector('.src-txt i');
      if (sub) {
        if (!sub.getAttribute('data-sub')) sub.setAttribute('data-sub', sub.textContent);
        sub.textContent = ok ? sub.getAttribute('data-sub') : '当前离线';
      }
      var dot = el.querySelector('.src-st');
      if (dot) dot.setAttribute('title', ok ? '在线' : '离线');
    }
  }
  function probeAllSrc() {
    (SOURCES && SOURCES.sources || []).forEach(function (s) {
      var url = srcProbeUrl(s);
      if (!url) { paintSrcHealth(s.id, true); return; }
      var ac = null, t = null;
      try { ac = new AbortController(); t = setTimeout(function () { ac.abort(); }, 3500); } catch (e) { }
      fetch(url, { cache: 'no-store', signal: ac ? ac.signal : undefined })
        .then(function () { clearTimeout(t); paintSrcHealth(s.id, true); })
        ['catch'](function () { clearTimeout(t); paintSrcHealth(s.id, false); });
    });
  }
  // 切回页面时重新看一遍，电脑开机后不用手动刷新
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden && !$('#home').hidden) probeAllSrc();
  });

  /* ---------------- 磁力保存（NAS 上的 magnet-hub，:5094） ----------------
     服务只装在 NAS 上，手机/电脑都在同一个局域网里访问它；页面从别的机器打开时
     location.hostname:5094 可能没人监听，所以按候选地址各探一次 /health。 */
  var MAG = { base: '', probing: null, timer: null, targets: [], target: '' };
  try { MAG.target = localStorage.getItem('mfm_mg_target') || 'nas'; } catch (e) { MAG.target = 'nas'; }
  function magnetCandidates() {
    var list = [], seen = {};
    [location.protocol + '//' + location.hostname + ':5094', sameHost('http://192.168.1.10:5094')]
      .forEach(function (u) {
        u = String(u).replace(/\/+$/, '');
        if (!seen[u]) { seen[u] = 1; list.push(u); }
      });
    return list;
  }
  function magnetEnsure() {
    if (MAG.base) return Promise.resolve(MAG.base);
    if (MAG.probing) return MAG.probing;
    var list = magnetCandidates();
    MAG.probing = new Promise(function (resolve, reject) {
      (function tryOne(i) {
        if (i >= list.length) {
          MAG.probing = null;
          reject(new Error('连不上磁力服务（NAS 上的 5094 没起来）'));
          return;
        }
        var done = false, ctl = null;
        var tm = setTimeout(function () {
          if (done) return; done = true;
          try { ctl && ctl.abort(); } catch (e) { }
          tryOne(i + 1);
        }, 1600);
        try { ctl = new AbortController(); } catch (e) { ctl = null; }
        var opt = { cache: 'no-store', credentials: 'omit' };
        if (ctl) opt.signal = ctl.signal;
        fetch(list[i] + '/health', opt)
          .then(function (r) { return r.json(); })
          .then(function (d) {
            if (done) return; done = true; clearTimeout(tm);
            if (d && d.ok) { MAG.base = list[i]; MAG.probing = null; resolve(list[i]); }
            else tryOne(i + 1);
          })['catch'](function () {
            if (done) return; done = true; clearTimeout(tm);
            tryOne(i + 1);
          });
      })(0);
    });
    return MAG.probing;
  }
  function magnetCall(path, body) {
    return magnetEnsure().then(function (base) {
      var opt = body === undefined
        ? { cache: 'no-store', credentials: 'omit' }
        : { method: 'POST', cache: 'no-store', credentials: 'omit',
            headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
      return fetch(base + path, opt).then(function (r) { return r.json(); });
    });
  }
  function sizeText(n) {
    n = Number(n) || 0;
    if (n >= 1073741824) return (n / 1073741824).toFixed(2) + ' GB';
    if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';
    if (n >= 1024) return Math.round(n / 1024) + ' KB';
    return n + ' B';
  }
  var MG_ST = { active: '下载中', waiting: '排队中', paused: '已暂停', complete: '已完成', error: '出错', removed: '已删除' };
  function magnetStop() {
    if (MAG.timer) { clearInterval(MAG.timer); MAG.timer = null; }
  }
  function mgTargets(force) {
    return magnetCall('/targets').then(function (d) {
      MAG.targets = (d && d.targets) || [];
      if (!MAG.targets.some(function (t) { return t.id === MAG.target; })) {
        var up = MAG.targets.filter(function (t) { return t.online; })[0] || MAG.targets[0];
        MAG.target = up ? up.id : 'nas';
      }
      return MAG.targets;
    });
  }
  function mgTargetInfo(id) {
    var arr = MAG.targets || [];
    for (var i = 0; i < arr.length; i++) if (arr[i].id === id) return arr[i];
    return null;
  }
  function mgDrawWhere() {
    var t = mgTargetInfo(MAG.target), w = $('#mgWhere');
    if (!w) return;
    if (!t) { w.textContent = '检查中…'; return; }
    w.textContent = (t.online ? '' : '这台现在连不上 · ') + (t.dir || '') +
      (t.free_gb != null ? ' · 剩余 ' + t.free_gb + ' GB' : '');
  }
  function mgDrawChips() {
    var box = $('#mgChips');
    if (!box) return;
    box.innerHTML = (MAG.targets || []).map(function (t) {
      return '<button class="mg-chip' + (t.id === MAG.target ? ' on' : '') + (t.online ? '' : ' off') +
        '" data-mgt="' + t.id + '">' + esc(t.name) +
        (t.free_gb != null ? '<i>' + t.free_gb + 'G</i>' : '<i>离线</i>') + '</button>';
    }).join('');
  }
  function magnetDraw(d) {
    var box = $('#mgList');
    if (!box) return;
    var tasks = (d && d.tasks) || [];
    mgDrawWhere();
    if (!tasks.length) {
      box.innerHTML = '<div class="mg-empty">还没有任务。选一台机器，粘一条磁力链接，点「保存」就开始下。</div>';
      return;
    }
    box.innerHTML = tasks.map(function (t) {
      var st = MG_ST[t.status] || t.status || '';
      var line = st;
      if (t.size) line += ' · ' + t.pct + '% · ' + sizeText(t.done) + ' / ' + sizeText(t.size);
      if (t.speed) line += ' · ' + sizeText(t.speed) + '/s';
      if (t.error) line += ' · ' + esc(t.error);
      var tg = ' data-target="' + (t.target || 'nas') + '"';
      var btns = '';
      if (t.status === 'active' || t.status === 'waiting') btns += '<button data-mg="pause"' + tg + ' data-gid="' + t.gid + '">暂停</button>';
      if (t.status === 'paused') btns += '<button data-mg="resume"' + tg + ' data-gid="' + t.gid + '">继续</button>';
      if (t.status !== 'removed') btns += '<button data-mg="remove"' + tg + ' data-gid="' + t.gid + '">删除</button>';
      return '<div class="mg-task">' +
        '<div class="mg-top"><b>' + esc(t.name || '（未知）') + '</b>' +
        '<span class="mg-st ' + (t.status || '') + '">' + esc(line) + '</span></div>' +
        '<div class="mg-bar"><i style="width:' + (t.pct || 0) + '%"></i></div>' +
        (btns ? '<div class="mg-act">' + btns + '</div>' : '') + '</div>';
    }).join('');
  }
  var _mgTick = 0;
  function magnetPoll(force) {
    magnetCall('/list').then(function (d) {
      if (d && d.ok === false && !d.tasks) { MAG.base = ''; throw new Error(d.error || '磁力服务出错'); }
      magnetDraw(d);
      if (force || (++_mgTick % 3) === 0) {                // 剩余空间/在线状态不用每 2 秒问一次
        mgTargets().then(function () { mgDrawChips(); mgDrawWhere(); })['catch'](function () { });
      }
    })['catch'](function (e) {
      var box = $('#mgList');
      if (box) box.innerHTML = '<div class="mg-empty">' + esc((e && e.message) || '连不上磁力服务') +
        '<br><button class="btn" data-mg="retry" style="margin-top:10px">重试</button></div>';
    });
  }
  function dlHide(gid) {
    (DL.mag || []).forEach(function (t) { if (t.gid === gid) t.status = 'removed'; });
    dlRender();
  }
  function magnetAct(kind, gid, target) {
    if (kind === 'retry') { MAG.base = ''; magnetPoll(true); return; }
    if (kind === 'remove') {
      var row = (DL.mag || []).filter(function (t) { return t.gid === gid; })[0];
      var done = row && (row.status === 'complete' || row.status === 'error');
      magnetCall('/remove', { gid: gid, target: target || 'nas' }).then(function (d) {
        if (d && d.ok === false) {
          if (done) { dlHide(gid); toast('已完成的任务：清单里已移除，文件还在那台机器上'); }
          else toast(d.error || '删除失败');
          return;
        }
        dlHide(gid);
      })['catch'](function () {
        if (done) { dlHide(gid); toast('已完成的任务：清单里已移除，文件还在那台机器上'); }
        else toast('删除失败');
      });
      return;
    }
    var name = { pause: '已暂停', resume: '已继续', remove: '已删除任务（文件留在下载夹里）' }[kind] || '已处理';
    magnetCall('/' + kind, { gid: gid, target: target || 'nas' }).then(function (d) {
      if (d && d.ok === false) { toast(d.error || '操作失败'); return; }
      toast(name);
      magnetPoll(true);
    })['catch'](function (e) { toast((e && e.message) || '操作失败'); });
  }
  function magnetSheet() {
    sheet('磁力保存',
      '<div class="note">粘 <b>magnet:?</b> 磁力链（也支持 .torrent 地址、http 直链）。NAS 只做转发：选哪台机器，就由那台去下，文件落在它共享的「<b>下载</b>」文件夹。</div>' +
      '<div class="mg-chips" id="mgChips"></div>' +
      '<div class="lf"><label for="mgUrl">磁力链接</label>' +
      '<input id="mgUrl" type="text" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="magnet:?xt=urn:btih:..."></div>' +
      '<div class="kv"><span>保存到</span><span id="mgWhere">检查中…</span></div>' +
      '<div class="err" id="mgErr"></div>' +
      '<div class="sheet-buttons"><button id="mgCancel">关闭</button>' +
      '<button class="primary" id="mgOk">保存</button></div>' +
      '<div id="mgList" class="mg-list"></div>');
    magnetStop();
    mgTargets().then(function () { mgDrawChips(); mgDrawWhere(); })['catch'](function () { });
    magnetPoll(true);
    MAG.timer = setInterval(magnetPoll, 2000);
    $('#mgCancel').onclick = function () { magnetStop(); closeSheet(); };
    $('#mgUrl').onkeydown = function (e) { if (e.key === 'Enter') $('#mgOk').click(); };
    $('#mgOk').onclick = function () {
      var v = ($('#mgUrl').value || '').trim();
      var err = $('#mgErr');
      if (!v) { err.textContent = '先把磁力链接粘进来'; return; }
      if (!/^(magnet:\?|https?:\/\/)/i.test(v)) { err.textContent = '要以 magnet:? 或 http(s):// 开头'; return; }
      var t = mgTargetInfo(MAG.target);
      if (t && !t.online) { err.textContent = '「' + t.name + '」现在连不上，换一台或者先把那台开机'; return; }
      err.textContent = '正在交给 ' + (t ? t.name : 'NAS') + '…';
      var btn = $('#mgOk'); btn.disabled = true;
      magnetCall('/add', { magnet: v, target: MAG.target || 'nas' }).then(function (d) {
        btn.disabled = false;
        if (!d || d.ok === false) { err.textContent = (d && d.error) || '添加失败'; return; }
        err.textContent = '';
        $('#mgUrl').value = '';
        toast('已开始下载（' + (t ? t.name : 'NAS') + '），进度在下面');
        magnetPoll(true);
      })['catch'](function (e) {
        btn.disabled = false;
        err.textContent = (e && e.message) || '添加失败';
      });
    };
    setTimeout(function () { var i = $('#mgUrl'); if (i) i.focus(); }, 100);
  }

  /* ---------------- ed2k 下载（NAS 上的 ed2k-hub，:5093 + aMule 容器） ----------------
     只有 NAS 一个目标：链接交给 NAS 上的 aMule，文件落到共享的「下载」文件夹。
     和磁力那套不同，这里没有「选哪台机器」——ed2k 只在 NAS 上下。 */
  var EDK = { base: '', probing: null, timer: null, info: null };
  function ed2kCandidates() {
    var list = [], seen = {};
    [location.protocol + '//' + location.hostname + ':5093', sameHost('http://192.168.1.10:5093')]
      .forEach(function (u) {
        u = String(u).replace(/\/+$/, '');
        if (!seen[u]) { seen[u] = 1; list.push(u); }
      });
    return list;
  }
  function ed2kEnsure() {
    if (EDK.base) return Promise.resolve(EDK.base);
    if (EDK.probing) return EDK.probing;
    var list = ed2kCandidates();
    EDK.probing = new Promise(function (resolve, reject) {
      (function tryOne(i) {
        if (i >= list.length) {
          EDK.probing = null;
          reject(new Error('连不上 ed2k 服务（NAS 上的 5093 没起来）'));
          return;
        }
        var done = false, ctl = null;
        var tm = setTimeout(function () {
          if (done) return; done = true;
          try { ctl && ctl.abort(); } catch (e) { }
          tryOne(i + 1);
        }, 1600);
        try { ctl = new AbortController(); } catch (e) { ctl = null; }
        var opt = { cache: 'no-store', credentials: 'omit' };
        if (ctl) opt.signal = ctl.signal;
        fetch(list[i] + '/health', opt)
          .then(function (r) { return r.json(); })
          .then(function (d) {
            if (done) return; done = true; clearTimeout(tm);
            if (d && d.ok) { EDK.base = list[i]; EDK.probing = null; resolve(list[i]); }
            else tryOne(i + 1);
          })['catch'](function () {
            if (done) return; done = true; clearTimeout(tm);
            tryOne(i + 1);
          });
      })(0);
    });
    return EDK.probing;
  }
  function ed2kCall(path, body) {
    return ed2kEnsure().then(function (base) {
      var opt = body === undefined
        ? { cache: 'no-store', credentials: 'omit' }
        : { method: 'POST', cache: 'no-store', credentials: 'omit',
            headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
      return fetch(base + path, opt).then(function (r) { return r.json(); });
    });
  }
  function ed2kStop() { if (EDK.timer) { clearInterval(EDK.timer); EDK.timer = null; } }
  var EDK_ST = {
    Downloading: '下载中', Waiting: '等待源', Paused: '已暂停', Stopped: '已停止',
    Hashing: '校验中', Completing: '收尾中', Allocating: '分配空间', Connecting: '连接中',
    Insufficient: '空间不足', Error: '出错',
    Transferring: '传到电脑', Done: '已完成'
  };
  function edkDrawInfo(d) {
    var box = $('#edkInfo');
    if (!box) return;
    if (!d || !d.ok) { box.textContent = (d && d.error) || '服务没响应'; return; }
    var low = /LowID/i.test(d.ed2k || '');
    box.textContent = (d.ed2k || '未连接') + ' · ' + (d.kad || '') +
      (low ? ' · 低速模式（端口没转发，能下但慢）' : '');
    box.className = 'edk-info' + (low ? ' warn' : '');
  }
  function ed2kDraw(d) {
    var box = $('#edkList');
    if (!box) return;
    edkDrawInfo(d);
    var where = $('#edkWhere');
    if (where) where.textContent = (d && d.dir) || '共享的「下载」文件夹';
    var tasks = (d && d.tasks) || [];
    if (!tasks.length) {
      box.innerHTML = '<div class="mg-empty">还没有任务。把 ed2k:// 链接粘到上面，点「添加」就开始下。</div>';
      return;
    }
    box.innerHTML = tasks.map(function (t) {
      var st = EDK_ST[t.status] || t.status || '排队中';
      var line = st;
      if (t.size) line += ' · ' + (t.percent || 0).toFixed(1) + '% · ' + sizeText(t.done || 0) + ' / ' + sizeText(t.size);
      else line += ' · 正在找源';
      if (t.speed) line += ' · ' + sizeText(t.speed) + '/s';
      var btns = '';
      if (t.status === 'Paused' || t.status === 'Stopped') btns += '<button data-edk="resume" data-hash="' + t.hash + '">继续</button>';
      else btns += '<button data-edk="pause" data-hash="' + t.hash + '">暂停</button>';
      btns += '<button data-edk="cancel" data-hash="' + t.hash + '">删除</button>';
      return '<div class="mg-task">' +
        '<div class="mg-top"><b>' + esc(t.name || t.hash.slice(0, 8)) + '</b>' +
        '<span class="mg-st">' + esc(line) + '</span></div>' +
        '<div class="mg-bar"><i style="width:' + (t.percent || 0) + '%"></i></div>' +
        '<div class="mg-act">' + btns + '</div></div>';
    }).join('');
  }
  function ed2kPoll(force) {
    ed2kCall('/list').then(function (d) {
      if (d && d.ok === false && !d.tasks) { EDK.base = ''; }
      ed2kDraw(d);
    })['catch'](function (e) {
      var box = $('#edkList');
      if (box) box.innerHTML = '<div class="mg-empty">' + esc((e && e.message) || '连不上 ed2k 服务') +
        '<br><button class="btn" data-edk="retry" style="margin-top:10px">重试</button></div>';
    });
  }
  function ed2kAct(kind, hash) {
    if (kind === 'retry') { EDK.base = ''; ed2kPoll(true); return; }
    var name = { pause: '已暂停', resume: '已继续', cancel: '已删除任务（临时文件一并清掉）' }[kind] || '已处理';
    ed2kCall('/' + kind, { hash: hash }).then(function (d) {
      if (d && d.ok === false) { toast(d.error || '操作失败'); return; }
      toast(name);
      ed2kPoll(true);
    })['catch'](function (e) { toast((e && e.message) || '操作失败'); });
  }
  function ed2kSheet() {
    sheet('ed2k 下载',
      '<div class="note">粘 <b>ed2k://</b> 链接（一行一条也可以），交给 NAS 上的 aMule 去下，文件落在共享的「<b>下载</b>」文件夹，下完直接在云匣里能看。</div>' +
      '<div class="lf"><label for="edkIn">ed2k 链接</label>' +
      '<textarea id="edkIn" rows="3" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="ed2k://|file|名称.mkv|1234567890|HASH|/"></textarea></div>' +
      '<div class="kv"><span>保存到</span><span id="edkWhere">读取中…</span></div>' +
      '<div class="kv"><span>网络</span><span id="edkInfo" class="edk-info">检查中…</span></div>' +
      '<div class="err" id="edkErr"></div>' +
      '<div class="sheet-buttons"><button id="edkCancel">关闭</button>' +
      '<button class="primary" id="edkOk">添加</button></div>' +
      '<div id="edkList" class="mg-list"></div>');
    ed2kStop();
    ed2kPoll(true);
    EDK.timer = setInterval(ed2kPoll, 2000);
    $('#edkCancel').onclick = function () { ed2kStop(); closeSheet(); };
    $('#edkOk').onclick = function () {
      var raw = ($('#edkIn').value || '').trim();
      var err = $('#edkErr');
      var links = raw.split(/[\r\n]+/).map(function (x) { return x.trim(); }).filter(Boolean);
      if (!links.length) { err.textContent = '先把 ed2k 链接粘进来'; return; }
      var bad = links.filter(function (x) { return !/^ed2k:\/\//i.test(x); });
      if (bad.length) { err.textContent = '有 ' + bad.length + ' 行不是 ed2k:// 开头'; return; }
      err.textContent = '正在添加…';
      var btn = $('#edkOk'); btn.disabled = true;
      ed2kCall('/add', { links: links }).then(function (d) {
        btn.disabled = false;
        if (!d || !d.ok) { err.textContent = (d && (d.errors || [])[0]) || '添加失败'; return; }
        err.textContent = '';
        $('#edkIn').value = '';
        toast('已加入 ' + d.added + ' 个任务');
        ed2kPoll(true);
      })['catch'](function (e) {
        btn.disabled = false;
        err.textContent = (e && e.message) || '添加失败';
      });
    };
    setTimeout(function () { var i = $('#edkIn'); if (i) i.focus(); }, 100);
  }

  /* ---------------- 统一下载入口（磁力 + ed2k） ----------------
     一个输入框，按前缀分流：magnet:? /.torrent / http(s) 直链 → 磁力中枢（可选下到 NAS 或电脑）；
     ed2k:// → NAS 上的 aMule。列表把两边的任务合并显示，操作按钮各走各的接口。 */
  var DL = { mag: [], edk: [], timer: null, magInfo: null, edkInfo: null, dir: '' };
  function dlCurDir() {
    // 本机存储的当前目录就写在地址栏里（dufs 每个目录一个 URL）
    if (isRemote() || (ST.src && ST.src !== 'nas')) return '';
    try { return pathParts().join('/'); } catch (e) { return ''; }
  }
  // 下载落点要看「现在在哪个来源里」：NAS 本机 → 直接下到当前目录；
  // 电脑（LIFRE）→ 交给那台机器的下载节点，下到它共享根下的同一路径。
  function dlCtx() {
    var id = ST.src || 'nas';
    var clean = function (p) { return String(p || '').replace(/^\/+|\/+$/g, ''); };
    if (id === 'pc') {
      var sub = clean(ST.path);
      return { target: 'pc', dir: sub,
               label: '电脑 · LIFRE /' + (sub || ''), where: '电脑 · LIFRE 的「' + (sub || '共享根') + '」',
               note: '电脑端自己下，直接落到 ' + (sub ? '/ ' + sub : '共享根目录') };
    }
    if (id === 'nas' || !id) {
      var d = dlCurDir();
      return { target: 'nas', dir: d, label: d ? '/' + d : 'NAS 共享根目录',
               where: d ? '/' + d : 'NAS 共享根目录',
               note: '' };
    }
    // pc2（PXY）和 115 网盘都没有下载节点：只能落到 NAS 的「下载」
    return { target: 'nas', dir: '', label: 'NAS 的「下载」（这个来源没有下载节点）',
             where: 'NAS 的「下载」', note: '这个来源没有下载节点，会先落到 NAS 的「下载」' };
  }
  function dlStop() { if (DL.timer) { clearInterval(DL.timer); DL.timer = null; } }
  var DL_RANK = { active: 0, waiting: 1, paused: 2, complete: 3, error: 4 };

  function dlMagnetRow(t) {
    var st = MG_ST[t.status] || t.status || '';
    var line;
    if (t.status === 'complete') {
      line = '已完成 · ' + sizeText(t.size || t.done || 0) + (t.path ? ' · ' + t.path : '');
    } else {
      line = st;
      if (t.size) line += ' · ' + t.pct + '% · ' + sizeText(t.done) + ' / ' + sizeText(t.size);
      if (t.speed) {
        line += ' · ' + sizeText(t.speed) + '/s';
        var eta = dlEta((t.size - (t.done || 0)) / t.speed);
        if (eta) line += ' · 还剩 ' + eta;
      } else if (t.status === 'active' && t.pct === 0) {
        line += ' · 正在找源';
      }
    }
    var tg = ' data-target="' + (t.target || 'nas') + '"';
    var btns = '';
    if (t.status === 'active' || t.status === 'waiting') btns += '<button data-mg="pause"' + tg + ' data-gid="' + t.gid + '">暂停</button>';
    if (t.status === 'paused') btns += '<button data-mg="resume"' + tg + ' data-gid="' + t.gid + '">继续</button>';
    if (t.status === 'complete') t.status = 'complete';
    if (t.status !== 'removed') btns += '<button data-mg="remove"' + tg + ' data-gid="' + t.gid + '">删除</button>';
    return {
      rank: DL_RANK[t.status] != null ? DL_RANK[t.status] : 5,
      html: '<div class="mg-task' + (t.status === 'complete' ? ' is-done' : '') + '">' +
        '<div class="mg-top"><b>' + (t.status === 'complete' ? '✓ ' : '') + esc(t.name || '（未知）') + '</b>' +
        '<span class="dl-badge">磁力</span>' +
        '<span class="mg-st ' + (t.status || '') + '">' + esc(line) + '</span></div>' +
        '<div class="mg-bar"><i style="width:' + (t.pct || 0) + '%"></i></div>' +
        (btns ? '<div class="mg-act">' + btns + '</div>' : '') + '</div>'
    };
  }

  function dlEta(sec) {
    if (!sec || !isFinite(sec) || sec <= 0 || sec > 86400 * 7) return '';
    var h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
    if (h >= 24) return Math.floor(h / 24) + ' 天 ' + (h % 24) + ' 小时';
    if (h > 0) return h + ' 小时 ' + m + ' 分';
    if (m > 0) return m + ' 分';
    return Math.max(1, Math.round(sec)) + ' 秒';
  }
  function dlEdkRow(t) {
    var st = EDK_ST[t.status] || t.status || '排队中';
    var destTxt = t.dest ? '/' + t.dest : '共享根目录';
    var line = st;
    if (t.status === 'Done') {
      line = '已完成 · 在 ' + destTxt;
    } else {
      if (t.size) {
        line += ' · ' + (t.percent || 0).toFixed(1) + '% · ' +
          sizeText(t.done || 0) + ' / ' + sizeText(t.size);
        if (t.speed) {
          line += ' · ' + sizeText(t.speed) + '/s';
          var eta = dlEta((t.size - (t.done || 0)) / t.speed);
          if (eta) line += ' · 还剩 ' + eta;
        }
      } else {
        line += ' · 正在找源';
      }
      if (t.target && t.target !== 'nas') {
        line += ' · NAS 中转 → ' + (t.target_name || '电脑') + (t.dest ? ' /' + t.dest : '');
      } else {
        line += ' · 下到 NAS 后移到 ' + destTxt;
      }
    }
    var btns = '';
    var over = (t.status === 'Done' || t.status === 'Error');
    if (!over) {
      if (t.status === 'Paused' || t.status === 'Stopped') btns += '<button data-edk="resume" data-hash="' + t.hash + '">继续</button>';
      else btns += '<button data-edk="pause" data-hash="' + t.hash + '">暂停</button>';
    }
    btns += '<button data-edk="cancel" data-hash="' + t.hash + '">删除</button>';
    var rank = t.status === 'Downloading' ? 0 : (t.status === 'Waiting' || t.status === 'Connecting' ? 1
      : (t.status === 'Paused' || t.status === 'Stopped' ? 2 : 5));
    return {
      rank: rank,
      html: '<div class="mg-task' + (t.status === 'Done' ? ' is-done' : '') + '">' +
        '<div class="mg-top"><b>' + (t.status === 'Done' ? '✓ ' : '') + esc(t.name || t.hash.slice(0, 8)) + '</b>' +
        '<span class="dl-badge edk">ed2k</span>' +
        '<span class="mg-st">' + esc(line) + '</span></div>' +
        '<div class="mg-bar"><i style="width:' + (t.percent || 0) + '%"></i></div>' +
        '<div class="mg-act">' + btns + '</div></div>'
    };
  }

  function dlDrawInfo() {
    var box = $('#dlInfo');
    if (!box) return;
    var parts = [];
    if (DL.magInfo && DL.magInfo.ok) parts.push('磁力 ' + (DL.magInfo.engine ? '就绪' : '未就绪'));
    else parts.push('磁力 不可用');
    if (DL.edkInfo && DL.edkInfo.ok) {
      var low = /LowID/i.test(DL.edkInfo.ed2k || '');
      parts.push('ed2k ' + (low ? '低速模式' : '就绪'));
    } else parts.push('ed2k 不可用');
    box.textContent = parts.join(' · ');
    box.className = 'edk-info' + ((DL.magInfo && DL.magInfo.ok && DL.edkInfo && DL.edkInfo.ok) ? '' : ' warn');
  }

  function dlRender() {
    var box = $('#dlList');
    if (!box) return;
    dlDrawInfo();
    var rows = [];
    var edkNames = {};
    (DL.edk || []).forEach(function (t) {
      if (t.name && (t.status === 'Done' || t.status === 'Transferring')) edkNames[t.name] = 1;
    });
    (DL.mag || []).forEach(function (t) {
      if (t.status === 'removed') return;
      if (t.name && edkNames[t.name]) return;      // ed2k 转交给电脑的副本，别重复显示
      rows.push(dlMagnetRow(t));
    });
    (DL.edk || []).forEach(function (t) { rows.push(dlEdkRow(t)); });

    var sum = $('#dlSum');
    if (!rows.length) {
      box.innerHTML = '<div class="mg-empty">队列是空的。<br>点下面的「添加任务」，或在文件列表点右下角的 <b>＋</b> → <b>下载</b>，把磁力 / ed2k / 直链粘进去。</div>';
      if (sum) sum.innerHTML = '<span>暂无任务</span>';
      return;
    }
    rows.sort(function (a, b) { return a.rank - b.rank; });
    var live = rows.filter(function (r) { return r.rank <= 2; });
    var rest = rows.filter(function (r) { return r.rank > 2; });
    var speed = 0;
    (DL.mag || []).forEach(function (t) { if (t.status === 'active') speed += (t.speed || 0); });
    (DL.edk || []).forEach(function (t) { if (t.status === 'Downloading') speed += (t.speed || 0); });

    var html = '';
    if (live.length) {
      html += '<div class="dl-grp">进行中 · ' + live.length + (speed ? ' · ' + sizeText(speed) + '/s' : '') + '</div>' +
        live.map(function (r) { return r.html; }).join('');
    }
    if (rest.length) {
      html += '<div class="dl-grp">已结束 · ' + rest.length + '</div>' +
        rest.map(function (r) { return r.html; }).join('');
    }
    box.innerHTML = html;
    if (sum) {
      sum.innerHTML = '<span>' + (live.length ? live.length + ' 个在跑' : '没有在跑的任务') +
        (speed ? ' · ' + sizeText(speed) + '/s' : '') +
        (rest.length ? ' · ' + rest.length + ' 个已结束' : '') + '</span>' +
        (rest.length ? '<button type="button" class="mini" id="dlClear">清理已完成</button>' : '');
      var clr = $('#dlClear');
      if (clr) clr.onclick = function () {
        var jobs = [];
        (DL.mag || []).forEach(function (t) {
          if (t.status === 'complete' || t.status === 'error') jobs.push(magnetCall('/remove', { gid: t.gid, target: t.target || 'nas' })['catch'](function () { }));
        });
        (DL.edk || []).forEach(function (t) {
          if (t.status === 'Done' || t.status === 'Error') jobs.push(ed2kCall('/cancel', { hash: t.hash })['catch'](function () { }));
        });
        Promise.all(jobs).then(function () { toast('已清理 ' + jobs.length + ' 项'); dlPoll(true); });
      };
    }
  }

  function dlPoll(force) {
    var jobs = [];
    jobs.push(magnetCall('/list').then(function (d) {
      if (d && d.ok === false && !d.tasks) throw new Error(d.error || '磁力服务出错');
      DL.mag = (d && d.tasks) || [];
    })['catch'](function () { DL.mag = []; }));
    jobs.push(ed2kCall('/list').then(function (d) {
      DL.edkInfo = d;
      DL.edk = (d && d.tasks) || [];
    })['catch'](function () { DL.edk = []; DL.edkInfo = null; }));
    if (force || !DL.magInfo) {
      jobs.push(magnetCall('/health').then(function (d) { DL.magInfo = d; })['catch'](function () { DL.magInfo = null; }));
    }
    Promise.all(jobs).then(function () { dlRender(); });
  }

  function dlAdd() {
    var raw = ($('#dlIn').value || '').trim();
    var err = $('#dlErr');
    var lines = raw.split(/[\r\n]+/).map(function (x) { return x.trim(); }).filter(Boolean);
    if (!lines.length) { err.textContent = '先把链接粘进来'; return; }
    var mags = [], edks = [], bad = [];
    lines.forEach(function (l) {
      if (/^ed2k:\/\//i.test(l)) edks.push(l);
      else if (/^(magnet:\?|https?:\/\/)/i.test(l)) mags.push(l);
      else bad.push(l);
    });
    if (bad.length) { err.textContent = '有 ' + bad.length + ' 行认不出（要 magnet:? / ed2k:// / http(s)://）'; return; }
    var tgt = (DL.ctx || {}).target || 'nas';
    var tt = mgTargetInfo(tgt);
    if (tt && tt.online === false) {
      err.textContent = (tgt === 'nas' ? 'NAS 上的下载服务现在连不上' : '「' + tt.name + '」现在连不上（电脑要开机）');
      return;
    }
    var btn = $('#dlOk'); btn.disabled = true;
    err.textContent = '正在添加…';
    var jobs = [];
    var added = 0, errs = [];
    if (edks.length) {
      jobs.push(ed2kCall('/add', { links: edks, target: (DL.ctx || {}).target || 'nas', dir: (DL.ctx || {}).dir || '' }).then(function (d) {
        if (d && d.ok) added += d.added || 0;
        else errs.push((d && (d.errors || [])[0]) || 'ed2k 添加失败');
      })['catch'](function (e) { errs.push('ed2k：' + ((e && e.message) || '添加失败')); }));
    }
    mags.forEach(function (m) {
      jobs.push(magnetCall('/add', { magnet: m, target: (DL.ctx || {}).target || 'nas', dir: (DL.ctx || {}).dir || '' }).then(function (d) {
        if (d && d.ok !== false) added += 1;
        else errs.push((d && d.error) || '磁力添加失败');
      })['catch'](function (e) { errs.push('磁力：' + ((e && e.message) || '添加失败')); }));
    });
    Promise.all(jobs).then(function () {
      btn.disabled = false;
      if (!added) { err.textContent = errs[0] || '添加失败'; return; }
      err.textContent = errs.length ? errs[0] : '';
      $('#dlIn').value = '';
      var bits = [];
      if (mags.length) bits.push(mags.length + ' 个磁力');
      if (edks.length) bits.push(edks.length + ' 个 ed2k');
      toast('已加 ' + bits.join(' + ') + ' → ' + ((DL.ctx || {}).where || 'NAS'));
    });
  }

  function dlQueueSheet() {
    sheet('下载队列',
      '<div class="dl-sum" id="dlSum"><span>读取中…</span></div>' +
      '<div id="dlList" class="mg-list"><div class="mg-empty">读取中…</div></div>' +
      '<div class="kv kv-svc"><span>服务</span><span id="dlInfo" class="edk-info">检查中…</span></div>' +
      '<div class="sheet-buttons"><button id="dlClose">关闭</button>' +
      '<button class="primary" id="dlAdd">添加任务</button></div>');
    dlStop();
    DL.ctx = dlCtx();
    DL.dir = DL.ctx.dir;
    DL.timer = setInterval(dlPoll, 2000);
    dlPoll(true);
    $('#dlClose').onclick = function () { dlStop(); closeSheet(); };
    // 提交磁力/ed2k 写的是 NAS 上的中枢，跟「当前目录能不能写」无关 ——
    // 只读或未登录时 ＋ 是隐藏的，这里必须留一个入口，否则下载功能对匿名用户等于不存在
    $('#dlAdd').onclick = function () { dlStop(); dlSheet(); };
  }

  function dlSheet() {
    sheet('下载',
      '<div class="dl-dest"><div class="dl-dest-ico">📁</div><div class="dl-dest-tx">' +
        '<div class="dl-dest-t">文件落到</div><div class="dl-dest-p" id="dlWhere">—</div></div></div>' +
      '<div class="lf"><label for="dlIn">粘贴链接</label>' +
      '<textarea id="dlIn" rows="3" autocapitalize="off" autocorrect="off" spellcheck="false" ' +
      'placeholder="magnet:?xt=urn:btih:...&#10;ed2k://|file|xxx.mkv|123|HASH|/&#10;https://.../xxx.torrent"></textarea>' +
      '<div class="dl-tools"><span class="dl-scan" id="dlScan">磁力 / ed2k / 直链，一行一条</span>' +
      '<button type="button" class="mini" id="dlPaste">粘贴</button></div></div>' +
      '<div class="dl-hint" id="dlHint"></div>' +
      '<div class="err" id="dlErr"></div>' +
      '<div class="sheet-buttons"><button id="dlClose">关闭</button>' +
      '<button class="primary" id="dlOk">添加</button></div>' +
      '<div class="dl-more"><a id="dlGo">查看下载队列 →</a></div>');

    dlStop();
    DL.ctx = dlCtx();
    DL.dir = DL.ctx.dir;
    var wh = $('#dlWhere');
    if (wh) wh.textContent = DL.ctx.where;

    var ta = $('#dlIn'), scan = $('#dlScan'), hintBox = $('#dlHint'), okBtn = $('#dlOk');

    function parse() {
      var out = { mag: [], edk: [], bad: [] };
      String(ta.value || '').split(/\r?\n/).forEach(function (raw) {
        var l = raw.trim();
        if (!l) return;
        if (/^ed2k:\/\//i.test(l)) out.edk.push(l);
        else if (/^(magnet:\?|https?:\/\/)/i.test(l)) out.mag.push(l);
        else out.bad.push(l);
      });
      return out;
    }
    function refresh() {
      var r = parse();
      var bits = [];
      if (r.mag.length) bits.push(r.mag.length + ' 个磁力');
      if (r.edk.length) bits.push(r.edk.length + ' 个 ed2k');
      var n = r.mag.length + r.edk.length;
      if (r.bad.length) {
        scan.className = 'dl-scan bad';
        scan.textContent = r.bad.length + ' 行认不出（要 magnet:? / ed2k:// / http(s)://）';
      } else if (n) {
        scan.className = 'dl-scan ok';
        scan.textContent = '识别到 ' + bits.join(' + ');
      } else {
        scan.className = 'dl-scan';
        scan.textContent = '磁力 / ed2k / 直链，一行一条';
      }
      okBtn.textContent = n > 1 ? '添加 ' + n + ' 项' : '添加';
      okBtn.disabled = !n;
      if (r.edk.length) {
        hintBox.style.display = 'block';
        if ((DL.ctx || {}).target === 'pc') {
          hintBox.innerHTML = 'ed2k 由 NAS 先下到自己的「<b>下载</b>」，下完立刻转给电脑，落到电脑的 <b>' +
            (DL.ctx.dir ? '/' + DL.ctx.dir : '共享根目录') + '</b>。';
        } else {
          hintBox.innerHTML = 'ed2k 先下到 NAS 的「<b>下载</b>」，下完再移动到 <b>' +
            (DL.dir ? '/' + DL.dir : '共享根目录') + '</b>。';
        }
      } else {
        hintBox.style.display = 'none';
      }
    }
    ta.oninput = refresh;
    ta.onpaste = function () { setTimeout(refresh, 30); };
    refresh();

    var paste = $('#dlPaste');
    if (paste) paste.onclick = function () {
      var put = function (txt) {
        if (!txt) return;
        ta.value = ta.value ? (ta.value.replace(/\s+$/, '') + '\n' + txt) : txt;
        refresh(); ta.focus();
      };
      if (navigator.clipboard && navigator.clipboard.readText) {
        navigator.clipboard.readText().then(put)['catch'](function () { toast('读不到剪贴板，长按输入框粘贴'); });
      } else {
        ta.focus(); toast('长按输入框粘贴');
      }
    };

    var go = $('#dlGo');
    if (go) go.onclick = function () { closeSheet(); setTimeout(dlQueueSheet, 120); };
  }

  /* ---------------- 网盘来源（走 NAS 上的转发服务） ---------------- */
  // 全库搜索（dufs 的 ?q=）是「同步遍历整棵树」：NAS 那份共享下面挂了两个巨大的媒体目录
  // （media/Jav、media/影音库），实测一次 ?q= 65 秒还没响应、页面直接白屏。
  // 所以按主机关掉它，只保留当前目录的实时过滤 —— 否则用户按一下回车就以为坏了。
  var WIDE_SEARCH_SLOW = ['192.168.1.10', '100.64.0.1'];
  function wideSearchOk() {
    if (srcKind() !== 'dufs' || ST.path) return false;
    return WIDE_SEARCH_SLOW.indexOf(location.hostname) < 0;
  }
  function wideSearchWhy() {
    if (srcKind() !== 'dufs' || ST.path) return '这个来源只能搜当前目录（全库搜索是 NAS 本机共享的能力）';
    return '这个来源文件太多，全库搜索会卡住；先进入某个目录再搜，或者告诉我，我给 NAS 建一份搜索索引';
  }

  function srcKind() { var s = activeSrc(); return s ? s.kind : 'dufs'; }
  function isDav() { return srcKind() === 'webdav'; }              // 网盘：走 NAS 上的转发服务
  function isRemoteDufs() { return srcKind() === 'dufs-remote'; }  // 别人的 dufs：直接问它的 ?json
  function isRemote() { return isDav() || isRemoteDufs(); }
  // 页面是不是从 Tailscale 地址打开的（手机在外面用 Tailscale 时就是这样）
  function fromTailnet() {
    var h = location.hostname || '';
    return /^100\.(6[4-9]|[7-9]\d|1[0-2]\d)\./.test(h) || /\.ts\.net$/i.test(h);
  }
  // 同一台机器上的服务（115 转发、听译中枢）：页面从 Tailscale 打开时，
  // 不能还用 192.168.x.x 那种局域网地址，否则手机上直接卡死
  function sameHost(u) {
    if (!u) return u;
    try {
      var x = new URL(u, location.href);
      if (fromTailnet() && x.hostname !== location.hostname) return x.protocol + '//' + location.hostname + ':' + x.port + x.pathname;
      return u;
    } catch (e) { return u; }
  }
  // 别的机器（电脑上的 dufs）：优先用配好的 Tailscale 地址
  function otherHost(s, lanKey, wanKey) {
    if (!s) return '';
    if (fromTailnet() && s[wanKey]) return s[wanKey];
    return s[lanKey] || '';
  }
  function davRelay() {
    var s = activeSrc(); if (!s) return '';
    if (s.relay) return sameHost(s.relay);
    return otherHost(s, 'base', 'baseWan');
  }
  function remoteBase() {
    var s = activeSrc();
    if (!s) return '';
    var b = s.relay ? sameHost(s.relay) : otherHost(s, 'base', 'baseWan');
    return b.slice(-1) === '/' ? b : b + '/';
  }

  function davToItem(x) {
    var rel = (ST.path ? ST.path + '/' : '') + x.n;
    if (isRemoteDufs()) {                     // dufs 那边：文件名就是链接的最后一段
      var u = remoteBase() + encPath(rel) + (x.d ? '/' : '');
      return {
        name: x.n, isDir: !!x.d, size: x.s || 0, mtime: x.m || 0,
        kind: kindOf(x.n, !!x.d), davPath: rel, isDav: true, isRemote: true, url: u
      };
    }
    return {
      name: x.n, isDir: !!x.d, size: x.s || 0, mtime: x.m || 0,
      kind: kindOf(x.n, !!x.d), davPath: rel, isDav: true, isRemote: true,
      url: davRelay() + 'file?p=' + encodeURIComponent(rel)
    };
  }

  // 远程来源的目录清单：网盘走转发服务；别人的 dufs 直接用它的 ?json 接口（它开了 CORS）
  function remoteListUrl(path) {
    if (isRemoteDufs()) return remoteBase() + encPath(path || '') + (path ? '/' : '') + '?json';
    return davRelay() + 'list?p=' + encodeURIComponent(path || '');
  }
  function remoteParse(d, path) {
    if (isRemoteDufs()) {
      return ((d && d.paths) || []).map(function (p) {
        return { n: p.name, d: String(p.path_type).indexOf('Dir') >= 0 ? 1 : 0, s: p.size || 0, m: p.mtime || 0 };
      });
    }
    return (d && d.items) || [];
  }

  function davFiltered() {
    var arr = (ST.davItems || []).slice();
    if (ST.q) {
      var q = ST.q.toLowerCase();
      arr = arr.filter(function (x) { return x.name.toLowerCase().indexOf(q) >= 0; });
    }
    var dir = ST.order === 'desc' ? -1 : 1;
    arr.sort(function (a, b) {
      if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
      if (ST.sort === 'size') return ((a.isDir ? -1 : a.size) - (b.isDir ? -1 : b.size)) * dir;
      if (ST.sort === 'mtime' || ST.view === 'recent') return (a.mtime - b.mtime) * (ST.view === 'recent' ? -1 : dir);
      return a.name.localeCompare(b.name, 'zh-CN') * dir;
    });
    if (ST.view === 'recent') arr = arr.slice(0, 30);
    return arr;
  }

  function loadDav(path, fresh) {
    if (!isRemote()) return;
    ST.path = path || '';
    ST.davLoading = true; ST.davErr = null; ST.davNeedAuth = false;
    if (fresh) ST.davItems = [];
    render();
    davFetch((activeSrc() || {}).id, ST.path, false);
  }

  /* 401 不一定是「没登录」：手机上存着的那份旧凭据（账号改过、密码换过）
     会让一个匿名本来就能读的共享显示成「需要登录才能读取」。
     所以带了凭据还被 401 时，先把它清掉、匿名再试一次，只有匿名也被拒才提示登录。 */
  function davFetch(sid, path, retried) {
    var ctl = (typeof AbortController !== 'undefined') ? new AbortController() : null;
    var tid = ctl ? setTimeout(function () { try { ctl.abort(); } catch (e) { } }, 12000) : 0;
    var usedAuth = !!srcAuth(sid);
    fetch(remoteListUrl(path), { cache: 'no-store', credentials: 'omit',
        signal: ctl ? ctl.signal : undefined,
        headers: authHeadersFor(sid) })
      .then(function (r) {
        if (tid) clearTimeout(tid);
        if (r.status === 401 || r.status === 403) {
          if (usedAuth && !retried) {
            setSrcAuth(sid, '');
            toast('「' + ((srcById(sid) || {}).name || '这个来源') + '」保存的登录已失效，已按匿名只读读取');
            davFetch(sid, path, true);
            return null;
          }
          ST.davNeedAuth = true; ST.davErr = null; ST.davItems = []; ST.davLoading = false;
          render();
          return null;
        }
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(function (d) {
        if (!d) return;
        ST.davNeedAuth = false;
        if (d && d.error) { ST.davErr = d.error; ST.davItems = []; }
        else { ST.davItems = remoteParse(d, path).map(davToItem); }
        ST.davLoading = false;
        render();
      })
      .catch(function (e) {
        if (tid) clearTimeout(tid);
        var m = String((e && e.message) || e);
        if ((e && e.name === 'AbortError') || /abort/i.test(m)) m = '12 秒没响应（这个地址连不上）';
        // 脚本自己报的错（多为手机缓存了旧版 JS）不能被说成「电脑没开机」
        ST.davJsErr = /TypeError|ReferenceError|not a function|not an object|reading '|undefined is not/i.test(m);
        if (ST.davJsErr) m = '页面脚本出错：' + m;
        ST.davErr = m;
        ST.davUrl = remoteListUrl(ST.path);
        ST.davItems = []; ST.davLoading = false;
        render();
      });
  }

  function davCrumbs() {
    var s = activeSrc();
    if (!s) return '';
    var segs = String(ST.path || '').split('/').filter(Boolean);
    var out = [];
    out.push(segs.length
      ? '<a href="javascript:;" data-dav="">' + esc(s.name) + '</a>'
      : '<span class="now">' + esc(s.name) + '</span>');
    var acc = '';
    segs.forEach(function (p, i) {
      acc += (acc ? '/' : '') + p;
      out.push('<span class="sep">/</span>');
      if (i === segs.length - 1) out.push('<span class="now">' + esc(p) + '</span>');
      else out.push('<a href="javascript:;" data-dav="' + esc(acc) + '">' + esc(p) + '</a>');
    });
    return out.join('');
  }


  function thumbUrl(url) {
    var i = url.lastIndexOf('/');
    return url.slice(0, i + 1) + '.thumbs/' + url.slice(i + 1) + '.jpg';
  }

  function renderFiles(list) {
    el.fileList.className = 'file-list' + (ST.mode === 'grid' ? ' grid' : '');
    // 一次最多画 500 行（手机 DOM 上限），其余用「加载更多」按需追加；换目录/换排序会复位
    var total = list.length, tail = '';
    if (total > LIMIT) {
      tail = '<div class="more-box"><button class="btn-more" id="moreBtn" type="button">' +
        icn('add', 16) + ' 加载更多（还剩 ' + nfmt(total - LIMIT) + ' 个）</button></div>';
      list = list.slice(0, LIMIT);
    }
    if (!list.length) {
      el.fileList.className = 'file-list';
      var emptyMsg = ST.q ? '没有匹配「' + esc(ST.q) + '」的项目' : '这里还没有文件';
      el.fileList.innerHTML = '<div class="empty"><b>' + icn(ST.q ? 'search' : 'folder', 30) + '</b>' +
        emptyMsg + '</div>';
      return;
    }
    var listHead = ST.mode === 'grid' ? '' :
      '<div class="list-head"><i></i><b>名称</b><b class="r">修改时间</b><b class="r">大小</b><i></i></div>';
    el.fileList.innerHTML = listHead + list.map(function (x) {
      var i = CUR.indexOf(x);
      var inner;
      if (ST.mode === 'grid' && THUMBS && x.kind === 'image') {
        inner = '<img loading="lazy" decoding="async" fetchpriority="low" alt="" src="' + esc(thumbUrl(x.url)) +
          '" onerror="this.style.display=\'none\';window.__icoFall(this,\'' + x.kind + '\')">';
      } else inner = iconOf(x);
      // 视频/音频：标出看到哪儿了（和播放器共用同一份进度记录）
      var seen = 0;
      if (x.kind === 'video' || x.kind === 'audio') {
        try {
          var u = String(x.url || x.name), h = 0;
          for (var q2 = 0; q2 < u.length; q2++) h = (h * 31 + u.charCodeAt(q2)) | 0;
          seen = parseFloat(localStorage.getItem('mfm_pos_' + (h >>> 0)) || '0') || 0;
        } catch (e) { }
      }
      // 远程来源列表里标出文件在哪（只留末一级文件夹，标题已写明是哪一类，不再重复）
      var meta;
      if (x.folder) {
        var seg = String(x.folder).split('/');
        meta = dayOf(x.mtime) + ' · ' + (seg.length > 1 ? '…/' : '') + seg[seg.length - 1];
      } else {
        meta = dayOf(x.mtime) + ' · ' + (x.isDir ? ((x.size >= 1000 ? '>999' : x.size) + ' 项') : kindLabel(x.kind));
      }
      if (seen > 8) meta += ' · 已看 ' + Math.floor(seen / 60) + ':' + pad(Math.floor(seen % 60));
      return '<div class="file-row" data-i="' + i + '">' +
        '<div class="file-icon ' + fiOf(x) + '">' + inner + '</div>' +
        '<div class="file-info"><div class="file-name">' + esc(x.name) + '</div>' +
        '<div class="file-meta">' + meta + '</div></div>' +
        '<div class="file-size">' + (x.isDir ? '' : fmt(x.size)) + '</div>' +
        '<button class="dots" data-more="' + i + '" aria-label="更多操作">' + icn('more', 18) + '</button></div>';
    }).join('') + tail;
  }

  /* ---------------- 设置页 ---------------- */
  function posCount() {                        // 记了多少个文件的播放进度
    var n = 0;
    try {
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i);
        if (k && k.indexOf('mfm_pos_') === 0) n++;
      }
    } catch (e) { }
    return n;
  }
  /* 「继续观看」本地索引：mfm_recent = [{u,n,s,at,t,d}]，只在本机，最多 12 条 */
  function recGet() {
    try { var a = JSON.parse(localStorage.getItem('mfm_recent') || '[]'); return Array.isArray(a) ? a : []; } catch (e) { return []; }
  }
  function recSave(a) { try { localStorage.setItem('mfm_recent', JSON.stringify(a.slice(0, 12))); } catch (e) { } }
  function recPush(it) {
    if (!it || !it.url) return;
    var a = recGet().filter(function (x) { return x.u !== it.url; });
    a.unshift({ u: it.url, n: it.name || '', s: (it.src || ST.src || ''), at: Date.now(), t: 0, d: 0 });
    recSave(a);
  }
  function recTouch(u, t, d) {
    if (!u) return;
    var a = recGet(), i, hit = false;
    for (i = 0; i < a.length; i++) {
      if (a[i].u === u) { a[i].t = Math.floor(t || 0); a[i].d = Math.round(d || 0); a[i].at = Date.now(); hit = true; break; }
    }
    if (hit) recSave(a);
  }
  function recClear() { try { localStorage.removeItem('mfm_recent'); } catch (e) { } }
  function ago(ts) {
    var sec = Math.floor((Date.now() - ts) / 1000);
    if (sec < 60) return '刚刚';
    if (sec < 3600) return Math.floor(sec / 60) + ' 分钟前';
    if (sec < 86400) return Math.floor(sec / 3600) + ' 小时前';
    if (sec < 86400 * 7) return Math.floor(sec / 86400) + ' 天前';
    return new Date(ts).toLocaleDateString('zh-CN', { month: 'numeric', day: 'numeric' });
  }
  function clearPos() {
    try {
      var ks = [];
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i);
        if (k && k.indexOf('mfm_pos_') === 0) ks.push(k);
      }
      for (var j = 0; j < ks.length; j++) localStorage.removeItem(ks[j]);
    } catch (e) { }
  }
  function gsNum(k, d) { try { var v = parseFloat(localStorage.getItem(k)); return isNaN(v) ? d : v; } catch (e) { return d; } }
  function setPref(key, v) {
    try {
      if (key === 'mode') { ST.mode = v; saveState(); render(); return; }
      if (key === 'subs') { SUBP.on = (v === 'on'); subsSavePrefs(); render(); return; }
      if (key === 'sublive') {
        SUBP.live = (String(v) === '1'); subsSavePrefs();
        toast(SUBP.live ? '实时听译已开：边播边出' : '实时听译已关：整片转完再出');
        render(); return;
      }
      if (key === 'submodel') {
        SUBP.model = (v === 'small' ? 'small' : 'turbo'); subsSavePrefs();
        toast('识别精度：' + (SUBP.model === 'turbo' ? '高质量' : '快速')); render(); return;
      }
      if (key === 'rate') { localStorage.setItem('mfm_rate', String(v)); toast('播放速度 ' + v + '×'); }
      else if (key === 'lp') { localStorage.setItem('mfm_lp_rate', String(v)); toast('长按加速 ' + v + '×'); }
      else if (key === 'sw') {
        localStorage.setItem('mfm_sw_k', String(v));
        toast('滑动灵敏度 ' + (String(v) === '0.6' ? '慢' : String(v) === '1.6' ? '快' : '标准'));
      }
    } catch (e) { }
    render();
  }
  function srow(ico, label, value, act, val, tone) {
    return '<div class="srow"' + (act ? ' data-act="' + act + '"' + (val != null ? ' data-val="' + esc(val) + '"' : '') : '') +
      '><span class="s-ico' + (tone ? ' ' + tone : '') + '">' + ico + '</span>' +
      '<span class="s-txt"><b>' + label + '</b>' + (value ? '<i>' + value + '</i>' : '') + '</span>' +
      (act ? '<span class="s-go">' + icn('chevron-right', 16) + '</span>' : '') + '</div>';
  }
  /* 设置分组：带 key 的可以收起，状态记在这台手机上（mfm_setcoll） */
  var SETCOL = {};
  // JSON.parse 可能返回字符串/数组/null：1862 行是 `key in SETCOL`，非对象会抛 TypeError 把整个设置页渲染打断
  try {
    var _sc = JSON.parse(localStorage.getItem('mfm_setcoll') || '{}');
    SETCOL = (_sc && typeof _sc === 'object' && !Array.isArray(_sc)) ? _sc : {};
  } catch (e) { SETCOL = {}; }
  function setCollSave() { try { localStorage.setItem('mfm_setcoll', JSON.stringify(SETCOL)); } catch (e) { } }
  var SETCOL_DEF = { player: 1, asr: 1, about: 1 };   // 第一次打开时收起的几组

  function sgroup(title, rows, opt) {
    opt = opt || {};
    var key = opt.k || '';
    var coll = !!(key && (key in SETCOL ? SETCOL[key] : SETCOL_DEF[key]));
    return '<div class="set-group' + (coll ? ' coll' : '') + '"' + (key ? ' data-g="' + key + '"' : '') + '>' +
      '<div class="set-h"' + (key ? ' data-gt="' + key + '"' : '') + '>' + title +
      (opt.s ? '<span class="sv">' + opt.s + '</span>' : '') +
      (key ? '<span class="cv">' + icn('chevron-right', 15) + '</span>' : '') +
      '</div><div class="set-body">' + rows.join('') + '</div></div>';
  }
  function seg(key, items, cur) {
    return '<div class="seg">' + items.map(function (x) {
      return '<b' + (String(x[0]) === String(cur) ? ' class="on"' : '') + ' data-set="' + key + '" data-v="' + x[0] + '">' + x[1] + '</b>';
    }).join('') + '</div>';
  }

  function renderSettings() {
    var s = activeSrc(), sk = srcKind();
    var folders = ITEMS.filter(function (x) { return x.isDir; }).length;
    var files = ITEMS.length - folders;
    var modeIco = ST.mode === 'grid' ? icn('grid', 18) : icn('list', 18);
    var perm = canWrite()
      ? (isRemote() ? '已登录 · 可上传 / 改名 / 删除' : (CAN_DELETE ? '可上传 · 可重命名 · 可删除' : '可上传（不能改删）'))
      : (isRemote() && isRemoteDufs() ? '只读 · 登录后可写入' : '只读（登录后可上传）');
    var sortName = ({ name: '名称', mtime: '修改时间', size: '大小' })[ST.sort] || '名称';
    var sortDir = ST.order === 'asc' ? '正序' : '倒序';
    if (ST.sort === 'name') sortDir = ST.order === 'asc' ? 'A → Z' : 'Z → A';

    var html = '';

    /* 状态卡：来源 / 位置 / 权限 / 数量，一屏之内直接读到 */
    var pemCls = canWrite() ? 'ok' : (isRemote() && isRemoteDufs() ? 'warn' : 'ro');
    var pemTxt = canWrite() ? (isRemote() ? '可读写' : (CAN_DELETE ? '可读写' : '可上传'))
      : (isRemote() && isRemoteDufs() ? '需登录' : (sk === 'dufs' ? '未登录' : '只读'));
    var curSrcId = (s && s.id) || 'nas';
    html += '<div class="set-status">' +
      '<div class="ss-top" data-ss="auth" data-v="' + curSrcId + '">' +
      '<span class="ss-ico">' + (sk === 'dufs' ? icn('src-nas', 22) : (sk === 'webdav' ? icn('src-cloud', 22) : icn('src-pc', 22))) + '</span>' +
      '<div class="ss-id"><b>' + esc(s && s.name ? s.name : '本机共享') + '</b>' +
      '<span>' + (isRemote() ? (ST.path ? esc(ST.path) : '根目录') : (pathParts().length ? esc(curDirName()) : '根目录')) +
      ' · ' + esc(location.origin.replace(/^https?:\/\//, '')) + '</span></div>' +
      '<span class="ss-pill ' + pemCls + '">' + pemTxt + '<i class="ss-go">›</i></span>' +
      '</div>' +
      '<div class="ss-stats">' +
      '<div><b>' + folders + '</b><span>文件夹</span></div>' +
      '<div><b>' + files + '</b><span>文件</span></div>' +
      '<div><b>' + (posCount() || 0) + '</b><span>看过</span></div>' +
      '</div></div>';

    /* 账号状态：按来源列出来，状态用色标说清，点一下才进那台的登录面板 */
    html += sgroup('账号状态', ((SOURCES && SOURCES.sources) || []).map(function (x) {
      var a = srcAuth(x.id), pill, sub, ico;
      if (x.kind === 'webdav') {
        pill = '<span class="ss-pill host">NAS 托管</span>';
        sub = '账号在 NAS 的 CloudDrive 里 · 只读';
        ico = 'src-cloud';
      } else if (a) {
        pill = '<span class="ss-pill ok">已登录</span>';
        sub = esc(userOf(a) || '已登录') + ' · 可上传 / 改名 / 删除';
        ico = x.kind === 'dufs' ? 'src-nas' : 'src-pc';
      } else {
        pill = '<span class="ss-pill ' + (x.kind === 'dufs' ? 'warn' : 'ro') + '">' + (x.kind === 'dufs' ? '未登录' : '未登录') + '</span>';
        sub = x.kind === 'dufs' ? '点一下登录，就能上传 / 改名 / 删除' : '只读 · 浏览和播放不用登录';
        ico = x.kind === 'dufs' ? 'src-nas' : 'src-pc';
      }
      return '<div class="srow" data-act="srcauth" data-val="' + x.id + '">' +
        '<span class="s-ico">' + icn(ico, 18) + '</span>' +
        '<span class="s-txt"><b>' + esc(x.name) + '</b><i>' + sub + '</i></span>' +
        pill + '</div>';
    }));

    html += sgroup('显示与外观', [
      srow(modeIco, '显示方式', ST.mode === 'grid' ? '网格缩略图' : '紧凑列表') +
      seg('mode', [['list', '紧凑列表'], ['grid', '网格缩略图']], ST.mode),
      srow(icn('sort', 18), '排序', sortName + ' · ' + sortDir, 'sortsheet'),
      srow(icn('setting', 18), '主题', '当前：' + themeName(themeNow()), 'themesheet')
    ], { k: 'disp' });

    var atRoot = isRemote() ? !ST.path : !pathParts().length;
    html += sgroup('操作', [
      srow(icn('refresh', 18), '刷新列表', '重新向服务端取这个目录', 'refresh'),
      atRoot ? '' : srow(icn('home', 18), '回到共享根目录', '直接跳到最外层', 'root'),
      srow(icn('monitor', 18), '听译监控', '所有任务的进度 · 导出 · 重听 · 停止', 'subsmon'),
      srow(icn('download', 18), '下载队列', '磁力 / ed2k 任务 · 进度 · 暂停删除', 'dlqueue'),
      posCount() ? srow(icn('trash', 18), '清空播放记录', posCount() + ' 个文件记住了看到哪儿', 'clearpos') : '',
      srow(icn('help', 18), '使用说明', '打开图文说明书', 'helpx')
    ], { k: 'ops' });

    html += sgroup('播放器', [
      srow(icn('play', 18), '播放速度', '当前 ' + gsNum('mfm_rate', 1) + '× · 与播放器面板同步') +
      seg('rate', [[0.5, '0.5×'], [0.75, '0.75×'], [1, '1×'], [1.25, '1.25×'], [1.5, '1.5×'], [2, '2×'], [3, '3×'], [4, '4×']], gsNum('mfm_rate', 1)),
      srow(icn('speed', 18), '长按画面加速', '当前 ' + gsNum('mfm_lp_rate', 3) + '×') +
      seg('lp', [[2, '2×'], [3, '3×'], [4, '4×'], [6, '6×']], gsNum('mfm_lp_rate', 3)),
      srow(icn('rotate', 18), '左右滑灵敏度', '当前 ' + (gsNum('mfm_sw_k', 1) === 0.6 ? '慢' : gsNum('mfm_sw_k', 1) === 1.6 ? '快' : '标准')) +
      seg('sw', [[0.6, '慢'], [1, '标准'], [1.6, '快']], gsNum('mfm_sw_k', 1))
    ], { k: 'player', s: '速度 ' + gsNum('mfm_rate', 1) + '× · 长按 ' + gsNum('mfm_lp_rate', 3) + '×' });

    html += sgroup('AI 听译', [
      srow(icn('translate', 18), '实时听译', SUBP.live
        ? '边播边出 · 从当前进度起，约 10 秒出第一句' : '关 · 整片转完才出字幕') +
      seg('sublive', [['1', '开'], ['0', '关']], SUBP.live ? '1' : '0') +
      srow(icn('translate', 18), '识别精度', SUBP.model === 'turbo'
        ? '高质量 · large-v3-turbo（约 1.4× 实时）' : '快速 · small（约 3.2× 实时）') +
      seg('submodel', [['turbo', '高质量'], ['small', '快速']], SUBP.model),
      srow(icn('link', 18), '听译服务地址', esc(subsBase()) + (SUBP.api ? '' : '（自动）'), 'subsapi'),
      srow(icn('help', 18), '原理', '电脑听写 · NAS 翻译存档 · 第二次看同一部片秒开')
    ], { k: 'asr', s: (SUBP.live ? '实时' : '整片') + ' · ' + (SUBP.model === 'turbo' ? '高质量' : '快速') });

    html += sgroup('关于', [
      srow(icn('link', 18), '服务地址', esc(location.origin.replace(/^https?:\/\//, '')), 'copy', location.origin),
      srow(icn('folder', 18), '当前路径', isRemote() && ST.path ? esc(ST.path) : esc(curDirName()),
        'copy', isRemote() && ST.path ? ST.path : decodeURIComponent(location.pathname)),
      srow(icn('help', 18), '服务端', 'dufs v0.46.0 · 图标 Hugeicons · 仅局域网')
    ], { k: 'about' });

    el.fileList.className = 'settings-wrap';
    el.fileList.innerHTML = html;
  }

  function render() {
    try { if (window.MFM_CHAT) window.MFM_CHAT.hide(); } catch (e) { }
    var __sb = document.getElementById('sortBtn');
    if (__sb && __sb.dataset.mode === 'chat') { __sb.innerHTML = '排序 ' + icn('sort', 14); delete __sb.dataset.mode; }
    var dav = isRemote();
    var list = dav ? davFiltered() : filtered();

    var cr = dav ? davCrumbs() : crumbsHtml();
    var setv = ST.view === 'settings';
    var subline = '';
    var homev = (ST.view === 'home' || !ST.view);
    if (setv) subline = '改动立刻生效 · 只存在这台设备';
    else if (homev) subline = '';
    else if (ST.view === 'recent') subline = '当前目录 · 按时间倒序';
    else if (ST.q) subline = '搜索「' + ST.q + '」';
    el.crumbs.style.display = (homev && !subline) ? 'none' : '';
    el.crumbs.innerHTML = subline
      ? '<span class="now">' + esc(subline) + '</span>'
      : (cr || ('<span class="now">' + location.origin.replace(/^https?:\/\//, '') +
        ' · ' + (DATA.user ? '已登录 ' + esc(DATA.user) : '匿名只读') + '</span>'));
    var title = dav ? (ST.path ? decodeURIComponent(ST.path.split('/').pop()) : (activeSrc() ? activeSrc().name : '网盘'))
      : (pathParts().length ? curDirName() : '根目录');
    if (ST.view === 'recent') title = '对话';
    if (ST.cat) title = kindLabel(ST.cat);
    if (ST.view === 'settings') title = '设置';
    if (ST.view === 'home' || !ST.view) title = '我的储存';
    if (Q) title = '搜索结果';
    el.title.textContent = title;
    el.title.style.display = title ? '' : 'none';

    $$('.nav-item', el.nav).forEach(function (b) {
      b.classList.toggle('active', b.dataset.nav === ST.view);
    });

    /* 「对话」页：列表、排序、搜索全让位给 chat.js 的对话层 */
    if (ST.view === 'recent' && window.MFM_CHAT) {
      el.title.textContent = '对话';
      el.title.style.display = '';
      el.crumbs.style.display = 'none';
      el.srcSec.style.display = 'none';
      el.listSec.style.display = 'none';
      el.fileList.innerHTML = '';
      $('#listHead').style.display = 'none';
      var sb = $('#sortBtn');
      sb.innerHTML = '新对话';
      sb.dataset.mode = 'chat';
      sb.style.display = '';
      el.searchFab.classList.remove('on');
      el.app.classList.remove('has-sfab');
      el.searchBar.classList.remove('on');
      el.fab.style.display = 'none';
      var __ok = window.MFM_CHAT.mount();
      if (!__ok) {
        /* 对话层没起来就退回普通列表，绝不把整页留白 */
        el.listSec.style.display = 'block';
        el.listTitle.textContent = '对话';
        el.listSec.classList.remove('bare');
        $('#listHead').style.display = '';
        el.fileList.innerHTML = '<div class="empty"><b>' + icn('recent', 30) + '</b>' +
          '对话页加载失败<br><span class="hint">下拉刷新，或关掉标签页重开</span></div>';
      }
      return saveState();
    }

    // 搜索只在「文件」这一栏：右下角一个圆球，点开在底部展开输入条
    el.searchFab.classList.toggle('on', ST.view === 'files' && !ST.qOpen && !ST.davErr);
    // 搜索球是 fixed 悬浮在列表右下方的（距底 158px），列表底部要留出它的高度，否则压住最后一行
    el.app.classList.toggle('has-sfab', ST.view === 'files' && !ST.qOpen && !ST.davErr);
    el.searchBar.classList.toggle('on', !!ST.qOpen);

    // 首页 = 概览（统计 + 分类浏览），不放文件夹卡片、也不放文件列表 —— 根目录和任何文件夹里都一样，
    // 这样点进文件夹后仍然停在首页，界面不会变成「文件」那一栏的样子
    // 文件 / 分类 = 纯列表（文件夹排在最前，点文件夹进下一层）
    // 首页 = 储存来源选择器；文件 = 浏览当前来源
    var dashboard = (ST.view === 'home') && !ST.cat;
    var showList = (ST.view !== 'settings') && !dashboard;
    CUR = dav ? (ST.davItems || []) : ITEMS;

    el.srcSec.style.display = dashboard ? '' : 'none';   // 空字符串：交给 CSS 决定（电脑端是 flex 网格）
    if (dashboard) renderSources();
    try { hubDiscover(); } catch (e) { }
    // 「＋」只属于「文件」这一栏：首页是储存来源选择器、设置没东西可加，
    // 远程来源只读、匿名（没登录）也加不了 —— 这些情况都不显示悬浮球
    el.fab.style.display = (ST.view === 'files' && !dashboard && canWrite()) ? '' : 'none';
    el.q.placeholder = wideSearchOk()
      ? '搜索当前目录（回车在整个共享里搜）'
      : '搜索当前目录';

    var t = '';                        // 默认不留标题（「文件列表」四个字去掉了）
    if (ST.view === 'recent') t = '';
    else if (ST.q) t = '';             // 当前目录过滤：上面那行小字已经写了「搜索「…」」，这里不再重复一遍
    else if (Q) t = '搜索「' + Q + '」';
    else if (isRemote()) t = '';
    else if (ST.cat) t = kindLabel(ST.cat) + '（当前目录）';
    el.listTitle.textContent = (t && t !== '设置') ? t : '';
    // 「文件」栏默认没有标题 —— 整行不留，排序已经在标题行右侧了；只有搜索/分类才有标题行
    var bare = !el.listTitle.textContent;
    $('#listHead').style.display = bare ? 'none' : '';
    el.listSec.classList.toggle('bare', bare);
    // 「排序」只在真有列表可排的地方出现（首页概览、设置里都没有）
    $('#sortBtn').style.display = (ST.view === 'settings' || dashboard) ? 'none' : '';

    if (ST.view === 'settings') { el.listSec.style.display = 'block'; renderSettings(); return saveState(); }

    if (!showList) { el.listSec.style.display = 'none'; return saveState(); }

    el.listSec.style.display = 'block';
    if (dav && ST.davLoading && !(ST.davItems || []).length) {   // 网盘是现取的，先给个提示
      el.fileList.className = 'file-list';
      el.fileList.innerHTML = '<div class="empty"><b>' + icn('recent', 30) + '</b>正在读取网盘目录…</div>';
      return saveState();
    }
    if (dav && ST.davNeedAuth) {
      var sN = activeSrc() || {};
      el.fileList.className = 'file-list';
      el.fileList.innerHTML = '<div class="empty"><b>' + icn('login', 30) + '</b>' +
        '「' + esc(sN.name || '这个来源') + '」需要登录才能读取<br>' +
        '<span class="hint">登录只在这台手机上保存，不会发给别的来源</span>' +
        '<br><button class="btn" data-act="davauth" style="margin-top:12px">登录这个来源</button></div>';
      return saveState();
    }
    if (dav && ST.davErr) {
      el.fileList.className = 'file-list';
      el.fileList.innerHTML = '<div class="empty"><b>' + icn('info', 30) + '</b>' +
        (ST.davJsErr
          ? '读取目录出错：' + esc(errText(ST.davErr)) + '<br><span class="hint">页面可能是旧版本：下拉刷新，或关掉标签页重开</span>'
          : (isRemoteDufs() ? '连不上这台设备：' + esc(errText(ST.davErr)) + '<br><span class="hint">电脑可能没开机，或那边的共享没启动</span>'
                            : '网盘读取失败：' + esc(errText(ST.davErr)) + '<br><span class="hint">检查转发服务（5008 端口）是否在跑</span>')) +
        (ST.davUrl ? '<br><span class="hint" style="opacity:.7">' + esc(ST.davUrl) + '</span>' : '') +
        '<br><button class="btn" data-act="davretry" style="margin-top:10px">重试</button></div>';
      return saveState();
    }
    var shown = list;   // 文件夹在 filtered() 里已经排在最前面
    LAST_SHOWN = shown;
    // 目录真的空才收起列表区；搜索/分类没匹配上时要留着，好显示「没有匹配」的提示
    // 对话页兜底列表、以及只含文件夹的目录也不能收：收起后空态文案会被一起藏掉，用户看到整块空白
    if (!shown.length && !ST.q && !Q && !ST.cat && ST.view !== 'recent' && el.uploadBox.style.display === 'none') {
      el.listSec.style.display = 'none';
    }
    renderFiles(shown);
    saveState();
  }

  /* ---------------- 真实操作 ---------------- */
  function reload() { location.href = BASE; }

  /* 当前目录对应的「写地址」和凭据：本机是 BASE，远程 dufs 是它的目录 URL */
  function writeBase() {
    if (!isRemoteDufs()) return BASE;
    var p = ST.path ? encPath(ST.path) : '';
    var b = remoteBase();
    if (!p) return b;
    return b + p + (p.slice(-1) === '/' ? '' : '/');
  }
  function writeAuthHeaders(extra) {
    var id = isRemote() ? (activeSrc() || {}).id : 'nas';
    return authHeadersFor(id, extra);
  }
  function afterWrite(msg) {
    closeSheet();
    toast(msg);
    if (isRemote()) { loadDav(ST.path, true); return; }
    setTimeout(reload, 500);
  }

  function mkdir(name) {
    fetch(writeBase() + encodeURIComponent(name), { method: 'MKCOL', headers: writeAuthHeaders() }).then(function (r) {
      if (r.ok || r.status === 201 || r.status === 405) afterWrite('文件夹已创建');
      else if (r.status === 401 || r.status === 403) { toast('没有权限，先登录这个来源'); srcAuthSheet((activeSrc() || {}).id); }
      else toast('创建失败（' + r.status + '）');
    }).catch(function () { toast('创建失败：网络错误'); });
  }
  function renameItem(it, name) {
    var target = writeBase() + encodeURIComponent(name) + (it.isDir ? '/' : '');
    fetch(it.url, { method: 'MOVE', headers: writeAuthHeaders({ Destination: target }) }).then(function (r) {
      if (r.ok || r.status === 201 || r.status === 204) afterWrite('已重命名');
      else if (r.status === 401 || r.status === 403) { toast('没有权限，先登录这个来源'); srcAuthSheet((activeSrc() || {}).id); }
      else toast('重命名失败（' + r.status + '）');
    }).catch(function () { toast('重命名失败：网络错误'); });
  }
  function deleteItem(it) {
    fetch(it.url, { method: 'DELETE', headers: writeAuthHeaders() }).then(function (r) {
      if (r.ok || r.status === 204) afterWrite('已删除');
      else if (r.status === 401 || r.status === 403) { toast('没有权限，先登录这个来源'); srcAuthSheet((activeSrc() || {}).id); }
      else toast('删除失败（' + r.status + '）');
    }).catch(function () { toast('删除失败：网络错误'); });
  }
  function uploadFiles(files) {
    var list = Array.prototype.slice.call(files);
    if (!list.length) return;
    el.uploadBox.style.display = 'block';
    var pool = isRemote() ? (ST.davItems || []) : ITEMS;
    var collide = list.filter(function (f) { return pool.some(function (x) { return x.name === f.name; }); });
    if (collide.length) {
      sheet('同名文件已存在',
        '<div class="note">' + collide.map(function (f) { return esc(f.name); }).join('、') +
        ' 已存在。<br>继续上传会覆盖原文件。</div>' +
        '<div class="sheet-buttons"><button id="upCancel">取消</button>' +
        '<button class="primary" id="upGo">覆盖并上传</button></div>');
      $('#upCancel').onclick = function () { closeSheet(); el.uploadBox.style.display = 'none'; };
      $('#upGo').onclick = function () { closeSheet(); doUpload(list); };
      return;
    }
    doUpload(list);
  }
  function doUpload(list) {
    var done = 0, fail = 0;
    el.uploadBox.style.display = 'block';
    el.listSec.style.display = 'block';   // 空目录 / 首页概览时列表区是收起的，上传进度得保证看得见
    el.fileList.innerHTML = '';           // 只显示进度，不显示过期的列表内容
    el.uploadBox.innerHTML = '<div class="file-meta" style="margin:0 0 4px">正在上传 ' + list.length + ' 个文件…</div>';
    list.forEach(function (f, idx) {
      var r = document.createElement('div');
      r.className = 'u-row';
      r.innerHTML = '<span class="u-state">↑</span>' +
        '<div style="flex:1;min-width:0"><div class="u-name">' + esc(f.name) + '</div>' +
        '<div class="u-bar"><i></i></div></div><span class="u-state">0%</span>';
      el.uploadBox.appendChild(r);
      var bar = $('i', r), st = $('.u-state:last-child', r);
      var xhr = new XMLHttpRequest();
      xhr.open('PUT', writeBase() + encodeURIComponent(f.name), true);
      var wa = isRemote() ? srcAuth((activeSrc() || {}).id) : AUTH;
      if (wa) xhr.setRequestHeader('Authorization', 'Basic ' + wa);
      xhr.upload.onprogress = function (e) {
        if (!e.lengthComputable) return;
        var p = Math.round(e.loaded / e.total * 100);
        bar.style.width = p + '%'; st.textContent = p + '%';
      };
      xhr.onload = function () {
        if (xhr.status === 401 || xhr.status === 403) { fail++; upDone('无权限', 'err'); }
        else if (xhr.status >= 200 && xhr.status < 300) { bar.style.width = '100%'; upDone('完成', 'ok'); }
        else { fail++; upDone('失败 ' + xhr.status, 'err'); }
      };
      function upDone(msg, cls) {
        if (msg) { st.textContent = msg; st.className = 'u-state ' + cls; }
        done++;
        if (done >= list.length) {
          toast('上传结束（' + done + ' 个，' + fail + ' 个失败）');
          if (isRemote()) setTimeout(function () { loadDav(ST.path, true); }, 900);
          else setTimeout(reload, 1200);
        }
      }
      xhr.onerror = function () { fail++; upDone('网络错误', 'err'); };
      xhr.onabort = function () { fail++; upDone('已中断', 'err'); };
      xhr.send(f);
    });
  }
  function pickFiles() {
    var inp = $('#file');
    if (!inp) { toast('上传控件不可用'); return; }
    inp.value = ''; inp.click();
  }
  /* dufs 对文件发的是 Content-Disposition: inline，所以「下载」不能靠服务端。
     只挂 download 属性时桌面 Chrome 会存文件，但 iOS Safari 会当预览在新标签打开；
     先 fetch 成 blob 再挂 download，iOS 才会真的弹「存储到文件」。 */
  // 字幕导出：必须在点击的同一个 tick 里发起，iOS 会忽略异步回调里的下载。
  // 中枢的 /srt/ 带 Content-Disposition: attachment，直接导航就会存成文件。
  function srtDownload(id, name) {
    if (!id) { toast('还没有字幕'); return; }
    var url = subsBase() + '/srt/' + id;
    var fn = (name || '字幕').replace(/\.[^.]+$/, '') + '.srt';
    var a = document.createElement('a');
    a.href = url; a.download = fn; a.rel = 'noopener';
    a.style.cssText = 'position:fixed;left:-9999px;top:0;width:1px;height:1px;opacity:0';
    document.body.appendChild(a);
    a.click();
    setTimeout(function () { try { a.parentNode && a.parentNode.removeChild(a); } catch (e) { } }, 6000);
    toast('正在保存 ' + fn);
  }

  function downloadFile(url, name, size) {
    name = name || decodeURIComponent(String(url).split('?')[0].split('/').pop() || '') || 'download';
    // 先把 <a> 建好挂进 DOM（iOS 要求下载动作紧跟点击，别等异步再建元素）
    var a = document.createElement('a');
    a.download = name; a.rel = 'noopener';
    a.style.cssText = 'position:fixed;left:-9999px;top:0;width:1px;height:1px;opacity:0';
    document.body.appendChild(a);
    var drop = function () { setTimeout(function () { try { a.parentNode && a.parentNode.removeChild(a); } catch (e) { } }, 8000); };
    var direct = function () { a.href = url; a.click(); drop(); };
    if (size && size > 300 * 1024 * 1024) {       // 300MB 以上不在内存里过一遍
      toast('文件较大（' + fmt(size) + '），交给浏览器处理');
      direct();
      return;
    }
    toast('正在下载 ' + name);
    fetch(url, { headers: authHeaders() })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.blob(); })
      .then(function (b) {
        var u = URL.createObjectURL(b);
        a.href = u;
        a.click();
        toast('已保存 ' + name);
        drop();
        setTimeout(function () { try { URL.revokeObjectURL(u); } catch (e) { } }, 60000);
      })
      ['catch'](function () {                      // 取不到数据就退回直接开链接
        toast('改用浏览器内置方式下载');
        direct();
      });
  }
  function copyText(t) {
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(t).then(function () { toast('已复制'); }, function () { toast('复制失败'); });
    } else {
      var a = document.createElement('textarea');
      a.value = t; document.body.appendChild(a); a.select();
      try { document.execCommand('copy'); toast('已复制'); } catch (e) { toast('复制失败'); }
      document.body.removeChild(a);
    }
  }

  /* ---------------- 弹窗 ---------------- */
  function itemSheet(it) {
    curItem = it;
    var rows = [];
    if (it.isRemote) {
      rows.push(row(icn(it.isDir ? 'chevron-right' : 'open-new'), '打开', 'open'));
      if (it.isDir) {
        var fp1 = favPathOf(it);
        rows.push(row(icn('star'), favHas(ST.src, fp1) ? '取消收藏' : '收藏到首页', 'fav'));
      }
      if (it.kind === 'video' || it.kind === 'audio') rows.push(row(icn('play'), '播放', 'play'));
      if (it.kind === 'video') rows.push(row(icn('subs'), '添加到听译队列', 'subsadd'));
      if (!it.isDir) rows.push(row(icn('download'), '下载', 'dl', it.size != null ? fmt(it.size) : ''));
      rows.push(row(icn('link'), '复制链接', 'link'));
      if (canWrite()) {                       // 这个来源登录过：能改名、能删
        rows.push(row(icn('edit'), '重命名', 'rename'));
        rows.push(row(icn('trash'), '删除', 'del', '', true));
      } else {
        rows.push('<div class="note">' + (isRemoteDufs()
          ? '只读：浏览、播放、下载都能用。登录这台设备后可以上传 / 改名 / 删除。'
          : '这是 NAS 网盘里的文件，只能看和下载。') + '</div>');
        if (isRemoteDufs()) rows.push(row(icn('login'), '登录这个来源', 'srclogin'));
      }
      rows.push(row(icn('close'), '取消', 'cancel'));
      sheet(esc(it.name), rows.join(''));
      return;
    }
    rows.push(row(icn(it.isDir ? 'chevron-right' : 'open-new'), '打开', 'open'));
    if (it.isDir) {
      var fp0 = favPathOf(it);
      rows.push(row(icn('star'), favHas(ST.src, fp0) ? '取消收藏' : '收藏到首页', 'fav'));
    }
    if (it.kind === 'video' || it.kind === 'audio') rows.push(row(icn('play'), '播放', 'play'));
    if (it.kind === 'video') rows.push(row(icn('subs'), '添加到听译队列', 'subsadd'));
    if (!it.isDir) rows.push(row(icn('download'), '下载', 'dl', it.size != null ? fmt(it.size) : ''));
    rows.push(row(icn('link'), '复制链接', 'link'));
    if (canWrite()) rows.push(row(icn('edit'), '重命名', 'rename'));
    if (CAN_DELETE) rows.push(row(icn('trash'), '删除', 'del', '', true));
    if (!CAN_WRITE) rows.push('<div class="note">当前是只读会话：能看能下载，不能改。登录后可上传 / 重命名 / 删除。</div>' + row(icn('login'), '登录', 'auth'));
    rows.push(row(icn('close'), '取消', 'cancel'));
    sheet(esc(it.name), rows.join(''));
  }
  function addSheet() {
    var html = [];
    if (canWrite()) {
      html.push(row(icn('upload'), '上传文件', 'upload', '可多选'));
      html.push(row(icn('folder-add'), '新建文件夹', 'mkdir'));
    } else {
      html.push('<div class="note">当前目录是只读的。登录后可上传文件、新建文件夹、重命名和删除。</div>');
      html.push(row(icn('login'), '登录' + (isRemote() ? '这个来源' : ''), isRemote() ? 'srclogin' : 'auth'));
    }
    html.push(row(icn('download'), '下载', 'dlsheet', '磁力 / ed2k，选下到 NAS 还是电脑'));
    html.push(row(icn('refresh'), '刷新列表', 'refresh'));
    html.push(row(icn('home'), '回到根目录', 'root'));
    html.push(row(icn('help'), '使用说明', 'help'));
    sheet('添加 / 操作', html.join(''));
  }
  function sortSheet() {
    var b = document.getElementById('sortBtn');
    if (b && b.dataset.mode === 'chat') { if (window.MFM_CHAT) window.MFM_CHAT.reset(); return; }
    var o = ST.order === 'desc';
    sheet('排序 / 显示', [
      row(icn('sort'), '名称', 'sort-name', o ? 'Z→A' : 'A→Z'),
      row(icn('sort'), '修改时间', 'sort-mtime', o ? '旧→新' : '新→旧'),
      row(icn('sort'), '大小', 'sort-size', o ? '小→大' : '大→小'),
      '<div class="note" style="margin:14px 0 8px">显示方式</div>',
      row(icn('list'), '紧凑列表', 'mode-list', ST.mode === 'list' ? '当前' : ''),
      row(icn('grid'), '网格缩略图', 'mode-grid', ST.mode === 'grid' ? '当前' : '')
    ].join(''));
  }
  function onlineSheet() {
    sheet('在线播放', (
      '<div class="note">粘贴视频直链（http/https 开头）。mkv、mp4、webm 都能播；m3u8 只有 Safari 支持。</div>' +
      '<input id="olUrl" class="ol-inp" type="url" inputmode="url" placeholder="https://…/video.mp4" ' +
      'autocomplete="off" autocapitalize="off" spellcheck="false">' +
      '<input id="olName" class="ol-inp" type="text" placeholder="标题（可留空）" autocomplete="off">' +
      row(icn('play'), '开始播放', 'olgo') +
      row('×', '取消', 'cancel')
    ));
    setTimeout(function () { var i = $('#olUrl'); if (i) i.focus(); }, 150);
  }

  function playOnline(url, name) {
    var nm = name;
    if (!nm) {
      try { nm = decodeURIComponent(url.split('?')[0].split('/').pop() || ''); } catch (e) { nm = ''; }
      if (!nm) nm = '在线视频';
    }
    ONELINE = { name: nm, url: url, kind: 'video', online: true, size: null, mtime: 0 };
    SUBR.id = ''; SUBR.known = false; SUBR.online = false;
    Player.openItem(ONELINE);
  }

  function onlineSheetOpen() {
    var it = SUBR.it;
    if (it && it.online && SUBR.id && SUBR.online) {
      toast('这个链接正在听译，先继续看');
    }
    onlineSheet();
  }

  function authSheet() {
    sheet('账号', [
      '<div class="note">' + (DATA.user
        ? '已以 <b>' + esc(DATA.user) + '</b> 登录，可以上传、重命名、删除。'
        : '当前是匿名只读访问：能浏览和下载，不能修改。登录后开启写入权限。') + '</div>',
      DATA.user ? row(icn('logout'), '退出登录', 'logout') : row(icn('login'), '登录', 'login'),
      row('×', '取消', 'cancel')
    ].join(''));
  }
  function helpText() {
    sheet('使用说明', '<div class="note">' +
      '· 首页：当前目录总览 + 分类，点分类只看该类文件<br>' +
      '· 文件：完整列表；每行右边 ··· 是 打开 / 下载 / 重命名 / 删除<br>' +
      '· 对话：直接打字提问，能读写这台机器上的文件<br>' +
      '· 设置 → 账号状态：每个储存来源单独登录（NAS 和电脑各用各的账号）；115 网盘由 NAS 托管，不用登录<br>' +
      '· 图片点一下进全屏：左右滑动换张、双击放大、下滑关闭<br>' +
      '· 上传：点 ＋ 选「上传文件」，可多选，进度显示在列表上方' +
      '</div>' + row(icn('help'), '打开图文说明书', 'help-html') + row(icn('close'), '关闭', 'cancel'));
  }

  /* ---------------- 图片查看器 ---------------- */
  var Viewer = (function () {
    var box = null, imgEl, nameEl, cntEl, dlEl, posEl, prevB, nextB, rangeEl, hintEl;
    var metaEl, zoomEl, hintBtn = null, retryUrl = '';
    var idx = 0, scale = 1, tx = 0, ty = 0, rot = 0, pushed = false, lastTap = 0, tapTimer = null;
    function imgs() {
      return (LAST_SHOWN && LAST_SHOWN.length ? LAST_SHOWN : ITEMS)
        .filter(function (x) { return x.kind === 'image'; });
    }
    function build() {
      if (box) return;
      box = document.createElement('div');
      box.id = 'iv';
      box.innerHTML =
        '<div class="iv-top"><button class="iv-btn sm" data-act="close" title="关闭">' + icn('close', 19) + '</button>' +
        '<div class="iv-name"></div><span class="iv-zoom"></span><span class="iv-count"></span>' +
        '<button class="iv-btn sm" data-act="rot" title="旋转 90°">' + icn('rotate', 19) + '</button>' +
        '<button class="iv-btn sm" data-act="tab" title="在新标签打开原图">' + icn('open-new', 19) + '</button>' +
        '<a class="iv-btn sm" data-act="dl" download title="保存原图">' + icn('download', 19) + '</a></div>' +
        '<div class="iv-stage"><button class="iv-btn iv-nav iv-prev" data-act="prev" title="上一张">' + icn('arrow-left', 26) + '</button>' +
        '<img class="iv-img" alt=""><button class="iv-btn iv-nav iv-next" data-act="next" title="下一张">' + icn('arrow-right', 26) + '</button>' +
        '<div class="iv-hint"></div></div>' +
        '<div class="iv-bottom">' +
        '<div class="iv-row"><span class="iv-pos"></span><span class="iv-meta"></span></div>' +
        '<div class="iv-row iv-tips"><span>左右滑动切换 · 双击放大 · 双指缩放 · 下滑关闭</span></div>' +
        '<input class="iv-range" type="range" min="0" max="0" step="1" value="0"></div>';
      document.body.appendChild(box);
      imgEl = $('.iv-img', box); nameEl = $('.iv-name', box); cntEl = $('.iv-count', box);
      dlEl = $('[data-act="dl"]', box); posEl = $('.iv-pos', box);
      metaEl = $('.iv-meta', box); zoomEl = $('.iv-zoom', box);
      prevB = $('.iv-prev', box); nextB = $('.iv-next', box); rangeEl = $('.iv-range', box); hintEl = $('.iv-hint', box);
      box.addEventListener('click', function (e) {
        var t = e.target.closest && e.target.closest('[data-act]');
        if (!t) return;
        var a = t.getAttribute('data-act');
        if (a === 'close') close();
        else if (a === 'prev') prev();
        else if (a === 'next') next();
        else if (a === 'rot') { rot = (rot + 90) % 360; scale = 1; tx = 0; ty = 0; apply(); }
        else if (a === 'tab') { if (imgEl.src) window.open(imgEl.src, '_blank'); }
        else if (a === 'dl') { e.preventDefault(); var ci = imgs()[idx]; if (ci) downloadFile(ci.url, ci.name, ci.size); }
        else if (a === 'retry') { hintBtn = null; var u = retryUrl; show(idx); if (u) { imgEl.src = ''; imgEl.src = u; } }
      });
      imgEl.addEventListener('load', function () { hintEl.innerHTML = ''; hintBtn = null; });
      imgEl.addEventListener('error', function () {
        hintEl.innerHTML = '图片加载失败' +
          '<br><button class="iv-retry" data-act="retry">重试</button>';
      });
      rangeEl.addEventListener('input', function () { posEl.textContent = (parseInt(rangeEl.value, 10) + 1) + ' / ' + imgs().length; });
      rangeEl.addEventListener('change', function () { show(parseInt(rangeEl.value, 10)); });
      document.addEventListener('keydown', function (e) {
        if (!open()) return;
        if (e.key === 'Escape') close();
        else if (e.key === 'ArrowRight') next();
        else if (e.key === 'ArrowLeft') prev();
        else if (e.key === '+' || e.key === '=') { scale = Math.min(6, scale + .5); apply(); }
        else if (e.key === '-' || e.key === '_') { scale = Math.max(1, scale - .5); clamp(); apply(); }
      });
      var stage = $('.iv-stage', box), g = null;
      function dist(e) { var a = e.touches[0], b = e.touches[1]; return Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY); }
      stage.addEventListener('touchstart', function (e) {
        if (e.touches.length === 1) {
          var t = e.touches[0];
          g = { pinch: false, x: t.clientX, y: t.clientY, tx: tx, ty: ty, moved: false, t: Date.now() };
        } else if (e.touches.length === 2) {
          g = { pinch: true, d: dist(e), scale: scale, tx: tx, ty: ty, moved: true, t: Date.now() };
        }
      }, { passive: true });
      stage.addEventListener('touchmove', function (e) {
        if (!g) return;
        if (g.pinch && e.touches.length === 2) {
          e.preventDefault();
          scale = Math.min(6, Math.max(1, g.scale * (dist(e) / (g.d || 1))));
          apply(); return;
        }
        if (e.touches.length === 1) {
          var t = e.touches[0], dx = t.clientX - g.x, dy = t.clientY - g.y;
          if (Math.abs(dx) > 6 || Math.abs(dy) > 6) g.moved = true;
          if (scale > 1) { e.preventDefault(); tx = g.tx + dx; ty = g.ty + dy; clamp(); apply(); }
        }
      }, { passive: false });
      stage.addEventListener('touchend', function (e) {
        if (!g) return;
        var gg = g; g = null;
        if (gg.pinch) { if (scale <= 1.03) { scale = 1; tx = 0; ty = 0; } clamp(); apply(); return; }
        var t = (e.changedTouches && e.changedTouches[0]) || null;
        var dx = t ? t.clientX - gg.x : 0, dy = t ? t.clientY - gg.y : 0;
        if (!gg.moved && t && Date.now() - gg.t < 320) { tap(); return; }
        if (scale > 1) { clamp(); apply(); return; }
        if (dy > 90 && Math.abs(dx) < 70) { close(); return; }
        if (Math.abs(dx) > 45 && Math.abs(dy) < 70) { dx < 0 ? next() : prev(); }
      }, { passive: true });
      window.addEventListener('popstate', function () { if (open()) { pushed = false; hide(); } });
    }
    function tap() {
      var now = Date.now();
      if (now - lastTap < 300) {
        lastTap = 0; clearTimeout(tapTimer);
        if (scale > 1) { scale = 1; tx = 0; ty = 0; } else scale = 2.5;
        apply(); return;
      }
      lastTap = now;
      tapTimer = setTimeout(function () { box.classList.toggle('chrome-hidden'); }, 270);
    }
    function clamp() {
      var s = $('.iv-stage', box);
      var mx = Math.max(0, (s.clientWidth * scale - s.clientWidth) / 2);
      var my = Math.max(0, (s.clientHeight * scale - s.clientHeight) / 2);
      tx = Math.max(-mx, Math.min(mx, tx)); ty = Math.max(-my, Math.min(my, ty));
    }
    function apply() {
      imgEl.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ') rotate(' + rot + 'deg)';
      box.classList.toggle('zoomed', scale > 1);
      if (zoomEl) {
        zoomEl.textContent = scale > 1.02 ? Math.round(scale * 100) + '%' : '';
        zoomEl.style.display = scale > 1.02 ? 'inline-block' : 'none';   // 样式表里默认是 none，不能用空值
      }
    }
    function show(k) {
      var list = imgs();
      if (!list.length) return;
      k = Math.max(0, Math.min(list.length - 1, k));
      idx = k; scale = 1; tx = 0; ty = 0; rot = 0;
      var it = list[k];
      hintEl.textContent = '加载中…';
      retryUrl = it.url;
      imgEl.src = it.url; imgEl.alt = it.name;
      nameEl.textContent = it.name;
      cntEl.textContent = (k + 1) + '/' + list.length;
      posEl.textContent = (k + 1) + ' / ' + list.length;
      if (metaEl) metaEl.textContent = (it.size != null ? fmt(it.size) + ' · ' : '') + dayOf(it.mtime);
      dlEl.setAttribute('href', it.url); dlEl.setAttribute('download', it.name);
      rangeEl.max = String(list.length - 1); rangeEl.value = String(k);
      prevB.disabled = k === 0; nextB.disabled = k === list.length - 1;
      apply();
      // 预取前后两张，翻页秒开
      [k + 1, k - 1, k + 2].forEach(function (j) { var n = list[j]; if (n) { var im = new Image(); im.src = n.url; } });
    }
    function next() { if (idx < imgs().length - 1) show(idx + 1); }
    function prev() { if (idx > 0) show(idx - 1); }
    function open() { return !!box && box.classList.contains('open'); }
    function hide() { if (!box) return; box.classList.remove('open', 'chrome-hidden'); document.body.classList.remove('iv-lock'); imgEl.removeAttribute('src'); }
    function close() { if (!open()) return; hide(); if (pushed) { pushed = false; history.back(); } }
    function openAt(k) {
      build();
      if (!open()) {
        document.body.classList.add('iv-lock'); box.classList.add('open');
        try { history.pushState({ iv: 1 }, ''); pushed = true; } catch (e) { pushed = false; }
      }
      show(k);
    }
    function openItem(it) {
      if (it.isDir) {
        if (it.isRemote || isRemote()) { loadDav(it.davPath || ''); return; }   // 网盘 / 别的 dufs：照旧
        navOpen(it.url, it.name, false);                                        // 本地共享：软打开，先出骨架
        return;
      }
      if (it.kind === 'image') {
        var list = imgs();
        for (var i = 0; i < list.length; i++) {
          if (list[i] === it) { openAt(i); return; }
        }
      }
      if (it.kind === 'video' || it.kind === 'audio') { Player.openItem(it); return; }
      window.open(it.url, '_blank');
    }
    return { openAt: openAt, openItem: openItem, close: close };
  })();

  /* ---------------- AI 听译字幕 ----------------
     subs-server.py 跑在电脑上：POST /job {url} 起任务（抽音频 → whisper 转写 → DeepSeek 翻译），
     GET /job/<id> 轮询拿 [{起,止,原文,中文}]。播放器把当前时间对上就显示。 */
  // 听译中枢在 NAS 上（任务表 + 字幕缓存 + 翻译），默认跟着页面地址走
  var _autoSubsApi = (function () {
    var h = location.hostname;
    if (/^(192\.168\.|10\.|100\.|172\.)/.test(h)) return location.protocol + '//' + h + ':5092';
    return sameHost('http://192.168.1.10:5092');
  })();
  var SUBP = { on: true, auto: false, api: '', model: 'turbo', size: 1, pos: 0, delay: 0, live: true };
  try {
    var _sp = JSON.parse(localStorage.getItem('mfm_subs') || '{}');
    ['on', 'auto', 'api', 'model', 'size', 'pos', 'delay', 'live'].forEach(function (k) { if (_sp[k] != null) SUBP[k] = _sp[k]; });
  } catch (e) { }
  function subsSavePrefs() { try { localStorage.setItem('mfm_subs', JSON.stringify(SUBP)); } catch (e) { } }
  function subsBase() { return String(SUBP.api || _autoSubsApi).replace(/\/+$/, ''); }

  // 中枢只装在 NAS 上。页面若从另一台电脑（.14 / .10）打开，按 location.hostname 拼出的
  // :5092 根本没人监听，首页就显示「连不上中枢」——其实是找错了门。这里按候选地址各探一次，
  // 谁答 /health 就用谁（NAS 页面上第一个候选就是它自己，探测秒过）。
  var _hubProbed = false;
  function hubDiscover() {
    if (_hubProbed || SUBP.api) return;
    _hubProbed = true;
    var list = [], seen = {};
    [location.protocol + '//' + location.hostname + ':5092', sameHost('http://192.168.1.10:5092')]
      .forEach(function (u) {
        u = String(u).replace(/\/+$/, '');
        if (!seen[u]) { seen[u] = 1; list.push(u); }
      });
    (function tryOne(i) {
      if (i >= list.length) { _hubProbed = false; return; }
      var done = false, ctl = null;
      var tm = setTimeout(function () {
        if (done) return; done = true;
        try { ctl && ctl.abort(); } catch (e) { }
        tryOne(i + 1);
      }, 1600);
      try { ctl = new AbortController(); } catch (e) { ctl = null; }
      var opt = { cache: 'no-store', credentials: 'omit' };
      if (ctl) opt.signal = ctl.signal;
      fetch(list[i] + '/health', opt)
        .then(function (r) { if (!r.ok) throw 0; return r.json(); })
        .then(function () {
          if (done) return; done = true; clearTimeout(tm);
          if (list[i] !== _autoSubsApi) {
            _autoSubsApi = list[i];
            try { probeHub(); } catch (e) { }
            document.dispatchEvent(new Event('hubchange'));
          }
        })
        ['catch'](function () {
          if (done) return; done = true; clearTimeout(tm);
          tryOne(i + 1);
        });
    })(0);
  }

  var SUBR = { url: '', cues: [], id: null, timer: null, state: '', msg: '', lang: '', name: '', live: false, until: 0 };
  var subLastT = 0;

  function subsWrap() { return document.querySelector('#vp .vp-subs'); }
  // 字幕外观：字号倍率 --sub-k、上下偏移 --sub-dy（像素，正值往上）
  function subApply() {
    var w = subsWrap(); if (!w) return;
    w.style.setProperty('--sub-k', String(SUBP.size || 1));
    w.style.setProperty('--sub-dy', (SUBP.pos || 0) + 'px');
  }

  // ---- 原生字幕轨：交给系统播放器（真全屏）时唯一能显示字幕的方式 ----
  var vttT = null;
  function vttBuild() {
    var v = document.querySelector('#vp video');
    if (!v) return null;
    try {
      if (!vttT) {
        if (!v.addTextTrack) return null;
        vttT = v.addTextTrack('subtitles', '双语', 'zh');
        vttT.mode = 'hidden';                     // 平时不显示，交给自己的字幕层
      }
      var a = activeCues();
      var cues = (a && a.cues) || [];
      while (vttT.cues && vttT.cues.length) { try { vttT.removeCue(vttT.cues[0]); } catch (e) { break; } }
      for (var i = 0; i < cues.length; i++) {
        var c = cues[i];
        var txt = (c[3] ? (c[2] ? c[2] + '\n' + c[3] : c[3]) : c[2]) || '';
        if (!txt) continue;
        try { vttT.addCue(new VTTCue(c[0], c[1], txt)); } catch (e) { }
      }
      return vttT;
    } catch (e) { vttT = null; return null; }
  }
  function vttMode(on) {
    var t = on ? vttBuild() : vttT;
    if (!t) return;
    try { t.mode = on ? 'showing' : 'hidden'; } catch (e) { }
  }

  /* ---------- 字幕源 ----------
     file：和视频同名的字幕文件（.srt/.vtt/.ass/.ssa，同目录），优先级最高
     ai  ：听译出来的双语字幕
     有字幕就默认打开，没有就关；优先级 同名字幕文件 > 听译字幕。 */
  var SUBF = { url: '', name: '', cues: [] };
  var PLAY = { on: false, base: 0, dur: 0, it: null, busy: false, at: null, kind: '' };
  var BRAND_GLYPH = '<svg viewBox="0 0 512 512" width="38" height="38" aria-hidden="true"><rect x="149" y="149" width="214" height="214" rx="49" fill="none" stroke="#fff" stroke-width="46"/><path d="M236 194 L322 256 L236 318 Z" fill="#fff"/></svg>';
  var ONELINE = null;          // 正在播放的在线链接（不属于任何目录，播完就清）

  function vpRealT() {
    var v = document.querySelector('#vp video');
    var t = v ? (v.currentTime || 0) : 0;
    return (PLAY.on ? PLAY.base : 0) + t;
  }

  function vpDurAll() {
    var v = document.querySelector('#vp video');
    if (PLAY.on) return PLAY.dur || 0;
    return v ? (v.duration || 0) : 0;
  }

  function curT() { return vpRealT(); }
  var SUBW = '';                       // '' | 'file' | 'ai'
  var SUBUSER = false;                 // 这一集用户手动选过字幕源，就别再自动开
  function activeCues() {
    if (SUBW === 'file' && SUBF.cues.length) return { cues: SUBF.cues, ai: false };
    if (SUBW === 'ai' && SUBR.cues.length) return { cues: SUBR.cues, ai: true };
    return null;
  }
  function tsec(x) {
    var m = String(x).match(/(\d+):(\d{1,2}):(\d{1,2})[.,](\d{1,3})/);
    if (m) return (+m[1]) * 3600 + (+m[2]) * 60 + (+m[3]) + (+m[4]) / 1000;
    m = String(x).match(/(\d{1,2}):(\d{1,2})[.,](\d{1,3})/);
    if (m) return (+m[1]) * 60 + (+m[2]) + (+m[3]) / 1000;
    return NaN;
  }
  function looksZh(t) { return /[\u4e00-\u9fff]/.test(t) && !/[\u3040-\u30ff]/.test(t); }
  function pushCue(out, a, b, lines) {
    lines = (lines || []).filter(function (x) { return x && x.trim(); });
    if (!lines.length) return;
    var or = '', zh = '';
    if (lines.length >= 2) { or = lines[0]; zh = lines.slice(1).join(' '); }
    else if (looksZh(lines[0])) { zh = lines[0]; }
    else { or = lines[0]; }
    out.push([a, b, or, zh]);
  }
  function decodeSub(buf) {
    var u8 = new Uint8Array(buf);
    if (u8.length > 1 && u8[0] === 0xFF && u8[1] === 0xFE) return new TextDecoder('utf-16le').decode(u8);
    if (u8.length > 1 && u8[0] === 0xFE && u8[1] === 0xFF) return new TextDecoder('utf-16be').decode(u8);
    if (u8.length > 2 && u8[0] === 0xEF && u8[1] === 0xBB && u8[2] === 0xBF) return new TextDecoder('utf-8').decode(u8.subarray(3));
    var t = new TextDecoder('utf-8', { fatal: false }).decode(u8);
    if (t.indexOf('\uFFFD') >= 0) {                      // 不是 UTF-8，多半是 GBK/GB18030 的老字幕
      try {
        var g = new TextDecoder('gb18030', { fatal: false }).decode(u8);
        if (g.indexOf('\uFFFD') < t.indexOf('\uFFFD')) t = g;
      } catch (e) { }
    }
    return t.replace(/^\uFEFF/, '');
  }
  function parseSubs(txt, name) {
    txt = String(txt || '').replace(/\r\n?/g, '\n');
    var out = [], i, k;
    if (/\.(ass|ssa)$/i.test(name)) {
      var L = txt.split('\n');
      for (i = 0; i < L.length; i++) {
        if (L[i].indexOf('Dialogue:') !== 0) continue;
        var f = L[i].slice(9).split(',');
        if (f.length < 10) continue;
        var a = tsec(f[1]), b = tsec(f[2]);
        if (!isFinite(a) || !isFinite(b)) continue;
        var body = f.slice(9).join(',')
          .replace(/\{[^}]*\}/g, '')                 // 样式标签
          .replace(/\\N|\\n/gi, '\n')
          .split('\n');
        pushCue(out, a, b, body);
      }
      out.sort(function (x, y) { return x[0] - y[0]; });
      return out;
    }
    var blocks = txt.split(/\n{2,}/);
    for (i = 0; i < blocks.length; i++) {
      var lines = blocks[i].split('\n').filter(function (x) { return x.trim() !== ''; });
      if (!lines.length) continue;
      var ti = -1;
      for (k = 0; k < lines.length; k++) if (lines[k].indexOf('-->') >= 0) { ti = k; break; }
      if (ti < 0) continue;
      var seg = lines[ti].split('-->');
      var A = tsec(seg[0]), B = tsec(seg[1]);
      if (!isFinite(A) || !isFinite(B)) continue;
      var body2 = lines.slice(ti + 1).map(function (x) {
        return x.replace(/<[^>]+>/g, '').replace(/\{\\[^}]*\}/g, '').trim();
      });
      pushCue(out, A, B, body2);
    }
    out.sort(function (x, y) { return x[0] - y[0]; });
    return out;
  }
  // 打开视频时扫同目录：找和文件名同前缀的字幕，挑最贴近的（名字最短那个）
  function subScan(it) {
    SUBF = { url: '', name: '', cues: [] };
    SUBW = '';
    SUBUSER = false;
    if (!it || !it.url) { drawSubMenu(); subsRender(); return; }
    var u = String(it.url).split('?')[0];
    var cut = u.lastIndexOf('/');
    if (cut < 0) return;
    var dir = u.slice(0, cut + 1);
    var file = decodeURIComponent(u.slice(cut + 1));
    var base = file.replace(/\.[^.]+$/, '').toLowerCase();
    fetch(dir + '?json', { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        var names = ((d && d.paths) || []).map(function (x) { return x.name; });
        var cands = names.filter(function (n) {
          return /\.(srt|vtt|ass|ssa)$/i.test(n) && n.toLowerCase().indexOf(base) === 0;
        });
        if (!cands.length) { drawSubMenu(); subsRender(); return; }
        cands.sort(function (a, b) { return a.length - b.length; });
        var pick = cands[0];
        return fetch(dir + encodeURIComponent(pick), { cache: 'no-store' })
          .then(function (r) { return r.arrayBuffer(); })
          .then(function (buf) {
            var cues = parseSubs(decodeSub(buf), pick);
            if (!cues.length) { drawSubMenu(); subsRender(); return; }
            SUBF = { url: dir + encodeURIComponent(pick), name: pick, cues: cues };
            SUBW = 'file';                                     // 同名字幕优先
            drawSubMenu(); subsRender();
            subsSync(curT());
            toast('同名字幕：' + (pick.length > 30 ? pick.slice(0, 28) + '…' : pick), 2400);
          });
      })
      ['catch'](function () { drawSubMenu(); subsRender(); });
  }
  // 字幕菜单：只列「来源 + 开关」，没有字幕就什么都不显示
  function drawSubMenu() {
    var box = document.querySelector('#vp .vp-sm-body');
    if (!box) return;
    var rows = '';
    if (SUBF.cues.length) {
      rows += '<div class="vp-sm-row"><span>同名字幕</span><b>' + esc(SUBF.name) + '</b>' +
        '<button class="vp-sw' + (SUBW === 'file' ? ' on' : '') + '" data-act="subsw" data-src="file" aria-label="同名字幕开关"><i></i></button></div>';
    }
    if (SUBR.cues.length || SUBR.id) {
      rows += '<div class="vp-sm-row"><span>听译字幕</span><b>' + (SUBR.cues.length ? '双语' : '还没出来') + '</b>' +
        '<button class="vp-sw' + (SUBW === 'ai' ? ' on' : '') + '" data-act="subsw" data-src="ai"' +
        (SUBR.cues.length ? '' : ' disabled') + ' aria-label="听译字幕开关"><i></i></button></div>';
    }
    if (SUBF.cues.length || SUBR.cues.length) {
      function adj(label, k, val) {
        return '<div class="vp-sm-row vp-sm-adj"><span>' + label + '</span>' +
          '<div class="vp-step">' +
          '<button data-act="subadj" data-v="' + k + '-" aria-label="减小">−</button>' +
          '<b>' + val + '</b>' +
          '<button data-act="subadj" data-v="' + k + '+">+</button>' +
          '</div></div>';
      }
      var dl = +(SUBP.delay || 0);
      rows += '<div class="vp-sm-hd2">字幕调整</div>' +
        adj('大小', 'size', Math.round((SUBP.size || 1) * 100) + '%') +
        adj('位置', 'pos', (SUBP.pos || 0) + '') +
        adj('延迟', 'del', (dl > 0 ? '+' : '') + dl.toFixed(1) + 's') +
        '<div class="vp-sm-row vp-sm-rst"><button class="vp-mini" data-act="subadj" data-v="reset">恢复默认</button></div>';
    }
    box.innerHTML = rows || '<div class="vp-sm-none">没有字幕</div>';
    subApply();
    var b = document.querySelector('#vp [data-act="submenu"]');
    if (b) b.classList.toggle('on', !!SUBW);
  }
  // 音轨菜单：列出这条片子的所有音轨，点一条就切过去（走中枢换封装，带 &at=）
  var LANG_CN = { eng: '英语', jpn: '日语', chi: '中文', zho: '中文', kor: '韩语', fre: '法语',
                  ger: '德语', spa: '西班牙语', rus: '俄语', ita: '意大利语', tha: '泰语', yue: '粤语' };
  function drawAtMenu() {
    var box = document.querySelector('#vp .vp-atmenu .vp-sm-body');
    if (!box) return;
    var tr = (PLAY.probe || {}).tracks || [];
    if (!tr.length) {
      box.innerHTML = '<div class="vp-sm-none">这条片子没有音轨</div>';
      return;
    }
    var cur = (PLAY.at != null) ? PLAY.at : tr[0].i;
    var showLang = tr.length > 1;      // 只有一条时不写语言：文件标签经常是错的，写了反而误导
    box.innerHTML = tr.map(function (x, n) {
      var bits = [String(x.codec || '').toUpperCase(),
                  x.ch ? (x.ch === 6 ? '5.1' : x.ch + ' 声道') : '',
                  showLang ? (LANG_CN[x.lang] || x.lang || '') : '',
                  x.title || ''].filter(function (z) { return !!z; });
      return '<div class="vp-sm-row vp-at-row' + (x.i === cur ? ' on' : '') + '" data-act="atpick" data-val="' + x.i + '">' +
        '<span>音轨 ' + (n + 1) + '</span><b>' + esc(bits.join(' · ')) + '</b>' +
        (x.i === cur ? '<i class="vp-at-ok">✓</i>' : '') + '</div>';
    }).join('');
    var btn = document.querySelector('#vp [data-act="atmenu"]');
    if (btn) btn.classList.toggle('on', true);
  }

  // 排查用：window.__subDbg() 看当前字幕源状态
  window.__subDbg = function () {
    return { which: SUBW, userPicked: SUBUSER, aiCues: (SUBR.cues || []).length, job: SUBR.id || '',
      fileCues: (SUBF.cues || []).length, file: SUBF.name || '' };
  };
  function subsSwitch(src) {
    var cues = src === 'file' ? SUBF.cues : SUBR.cues;
    if (!cues || !cues.length) { toast('这个来源还没有字幕'); return; }
    SUBUSER = true;
    SUBW = (SUBW === src) ? '' : src;                          // 再点一次＝关掉
    drawSubMenu(); subsRender();
    subsSync(curT());
    toast(SUBW ? (SUBW === 'file' ? '显示同名字幕' : '显示听译字幕') : '字幕已关闭');
  }
  function subsStatus(t) { var e = document.querySelector('#vp .vp-stat'); if (e) e.textContent = t || ''; }
  function subsRender() { var w = subsWrap(); var a = activeCues(); if (w) w.classList.toggle('on', !!(a && a.cues.length)); }
  function subsSync(t) {
    subLastT = t;
    if (SUBP.delay) t = t + SUBP.delay;      // 正数＝字幕往后推
    var w = subsWrap(); if (!w) return;
    var src = activeCues();
    var orEl = w.querySelector('.vp-sub-or'), zhEl = w.querySelector('.vp-sub-zh');
    if (!orEl || !zhEl) return;
    if (!src) { orEl.textContent = ''; zhEl.textContent = ''; return; }
    var c = null;
    for (var i = 0; i < src.cues.length; i++) {
      var x = src.cues[i];
      if (t >= x[0] - 0.2 && t <= x[1] + 0.35) { c = x; break; }
    }
    if (!c) { orEl.textContent = ''; zhEl.textContent = ''; return; }
    var orTxt = c[2] || '', zhTxt = c[3] || '';
    if (src.ai && /^zh/i.test(SUBR.lang || '')) { zhTxt = c[3] || c[2]; orTxt = ''; }
    orEl.textContent = orTxt;
    zhEl.textContent = zhTxt;
    w.classList.toggle('only-zh', !orTxt);
  }
  function subsStop() { if (SUBR.timer) { clearInterval(SUBR.timer); SUBR.timer = null; } }
  function subsReset(url) {
    subsStop();
    SUBR = { url: url || '', cues: [], id: null, timer: null, state: '', msg: '', lang: '', name: SUBR.name || '', it: SUBR.it || null };
    subsStatus('');
    subsRender();
  }
  function subsApply(d) {
    if (!d) return;
    SUBR.state = d.state || '';
    if (d.lang) SUBR.lang = d.lang;
    if (d.msg) SUBR.msg = d.msg;
    if (d.segments) {
      SUBR.cues = d.segments; vttBuild();
      if (!SUBW && !SUBUSER && SUBR.cues.length) SUBW = 'ai';    // 有字幕就打开
      drawSubMenu();
    }
    var du = d.done_until || 0;
    if (du) SUBR.until = du;
    subsLiveGuard();
    if (SUBR.live && d.state === 'asr') {
      subsStatus('实时听译中 · 已出 ' + SUBR.cues.length + ' 条 · 领先画面 ' +
        Math.max(0, Math.round(du - ((vpV() || {}).currentTime || 0))) + ' 秒');
    }
    else if (d.state === 'done') subsStatus(SUBR.cues.length ? '字幕已就绪' : '没听到人声');
    else if (d.state === 'error') subsStatus('听译失败：' + (d.msg || '服务出错'));
    else if (d.state === 'cancelled') subsStatus('听译已取消');
    else if (d.state === 'queued' && d.queue > 0) subsStatus('排队中… 前面还有 ' + d.queue + ' 个');
    else if (d.state === 'translating') subsStatus('翻译中… 已出 ' + SUBR.cues.length + ' 条');
    else if (SUBR.live) { /* 上面已经写过了 */ }
    else if (d.msg) subsStatus(d.msg);
    else if (du > 0) subsStatus('听译中… 已听 ' + (du >= 60 ? Math.floor(du / 60) + ':' + pad(Math.floor(du % 60)) : Math.floor(du) + ' 秒'));
    else subsStatus('听译中…（转写工正在准备）');
    subsRender();
    if (d.state === 'done' || d.state === 'error' || d.state === 'cancelled') subsStop();
  }
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) return;
    if (SUBR.id) subsPoll();
    var b = document.querySelector('#vp .vp-mon');
    if (b && !b.hidden) monRender();
  });

  var LIVE_RE = 0;
  function subsCovered(t) {
    var c = SUBR.cues || [];
    for (var i = 0; i < c.length; i++) {
      if (t >= c[i][0] - 1.5 && t <= c[i][1] + 1.5) return true;
    }
    return false;
  }
  function subsLiveGuard() {
    if (!SUBR.live || !SUBR.it || !SUBR.id) return;
    var v = vpV();
    if (!v || !SUBR.until) return;
    var t = v.currentTime || 0;
    var now = Date.now();
    if (now - LIVE_RE < 8000) return;
    if (subsCovered(t)) return;             // 这段已经转过了，直接用现成字幕
    if (t > SUBR.until + 40 || t < SUBR.until - 150) {
      LIVE_RE = now;
      subsStatus('换了位置，重新实时听译…');
      subsStart(SUBR.it, true);
    }
  }

  var pollFailN = 0;
  function subsPoll() {
    if (!SUBR.id) return;
    if (document.hidden) return;          // 切到后台就别轮询了（省电省流量），回到前台立刻补一次
    fetch(subsBase() + '/job/' + SUBR.id, { cache: 'no-store' })
      .then(function (r) {
        // 任务被别处删掉（/ol/drop、监控面板删除、另一台设备退播）时服务端回 404 + JSON，
        // 直接 r.json() 会把错误当正常数据解析，状态机落到 else 里永远停在「听译中…」，这里必须显式区分
        if (r.status === 404) { var g = new Error('gone'); g.gone = true; throw g; }
        if (!r.ok) throw new Error('http ' + r.status);
        return r.json();
      })
      .then(function (d) { pollFailN = 0; subsApply(d); })
      ['catch'](function (e) {                // 偶发失败别停轮询（刚建的任务常有一次读不到）
        if (e && e.gone) { subsStatus('听译任务已不存在（可能已被删除或重新开始过）'); subsStop(); pollFailN = 0; return; }
        pollFailN++;
        if (pollFailN >= 3) { subsStatus('听译服务没响应'); subsStop(); pollFailN = 0; }
      });
  }
  // 播放时用：只“接上”这集已经有的字幕/进度，绝不新建任务
  // ---------------- 外挂音轨：浏览器解不了 AC3/DTS 时补一条 AAC ----------------
  // 视频照旧直连（不解码视频），这条流只把音轨转成 AAC，和视频对齐播放。
  var AUD = null, AUDSS = 0, AUDT = null, AUDURL = '', AUDPEND = false, AUDGEST = false, AUDALIGN = 0, AUDWAIT = false;

  function vpV() { return document.querySelector('#vp video'); }

  function audioSet(v) {
    if (AUD) {
      try { AUD.volume = Math.max(0, Math.min(1, v)); } catch (e) { }
      return;
    }
    var el = vpV();
    if (el) { try { el.volume = Math.max(0, Math.min(1, v)); } catch (e) { } }
  }

  window.__audOn = function () { return !!AUD; };
  window.__audDbg = function () {
    if (!AUD) return null;
    return { t: +AUD.currentTime.toFixed(2), ss: AUDSS, rs: AUD.readyState,
             paused: AUD.paused, vol: AUD.volume, err: AUD.error ? AUD.error.code : 0,
             abs: +(AUDSS + AUD.currentTime).toFixed(2) };
  };

  function audStop() {
    if (AUDT) { clearInterval(AUDT); AUDT = null; }
    if (AUD) {
      try { AUD.pause(); AUD.removeAttribute('src'); AUD.load(); } catch (e) { }
      AUD = null;
    }
    AUDURL = ''; AUDSS = 0; AUDPEND = false;
    var v = vpV();
    if (v) { try { v.muted = false; } catch (e) { } }
  }

  // 音频真出声后，把视频拨到音频的位置（差距通常 < 0.4 秒，看不出来）
  function audBindPlay() {
    if (!AUD) return;
    AUD.addEventListener('playing', function () {
      var v = vpV();
      if (!v || !AUD) return;
      var want = AUDSS + (AUD.currentTime || 0);
      var d = (v.currentTime || 0) - want;
      if (Math.abs(d) > 0.25 && Math.abs(d) < 5) {
        try { v.currentTime = want; } catch (e) { }
      }
      AUD.playbackRate = v.playbackRate || 1;
      AUDWAIT = false; AUDALIGN = Date.now();
      if (v.paused) v.play()['catch'](function () { });
    }, { once: true });
  }

  function audFeed() {
    if (!AUD) return;
    AUD.play().then(function () { AUDPEND = false; })['catch'](function () { AUDPEND = true; });
    // 没有用户手势时浏览器不许出声：之后随便点一下页面就恢复
    if (!AUDGEST) {
      AUDGEST = true;
      ['pointerdown', 'touchstart', 'click'].forEach(function (ev) {
        document.addEventListener(ev, function () { if (AUD) audFeed(); }, { passive: true });
      });
    }
  }

  function audRestart(t) {
    if (!AUDURL) return;
    var v = vpV(); if (!v) return;
    t = Math.max(0, Math.floor(t || 0));
    AUDSS = t;
    try { AUD.pause(); } catch (e) { }
    try { AUD.removeAttribute('src'); AUD.load(); } catch (e) { }
    AUD.src = subsBase() + '/atrack?url=' + encodeURIComponent(AUDURL) + '&ss=' + t +
      (PLAY.at != null ? '&at=' + PLAY.at : '');
    AUD.playbackRate = v.playbackRate || 1;
    audBindPlay();
    audFeed();
    if (!v.paused) { try { v.pause(); } catch (e) { } AUDWAIT = true; }
  }

  function audBind(v) {
    if (!v || v.__audBound) return;
    v.__audBound = 1;
    v.addEventListener('play', function () { if (AUD) { audFeed(); } });
    v.addEventListener('pause', function () { if (AUD) { try { AUD.pause(); } catch (e) { } } });
    v.addEventListener('seeked', function () {
      if (!AUD) return;
      var want = v.currentTime || 0;
      if (Math.abs(want - (AUDSS + (AUD.currentTime || 0))) > 1.2) audRestart(want);
    });
    v.addEventListener('ratechange', function () { if (AUD) AUD.playbackRate = v.playbackRate || 1; });
  }

  function audStart(it, at) {
    var v = vpV(); if (!v || !it || !it.url) return;
    audStop();
    audBind(v);
    AUDURL = it.url;
    AUD = new Audio();
    AUD.preload = 'auto';
    try { AUD.volume = 1; } catch (e) { }
    v.muted = true;                       // 视频那条音轨本来就解不出来，静音更干净
    AUDSS = Math.max(0, Math.floor(v.currentTime || 0));
    AUD.src = subsBase() + '/atrack?url=' + encodeURIComponent(it.url) + '&ss=' + AUDSS +
      (at != null ? '&at=' + at : '');
    audBindPlay();
    audFeed();
    if (AUDT) clearInterval(AUDT);
    AUDT = setInterval(function () {
      if (!AUD) return;
      var el = vpV(); if (!el) return;
      if (AUDPEND) { audFeed(); return; }
      if (AUDWAIT) return;
      if (el.paused) { try { AUD.pause(); } catch (e) { } return; }
      var d = (el.currentTime || 0) - (AUDSS + (AUD.currentTime || 0));
      if (Math.abs(d) > 1.5) { audRestart(el.currentTime || 0); return; }
      // 起播时音频通常晚 0.4~0.8 秒（缓冲），把视频拨到音频位置上，之后两边同速走
      if (AUD.readyState >= 3 && Math.abs(d) > 0.3 && Math.abs(d) < 1.5
          && Date.now() - AUDALIGN > 8000) {
        AUDALIGN = Date.now();
        try { el.currentTime = AUDSS + (AUD.currentTime || 0); } catch (e) { }
      }
    }, 3000);
  }

  // 只在浏览器真的解不了时开（中枢 ffprobe 判定 afix）
  function audCheck(it) {
    if (!it || !it.url || AUDURL === it.url) return;
    // /play 和 /hls 已经把音轨换成 AAC 了，再叠一条外挂音轨只会双份或直接没声
    if (PLAY.kind && PLAY.kind !== 'raw') { audStop(); return; }
    fetch(subsBase() + '/probe?url=' + encodeURIComponent(it.url))
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (!d || !d.ok) return;
        if (!d.afix && PLAY.at == null) return;      // 原生能解、也没指定音轨：不用外挂
        if (AUDURL === it.url) return;
        audStart(it, PLAY.at);
      })['catch'](function () { });
  }

  // 这台设备解不了这条片子吗？（iOS/Safari 尤其严格：不认 MKV，不认 10bit H.264）
  function needPlay(d) {
    if (!d || !d.ok) return false;
    var ios = /iPhone|iPad|iPod/.test(navigator.userAgent);
    var cont = String(d.container || '').toLowerCase();
    var v = d.v || {}, a = d.a || {};
    var vc = String(v.codec || '').toLowerCase();
    var pix = String(v.pix || '').toLowerCase();
    var badBox = /matroska|avi|mpegts|flv|asf|ogg/.test(cont);
    var vOk = (vc === 'h264' && !/10|12/.test(pix)) || vc === 'hevc';
    if (ios) return badBox || !vOk;
    if (badBox && (vc !== 'h264' || /10|12/.test(pix))) return true;
    return false;
  }

  // 只换封装就够（视频流原样复制，CPU 几乎为零）还是要真转码（慢）
  function onlyRemux(d) {
    var v = (d && d.v) || {};
    var vc = String(v.codec || '').toLowerCase();
    var pix = String(v.pix || '').toLowerCase();
    return (vc === 'h264' && !/10|12/.test(pix)) || vc === 'hevc';
  }

  // 苹果真解不了时，盖一块说明（不能用 .vp-stat，字幕模块会把它清空）
  function vpUnsupported(msg, sub, btn) {
    var box = document.getElementById('vp');
    if (!box) return;
    var old = box.querySelector('.vp-unsup');
    if (old) old.parentNode.removeChild(old);
    if (!msg) return;
    var d = document.createElement('div');
    d.className = 'vp-unsup';
    d.innerHTML = '<div><b>' + msg + '</b><span>' + (sub ||
      '这条片子是 H.264 10bit（Hi10P），苹果没有解码器<br>换安卓手机或电脑上看') + '</span>' +
      (btn ? '<button class="vp-trans-btn" type="button">' + btn + '</button>' : '') + '</div>';
    box.appendChild(d);
  }

  // ---- 真转码：交给 NAS 先转好，转完当普通文件播（能拖进度）----


  // 流刚起来就报错（首片/init 还没写完）时，重试一次就正常了
  var VPRETRY = 0;
  window.__vpRetry = function () {
    if (!PLAY.on || !PLAY.it || VPRETRY >= 2) return false;
    VPRETRY++;
    setTimeout(function () {
      vpPlaySrc(PLAY.base).then(function (src) {
        var v = document.querySelector('#vp video');
        if (!v) return;
        v.src = src;
        try { v.play(); } catch (e) { }
      });
    }, 1200);
    return true;
  };

  // 取播放地址：MKV / AC3 这类要换封装就走中枢（苹果要 /hls 分片，其它 /play 单流），
  // 中枢说这条得重编码（415）就退回原文件直连 —— 能不能解交给播放器自己试，别提前判死。
  function vpPlaySrc(ss) {
    var it = PLAY.it || {}, raw = it.url || '', base = subsBase();
    var t = Math.max(0, Math.floor(ss || 0));
    var q = '?url=' + encodeURIComponent(raw) + '&ss=' + t + (PLAY.at != null ? '&at=' + PLAY.at : '');
    var p = PLAY.probe || {};
    if (!p.ok) { PLAY.kind = 'raw'; return Promise.resolve(raw); }            // 网盘/远端：中枢碰不到，原样发
    if (PLAY.at == null && !onlyRemux(p)) { PLAY.kind = 'raw'; return Promise.resolve(raw); }   // 原生能解：直连
    // 指定了音轨 → 必须让中枢换封装，浏览器自己切不了内嵌音轨
    if (!/iPhone|iPad|iPod/.test(navigator.userAgent)) { PLAY.kind = 'play'; return Promise.resolve(base + '/play' + q); }
    return fetch(base + '/hls' + q)
      .then(function (r) { return r.json(); })
      .then(function (j) {
        if (j && j.playlist) { PLAY.kind = 'hls'; return base + j.playlist; }
        PLAY.kind = 'play'; return base + '/play' + q;
      })
      ['catch'](function () { PLAY.kind = 'play'; return base + '/play' + q; });
  }

  function vpPrepare(it, at) {
    var v = document.querySelector('#vp video');
    if (!v || !it || !it.url) return;
    PLAY.on = false; PLAY.base = 0; PLAY.dur = 0; PLAY.it = it; PLAY.probe = null; VPRETRY = 0;
    vpUnsupported('');
    var started = false;
    function go() {
      if (started) return;
      started = true;
      var ss = Math.max(0, Math.floor(at || (v.currentTime || 0)));
      PLAY.on = true;
      PLAY.base = ss;
      PLAY.busy = true;
      vpPlaySrc(ss).then(function (src) {
        try { v.pause(); v.removeAttribute('src'); v.load(); } catch (e) { }
        v.src = src;
        try { v.play(); } catch (e) { }
        audCheck(it);                      // 现在才知道是直连还是中枢换封装
      });
      setTimeout(function () { PLAY.busy = false; }, 1500);
    }
    // 先问一句编码信息（只为拿时长 / 决定走不走换封装），拿不到也照样开播
    fetch(subsBase() + '/probe?url=' + encodeURIComponent(it.url))
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (d && d.ok) { PLAY.dur = d.dur || 0; PLAY.probe = d; }
        if (!d || !d.ok) {                          // 探测不到（网盘 / 远端）：直接播原文件
          PLAY.on = false; PLAY.kind = 'raw';
          v.src = it.url;
          try { v.play(); } catch (e) { }
          audCheck(it);
          return;
        }
        if (!needPlay(d)) {                         // 浏览器原生就能解：直连原文件
          PLAY.on = false; PLAY.kind = 'raw';
          v.src = it.url;
          try { v.play(); } catch (e) { }
          audCheck(it);                             // 直连时音轨解不了（AC3/DTS）→ 补一条 AAC
          return;
        }
        go();
      })['catch'](function () {
        PLAY.on = false; PLAY.kind = 'raw';
        v.src = it.url;
        try { v.play(); } catch (e) { }
        audCheck(it);
      });
  }

  // 统一的跳转：直连就改 currentTime，流模式就带 ss 重开一条
  window.__vpSeek = function (t) { return vpSeek(t); };
  function vpSeek(t) {
    var v = document.querySelector('#vp video');
    if (!v) return;
    t = Math.max(0, t || 0);
    if (!PLAY.on) { try { v.currentTime = t; } catch (e) { } return; }
    if (Math.abs(t - vpRealT()) < 0.6) return;
    PLAY.base = Math.floor(t);
    PLAY.busy = true;
    VPRETRY = 0;
    try { v.pause(); v.removeAttribute('src'); v.load(); } catch (e) { }
    vpPlaySrc(PLAY.base).then(function (src) {
      v.src = src;
      try { v.play(); } catch (e) { }
    });
    setTimeout(function () { PLAY.busy = false; }, 1500);
  }

  function subsAttach(it) {
    if (it) SUBR.it = it;
    if (!it || !it.url) return;
    if (it.online) {   // 在线直链没有外挂/听译字幕：留着上一集的 cues 会在新画面上飘旧台词
      if (SUBR.url !== it.url) subsReset(it.url);
      SUBR.name = it.name || SUBR.name; subsStatus(''); subsRender(); return;
    }
    SUBR.name = it.name || SUBR.name;
    if (SUBR.url === it.url && SUBR.id) { subsRender(); subsSync(subLastT); return; }
    if (SUBR.url !== it.url) subsReset(it.url);
    var tok = SUBR.url;
    fetch(subsBase() + '/find', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: it.url, name: it.name })
    }).then(function (r) { return r.json(); }).then(function (d) {
      if (!d || !d.found || SUBR.url !== tok) { subsStatus(''); subsRender(); return; }
      SUBR.id = d.id;
      SUBR.known = true;
      subsPoll();
      if (d.state !== 'done' && d.state !== 'cancelled' && d.state !== 'error') {
        subsStop();
        SUBR.timer = setInterval(subsPoll, 2500);
      }
    })['catch'](function () { });
  }
  // 在线播放：关掉播放器时把临时任务删掉（任务 + 音频 + 字幕）
  function olDrop() {
    if (SUBR.live && SUBR.id) {
      fetch(subsBase() + '/cancel', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: SUBR.id })
      })['catch'](function () { });
      SUBR.live = false;
    }
    var jid = (SUBR.online && SUBR.id) ? SUBR.id : '';
    if (ONELINE) ONELINE = null;
    if (!jid) return;
    SUBR.online = false;
    fetch(subsBase() + '/ol/drop', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: jid })
    })['catch'](function () { });
  }

  // 用户点「开始听译」或更多菜单「添加到听译队列」时才真正建任务
  function subsStart(it, hot) {
    if (!it || !it.url) return;
    SUBR.name = it.name || SUBR.name;
    var sameLive = (SUBR.url === it.url && SUBP.live && !it.online);
    if (sameLive) {
      // 实时听译换位置重开：保留已经转出来的字幕，别清空（这些段落不用再转一遍）
      subsStop();
      SUBR.state = '';
    } else {
      subsReset(it.url);
    }
    SUBR.it = it;
    SUBR.online = !!it.online;
    subsStatus(it.online ? '正在给这个链接建听译…' : '正在连接听译服务…');
    var isLive = !!SUBP.live && !it.online;
    var vEl = vpV();
    var startAt = Math.max(0, Math.floor(((vEl && vEl.currentTime) || 0) - 2));
    var body = { url: it.url, name: it.name, model: SUBP.model, hot: !!hot };
    // 方案(a)：只在用户手动选过音轨时才传 at（PLAY.at 由音轨菜单赋值、换片 4514 清空）
    // 不传 = 服务端按 LANG_PREF 自动选轨；老任务 at 保持 None → 收养分支，不丢现成字幕
    var atNow = PLAY.at;
    if (atNow != null) body.at = atNow;
    if (isLive) body.start = startAt;
    fetch(subsBase() + (it.online ? '/ol/job' : (isLive ? '/live' : '/job')), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    }).then(function (r) { return r.json(); }).then(function (d) {
      if (d && d.error === 'queue_full') {
        subsStatus('听译队列已满（上限 ' + d.max + ' 个）· 监控面板可调');
        toast('听译队列已满：上限 ' + d.max + ' 个，可在监控面板调大');
        return;
      }
      if (!d || !d.id) throw new Error('no id');
      SUBR.id = d.id;
      SUBR.live = isLive;
      SUBR.until = d.done_until || startAt;
      SUBR.viaSig = (d.via === 'sig');
      subsStatus(isLive ? '实时听译中…（第一句大约 10 秒）'
        : (d.reused ? (SUBR.viaSig ? '这个文件听译过了（换个入口打开的），正在读…' : '读取已生成的字幕…')
          : '听译中…（第一条大约 20 秒）'));
      if (SUBR.viaSig && !d.reused) toast('同一个文件，接着之前的进度听译，不会从头再来');
      else if (SUBR.viaSig) toast('这集你从别的入口听过，直接复用字幕');
      subsPoll();
      subsStop();
      SUBR.timer = setInterval(subsPoll, 2500);
    })['catch'](function () {
      subsStatus('听译服务连不上（' + subsBase() + '）');
      subsStop();
    });
  }
  // 更多菜单里的「添加到听译队列」：后台转，不抢占、不影响当前播放
  function subsEnqueue(it) {
    if (!it || !it.url) return;
    fetch(subsBase() + '/job', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: it.url, name: it.name, model: SUBP.model, hot: false })
    }).then(function (r) { return r.json(); }).then(function (d) {
      if (d && d.error === 'queue_full') { toast('听译队列已满（上限 ' + d.max + ' 个），可在监控面板调大'); return; }
      if (!d || !d.id) { toast('加入失败'); return; }
      if (d.state === 'done') toast('这集已经听译好了');
      else if (d.reused) toast('这集已经在队列里了');
      else toast('已加入听译队列，后台慢慢转');
    })['catch'](function () { toast('连不上听译服务'); });
  }

  /* ---------------- 听译监控面板（播放器里点开） ---------------- */
  var monTimer = null;
  var monHealth = null;

  function monBox() { return document.querySelector('#vp .vp-mon'); }

  function monOpen() {
    var b = monBox(); if (!b) return;
    b.hidden = false;
    var vp = document.getElementById('vp'); if (vp) vp.classList.add('mon-open');
    monRender();
    if (monTimer) clearInterval(monTimer);
    monTimer = setInterval(function () { if (!document.hidden) monRender(); }, 1500);
  }
  function monClose() {
    var b = monBox(); if (b) b.hidden = true;
    var vp = document.getElementById('vp'); if (vp) vp.classList.remove('mon-open');
    if (monTimer) { clearInterval(monTimer); monTimer = null; }
  }
  function fmtDur(s) {
    s = Math.max(0, Math.floor(s || 0));
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), ss = s % 60;
    return (h ? h + ':' + pad(m) : m) + ':' + pad(ss);
  }
  var ST_TXT = { queued: '排队中', asr: '转写中', translating: '翻译中', done: '已完成', error: '出错', cancelled: '已停止' };
  var ST_CLS = { queued: 'wait', asr: 'run', translating: 'run', done: 'ok', error: 'bad', cancelled: 'bad' };

  function monDraw(d, h) {
    if (h) monHealth = h;
    var live = monBox() && monBox().querySelector('.mon-live'); if (!live) return;
    var stBtn = monBox().querySelector('[data-mon="start"]');   // 本集听译按钮：无论有没有任务都要更新
    if (stBtn) {
      var hasJob = !!SUBR.id;
      stBtn.textContent = hasJob ? ((d && ST_TXT[d.state]) || '已在听译') : '开始听译';
      stBtn.disabled = false;                    // 永远能点：点了给明确回应，不要"没反应"
      stBtn.classList.toggle('on', !hasJob);
    }
    var v = document.querySelector('#vp video');
    if (!d) {
      live.innerHTML = '<div class="mon-empty">还没开始听译</div>';
      return;
    }
    var total = (v && isFinite(v.duration) && v.duration > 0) ? v.duration : (d.dur_total || 0);
    var got = d.done_until || 0;
    var pct = total ? Math.min(100, Math.round(got / total * 100)) : 0;
    var segs = (d.segments || []).length;
    var badge = '<span class="mon-badge ' + (ST_CLS[d.state] || 'wait') + '">' + (ST_TXT[d.state] || d.state) + '</span>';
    var extra = '';
    if (d.state === 'queued' && d.queue > 0) extra = '<span class="mon-dim">前面还有 ' + d.queue + ' 个</span>';
    else if (d.msg) extra = '<span class="mon-dim">' + esc(d.msg) + '</span>';
    var rows = [
      ['已听 / 总长', fmtDur(got) + ' / ' + (total ? fmtDur(total) : '未知') + ' · ' + pct + '%'],
      ['速度', d.speed ? d.speed + '× 实时' : '—'],
      ['段落 / 待译', segs + ' / ' + (d.pending || 0)],
      ['语言', (d.lang || '未定') + (d.audio_ready ? ' · 用 NAS 音频' : '')],
      ['转写工', d.state === 'asr' && (d.touch_age || 0) < 15 ? d.touch_age + ' 秒前有心跳' : (d.touch_age ? d.touch_age + ' 秒前' : '—')]
    ];
    var grid = rows.map(function (r) {
      return '<div><span>' + r[0] + '</span><b>' + r[1] + '</b></div>';
    }).join('');
    live.innerHTML = '<div class="mon-head">' + badge + extra + '</div>' +
      '<div class="mon-bar"><i style="width:' + pct + '%"></i></div>' +
      '<div class="mon-kv">' + grid + '</div>' +
      (h ? '<div class="mon-kv mon-hub"><div><span>中枢</span><b>' + (h.jobs || 0) + ' 任务 · 排队 ' + (h.queued || 0) +
        ' · 转写 ' + (h.asr || 0) + '/' + (h.max_active || '?') +
        (h.stuck ? ' · 卡死 ' + h.stuck : '') + '</b></div><div><span>翻译接口</span><b>' +
        (h.key ? '正常' : '缺密钥') + '</b></div></div>' : '');
    // 设置项的选中态
    var b = monBox();
    b.querySelectorAll('[data-mon^="model-"]').forEach(function (x) {
      x.classList.toggle('on', (x.dataset.mon === 'model-turbo') === (SUBP.model === 'turbo'));
    });
    var mx = (monHealth && monHealth.max_active) || 3;
    b.querySelectorAll('[data-mon^="max-"]').forEach(function (x) {
      var v = parseInt(x.dataset.mon.slice(4), 10);
      x.classList.toggle('on', v === mx);
    });
  }

  function monRender() {
    if (!monBox() || monBox().hidden) return;
    if (!SUBR.id) { monDraw(null, null); return; }
    fetch(subsBase() + '/job/' + SUBR.id, { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(function (d) {
        fetch(subsBase() + '/health', { cache: 'no-store' })
          .then(function (r) { return r.json(); })
          .then(function (h) { monDraw(d, h); })
          ['catch'](function () { monDraw(d, null); });
      })
      ['catch'](function () { monDraw(null, null); });
  }

  // 设置页监控面板里的单任务操作：data-tk="<任务id>|<动作>"
  document.addEventListener('click', function (e) {
    var t = e.target && e.target.closest && e.target.closest('[data-tk]');
    if (!t) return;
    e.preventDefault(); e.stopPropagation();
    var v = String(t.getAttribute('data-tk')).split('|'), id = v[0], act = v[1], job = null;
    if (id === '__tab') { monTab = act; monDelArm = ''; monSheetDraw(); return; }
    for (var i = 0; i < monJobsCache.length; i++) if (monJobsCache[i].id === id) job = monJobsCache[i];
    if (act === 'del') {
      if (monDelArm !== id) {          // 两下确认，防误删
        monDelArm = id;
        monSheetDraw();
        setTimeout(function () { if (monDelArm === id) { monDelArm = ''; monSheetDraw(); } }, 4000);
        toast('再点一次就删除，4 秒后取消');
        return;
      }
      monDelArm = '';
      fetch(subsBase() + '/delete', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: id }) })
        .then(function (r) { return r.json(); })
        .then(function (d) {
          toast(d && d.ok ? '已删除' : ('删除失败：' + ((d && (d.msg || d.error)) || '未知')));
          monSheetDraw();
        })
        ['catch'](function () { toast('删除失败：连不上中枢'); });
      return;
    }
    if (act === 'srt') {
      srtDownload(id, (job && job.name) || '字幕');
      return;
    }
    fetch(subsBase() + (act === 'stop' ? '/cancel' : '/reset'),
      { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id: id }) })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        toast(d && d.ok ? (act === 'stop' ? '已停止（已出的字幕保留）' : '已重新排队') : '操作失败');
        monSheetDraw();
      })
      ['catch'](function () { toast('操作失败：连不上中枢'); });
  }, true);

  // 面板里的按钮用 data-mon 标记，捕获阶段拦下来，别和播放器的 data-act 混在一起
  document.addEventListener('click', function (e) {
    var t = e.target && e.target.closest && e.target.closest('[data-mon]');
    if (t) { e.preventDefault(); e.stopPropagation(); monAct(t.getAttribute('data-mon')); }
  }, true);

  function monAct(a) {
    if (a === 'start') {
      var it = SUBR.it;
      if (!it) { toast('先播放一个视频'); return; }
      if (SUBR.id) {                                   // 已有任务：说清现在是什么状态、该点哪里
        var st0 = SUBR.state;
        if (st0 === 'done') toast('这一集已经听译好了；要重来点下面「重新听译」');
        else if (st0 === 'error') toast('上次出错了；点下面「重新听译」再跑一遍');
        else if (st0 === 'cancelled') toast('上次已停止；点下面「重新听译」接着转');
        else toast('这一集正在听译（' + (ST_TXT[st0] || st0 || '排队中') + '），要停就点「停止」');
        return;
      }
      subsStart(it, true);
      monRender();
      return;
    }
    if (a === 'model-turbo' || a === 'model-small') {
      SUBP.model = (a === 'model-small' ? 'small' : 'turbo'); subsSavePrefs();
      toast('精度：' + (SUBP.model === 'turbo' ? '高质量' : '快速') + '（对下一个任务生效）'); monRender(); return;
    }
    if (a === 'refresh') { monSheetDraw(); return; }
    if (a.indexOf('max-') === 0) {
      var n = parseInt(a.slice(4), 10) || 3;
      fetch(subsBase() + '/config', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ max_active: n }) })
        .then(function (r) { return r.json(); })
        .then(function (d) {
          toast('最多同时听译 ' + d.max_active + ' 个');
          monRender();
        })
        ['catch'](function () { toast('设置失败：连不上中枢'); });
      return;
    }
    if (a === 'srt') {
      if (!SUBR.id) { toast('还没有字幕'); return; }
      srtDownload(SUBR.id, SUBR.name || '字幕');
      return;
    }
    if (a === 'reset') {
      if (!SUBR.id) { toast('还没有任务'); return; }
      fetch(subsBase() + '/reset', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: SUBR.id }) })
        .then(function (r) { return r.json(); })
        .then(function (d) {
          if (!d || !d.ok) { toast('重跑失败'); return; }
          SUBR.cues = []; SUBR.state = 'queued';
          subsStop(); subsPoll(); SUBR.timer = setInterval(subsPoll, 2500);
          toast('已重新排队，从头再听一次'); monRender();
        })
        ['catch'](function () { toast('重跑失败：连不上中枢'); });
      return;
    }
    if (a === 'stop') {
      if (!SUBR.id) { toast('还没有任务'); return; }
      fetch(subsBase() + '/cancel', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: SUBR.id }) })
        .then(function (r) { return r.json(); })
        .then(function (d) { toast(d && d.ok ? '已停止（已出的字幕保留）' : '停止失败'); subsStop(); monRender(); })
        ['catch'](function () { toast('停止失败：连不上中枢'); });
      return;
    }
  }

  /* ---------------- 设置页的「听译监控」面板 ---------------- */
  var monJobsCache = [];
  var monSheetTimer = null;
  var monTab = 'live';          // live | done | stopped
  var monDelArm = '';           // 待确认删除的任务 id

  function monSheet() {
    sheet('听译监控', '<div id="monBox"><div class="mon-empty">正在读取…</div></div>');
    monSheetDraw();
    if (monSheetTimer) clearInterval(monSheetTimer);
    monSheetTimer = setInterval(function () { if (!document.hidden) monSheetDraw(); }, 3000);
  }
  function monSheetStop() {
    if (monSheetTimer) { clearInterval(monSheetTimer); monSheetTimer = null; }
  }
  // 任务来自哪台设备：把 IP 换回来源名（电脑 · LIFRE → LIFRE）
  function srcLabelOf(host) {
    if (!SOURCES || !host) return '';
    var src = SOURCES.sources || [];
    for (var i = 0; i < src.length; i++) {
      var s = src[i], cand = [s.base, s.baseWan, s.relay, s.wan], hit = false;
      for (var k = 0; k < cand.length; k++) {
        if (!cand[k]) continue;
        try { if (new URL(cand[k], location.href).hostname === host) { hit = true; break; } } catch (e) { }
      }
      if (hit) {
        var nm = String(s.name || '');
        var i2 = nm.indexOf('·');
        return (i2 >= 0 ? nm.slice(i2 + 1) : nm).trim();
      }
    }
    return '';
  }
  function monPath(j) {
    var host = String(j.host || '').replace(/:\d+$/, '');
    var label = '';
    if (host && host !== location.hostname) label = srcLabelOf(host) || host;
    var folder = j.folder || '（根目录）';
    var alt = (j.alt || 0) ? '另 ' + j.alt + ' 个入口' : '';
    return '<div class="mon-path">' + icn('type-folder', 12) +
      '<span>' + esc(label ? label + ' · ' + folder : folder) + '</span>' +
      (alt ? '<em class="mon-alt" title="同一个文件，从别的入口打开过">' + esc(alt) + '</em>' : '') + '</div>';
  }

  function monBadge(st) {
    return '<span class="mon-badge ' + (ST_CLS[st] || 'wait') + '">' + (ST_TXT[st] || st) + '</span>';
  }
  function monCard(j) {
    var total = j.dur_total || 0, got = j.done_until || 0;
    var pct = total ? Math.min(100, Math.round(got / total * 100)) : (j.state === 'done' ? 100 : 0);
    var nm = (j.name || j.id).replace(/\.[^.]+$/, '');
    var segs = (j.segments || []).length;
    var running = (j.state === 'asr' || j.state === 'queued' || j.state === 'translating');
    var extra = '';
    if (j.state === 'queued') extra = j.queue ? '排队第 ' + (j.queue + 1) + ' 个' : '下一个就轮到';
    else if (j.state === 'asr' || j.state === 'translating') extra = j.speed ? j.speed + '× 实时' : '正在转写';
    else if (j.state === 'cancelled') extra = '停了，已出的字幕保留';
    else if (j.state === 'error') extra = j.msg ? j.msg.slice(0, 18) : '出错';
    var meta = fmtDur(got) + (total ? ' / ' + fmtDur(total) + ' · ' + pct + '%' : '') + ' · ' +
      segs + ' 段' + (extra ? ' · ' + extra : '');
    var id = esc(j.id);
    var acts = '';
    if (running) {
      if (segs) acts += '<button data-tk="' + id + '|srt">导出已出部分</button>';
      acts += '<button class="danger" data-tk="' + id + '|stop">停止</button>';
      acts += '<button disabled title="先停止才能删除">删除</button>';
    } else if (j.state === 'done') {
      acts += '<button data-tk="' + id + '|srt">导出 .srt</button>';
      acts += '<button data-tk="' + id + '|reset">重新听译</button>';
      acts += '<button class="danger" data-tk="' + id + '|del">' + (monDelArm === j.id ? '再点一次' : '删除') + '</button>';
    } else {
      if (segs) acts += '<button data-tk="' + id + '|srt">导出已出部分</button>';
      acts += '<button data-tk="' + id + '|reset">重新听译</button>';
      acts += '<button class="danger" data-tk="' + id + '|del">' + (monDelArm === j.id ? '再点一次' : '删除') + '</button>';
    }
    return '<div class="mon-card"><div class="mon-card-h"><b>' + esc(nm) + '</b>' + monBadge(j.state) + '</div>' +
      monPath(j) +
      '<div class="mon-bar"><i style="width:' + pct + '%"></i></div>' +
      '<div class="mon-card-m">' + meta + '</div>' +
      '<div class="mon-card-a">' + acts + '</div></div>';
  }
  function monSheetDraw() {
    var box = document.getElementById('monBox');
    if (!box) { monSheetStop(); return; }
    function tj(url, ms) {
      var ctl = null;
      try { ctl = new AbortController(); } catch (e) { ctl = null; }
      var tm = setTimeout(function () { try { ctl && ctl.abort(); } catch (e) { } }, ms);
      return fetch(url, ctl ? { cache: 'no-store', signal: ctl.signal } : { cache: 'no-store' })
        .then(function (r) { clearTimeout(tm); return r.json(); })
        ['catch'](function () { clearTimeout(tm); return null; });
    }
    Promise.all([
      tj(subsBase() + '/jobs?brief=1', 8000),
      tj(subsBase() + '/health', 6000)
    ]).then(function (a) {
      var d = a[0], h = a[1];
      if (!d || !d.jobs) {
        box.innerHTML = '<div class="mon-empty">连不上听译中枢（超时或没响应）<br><small>' + esc(subsBase()) +
          '</small><br><button class="mon-chip" data-mon="refresh" style="margin-top:10px">重试</button></div>';
        return;
      }
      monJobsCache = d.jobs;
      var mx = d.max_active || 3;
      var chips = [[1, '1 个'], [2, '2 个'], [3, '3 个']].map(function (x) {
        return '<button data-mon="max-' + x[0] + '"' + (mx === x[0] ? ' class="on"' : '') + '>' + x[1] + '</button>';
      }).join('');
      var out = '<div class="mon-sum">' +
        '<span class="mon-badge ' + (h && h.ok ? 'ok' : 'bad') + '">' + (h && h.ok ? '中枢正常' : '中枢无响应') + '</span>' +
        '<span class="mon-dim">转写 ' + (h ? h.asr : '?') + '/' + mx + ' · 排队 ' + (h ? h.queued : '?') +
        (h && h.stuck ? ' · 卡死 ' + h.stuck : '') + ' · 翻译' + (h && h.key ? '正常' : '缺密钥') + '</span></div>' +
        '<div class="mon-row"><span>同时听译</span><div class="mon-chips">' + chips + '</div></div>';
      var live = [], done = [], stopped = [];
      monJobsCache.forEach(function (j) {
        if (j.state === 'done') done.push(j);
        else if (j.state === 'queued' || j.state === 'asr' || j.state === 'translating') live.push(j);
        else stopped.push(j);
      });
      var TAB = [['live', '进行中', live.length], ['done', '已完成', done.length], ['stopped', '已停止', stopped.length]];
      out += '<div class="mon-tabs">' + TAB.map(function (t) {
        return '<button data-tk="__tab|' + t[0] + '"' + (monTab === t[0] ? ' class="on"' : '') + '>' +
          t[1] + (t[2] ? ' <i>' + t[2] + '</i>' : '') + '</button>';
      }).join('') + '</div>';
      var cur = monTab === 'live' ? live : (monTab === 'done' ? done : stopped);
      if (!cur.length) {
        out += '<div class="mon-empty">' + (monTab === 'live' ? '现在没有在听译的片子'
          : monTab === 'done' ? '还没有听译完成的片子' : '没有已停止的任务') + '</div>';
      } else {
        out += cur.map(monCard).join('');
      }
      out += '<div class="mon-tip">同时听译的数量按上面的设置走：开几个就在同时转几个，正在看的片子优先。<br>' +
        '正在跑的任务要先「停止」才能删除。<br>3 秒自动刷新一次。</div>';
      box.innerHTML = out;
    });
  }

  /* ---------------- 视频 / 音频播放器 ----------------
     布局：顶栏 + 画面 + 底栏 全部叠在视频上（画面铺满整屏，横屏全屏时不被控制条挤小）。
     原生 controls 关掉，进度条/播放键/时间都是自己的，避免两套控件打架。            */
  var Player = (function () {
    var box = null, vEl, nameEl, cntEl, dlEl, metaEl, prevB, nextB, statEl;
    var playBtn, rateBtn, listPanel, listItems, listN, toastEl;
    var centerBtn, barWrap, barEl, barFill, barBuf, t1El, t2El, sheet;
    var idx = 0, pushed = false, curKey = '', lastSave = 0, statT = null;
    var autoT = null, toastT = null, noticeEl = null, immT = null;
    var RATES = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4];
    var LPRATES = [2, 3, 4, 6];
    var SWK = [['慢', 0.6], ['标准', 1], ['快', 1.6]];
    var scr = { on: false, was: true, t: null };

    function list() {
      if (ONELINE) return [ONELINE];        // 在线播放：播放列表里只有这一条
      return (LAST_SHOWN && LAST_SHOWN.length ? LAST_SHOWN : ITEMS)
        .filter(function (x) { return x.kind === 'video' || x.kind === 'audio'; });
    }
    function keyOf(it) {
      var u = String(it.url || it.name), h = 0;
      for (var i = 0; i < u.length; i++) h = (h * 31 + u.charCodeAt(i)) | 0;
      return 'mfm_pos_' + (h >>> 0);
    }
    function posGet(k, dur) {
      try {
        var v = parseFloat(localStorage.getItem(k) || '0') || 0;
        if (dur && v > dur - 12) v = 0;      // 快看完了，下次从头
        return v;
      } catch (e) { return 0; }
    }
    function posSet(k, v) {
      try { if (v > 8) localStorage.setItem(k, String(Math.floor(v))); else localStorage.removeItem(k); } catch (e) { }
    }
    function rateGet() { try { return parseFloat(localStorage.getItem('mfm_rate') || '1') || 1; } catch (e) { return 1; } }
    function rateSet(r) { try { localStorage.setItem('mfm_rate', String(r)); } catch (e) { } }
    function gs(k, d) { try { var v = parseFloat(localStorage.getItem(k)); return isNaN(v) ? d : v; } catch (e) { return d; } }
    function gsSet(k, v) { try { localStorage.setItem(k, String(v)); } catch (e) { } }
    function lpRate() { return gs('mfm_lp_rate', 3); }                       // 长按加速倍率
    function swSens(dur) {                                                   // 长视频灵敏度 0.5、短视频 0.2，再乘用户系数
      var base = (dur && dur <= gs('mfm_sw_th', 300)) ? 0.2 : 0.5;
      return base * gs('mfm_sw_k', 1);
    }
    function hm(sec) {
      sec = Math.max(0, Math.floor(sec || 0));
      var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), x = sec % 60;
      return (h ? h + ':' + pad(m) : m + '') + ':' + pad(x);
    }
    function notice(html) {
      if (!noticeEl) return;
      noticeEl.innerHTML = html;
      noticeEl.classList.add('on');
    }
    function noticeHide() { if (noticeEl) noticeEl.classList.remove('on'); }
    // ---- 亮度（浏览器管不了系统亮度，只能压画面本身）----
    function briGet() { var v = parseFloat(localStorage.getItem('mfm_bri') || '1'); return isFinite(v) ? Math.max(0.2, Math.min(1, v)) : 1; }
    var briSaveT = null;
    function briSet(v, save) {
      v = Math.max(0.2, Math.min(1, v));
      var d = box && box.querySelector('.vp-dim');
      if (d) d.style.opacity = v >= 0.99 ? '0' : ((1 - v) * 0.9).toFixed(3);
      if (save !== false) {                                  // 拖动中不写盘，松手才写
        clearTimeout(briSaveT);
        briSaveT = setTimeout(function () { localStorage.setItem('mfm_bri', v.toFixed(2)); }, 250);
      }
      return v;
    }
    // 移动端网页改不了正在播放的媒体音量：WebView 里 video.volume 设了不生效（只有 muted 有效），
    // 系统媒体流要 app 权限（Via 自带控件能调就是因为它自己就是 app）。所以移动端只如实提示用侧键。
    function volAdjustable() {
      return !/Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent);
    }
    function setVol(v) {
      v = Math.max(0, Math.min(1, v));
      if (!vEl) return v;
      if (window.__audOn && window.__audOn()) { audioSet(v); return v; }
      vEl.muted = false;
      try { vEl.volume = v; } catch (e) { }
      return v;
    }

    function immersive(on) {
      clearTimeout(immT);
      if (!box) return;
      if (on) immT = setTimeout(function () { if (open() && !vEl.paused) box.classList.add('imm'); }, 3500);
      else box.classList.remove('imm');
    }
    function saveNow() {
      if (!vEl || !curKey) return;
      var t = vpRealT(), d = vpDurAll();
      if (d && t > d - 12) { posSet(curKey, 0); recTouch(PLAY.rec, 0, d); lastSave = Date.now(); return; }  // 快看完了就别记
      posSet(curKey, t);
      recTouch(PLAY.rec, t, d);
      lastSave = Date.now();
    }
    function toast(msg, ms) {
      if (!toastEl) return;
      toastEl.textContent = msg;
      toastEl.classList.add('on');
      clearTimeout(toastT);
      toastT = setTimeout(function () { toastEl.classList.remove('on'); }, ms || 2600);
    }
    window.__vpStat = function (txt, keep) { return setStat(txt, keep); };
    function setStat(txt, keep) {                       // 画面上的状态一句话（讲完自己消失；报错留着）
      if (!statEl) return;
      statEl.textContent = txt || '';
      clearTimeout(statT);
      if (txt && !keep) statT = setTimeout(function () { if (statEl) statEl.textContent = ''; }, 7000);
    }
    function drawProg(t) {
      var d = vpDurAll(), cur = (t == null ? vpRealT() : t);
      barFill.style.width = (d ? Math.max(0, Math.min(100, cur / d * 100)) : 0) + '%';
      var b = 0;
      try { b = (vEl.buffered && vEl.buffered.length) ? vEl.buffered.end(vEl.buffered.length - 1) : 0; } catch (e) { b = 0; }
      barBuf.style.width = (d ? Math.max(0, Math.min(100, b / d * 100)) : 0) + '%';
      if (!scr.on) t1El.textContent = hm(cur);
      t2El.textContent = d ? hm(d) : '--:--';
    }
    function syncBtn() {
      var paused = !!vEl.paused;
      if (playBtn) playBtn.innerHTML = paused ? icn('play', 20) : icn('pause', 20);
      if (centerBtn) centerBtn.innerHTML = paused ? icn('play', 26) : icn('pause', 26);
      if (rateBtn) rateBtn.textContent = (vEl.playbackRate || 1).toFixed(2).replace(/0$/, '').replace(/\.$/, '.0') + '×';
      if (box) box.classList.toggle('paused', paused);
    }

    /* iPhone 上没有元素级全屏 API（只有 video.webkitEnterFullscreen()，那会把画面交给苹果原生播放器，
       我们的工具条和手势就全没了）。所以那边改用「网页全屏」：自己把整个播放器转 90° 贴满屏幕。 */
    var webFs = false;
    function realFsOK() {
      var d = document;
      return !!((d.fullscreenEnabled && box.requestFullscreen) || (d.webkitFullscreenEnabled && box.webkitRequestFullscreen));
    }
    // 苹果在较老的 iOS 上只给「视频交给系统播放器」这条路：真满屏，但我们的字幕/手势/监控都没了。
    // 只能作为用户明确选择的兜底，不能自己偷偷调用。
    // （原生字幕轨 vttBuild/vttMode 已挪到模块级：听译轮询会调用它，闭包里取不到）

    // iOS 上「全屏」就是交给系统播放器：用苹果自己的控件，我们不再自绘（字幕走原生 textTrack）
    function iosNativeFull() {
      try {
        vttMode(true);
        // 系统播放器里拖动进度是它自己的事，退出来后把外挂音轨重新对一遍
        if (!vEl.__audFsBound) {
          vEl.__audFsBound = 1;
          vEl.addEventListener('webkitendfullscreen', function () {
            if (window.__audOn && window.__audOn()) audRestart(vEl.currentTime || 0);
          });
        }
        vEl.webkitEnterFullScreen();
        return true;
      } catch (e) { vttMode(false); return false; }
    }
    // 已添加到主屏幕（PWA 独立窗口）时本来就没有浏览器界面
    function standalone() {
      try {
        return (window.navigator.standalone === true) ||
          window.matchMedia('(display-mode: standalone)').matches ||
          window.matchMedia('(display-mode: fullscreen)').matches;
      } catch (e) { return false; }
    }
    function syncLayout() {                        // 设备横过来 / 网页全屏：都换紧凑布局
      if (!box || !vEl) return;
      box.classList.toggle('vp-land', window.innerWidth > window.innerHeight || webFs);
      subPlace();
    }
    // 字幕层贴住画面（不是屏幕）的底边：16:9 片子在竖屏上上下都有黑边，
    // 不这么算字幕会掉到黑边里，看着像"浮在画面外"
    function subPlace() {
      var w = subsWrap(); if (!w || !vEl) return;
      var r = vEl.getBoundingClientRect(), pr = box.getBoundingClientRect();
      var off = Math.round(pr.bottom - r.bottom);
      if (off > 24 && r.height > 80) w.style.bottom = (off + 14) + 'px';
      else w.style.bottom = '';                   // 满屏时不插手，交给 CSS
    }
    function webFsSet(on) {
      webFs = on;
      if (!box) return;
      box.classList.toggle('vp-web', on);
      document.documentElement.classList.toggle('fs-lock', on);
      syncLayout();
      if (on) {
        if (standalone()) { setStat(''); return; }        // 已是独立窗口：本来就是满屏
        try { window.scrollTo(0, 1); } catch (e) { }      // 顶一下，收起 Safari 底部工具栏
        setStat(realFsOK() ? ''
          : (window.innerWidth > window.innerHeight ? '这已经是浏览器能给的最大画面'
            : '把手机横过来＝满屏；或添加到主屏幕后打开，就没有浏览器工具栏了'));
      } else {
        setStat('');
      }
    }
    function toggleFull() {
      try {
        if (webFs) { webFsSet(false); return; }
        // 苹果（含 Via 这类 WebView）：全屏直接交给系统播放器
        if (/(iPhone|iPad|iPod)/.test(navigator.userAgent) && vEl && vEl.webkitEnterFullScreen) {
          if (iosNativeFull()) return;
        }
        if (document.fullscreenElement || document.webkitFullscreenElement) {
          (document.exitFullscreen || document.webkitExitFullscreen).call(document);
          return;
        }
        if (realFsOK()) {
          var pr = (box.requestFullscreen || box.webkitRequestFullscreen).call(box);
          if (pr && pr.catch) pr.catch(function () { webFsSet(true); });   // 被拒就退回网页全屏
          return;
        }
        webFsSet(true);                            // iPhone 等不支持元素全屏的浏览器
      } catch (err) { webFsSet(true); }
    }
    window.addEventListener('resize', syncLayout);
    var LOCK = false, lockArm = 0;
    function setLock(v) {
      LOCK = !!v;
      box.classList.toggle('vp-lock', LOCK);
      var chip = box.querySelector('.vp-lockchip');
      if (chip) chip.classList.remove('arm');
      if (LOCK) { immersive(true); toast('已锁定：点右下角的小锁解锁'); }
      else toast('已解锁');
    }

    function build() {
      if (box) return;
      box = document.createElement('div');
      box.id = 'vp';
      box.className = 'paused';
      box.innerHTML =
        '<div class="iv-top"><button class="iv-btn sm" data-act="close" title="关闭">' + icn('close', 19) + '</button>' +
        '<div class="iv-name"></div><span class="iv-meta"></span><span class="iv-count"></span>' +
        '<button class="iv-btn sm vp-subs-btn' + (SUBP.on ? ' on' : '') + '" data-act="submenu" title="字幕">' +
        icn('subs', 19) + '</button>' +
        '<button class="iv-btn sm vp-at-btn" data-act="atmenu" title="音轨">' + icn('volume', 19) + '</button>' +
        '<button class="iv-btn sm" data-act="monitor" title="听译监控">' + icn('monitor', 19) + '</button>' +
        '<button class="iv-btn sm" data-act="lock" title="锁定屏幕">' + icn('lock', 19) + '</button>' +
        '<a class="iv-btn sm" data-act="dl" download title="下载原文件">' + icn('download', 19) + '</a></div>' +

        '<div class="vp-stage">' +
        // 安卓各家浏览器（尤其小米/UC/QQ 的 X5 内核）会在视频上盖自己的播放器 UI：
        // playsinline/x5-playsinline 阻止它接管全屏，x5-video-player-type=h5-page 让它留在页面里，
        // controlslist + disablepictureinpicture 把原生控件全关掉。
        '<video class="vp-video" playsinline webkit-playsinline x5-playsinline ' +
        'x5-video-player-type="h5-page" x5-video-player-fullscreen="false" ' +
        'disablepictureinpicture disableremoteplayback ' +
        'controlslist="nodownload noplaybackrate noremoteplayback" ' +
        'preload="metadata"></video>' +
        '<button class="iv-btn iv-nav vp-prev" data-act="prev" title="上一集">' + icn('prev', 24) + '</button>' +
        '<button class="iv-btn iv-nav vp-next" data-act="next" title="下一集">' + icn('next', 24) + '</button>' +
        '<button class="vp-center" data-act="toggle" title="播放 / 暂停">' + icn('play', 26) + '</button>' +
        '<div class="vp-stat"></div>' +
        '<div class="vp-dim"></div>' +
        '<div class="vp-subs"><div class="vp-sub-or"></div><div class="vp-sub-zh"></div></div>' +
        '<div class="vp-mon" hidden><div class="vp-mon-hd"><span>听译监控</span>' +
        '<button class="iv-btn sm" data-act="monclose" title="收起">' + icn('close', 18) + '</button></div>' +
        '<div class="vp-mon-body">' +
        '<div class="mon-live"></div>' +
        '<div class="mon-set">' +

        '<div class="mon-row"><span>本集听译</span><div class="mon-chips">' +
        '<button data-mon="start">开始听译</button></div></div>' +
        '<div class="mon-row"><span>识别精度</span><div class="mon-chips">' +
        '<button data-mon="model-turbo">高质量</button><button data-mon="model-small">快速</button></div></div>' +
        '<div class="mon-row"><span>同时听译</span><div class="mon-chips">' +
        '<button data-mon="max-1">1 个</button><button data-mon="max-2">2 个</button>' +
        '<button data-mon="max-3">3 个</button></div></div>' +
        '</div>' +
        '<div class="mon-acts"><button data-mon="srt">导出 .srt</button>' +
        '<button data-mon="reset">重新听译</button>' +
        '<button data-mon="stop" class="danger">停止</button></div>' +
        '</div></div>' +
        '<div class="vp-submenu" hidden><div class="vp-sm-hd">字幕</div><div class="vp-sm-body"></div></div>' +
        '<div class="vp-submenu vp-atmenu" hidden><div class="vp-sm-hd">音轨</div><div class="vp-sm-body"></div></div>' +
        '<button class="vp-lockchip" data-act="unlockc" aria-label="解锁">' + icn('unlock', 18) + '</button>' +
        '<div class="vp-notice"></div><div class="vp-toast"></div></div>' +

        '<div class="iv-bottom">' +
        '<div class="vp-barwrap" title="拖动跳进度">' +
        '<span class="vp-t vp-t1">0:00</span>' +
        '<div class="vp-bar"><div class="vp-buf"></div><div class="vp-fill"><i class="vp-knob"></i></div></div>' +
        '<span class="vp-t vp-t2">0:00</span>' +
        '</div>' +
        '<div class="vp-tools">' +
        '<button class="vp-btn" data-act="back10" title="后退 10 秒">' + icn('back10', 22) + '</button>' +
        '<button class="vp-btn vp-big" data-act="toggle" title="播放 / 暂停">' + icn('play', 20) + '</button>' +
        '<button class="vp-btn" data-act="fwd10" title="前进 10 秒">' + icn('fwd10', 22) + '</button>' +
        '<span class="vp-sp"></span>' +
        '<button class="vp-btn sm" data-act="rate" title="播放设置">1.0×</button>' +
        '<button class="vp-btn sm" data-act="plist" title="本目录的视频">' + icn('playlist', 19) + '</button>' +
        '<button class="vp-btn sm" data-act="full" title="全屏">' + icn('fullscreen', 19) + '</button>' +
        '</div></div>' +

        '<div class="vp-rate-menu">' +
        '<div class="vp-rm-head">播放设置<button class="vp-btn sm" data-act="rmclose" title="关闭">' + icn('close', 18) + '</button></div>' +
        '<div class="vp-rm-row"><b>播放速度</b><div class="vp-rm-grid sp"></div></div>' +
        '<div class="vp-rm-row"><b>长按加速</b><div class="vp-rm-grid lp"></div></div>' +
        '<div class="vp-rm-row"><b>滑动灵敏度</b><div class="vp-rm-grid sw"></div></div>' +
        '<div class="vp-rm-acts"><button class="vp-rm-a" data-act="pip">' + icn('pip', 17) + ' 画中画</button>' +
        '<button class="vp-rm-a" data-act="fromhead">' + icn('rotate', 17) + ' 从头播放</button>' +
        '</div>' +
        '<div class="vp-rm-tip">左右滑＝快进快退 · 长按＝倍速快进 · 右侧竖滑＝音量（手机上用侧键） · 双击＝全屏</div>' +
        '</div>' +

        '<div class="vp-list"><div class="vp-list-head">本目录的视频 <span class="vp-list-n"></span>' +
        '<button class="vp-btn sm" data-act="plistclose" title="关闭">' + icn('close', 18) + '</button></div>' +
        '<div class="vp-items"></div></div>';
      document.body.appendChild(box);

      vEl = $('.vp-video', box);
      if (vEl) {
        vEl.controls = false; vEl.disablePictureInPicture = true;
      } nameEl = $('.iv-name', box); cntEl = $('.iv-count', box);
      dlEl = $('[data-act="dl"]', box); metaEl = $('.iv-meta', box); statEl = $('.vp-stat', box);
      prevB = $('.vp-prev', box); nextB = $('.vp-next', box);
      playBtn = $('.vp-big', box); centerBtn = $('.vp-center', box); rateBtn = $('[data-act="rate"]', box);
      listPanel = $('.vp-list', box); listItems = $('.vp-items', box); listN = $('.vp-list-n', box);
      toastEl = $('.vp-toast', box); noticeEl = $('.vp-notice', box); sheet = $('.vp-rate-menu', box);
      barWrap = $('.vp-barwrap', box); barEl = $('.vp-bar', box);
      barFill = $('.vp-fill', box); barBuf = $('.vp-buf', box);
      t1El = $('.vp-t1', box); t2El = $('.vp-t2', box);

      function curIt() { var a = list(); return a[idx] || null; }
      box.addEventListener('click', function (e) {
        var it2 = e.target.closest && e.target.closest('.vp-item');
        if (it2) { listPanel.classList.remove('on'); show(parseInt(it2.dataset.i, 10)); return; }
        var rsel = e.target.closest && e.target.closest('.vp-rm-b');   // 速度面板里的按钮没有 data-act，得先判
        if (rsel) {
          if (rsel.dataset.r) { vEl.playbackRate = parseFloat(rsel.dataset.r); rateSet(parseFloat(rsel.dataset.r)); syncBtn(); toast('播放速度 ' + rsel.dataset.r + '×'); }
          else if (rsel.dataset.lp) { gsSet('mfm_lp_rate', parseFloat(rsel.dataset.lp)); toast('长按加速 ' + rsel.dataset.lp + '×'); }
          else if (rsel.dataset.sw) { gsSet('mfm_sw_k', parseFloat(rsel.dataset.sw)); toast('滑动灵敏度 ' + rsel.dataset.swl); }
          drawRateMenu();
          return;
        }
        var t = e.target.closest && e.target.closest('[data-act]');
        if (!t) return;
        var a = t.getAttribute('data-act');
        if (a === 'fromhead') { resetHere(); return; }
        if (a === 'close') close();
        else if (a === 'prev') prev();
        else if (a === 'next') next();
        else if (a === 'toggle') { vEl.paused ? vEl.play() : vEl.pause(); }
        else if (a === 'back10') { vpSeek(Math.max(0, vpRealT() - 10)); toast('-10 秒'); }
        else if (a === 'fwd10') { vpSeek(Math.min(vpDurAll() || 1e9, vpRealT() + 10)); toast('+10 秒'); }
        else if (a === 'rate') {
          sheet.classList.toggle('on');
          if (sheet.classList.contains('on')) {
            drawRateMenu();
          }
        }
        else if (a === 'rmclose') { sheet.classList.remove('on'); }
        else if (a === 'submenu') {
          var sm = box.querySelector('.vp-submenu:not(.vp-atmenu)');
          var amz = box.querySelector('.vp-atmenu'); if (amz) amz.hidden = true;   // 和音轨面板互斥
          if (sm) {
            sm.hidden = !sm.hidden;
            if (!sm.hidden) {
              drawSubMenu();
              if (curIt() && !SUBR.id) subsAttach(curIt());   // 打开菜单时顺手查一下有没有听译好的
            }
          }
        }
        else if (a === 'subsw') { subsSwitch(t.getAttribute('data-src')); }
        else if (a === 'subadj') {
          var v = t.getAttribute('data-v') || '';
          var r1 = function (x) { return Math.round(x * 100) / 100; };
          if (v === 'reset') { SUBP.size = 1; SUBP.pos = 0; SUBP.delay = 0; }
          else if (v === 'size-') SUBP.size = Math.max(0.75, r1((SUBP.size || 1) - 0.05));
          else if (v === 'size+') SUBP.size = Math.min(1.7, r1((SUBP.size || 1) + 0.05));
          else if (v === 'pos-') SUBP.pos = Math.max(-90, (SUBP.pos || 0) - 15);
          else if (v === 'pos+') SUBP.pos = Math.min(240, (SUBP.pos || 0) + 15);
          else if (v === 'del-') SUBP.delay = Math.max(-5, r1((SUBP.delay || 0) - 0.5));
          else if (v === 'del+') SUBP.delay = Math.min(5, r1((SUBP.delay || 0) + 0.5));
          subsSavePrefs(); subApply(); drawSubMenu(); subsSync(curT());
        }
        else if (a === 'davretry') { loadDav(ST.path, true); }
        else if (a === 'davauth') { srcAuthSheet((activeSrc() || {}).id); }
        else if (a === 'atmenu') {
          var am = box.querySelector('.vp-atmenu');
          if (am) {
            sm = box.querySelector('.vp-submenu:not(.vp-atmenu)');
            if (sm) sm.hidden = true;                       // 和字幕面板互斥
            am.hidden = !am.hidden;
            if (!am.hidden) drawAtMenu();
          }
        }
        else if (a === 'atpick') {
          var av = parseInt(t.getAttribute('data-val'), 10);
          if (isNaN(av)) return;
          var am2 = box.querySelector('.vp-atmenu'); if (am2) am2.hidden = true;
          PLAY.at = av;
          var keepT = vpRealT();
          toast('切换到音轨 ' + (av + 1));
          audStop();
          vpPrepare(PLAY.it, keepT);                        // 带 at 重新取流
          // 听译跟着音轨走：换轨就从当前位置重开一段（旧字幕作废）
          if (SUBP.on && PLAY.it) subsStart(PLAY.it, true);
        }
        else if (a === 'lock') { setLock(true); }
        else if (a === 'unlockc') {
          var armed = (Date.now() - lockArm) < 3000;
          if (!armed) {
            lockArm = Date.now();
            box.querySelector('.vp-lockchip').classList.add('arm');
            toast('再点一次解锁');
            setTimeout(function () { var c = box.querySelector('.vp-lockchip'); if (c) c.classList.remove('arm'); }, 3000);
          } else { lockArm = 0; setLock(false); }
        }
        else if (a === 'monitor') {
          var mb = monBox();
          if (mb && !mb.hidden) monClose(); else monOpen();  // 再点一次＝收起
        }
        else if (a === 'monclose') { monClose(); }
        else if (a === 'pip') {
          try {
            if (document.pictureInPictureElement) document.exitPictureInPicture();
            else if (vEl.requestPictureInPicture) vEl.requestPictureInPicture();
            else toast('这个浏览器不支持画中画');
          } catch (err) { toast('画中画打不开'); }
        }
        else if (a === 'full') { toggleFull(); }
        else if (a === 'plist') { listPanel.classList.add('on'); drawList(); }
        else if (a === 'plistclose') { listPanel.classList.remove('on'); }
        else if (a === 'dl') { e.preventDefault(); var ci2 = list()[idx]; if (ci2) downloadFile(ci2.url, ci2.name, ci2.size); }
      });

      function drawRateMenu() {
        var cur = rateGet(), lp = lpRate(), sw = gs('mfm_sw_k', 1);
        $('.vp-rm-grid.sp', box).innerHTML = RATES.map(function (r) {
          return '<button class="vp-rm-b' + (Math.abs(r - cur) < 0.01 ? ' on' : '') + '" data-r="' + r + '">' + r + '×</button>';
        }).join('');
        $('.vp-rm-grid.lp', box).innerHTML = LPRATES.map(function (r) {
          return '<button class="vp-rm-b' + (Math.abs(r - lp) < 0.01 ? ' on' : '') + '" data-lp="' + r + '">' + r + '×</button>';
        }).join('');
        $('.vp-rm-grid.sw', box).innerHTML = SWK.map(function (x) {
          return '<button class="vp-rm-b' + (Math.abs(x[1] - sw) < 0.01 ? ' on' : '') + '" data-sw="' + x[1] + '" data-swl="' + x[0] + '">' + x[0] + '</button>';
        }).join('');
      }

      /* ---- 进度条：点/拖跳转（横屏全屏下也够大，拖动时不误触画面手势）---- */
      function ratioAt(x) {
        var r = barEl.getBoundingClientRect();
        return Math.max(0, Math.min(1, (x - r.left) / (r.width || 1)));
      }
      function scrTo(x) {
        var d = vpDurAll(); if (!d) return null;
        var t = ratioAt(x) * d;
        scr.t = t;
        t1El.textContent = hm(t);
        barFill.style.width = (ratioAt(x) * 100) + '%';
        notice('◀ ' + hm(t) + ' ▶<i>共 ' + hm(d) + '</i>');
        return t;
      }
      function scrStart(x) {
        scr.on = true; scr.was = !vEl.paused;
        box.classList.add('scrubbing');
        if (!vEl.paused) vEl.pause();
        scrTo(x);
      }
      function scrMove(x) { if (!scr.on) return; var t = scrTo(x); if (t == null) return; if (PLAY.on) return; var n = Date.now(); if (n - (scr.q || 0) < 300) return; scr.q = n; vpSeek(t); }
      function scrEnd() {
        if (!scr.on) return;
        scr.on = false; box.classList.remove('scrubbing'); noticeHide();
        if (scr.t != null) { vpSeek(scr.t); scr.t = null; }   // 只点一下（没拖动）也要跳
        drawProg();
        if (scr.was) { var pr = vEl.play(); if (pr && pr.catch) pr.catch(function () { }); }
      }
      barWrap.addEventListener('touchstart', function (e) {
        if (e.touches.length !== 1) return;
        e.preventDefault(); e.stopPropagation();
        scrStart(e.touches[0].clientX);
      }, { passive: false });
      barWrap.addEventListener('touchmove', function (e) {
        if (!scr.on || e.touches.length !== 1) return;
        e.preventDefault(); e.stopPropagation();
        scrMove(e.touches[0].clientX);
      }, { passive: false });
      barWrap.addEventListener('touchend', function (e) { e.preventDefault(); e.stopPropagation(); scrEnd(); }, { passive: false });
      barWrap.addEventListener('touchcancel', function () { scrEnd(); });
      barWrap.addEventListener('mousedown', function (e) { e.preventDefault(); scrStart(e.clientX); });
      window.addEventListener('mousemove', function (e) { if (scr.on) scrMove(e.clientX); });
      window.addEventListener('mouseup', function () { if (scr.on) scrEnd(); });

      /* ---- 手机手势：照着「俺的手机视频脚本」的做法（左右滑=快进快退、长按=倍速、竖滑=音量）---- */
      var G = { on: false, x0: 0, y0: 0, dir: 0, seek: 0, moved: false, lp: false, lpBack: 1, lpTimer: null, vol0: 1, wasPlaying: false, tgt: null };
      var stage = $('.vp-stage', box);
      // 手势面＝整个播放器（横屏时画面只有 260px 高，顶栏/底栏也盖在上面，只绑 stage 会滑不动）；
      // 真正的控件（按钮、进度条、面板）除外，它们自己处理。
      var NOGEST = 'button,a,input,select,textarea,.vp-barwrap,.vp-rate-menu,.vp-mon,.sheet,.vp-diag';
      box.addEventListener('touchstart', function (e) {
        if (e.touches.length !== 1) return;
        if (LOCK) return;                                    // 锁屏：不跟手、不调音量亮度、不唤出控件
        var t = e.touches[0];
        var tg = e.target;
        if (tg && tg.closest && tg.closest(NOGEST)) { G.on = false; return; }
        G.on = true; G.moved = false; G.dir = 0; G.seek = 0; G.lp = false; G.tgt = tg;
        G.x0 = Math.ceil(t.clientX); G.y0 = Math.ceil(t.clientY);
        G.vol0 = vEl.volume; G.bri0 = briGet(); G.wasPlaying = !vEl.paused;
        G.side = t.clientX < window.innerWidth / 2 ? 1 : 2;   // 1=左半屏(亮度) 2=右半屏(音量)
        G.wasImm = box.classList.contains('imm');              // 点之前界面是藏着的吗
        immersive(false);
        clearTimeout(G.lpTimer);
        G.lpTimer = setTimeout(function () {                 // 长按 0.8 秒：倍速快进
          if (!G.on || G.moved || !open()) return;
          G.lp = true; G.lpBack = vEl.playbackRate || 1;
          var r = lpRate();
          vEl.playbackRate = r;
          if (vEl.paused) { var pr = vEl.play(); if (pr && pr.catch) pr.catch(function () { }); }
          syncBtn();
          notice('▶ ' + r + '× 快进中');
          try { if (navigator.vibrate) navigator.vibrate(15); } catch (err) { }
        }, 800);
      }, { passive: true });

      box.addEventListener('touchmove', function (e) {
        if (!G.on || e.touches.length !== 1) return;
        var t = e.touches[0];
        var dx = Math.ceil(t.clientX) - G.x0, dy = Math.ceil(t.clientY) - G.y0;
        if (Math.abs(dx) > 10 || Math.abs(dy) > 10) { G.moved = true; clearTimeout(G.lpTimer); }
        if (G.lp) { e.preventDefault(); return; }            // 长按中不做别的
        if (Math.abs(dx) <= 10 && Math.abs(dy) <= 10) return;
        var ex = dx, ey = dy;                                 // 不再有 90° 伪全屏，轴就是屏幕轴
        if (!G.dir) G.dir = Math.abs(ex) >= Math.abs(ey) ? 1 : 2;   // 1=横滑进度 2=竖滑音量
        e.preventDefault();
        if (G.dir === 1) {
          G.seek = Math.round((Math.abs(ex) - 10) * swSens(vEl.duration)) * (ex > 0 ? 1 : -1);
          var tg = Math.max(0, Math.min(vEl.duration || 1e9, (vEl.currentTime || 0) + G.seek));
          notice((ex > 0 ? '▶▶ ' : '◀◀ ') + hm(tg) + '<i>' + (G.seek > 0 ? '+' : '−') + hm(Math.abs(G.seek)) + ' · 共 ' + hm(vEl.duration) + '</i>');
        } else if (G.dir === 2) {
          if (G.side === 1) {                                 // 左半屏：亮度
            var b = briSet(G.bri0 - ey / 220);
            notice('☀️ ' + Math.round(b * 100) + '%');
          } else {                                            // 右半屏：音量
            var nv = setVol(G.vol0 - ey / 200);
            if (volAdjustable()) notice((nv < 0.02 ? '🔇 ' : '🔊 ') + Math.round(nv * 100) + '%');
            else notice('🔇 音量请用手机侧键<i>网页改不了系统音量</i>');
          }
        }
      }, { passive: false });

      function gEnd() {
        clearTimeout(G.lpTimer);
        if (!G.on) return;
        G.on = false;
        var onBtn = G.tgt && G.tgt.closest && !!G.tgt.closest('button,a');
        if (G.lp) {                                          // 松手 → 恢复原速
          vEl.playbackRate = G.lpBack || 1; syncBtn();
          toast('恢复 ' + (G.lpBack || 1) + '×');
          noticeHide(); G.lp = false; return;
        }
        if (G.dir === 1 && G.seek) {                          // 滑动结束才动进度
          vpSeek(Math.max(0, Math.min(vpDurAll() || 1e9, vpRealT() + G.seek)));
          toast((G.seek > 0 ? '+' : '−') + hm(Math.abs(G.seek)));
        } else if (G.dir === 0 && !G.moved && !onBtn) {       // 轻点画面＝显示/隐藏 来回切；点按钮不插手
          if (G.wasImm) {                                     // 藏着 → 叫出来，并重新计时
            box.classList.remove('imm');
            if (!vEl.paused) immersive(true);
          } else {                                            // 露着 → 立刻收起来
            clearTimeout(immT);
            box.classList.add('imm');
          }
          setTimeout(function () { if (G.wasPlaying && vEl.paused) { var pr = vEl.play(); if (pr && pr.catch) pr.catch(function () { }); } }, 450);
        }
        noticeHide(); G.dir = 0; G.seek = 0;
        if (!vEl.paused) immersive(true);                     // 松手后重新计时：3.5 秒没动就隐藏
        else box.classList.remove('imm');
      }
      box.addEventListener('touchend', gEnd);
      box.addEventListener('touchcancel', gEnd);

      vEl.addEventListener('loadedmetadata', function () {
        vEl.playbackRate = rateGet(); syncBtn(); drawProg(); syncLayout();
        briSet(briGet()); vttBuild();
        var at = curKey ? posGet(curKey, vpDurAll()) : 0;
        if (at > 8 && !PLAY.on) {
          try { vEl.currentTime = at; } catch (e) { }
          toast('已跳到上次的位置 ' + hm(at));
        } else if (at > 8 && PLAY.on) {
          toast('接着上次 ' + hm(at) + ' 播放');
        }
        if (metaEl) metaEl.textContent = metaTxt;
      });
      // 苹果原生播放器全屏：系统会接管画面，只能靠 textTrack 显示字幕
      vEl.addEventListener('webkitbeginfullscreen', function () {
        box.classList.add('fs-native');
        vttMode(true);
        toast('系统全屏：字幕由播放器显示，手势和倍速不可用', 2600);
      });
      vEl.addEventListener('webkitendfullscreen', function () {
        box.classList.remove('fs-native');
        vttMode(false);
      });
      vEl.addEventListener('play', function () { syncBtn(); immersive(true); });
      vEl.addEventListener('pause', function () { syncBtn(); immersive(false); });
      vEl.addEventListener('timeupdate', function () {
        drawProg();
        subsSync(vpRealT());
        if (Date.now() - lastSave > 5000) saveNow();
        if (listPanel.classList.contains('on') && Date.now() - lastSave > 3000) drawList();
      });
      vEl.addEventListener('progress', function () { drawProg(); });
      vEl.addEventListener('durationchange', function () { drawProg(); });
      vEl.addEventListener('seeked', function () { drawProg(); });
      vEl.addEventListener('ended', function () {
        if (curKey) posSet(curKey, 0);
        var arr = list();
        if (idx < arr.length - 1) {
          var n = 6;
          setStat('这一集播完了，' + n + ' 秒后自动播下一集');
          clearInterval(autoT);
          var left = n;
          autoT = setInterval(function () {
            left--;
            if (left <= 0) { clearInterval(autoT); next(); }
            else setStat('这一集播完了，' + left + ' 秒后自动播下一集', true);
          }, 1000);
        } else {
          setStat('这是这一批的最后一个了', true);
        }
      });
      vEl.addEventListener('error', function () {
        if (window.__vpRetry && window.__vpRetry()) return;      // 首片/init 没写好：自动重试一次
        var p = PLAY.probe || {};
        if (p.ok && !onlyRemux(p)) {
          setStat('这台设备解不了这条片子的编码（H.264 10bit），推流也放不出来 —— 换 8bit 片源，或用别的播放器', true);
        } else {
          setStat('这个文件播不了（编码可能不支持），点右上角的下载按钮，下载后用别的播放器', true);
        }
      });
      function orientHandler() {
        var f = document.fullscreenElement || document.webkitFullscreenElement;
        syncLayout();
        try {
          var o = screen.orientation;
          if (!o || !o.lock) return;
          if (f && vEl.videoWidth >= vEl.videoHeight) { var pr = o.lock('landscape'); if (pr && pr.catch) pr.catch(function () { }); }
          else if (!f && o.unlock) o.unlock();
        } catch (err) { }                                    // iOS Safari 不支持方向锁定，忽略
      }
      document.addEventListener('fullscreenchange', orientHandler);
      document.addEventListener('webkitfullscreenchange', orientHandler);
      vEl.addEventListener('dblclick', function (e) { e.preventDefault(); toggleFull(); });
      // 桌面：鼠标一动就把控制条露出来，停 3.5 秒再自动隐藏（触屏不接这套）
      box.addEventListener('mousemove', function () {
        if ('ontouchstart' in window) return;
        if (box.classList.contains('imm')) box.classList.remove('imm');
        if (!vEl.paused) immersive(true);
      });
      // 桌面：点画面 = 播放/暂停（手机上点一下不暂停，交给手势那套）
      vEl.addEventListener('click', function () {
        if ('ontouchstart' in window) return;
        vEl.paused ? vEl.play() : vEl.pause();
      });
      document.addEventListener('keydown', function (e) {
        if (!open()) return;
        if (e.key === 'Escape') close();
        else if (e.key === 'ArrowRight') { vpSeek(vpRealT() + 10); }
        else if (e.key === 'ArrowLeft') { vpSeek(Math.max(0, vpRealT() - 10)); }
        else if (e.key === 'PageDown') next();
        else if (e.key === 'PageUp') prev();
        else if (e.key === ' ') { if (document.activeElement !== vEl) { e.preventDefault(); vEl.paused ? vEl.play() : vEl.pause(); } }
        else if (e.key === 'l' || e.key === 'L') { vpSeek(vpRealT() + 10); }
        else if (e.key === 'j' || e.key === 'J') { vpSeek(Math.max(0, vpRealT() - 10)); }
        else if (e.key === 'f' || e.key === 'F') { toggleFull(); }
        else if (e.key === 'Enter') { e.preventDefault(); toggleFull(); }
      });
      window.addEventListener('popstate', function () { if (open()) { pushed = false; hide(); } });
    }

    function drawList() {
      var arr = list();
      listN.textContent = (idx + 1) + ' / ' + arr.length;
      listItems.innerHTML = arr.map(function (x, i) {
        var at = posGet(keyOf(x), null), d = x.dur || 0;
        var badge = !at ? '' : '<i class="vp-prog">' + (d ? Math.round(at / d * 100) + '%' : hm(at)) + '</i>';
        return '<button class="vp-item' + (i === idx ? ' on' : '') + '" data-i="' + i + '">' +
          '<span class="vp-item-ico">' + icn('type-video', 18) + '</span>' +
          '<span class="vp-item-txt"><b>' + esc(x.name) + '</b>' +
          '<i>' + (x.size != null ? fmt(x.size) + ' · ' : '') + dayOf(x.mtime) + '</i></span>' +
          badge + '</button>';
      }).join('');
      var cur = $('.vp-item.on', listItems);
      if (cur && cur.scrollIntoView) cur.scrollIntoView({ block: 'center' });
    }

    var metaTxt = '';
    function show(k, autoplay) {
      var arr = list();
      if (!arr.length) return;
      k = Math.max(0, Math.min(arr.length - 1, k));
      idx = k;
      var it = arr[k];
      var newKey = keyOf(it);
      if (curKey && curKey !== newKey && vEl.getAttribute('src')) saveNow();
      curKey = newKey;
      PLAY.rec = it.url || '';
      recPush(it);
      clearInterval(autoT);
      noticeHide(); if (sheet) sheet.classList.remove('on'); box.classList.remove('imm');
      vEl.pause();
      vEl.removeAttribute('src'); vEl.load();
      PLAY.at = null;                          // 换片：音轨选择归零
      vpPrepare(it, curKey ? posGet(curKey, null) : 0);
      vEl.playbackRate = rateGet();
      SUBR.id = ''; SUBR.known = false;        // 换片先清掉上一集的
      audStop();                               // 换片先把上一条外挂音轨停掉
      subsAttach(it);                          // 只接已有进度，不新建任务
      subScan(it);                             // 同目录同名字幕：有就用它（优先于听译）
      // audCheck 挪到 vpPlaySrc 出结果之后（要知道是直连还是中枢换封装）
      nameEl.textContent = it.name;
      nameEl.title = it.name;
      cntEl.textContent = (k + 1) + '/' + arr.length;
      metaTxt = it.size != null ? fmt(it.size) : '';
      if (metaEl) metaEl.textContent = metaTxt;
      dlEl.setAttribute('href', it.url); dlEl.setAttribute('download', it.name);
      prevB.disabled = k === 0; nextB.disabled = k === arr.length - 1;
      var at = posGet(curKey, null);
      setStat(at > 8 ? '上次看到 ' + hm(at) + '，加载完会跳过去' : '');
      drawProg(0); syncBtn(); syncLayout();
      if (autoplay !== false) { var pr = vEl.play(); if (pr && pr.catch) pr.catch(function () { }); }
    }
    function next() { if (idx < list().length - 1) show(idx + 1); }
    function prev() { if (idx > 0) show(idx - 1); }
    function open() { return !!box && box.classList.contains('open'); }
    function hide() {
      if (!box) return;
      saveNow();
      olDrop();                       // 在线播放：关掉就把临时听译任务删干净
      try { subsStop(); } catch (e) { }   // 与 close() 对齐：不补这三条，侧滑/返回退出后
      try { monClose(); } catch (e) { }   // 2.5s 的 /job、1.5s 的 /jobs、3s 的音轨轮询会一直跑
      try { audStop(); } catch (e) { }
      clearInterval(autoT);
      try { vEl.pause(); } catch (e) { }
      try {
        if (document.fullscreenElement || document.webkitFullscreenElement) (document.exitFullscreen || document.webkitExitFullscreen).call(document);
        if (screen.orientation && screen.orientation.unlock) screen.orientation.unlock();
      } catch (e) { }
      if (document.pictureInPictureElement) { try { document.exitPictureInPicture(); } catch (e) { } }
      webFs = false;
      box.classList.remove('open', 'imm', 'paused', 'vp-web', 'vp-land');
      listPanel.classList.remove('on');
      document.body.classList.remove('iv-lock');
      vEl.removeAttribute('src'); vEl.load();
      try { render(); } catch (e) { }      // 让列表里的「已看 x:xx」跟着更新
    }
    function close() {
      if (!open()) return;
      subsStop(); monClose();
      try { audStop(); } catch (e) { }
      hide(); if (pushed) { pushed = false; history.back(); }
    }
    function openItem(it) {
      build();
      var arr = list(), at = -1;
      for (var i = 0; i < arr.length; i++) if (arr[i] === it) { at = i; break; }
      if (at < 0) { arr = [it]; at = 0; }
      if (!open()) {
        document.body.classList.add('iv-lock'); box.classList.add('open');
        try { history.pushState({ vp: 1 }, ''); pushed = true; } catch (e) { pushed = false; }
      }
      if (listPanel.classList.contains('on')) drawList();
      setTimeout(subPlace, 60);
      if (LOCK) setLock(false);
      subApply();
      show(at);
    }
    function resetHere() { vpSeek(0); if (curKey) posSet(curKey, 0); toast('从头开始'); }
    return { openItem: openItem, close: close, resetHere: resetHere, hide: hide };
  })();

  /* 自动跟上新版本：手机上的页面常年挂着不关，回到前台时对一下版本戳，
     发现服务器换了新的就自己重载一次 —— 免得一直跑旧代码还以为没生效 */
  (function () {
    var last = 0, busy = false;
    function check() {
      if (document.hidden || busy) return;
      var now = Date.now();
      if (now - last < 120000) return;
      last = now;
      busy = true;
      fetch('/', { cache: 'no-store' })
        .then(function (r) { return r.text(); })
        .then(function (t) {
          busy = false;
          var m = /v = '(\d+)'/.exec(t);
          if (m && window.__V && m[1] !== window.__V) location.reload();
        })
        ['catch'](function () { busy = false; });
    }
    document.addEventListener('visibilitychange', function () { if (!document.hidden) check(); });
    window.addEventListener('focus', check);
  })();

  /* ---------------- 事件 ---------------- */
  function bind() {
    el.nav.addEventListener('click', function (e) {
      var b = e.target.closest('[data-nav]');
      if (!b) return;
      navFinish();                          // 切到别的栏就放弃正在读的目录
      ST.view = b.dataset.nav; ST.cat = null; LIMIT = 500;
      saveState();
      render();
      window.scrollTo({ top: 0, behavior: SMOOTH });
    });

    // 点来源卡片：进这个来源开始浏览
    el.srcSec.addEventListener('click', function (e) {
      var oa = e.target.closest && e.target.closest('[data-act="online"]');
      if (oa) { e.preventDefault(); onlineSheet(); return; }
      var fx = e.target.closest && e.target.closest('[data-favdel]');
      if (fx) { e.preventDefault(); e.stopPropagation(); favDel(parseInt(fx.getAttribute('data-favdel'), 10)); return; }
      var fv = e.target.closest && e.target.closest('[data-fav]');
      if (fv) { e.preventDefault(); openFav(favGet()[parseInt(fv.getAttribute('data-fav'), 10)]); return; }
      var b = e.target.closest('[data-src]');
      if (!b) return;
      pickSource(b.dataset.src);
    });

    // 网盘路径面包屑：点哪一段跳哪一层
    el.crumbs.addEventListener('click', function (e) {
      var a = e.target.closest('[data-dav]');
      if (a) { e.preventDefault(); loadDav(a.dataset.dav || ''); return; }
      // 本地共享的面包屑同样走软打开：慢目录整页跳会白等 30-50 秒
      var link = e.target.closest('a[href]');
      if (!link || isRemote()) return;
      e.preventDefault();
      var u = link.href;
      if (!/\/$/.test(u)) u += '/';
      navOpen(u, safeDecode(u.split('/').filter(Boolean).pop() || '') || '云匣', false);
    });

    // 浏览器后退/前进：软打开进过的目录地址变了，要把列表跟着退回去（不是重新请求整页）
    window.addEventListener('popstate', function () {
      var here = location.href.split(/[?#]/)[0];
      if (!/\/$/.test(here)) here += '/';
      if (here === BASE) return;            // 查看器/播放器压进来的历史，地址没变
      navOpen(here, safeDecode(here.split('/').filter(Boolean).pop() || '') || '云匣', true);
    });

    var qT = null;
    el.q.addEventListener('input', function () {
      ST.q = el.q.value.trim();
      if (ST.view === 'settings') ST.view = 'files';
      clearTimeout(qT);
      qT = setTimeout(render, 120);        // 防抖：整张大列表别每敲一个字重绘一次
    });
    el.q.addEventListener('keydown', function (e) {
      if (e.key !== 'Enter') return;
      var v = el.q.value.trim();
      if (!v) return;
      e.preventDefault();
      // 全库搜索是 dufs 服务端的能力：网盘 / 电脑共享那边没有，只能在当前目录里过滤；
      // 文件树特别大的主机（NAS）连 dufs 的 ?q= 都跑不出来，同样只留当前目录过滤
      if (!wideSearchOk()) {
        toast(wideSearchWhy());
        return;
      }
      location.href = BASE + '?q=' + encodeURIComponent(v);
    });
    el.searchFab.addEventListener('click', function () {
      ST.qOpen = true;
      if (Q && el.q && !el.q.value) el.q.value = Q;
      render();
      setTimeout(function () { try { el.q.focus(); } catch (e) { } }, 40);
    });
    $('#qClose').addEventListener('click', function () {
      ST.qOpen = false; ST.q = '';
      if (el.q) el.q.value = '';
      render();
    });
    if ($('#sortIco')) $('#sortIco').addEventListener('click', sortSheet);
    $('#sortBtn').addEventListener('click', sortSheet);

    el.fileList.addEventListener('click', function (e) {
      // 空状态卡片里的按钮（需要登录 / 重试）不是 .srow，得单独接一下
      var ssEl = e.target.closest('[data-ss]');
      if (ssEl) { srcAuthSheet(ssEl.getAttribute('data-v')); return; }
      var gh = e.target.closest('.set-h[data-gt]');
      if (gh) {
        var gk = gh.getAttribute('data-gt'), gEl = gh.parentNode;
        var willColl = !gEl.classList.contains('coll');
        gEl.classList.toggle('coll', willColl);
        SETCOL[gk] = willColl ? 1 : 0;
        setCollSave();
        return;
      }
      var gbtn = e.target.closest('button[data-act]');
      if (gbtn && !gbtn.closest('.srow')) {
        var ga = gbtn.dataset.act;
        if (ga === 'davauth') { srcAuthSheet((activeSrc() || {}).id); return; }
        if (ga === 'davretry') { loadDav(ST.path, true); return; }
      }
      var seg1 = e.target.closest('[data-set]');
      if (seg1) { setPref(seg1.dataset.set, seg1.dataset.v); return; }
      var sr = e.target.closest('.srow[data-act]');
      if (sr) {
        var a = sr.dataset.act, v = sr.dataset.val || '';
        if (a === 'copy') { copyText(v); return; }
        if (a === 'auth') { authSheet(); return; }
        if (a === 'login') { loginSheet(); return; }
        if (a === 'logout') { doLogout(); return; }
        if (a === 'gosrc') { ST.view = 'home'; saveState(); render(); window.scrollTo(0, 0); return; }
        if (a === 'sortsheet') { sortSheet(); return; }
        if (a === 'themesheet') { themeSheet(); return; }
        if (a === 'srcauth') { srcAuthSheet(v); return; }
        if (a === 'substoggle') { SUBP.on = !SUBP.on; subsSavePrefs(); render(); return; }
        if (a === 'subsmon') { monSheet(); return; }
        if (a === 'magnet') { magnetSheet(); return; }
        if (a === 'ed2ksheet') { ed2kSheet(); return; }
        if (a === 'dlsheet') { dlSheet(); return; }
        if (a === 'dlqueue') { dlQueueSheet(); return; }
        if (a === 'subsapi') {
          sheet('听译服务地址',
            '<div class="note">电脑上跑的 <b>subs-server.py</b> 地址。手机和电脑在同一个局域网时用 192.168.x.x。</div>' +
            '<div class="lf"><label for="sapiIn">服务地址</label>' +
            '<input id="sapiIn" type="text" autocapitalize="off" autocorrect="off" spellcheck="false" value="' + esc(subsBase()) + '"></div>' +
            '<div class="note" style="margin-top:-4px">默认留空＝自动跟页面地址走；填了自己写的地址就一直用它。</div>' +
            '<div class="sheet-buttons"><button id="sapiCancel">取消</button>' +
            '<button class="primary" id="sapiOk">保存</button></div>');
          $('#sapiCancel').onclick = closeSheet;
          $('#sapiOk').onclick = function () {
            var v = $('#sapiIn').value.trim().replace(/\/+$/, '');
            if (v && !/^https?:\/\//.test(v)) { toast('要写完整地址，比如 http://192.168.1.10:5008/subs'); return; }
            if (v === _autoSubsApi) v = '';                 // 与自动值相同就存成「自动」
            SUBP.api = v; subsSavePrefs(); closeSheet(); toast('已保存：' + v); render();
          };
          return;
        }
        if (a === 'refresh') { toast('已刷新'); setTimeout(reload, 250); return; }
        if (a === 'root') { location.href = ROOT; return; }
        if (a === 'helpx') { window.open(ROOT + encodeURIComponent('说明书.html'), '_blank'); return; }
        if (a === 'clearpos') {
          var n = posCount();
          sheet('清空播放记录', '<div class="note">要清掉 <b>' + n + '</b> 个文件的播放进度吗？<br>' +
            '清单里的「已看 12:30」标记会一起消失，视频本身不动。</div>' +
            '<div class="sheet-buttons"><button id="cpCancel">取消</button>' +
            '<button class="primary" id="cpOk" style="background:#c0392b;border-color:#c0392b">清空</button></div>');
          $('#cpCancel').onclick = closeSheet;
          $('#cpOk').onclick = function () { clearPos(); closeSheet(); toast('已清空播放记录'); render(); };
          return;
        }
        return;
      }
      var mb = e.target.closest('#moreBtn');
      if (mb) { LIMIT += 500; render(); return; }
      var kv = e.target.closest('.kv[data-act]');
      if (kv) {
        var a = kv.dataset.act;
        if (a === 'copy') copyText(kv.dataset.val || '');
        if (a === 'mode') { ST.mode = ST.mode === 'grid' ? 'list' : 'grid'; saveState(); render(); }
        if (a === 'auth') authSheet();
        if (a === 'help') helpText();
        return;
      }
      var m = e.target.closest('[data-more]');
      if (m) { e.stopPropagation(); itemSheet(CUR[+m.dataset.more]); return; }
      var r = e.target.closest('[data-i]');
      if (!r) return;
      var it = CUR[+r.dataset.i];
      if (!it) return;
      if (it.isRemote && it.isDir) {          // 网盘里的文件夹：进下一层
        loadDav(it.davPath);
        window.scrollTo({ top: 0, behavior: SMOOTH });
        return;
      }
      // 点一下文件就直接打开（图片进全屏查看器，其他类型新标签打开）；更多功能走右边的 ···
      Viewer.openItem(it);
    });

    el.fab.addEventListener('click', addSheet);
    function mkdirSheet() {
      if (!canWrite()) { toast('登录后才能新建文件夹'); srcAuthSheet((activeSrc() || {}).id); return; }
      sheet('新建文件夹',
        '<label class="field">文件夹名称</label><input id="mkName" placeholder="例如：照片备份" maxlength="100">' +
        '<div class="sheet-buttons"><button id="mkCancel">取消</button><button class="primary" id="mkOk">创建</button></div>');
      $('#mkCancel').onclick = closeSheet;
      $('#mkOk').onclick = function () {
        var n = ($('#mkName').value || '').trim();
        if (!n) { toast('请输入名称'); return; }
        if (ITEMS.some(function (x) { return x.name === n; })) { toast('已存在同名项目'); return; }
        mkdir(n);
      };
      setTimeout(function () { var i = $('#mkName'); if (i) i.focus(); }, 60);
    }
    el.avatar.addEventListener('click', function () { srcAuthSheet((activeSrc() || {}).id || 'nas'); });

    el.sheetContent.addEventListener('click', function (e) {
      var mgt = e.target.closest('[data-mgt]');
      if (mgt) {
        MAG.target = mgt.dataset.mgt;
        try { localStorage.setItem('mfm_mg_target', MAG.target); } catch (e2) { }
        mgDrawChips(); mgDrawWhere(); return;
      }
      var mgb = e.target.closest('[data-mg]');
      if (mgb) { magnetAct(mgb.dataset.mg, mgb.dataset.gid || '', mgb.dataset.target || 'nas'); return; }
      var edkb = e.target.closest('[data-edk]');
      if (edkb) { ed2kAct(edkb.dataset.edk, edkb.dataset.hash || ''); return; }
      var b = e.target.closest('[data-act]');
      if (!b) return;
      var act = b.dataset.act;
      if (act === 'cancel') { closeSheet(); return; }
      if (act === 'srclogin') { closeSheet(); srcAuthSheet((activeSrc() || {}).id); return; }
      if (act === 'olgo') {
        var u = ($('#olUrl') ? ($('#olUrl').value || '') : '').trim();
        var n = ($('#olName') ? ($('#olName').value || '') : '').trim();
        if (!/^https?:\/\//i.test(u)) { toast('请输入 http/https 开头的链接'); return; }
        closeSheet();
        playOnline(u, n);
        return;
      }
      if (act === 'themeset') {
        var tid = b.dataset.val || '';
        applyTheme(tid);
        closeSheet();
        render();
        toast(tid ? '已换成「' + themeName(tid) + '」' : '已换成「蓝色」');
        return;
      }
      if (act === 'help-html') { window.open(ROOT + encodeURIComponent('说明书.html'), '_blank'); closeSheet(); return; }
      if (act === 'help') { helpText(); return; }
      if (act === 'upload') { closeSheet(); pickFiles(); return; }
      if (act === 'magnet') { closeSheet(); magnetSheet(); return; }
      if (act === 'ed2ksheet') { closeSheet(); ed2kSheet(); return; }
      if (act === 'dlsheet') { closeSheet(); dlSheet(); return; }
      if (act === 'dlqueue') { closeSheet(); dlQueueSheet(); return; }
      if (act === 'mkdir') { closeSheet(); mkdirSheet(); return; }
      if (act === 'refresh') { closeSheet(); toast('已刷新'); setTimeout(reload, 250); return; }
      if (act === 'root') { closeSheet(); location.href = ROOT; return; }
      if (act === 'login') { closeSheet(); srcAuthSheet((activeSrc() || {}).id || 'nas'); return; }
      if (act === 'logout') {
        closeSheet();
        var sid = (activeSrc() || {}).id || 'nas';
        setSrcAuth(sid, '');
        toast('已退出，恢复只读');
        refreshAfterAuth(sid);
        return;
      }
      if (act === 'auth') { closeSheet(); authSheet(); return; }
      if (act === 'mode-list') { ST.mode = 'list'; saveState(); closeSheet(); render(); return; }
      if (act === 'mode-grid') { ST.mode = 'grid'; saveState(); closeSheet(); render(); return; }
      if (act.indexOf('sort-') === 0) {
        var k = act.slice(5);
        if (ST.sort === k) ST.order = ST.order === 'asc' ? 'desc' : 'asc';
        else { ST.sort = k; ST.order = (k === 'name') ? 'asc' : 'desc'; }
        LIMIT = 500;                        // 排序变了，从第一屏重新开始
        saveState(); closeSheet(); render(); return;
      }
      var i = curItem;
      if (!i) return;
      if (act === 'open') { closeSheet(); Viewer.openItem(i); return; }
      if (act === 'play') { closeSheet(); Player.openItem(i); return; }
      if (act === 'fav') {
        var fpv = favPathOf(i);
        var added = favToggle(ST.src, fpv, i.name);
        closeSheet();
        toast(added ? '已收藏「' + i.name + '」到首页' : '已取消收藏「' + i.name + '」');
        try { renderSources(); } catch (e) { }
        return;
      }
      if (act === 'subsadd') { closeSheet(); subsEnqueue(i); return; }
      if (act === 'dl') { closeSheet(); downloadFile(i.url, i.name, i.size); return; }
      if (act === 'link') { copyText(i.url); closeSheet(); return; }
      if (act === 'rename') {
        sheet('重命名', '<label class="field">新名称</label><input id="rnName" value="' + esc(i.name) + '" maxlength="120">' +
          '<div class="sheet-buttons"><button id="rnCancel">取消</button><button class="primary" id="rnOk">保存</button></div>');
        $('#rnCancel').onclick = closeSheet;
        $('#rnOk').onclick = function () {
          var n = ($('#rnName').value || '').trim();
          if (!n) { toast('名称不能为空'); return; }
          if (n === i.name) { closeSheet(); return; }
          renameItem(i, n);
        };
        return;
      }
      if (act === 'del') {
        sheet('确认删除', '<div class="note">要删除 <b>' + esc(i.name) + '</b> 吗？<br>删除后无法恢复。</div>' +
          '<div class="sheet-buttons"><button id="delCancel">取消</button>' +
          '<button class="primary" id="delOk" style="background:#c0392b;border-color:#c0392b">删除</button></div>');
        $('#delCancel').onclick = closeSheet;
        $('#delOk').onclick = function () { deleteItem(i); };
        return;
      }
    });

    el.sheetBack.addEventListener('click', function (e) { if (e.target === el.sheetBack) closeSheet(); });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeSheet(); });

    document.addEventListener('change', function (e) {
      if (e.target && e.target.id === 'file' && e.target.files && e.target.files.length) {
        uploadFiles(e.target.files);
      }
    });

    layout();
    window.addEventListener('resize', layout);
  }

  function layout() {
    var wide = window.innerWidth >= 700;
    var topline = $('.topline', el.app);
    var trow = $('.title-row', el.app), sortBtn = $('#sortBtn', el.app);
    if (wide) {
      if (el.nav.parentNode !== topline) topline.insertBefore(el.nav, el.avatar);
      if (el.searchFab && trow && el.searchFab.parentNode !== trow) trow.insertBefore(el.searchFab, sortBtn);
    } else {
      if (el.nav.parentNode !== el.app) el.app.appendChild(el.nav);
      if (el.searchFab && el.searchFab.parentNode !== el.app) el.app.insertBefore(el.searchFab, el.searchBar);
    }
  }

  /* ---------------- 启动 ---------------- */
  buildShell();
  bind();
  render();
  // dufs 原生界面藏在暗处，但它已经把当前目录整张表建好了（1000 个文件≈1.6 万个节点）。
  // 我们用自己的列表，这些行永远不会被显示或点到 —— 直接丢掉，省手机上的样式/布局开销。
  // 只清 tbody 的行：.head 里的登录/退出/上传控件和 <template id="index-data"> 必须留着。
  try {
    var ntb = document.querySelector('.paths-table tbody');
    if (ntb && ntb.children.length) ntb.innerHTML = '';
  } catch (e) { }
  if (AUTH) refreshListing();          // 这台手机上存过凭据：重取目录，把登录后的权限和用户名带出来
  // 整个共享库的统计（几百字节）；拿到后首页统计卡和分类浏览换成全库数据
  fetch(ASSETS + 'sources.json', { cache: 'no-store' })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (d) {
      SOURCES = d && d.sources ? d : { sources: [] };
      // 恢复到上次用的来源（顶部记住上次用的那个）
      var last = null;
      try { last = localStorage.getItem('mfm_src'); } catch (e) { }
      var s = last ? srcById(last) : null;
      if (!s && SOURCES.sources.length) s = SOURCES.sources[0];
      ST.src = s ? s.id : null;
      if (isRemote()) loadDav('', true); else render();
    })
    .catch(function () {
      SOURCES = { sources: [] };
      render();
    });
  // 缩略图探测：拿当前目录第一张图片的缩略图试一下（比探测目录可靠，dufs 对隐藏目录的 HEAD 会返回 200）
  var firstImg = null;
  for (var i = 0; i < ITEMS.length; i++) if (ITEMS[i].kind === 'image') { firstImg = ITEMS[i]; break; }
  if (firstImg) {
    fetch(thumbUrl(firstImg.url), { method: 'HEAD' })
      .then(function (r) { THUMBS = r.ok; render(); })
      .catch(function () { });
  }
  document.title = curDirName() + ' · 文件管理器';
})();
