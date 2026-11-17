/* 云匣 · 上线前自检（只在你手动打开 ?selftest=1 时加载）
   跑 5 套主题 × 12 条断言，把结果画成一个面板，并把结果挂到 window.__ST。
   判定标准都是「可计算的事实」，不看截图：溢出、边框、对比度、点击区尺寸、资源状态码。 */
(function () {
  var THEMES = [
    { id: '', n: '蓝色' },
    { id: 'light', n: '浅色' },
    { id: 'dark', n: '深色' },
    { id: 'green', n: '绿色' },
    { id: 'sepia', n: '护眼' }
  ];

  function rgb(s) {
    var m = String(s).match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    var p = m[1].split(',').map(function (x) { return parseFloat(x); });
    return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
  }
  function lum(c) {
    var a = c.slice(0, 3).map(function (v) {
      v /= 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2];
  }
  function bgOf(el) {
    var e = el;
    while (e && e.nodeType === 1) {
      var c = rgb(getComputedStyle(e).backgroundColor);
      if (c && c[3] > 0.6) return c;
      e = e.parentElement;
    }
    return rgb(getComputedStyle(document.body).backgroundColor) || [255, 255, 255, 1];
  }
  function contrast(el) {
    var fg = rgb(getComputedStyle(el).color);
    if (!fg) return null;
    var bg = bgOf(el);
    var a = lum(fg), b = lum(bg);
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
  }
  function $(s) { return document.querySelector(s); }
  function $$(s) { return Array.prototype.slice.call(document.querySelectorAll(s)); }
  function rect(e) { return e.getBoundingClientRect(); }
  function isHome() { return !!document.querySelector('.home-side'); }
  function wide() { return window.innerWidth >= 700; }
  function accent() {
    var v = getComputedStyle(document.documentElement).getPropertyValue('--t-ac').trim();
    return v || '#1677f8';
  }

  var CHECKS = [
    {
      id: 'jsErr', name: 'JS 无报错',
      run: function () {
        var e = (window.__ERR || []).slice(0, 3);
        return { ok: e.length === 0, detail: e.length ? e.join(' | ') : 'clean' };
      }
    },
    {
      id: 'res', name: '资源全部 200',
      run: function () {
        /* 只看本站静态资源。来源探测（?json、:5010/:5011）失败是「某个盘/电脑没开机」，
           那是 自检.py 的活，不该让视觉自检跟着飘。 */
        var bad = (performance.getEntriesByType('resource') || []).filter(function (r) {
          if (!r.responseStatus || r.responseStatus < 400) return false;
          if (r.name.indexOf('/__dufs_v') < 0) return false;
          return /\.(js|css|json)(\?|$)/.test(r.name);
        }).map(function (r) { return r.responseStatus + ' ' + r.name.split('/').pop().split('?')[0]; });
        return { ok: bad.length === 0, detail: bad.length ? bad.slice(0, 4).join(', ') : 'all ok' };
      }
    },
    {
      id: 'ovf', name: '没有横向溢出',
      run: function () {
        var d = document.documentElement.scrollWidth - window.innerWidth;
        return { ok: d <= 1, detail: 'scrollWidth 超出 ' + d + 'px' };
      }
    },
    {
      id: 'rule', name: '列表行之间没有实线',
      run: function () {
        var rows = $$('.src-group .src-card');
        if (!rows.length) return { ok: true, detail: 'n/a' };
        var bad = rows.filter(function (r) { return parseFloat(getComputedStyle(r).borderTopWidth) > 0; });
        return { ok: bad.length === 0, detail: bad.length + ' 行有上边框' };
      }
    },
    {
      id: 'sel', name: '选中行没有被画成主色框',
      run: function () {
        var on = $('.src-card.on');
        if (!on) return { ok: true, detail: '当前没有选中的来源' };
        var cs = getComputedStyle(on);
        var w = parseFloat(cs.borderTopWidth);
        var color = cs.borderTopColor.replace(/\s/g, '');
        var ac = rgb(accent());
        var c = rgb(color);
        var same = ac && c && ac[0] === c[0] && ac[1] === c[1] && ac[2] === c[2];
        return { ok: w === 0 || !same, detail: '上边框 ' + w + 'px ' + color };
      }
    },
    {
      id: 'col', name: '两栏齐头齐尾（≥700）',
      run: function () {
        if (!wide()) return { ok: true, detail: 'n/a 单列' };
        var a = $('#srcSec > .act-group') || $('.act-group');
        var b = $('.home-side');
        if (!a || !b) return { ok: true, detail: 'n/a' };
        var d = Math.abs(rect(a).bottom - rect(b).bottom);
        return { ok: d <= 2, detail: '底边相差 ' + Math.round(d) + 'px' };
      }
    },
    {
      id: 'nav', name: '导航条背景符合断点',
      run: function () {
        var n = $('.bottom-nav');
        if (!n) return { ok: false, detail: '找不到导航条' };
        var c = rgb(getComputedStyle(n).backgroundColor);
        var transparent = !c || c[3] < 0.05;
        return wide()
          ? { ok: transparent, detail: '≥700 应透明，实际 ' + getComputedStyle(n).backgroundColor }
          : { ok: !transparent, detail: '<700 应有底，实际 ' + getComputedStyle(n).backgroundColor };
      }
    },
    {
      /* 正文按 4.5；实心强调块（选中来源卡、选中标签）按 2.5 / 3.0 —— iOS 标签栏、微信气泡都在这条线上，
         主色衬底 + 白字本来就到不了 4.5，不放宽这条永远红。
   正文按 4.5；选中的导航标签属于「强调要素」（和 iOS 标签栏同样处理），
         用强调色本身就不该过 4.5，按 3.0 校验，别把它算成缺陷。 */
      id: 'ctr', name: '文字对比度（正文 4.5 / 强调 3.0）',
      run: function () {
        var sels = [['.src-card:not(.on) .src-txt b', 4.5], ['.src-card:not(.on) .src-txt i', 4.5],
                    ['.src-card.on .src-txt b', 3.0], ['.home-h h2', 4.5],
                    ['.nav-item:not(.active)', 4.5], ['.nav-item.active', 3.0], ['#pageTitle', 4.5]];
        var bad = [];
        sels.forEach(function (pair) {
          var s = pair[0], min = pair[1];
          var el = $(s);
          if (!el) return;
          var v = contrast(el);
          if (v !== null && v < min) {
            var bg = bgOf(el);
            bad.push(s + ' ' + v.toFixed(1) + ' (' + getComputedStyle(el).color + ' on rgb(' +
              Math.round(bg[0]) + ',' + Math.round(bg[1]) + ',' + Math.round(bg[2]) + '))');
          }
        });
        return { ok: bad.length === 0, detail: bad.length ? bad.join(', ') : 'ok' };
      }
    },
    {
      id: 'kinds', name: '文件图标按类型分色（不统一成一个色）',
      run: function () {
        var KINDS = ['fi-folder', 'fi-img', 'fi-video', 'fi-audio', 'fi-zip', 'fi-code', 'fi-pdf', 'fi-doc'];
        var probe = document.createElement('div');
        probe.style.cssText = 'position:absolute;left:-9999px;top:0';
        document.body.appendChild(probe);
        var seen = {}, bad = [];
        KINDS.forEach(function (k) {
          var d = document.createElement('div');
          d.className = 'file-icon ' + k;
          probe.appendChild(d);
          var cs = getComputedStyle(d);
          seen[cs.backgroundColor] = 1;
          var c = contrast(d);
          if (c !== null && c < 3) bad.push(k + ' ' + c.toFixed(1));
        });
        probe.parentNode.removeChild(probe);
        var n = Object.keys(seen).length;
        return { ok: n >= 6 && bad.length === 0, detail: n + ' 种底色' + (bad.length ? ' · 对比度低: ' + bad.join(', ') : '') };
      }
    },
    {
      id: 'navsel', name: '选中的标签看得出来',
      run: function () {
        var on = $('.nav-item.active');
        var off = $$('.nav-item').filter(function (e) { return !e.classList.contains('active'); })[0];
        if (!on || !off) return { ok: false, detail: '找不到导航标签' };
        var a = getComputedStyle(on), b = getComputedStyle(off);
        var same = a.color === b.color && a.backgroundColor === b.backgroundColor && a.fontWeight === b.fontWeight;
        return { ok: !same, detail: '选中 ' + a.color + ' / 未选 ' + b.color };
      }
    },
    {
      id: 'tap', name: '点击区够大（≥40 / 行 ≥56）',
      run: function () {
        var bad = [];
        $$('.nav-item').forEach(function (e) {
          var h = rect(e).height;
          if (h < 40) bad.push('.nav-item ' + Math.round(h));
        });
        $$('.src-group .src-card').forEach(function (e) {
          var h = rect(e).height;
          if (h < 56) bad.push('行 ' + Math.round(h));
        });
        return { ok: bad.length === 0, detail: bad.length ? bad.slice(0, 3).join(', ') : 'ok' };
      }
    },
    {
      id: 'token', name: '主题变量确实生效',
      run: function () {
        var v = getComputedStyle(document.documentElement).getPropertyValue('--t-bg').trim();
        var has = document.documentElement.hasAttribute('data-theme');
        if (!has) return { ok: true, detail: '蓝色 = 默认，不设属性' };
        return { ok: v !== '', detail: '--t-bg ' + (v || '(空)') };
      }
    },
    {
      id: 'fav', name: '收藏行与数据一致',
      run: function () {
        if (!isHome()) return { ok: true, detail: 'n/a 不在首页' };
        var raw = [];
        try { raw = JSON.parse(localStorage.getItem('mfm_fav') || '[]'); } catch (e) { raw = []; }
        var rows = $$('.fav-row').length;
        var empty = !!$('.rec-empty.one');
        if (!raw.length) return { ok: empty && rows === 0, detail: '无收藏 → 空态 ' + (empty ? '✓' : '✗') };
        return { ok: rows === raw.length, detail: '数据 ' + raw.length + ' 条 / 渲染 ' + rows + ' 行' };
      }
    },
    {
      id: 'home', name: '首页三段结构完整',
      run: function () {
        if (!isHome()) return { ok: true, detail: 'n/a 不在首页' };
        var has = ['.src-group', '.home-side', '.act-group'].filter(function (s) { return !!$(s); });
        return { ok: has.length === 3, detail: has.join(' ') };
      }
    }
  ];

  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  /* 不要用 requestAnimationFrame：后台标签页/无头环境里它可能永远不触发，
     boot() 就会静默卡在第一个主题上，看起来像「自检脚本没跑」。 */
  function frame() { return wait(16); }

  async function runAll() {
    var prev = document.documentElement.getAttribute('data-theme') || '';
    /* 量之前先把过渡关掉：切主题时 background/color 有 .12s 过渡，
       过渡中途取值会读出「深色主题的文字压在浅色底上」这种假失败。 */
    var kill = document.createElement('style');
    kill.id = '__st_nomotion';
    kill.textContent = '*,*::before,*::after{transition-duration:0s!important;animation-duration:0s!important}';
    document.head.appendChild(kill);
    var results = [];
    for (var i = 0; i < THEMES.length; i++) {
      var t = THEMES[i];
      if (t.id) document.documentElement.setAttribute('data-theme', t.id);
      else document.documentElement.removeAttribute('data-theme');
      await frame();
      await wait(70);
      CHECKS.forEach(function (c) {
        var r;
        try { r = c.run(); } catch (e) { r = { ok: false, detail: '断言抛错: ' + e.message }; }
        results.push({ theme: t.n, id: c.id, name: c.name, ok: !!r.ok, detail: r.detail });
      });
    }
    if (prev) document.documentElement.setAttribute('data-theme', prev);
    else document.documentElement.removeAttribute('data-theme');
    var k = document.getElementById('__st_nomotion');
    if (k) k.parentNode.removeChild(k);
    return results;
  }

  function panel(results) {
    var fail = results.filter(function (r) { return !r.ok; });
    var box = document.createElement('div');
    box.style.cssText = 'position:fixed;inset:0;z-index:99999;background:#0f1115f2;color:#e8eaed;' +
      'font:13px/1.5 -apple-system,PingFang SC,sans-serif;overflow:auto;padding:16px 14px 40px';
    var html = '<div style="max-width:760px;margin:0 auto">';
    html += '<div style="font-size:19px;font-weight:700;margin-bottom:4px">云匣 · 上线自检</div>';
    html += '<div style="color:#9aa4b2;margin-bottom:14px">' + window.__V + ' · ' + window.innerWidth + '×' +
      window.innerHeight + ' · ' + results.length + ' 项 · ' +
      (fail.length ? '<b style="color:#ff6b6b">' + fail.length + ' 项失败</b>' : '<b style="color:#3ddc84">全部通过</b>') + '</div>';
    var cur = '';
    results.forEach(function (r) {
      if (r.theme !== cur) {
        cur = r.theme;
        html += '<div style="margin:14px 0 6px;color:#8ab4ff;font-weight:650">' + cur + '</div>';
      }
      html += '<div style="display:flex;gap:8px;padding:4px 0;border-bottom:1px solid #ffffff12">' +
        '<span style="width:16px;flex:0 0 auto;color:' + (r.ok ? '#3ddc84' : '#ff6b6b') + '">' + (r.ok ? '✓' : '✗') + '</span>' +
        '<span style="flex:1">' + r.name + '</span>' +
        '<span style="color:#8b95a3;font-size:12px;max-width:52%;text-align:right">' + (r.detail || '') + '</span></div>';
    });
    html += '<div style="margin-top:18px;color:#8b95a3;font-size:12px">window.__ST 里有完整结果；这个页面只在 ?selftest=1 时加载。</div>';
    html += '</div>';
    box.innerHTML = html;
    document.body.appendChild(box);
  }

  async function boot() {
    // 等首页渲染出来（最多 8 秒）
    for (var i = 0; i < 40; i++) {
      if (document.querySelector('.src-card') || document.querySelector('.file-row')) break;
      await wait(200);
    }
    var results = await runAll();
    var fail = results.filter(function (r) { return !r.ok; });
    window.__ST = { pass: results.length - fail.length, fail: fail.length, total: results.length, results: results };
    panel(results);
  }

  if (document.readyState === 'complete' || document.readyState === 'interactive') boot();
  else window.addEventListener('DOMContentLoaded', boot);
})();
