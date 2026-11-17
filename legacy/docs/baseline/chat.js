/* 云匣 · 对话（替换原来的「最近」页）
   纯前端，直接调前置代理下的 /hermes/api*，和独立版客户端同一套后端。
   依赖：app.js 在 render() 里调用 MFM_CHAT.mount()/hide()。 */
(function () {
  'use strict';

  var API = '/hermes/api/';
  var STORE = 'mfm.chat.v1';
  var root = null, els = null, built = false;
  var state = { messages: [], prevId: null, attachments: [], since: 0 };
  var busy = false, abortCtl = null;

  /* ---------- 图标：Hugeicons Stroke Rounded 风格，与云匣其余图标同源 ---------- */
  var SVG_SEND = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 19.2V5.3"/><path d="M5.75 11.25 12 5l6.25 6.25"/></svg>';
  var SVG_STOP = '<svg viewBox="0 0 24 24" width="17" height="17" aria-hidden="true"><rect x="7" y="7" width="10" height="10" rx="2.6" fill="currentColor"/></svg>';
  var SVG_ATTACH = '<svg viewBox="0 0 24 24" width="21" height="21" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20.2 11.4 11 20.6a5.6 5.6 0 0 1-7.92-7.92l9.2-9.2a3.73 3.73 0 0 1 5.28 5.28l-9.2 9.2a1.87 1.87 0 0 1-2.64-2.64l8.28-8.28"/></svg>';

  /* ---------- 样式 ---------- */
  var CSS = [
    '.cx{position:fixed;left:0;width:100%;display:flex;flex-direction:column;z-index:8;',
    'background:linear-gradient(180deg,#f7f9fd,#f7f9fd);overflow:hidden}',
    '.cx-log{flex:1 1 auto;overflow-y:auto;-webkit-overflow-scrolling:touch;overscroll-behavior:contain;padding:6px 16px 10px;width:100%;max-width:800px;margin:0 auto}',
    '.cx-intro{color:var(--t-ink3,#9aa8ba);text-align:center;margin-top:14vh;font-size:13px;line-height:2.1}',
    '.cx-intro b{display:block;color:var(--t-ink,#26364a);font-size:16px;font-weight:750;margin-bottom:7px}',
    '.cx-msg{display:flex;flex-direction:column;margin-bottom:13px;max-width:100%}',
    '.cx-msg.user{align-items:flex-end}',
    '.cx-b{max-width:min(84%,620px);padding:10px 13px;border-radius:16px;font-size:14.5px;line-height:1.65;white-space:pre-wrap;word-break:break-word}',
    '.cx-msg.user .cx-b{align-self:flex-end;background:var(--t-ac,#1677f8);color:#fff;border-bottom-right-radius:6px}',
    '.cx-msg.ai .cx-b{align-self:flex-start;background:#fff;color:var(--t-ink,#26364a);border:1px solid var(--t-line,#e9eef5);border-bottom-left-radius:6px}',
    '.cx-msg.ai .cx-b:empty{display:none}',
    '.cx-msg .cx-b code{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px;background:#eef2f8;color:#34455c;padding:1px 5px;border-radius:4px}',
    '.cx-msg .cx-b pre{background:#1d2b3d;color:#dfe9f6;padding:10px 12px;border-radius:9px;overflow-x:auto;margin:7px 0;font-size:12px;line-height:1.6}',
    '.cx-msg .cx-b pre code{background:none;color:inherit;padding:0}',
    /* 实时进度：和终端里一样，一步一行，跑着的时候是跳动的点 */
    '.cx-think{align-self:flex-start;max-width:min(84%,620px);font-size:11.5px;line-height:1.6;color:#8398b0;margin:0 0 5px 2px;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}',
    '.cx-steps{display:flex;flex-direction:column;gap:4px;margin-bottom:6px;align-self:stretch;max-width:min(94%,680px)}',
    '.cx-step{background:#f5f8fd;border:1px solid #e6eefb;border-radius:9px;padding:5px 9px;font-size:11.5px;line-height:1.55;color:#4a5f7a}',
    '.cx-step.run{background:#f1f7ff;border-color:#cfe0f8}',
    '.cx-step.bad{background:#fff5f5;border-color:#fbdcdd}',
    '.cx-sd{display:flex;align-items:center;gap:6px;min-width:0}',
    '.cx-sn{flex:0 0 auto;font-weight:700;color:#26364a;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11.5px}',
    '.cx-sa{flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#5d7391;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px}',
    '.cx-st{flex:0 0 auto;color:#9aa8ba;font-size:10.5px;font-variant-numeric:tabular-nums}',
    '.cx-dot{flex:0 0 auto;width:6px;height:6px;border-radius:50%;background:#1677f8;animation:cxp .9s ease-in-out infinite}',
    '@keyframes cxp{0%,100%{opacity:.25;transform:scale(.75)}50%{opacity:1;transform:scale(1)}}',
    '.cx-ok{flex:0 0 auto;color:#2f9e58;font-size:11px;font-weight:700}',
    '.cx-step.bad .cx-ok{color:#e5484d}',
    '.cx-so{margin-top:3px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px;line-height:1.5;color:#6d829c;white-space:pre-wrap;word-break:break-all;max-height:3.2em;overflow:hidden}',
    '.cx-step.open .cx-so{max-height:none}',
    '.cx-think{cursor:pointer}'
    ,'.cx-think.open{display:block;-webkit-line-clamp:unset;overflow:visible}'
    ,'.cx-think-more{align-self:flex-start;margin:0 0 7px 2px;font-size:11px;color:#8aa4c4;background:none;border:0;padding:0;cursor:pointer;text-decoration:underline}'
    ,'.cx-typing{padding:12px 15px!important}'
    ,'.cx-dots{display:inline-flex;gap:6px;align-items:center;height:11px}'
    ,'.cx-dots i{width:6px;height:6px;border-radius:50%;background:#c2cfdf;animation:cxb 1.2s infinite ease-in-out}'
    ,'.cx-dots i:nth-child(2){animation-delay:.16s}'
    ,'.cx-dots i:nth-child(3){animation-delay:.32s}'
    ,'@keyframes cxb{0%,80%,100%{opacity:.3;transform:translateY(0)}40%{opacity:1;transform:translateY(-3px)}}',
    '.cx-wait{align-self:flex-start;font-size:12px;color:#9aa8ba;padding:1px 0 2px}',
    /* 需要你点头才能跑的操作 */
    '.cx-ap{align-self:stretch;max-width:min(94%,680px);background:#fffdf5;border:1px solid #f0d9a8;border-radius:12px;padding:8px 10px;margin:2px 0 6px}',
    '.cx-ap-h{font-size:12px;color:#8a6a2f;font-weight:650;margin-bottom:5px;line-height:1.5}',
    '.cx-ap-c{margin:0 0 7px;background:#1d2b3d;color:#dfe9f6;padding:7px 9px;border-radius:8px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px;line-height:1.5;white-space:pre-wrap;word-break:break-all;max-height:7em;overflow:auto}',
    '.cx-ap-b{display:flex;gap:6px;flex-wrap:wrap}',
    '.cx-ap-b button{border:1px solid #e3cf9f;background:#fff;color:#7a5c1f;border-radius:8px;padding:5px 10px;font-size:11.5px;font-weight:600}',
    '.cx-ap-b button.ok{background:#2f9e58;border-color:#2f9e58;color:#fff}',
    '.cx-ap-b button.no{background:#e5484d;border-color:#e5484d;color:#fff}',
    '.cx-ap-d{font-size:11.5px;color:#7a5c1f}',
    '.cx-ap-d.err{color:#c0392b}',
    '.cx-msg.sys{align-items:center}',
    '.cx-dl{display:inline-flex;align-items:center;gap:4px;background:#eef4ff;border:1px solid #cfe0f8;border-radius:8px;padding:2px 8px;margin:1px 2px;color:#1677f8;font-size:12.5px;text-decoration:none;word-break:break-all}',
    '.cx-sys{align-self:center;max-width:88%;background:#eef2f8;color:#5d7391;border-radius:10px;padding:6px 10px;font-size:11.5px;line-height:1.6;white-space:pre-wrap;word-break:break-word;text-align:left}',
    '.cx-msg .cx-imgs{align-self:flex-start}',
    '.cx-imgs{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:6px}',
    '.cx-imgs img{width:104px;height:104px;object-fit:cover;border-radius:11px;border:1px solid var(--t-line,#e9eef5)}',
    '.cx-file{font-size:11.5px;color:var(--t-ink2,#5d7391);background:#fff;border:1px solid var(--t-line,#e9eef5);border-radius:8px;padding:4px 8px;margin-top:5px}',
    'a.cx-file{display:inline-block;text-decoration:none;color:var(--t-ac,#1677f8);border-color:#cfe0fb;background:#f4f8ff}',
    'a.cx-file b{font-weight:600}',
    '.cx-a{color:#1677f8;text-decoration:none;word-break:break-all}',
    '.cx-a:active{opacity:.65}',
    '.cx-msg.user .cx-a{color:#fff;text-decoration:underline}',
    '.cx-meta{font-size:10.5px;color:var(--t-ink3,#9aa8ba);margin-top:5px}',
    '.cx-bar{flex:0 0 auto;display:flex;align-items:flex-end;gap:8px;padding:9px 14px 10px;background:#fff;border-top:1px solid var(--t-line,#e9eef5)}',
    '.cx-btn{flex:0 0 auto;width:36px;height:36px;border-radius:19px;border:1px solid var(--t-line,#e9eef5);background:#fff;color:var(--t-ink2,#5d7391);font-size:19px;line-height:1;display:grid;place-items:center;padding:0}',
    '.cx-btn.go{background:var(--t-ac,#1677f8);border-color:var(--t-ac,#1677f8);color:#fff;font-size:16px}',
    '.cx-btn.stop{background:#e5484d;border-color:#e5484d;color:#fff}',
    '.cx-btn:disabled{opacity:.45}',
    '.cx-in{flex:1 1 auto;border:1px solid var(--t-line,#e9eef5);border-radius:18px;background:#f7f9fd;padding:8px 13px;font:inherit;font-size:16px;color:var(--t-ink,#26364a);resize:none;max-height:104px;min-height:36px;outline:none;line-height:1.5}',
    '.cx-in:focus{border-color:#cfe0f8;background:#fff}',
    'html.cx-kb,html.cx-kb body{overflow:hidden;height:100%}',
    '.cx-strip{display:flex;gap:7px;flex-wrap:wrap;padding:0 14px}',
    '.cx-strip:empty{display:none}',
    '.cx-chip{display:flex;align-items:center;gap:5px;background:#eef4ff;border-radius:9px;padding:3px 7px;font-size:11.5px;color:var(--t-ink2,#5d7391);max-width:170px;margin-top:8px}',
    '.cx-chip img{width:28px;height:28px;border-radius:5px;object-fit:cover}',
    '.cx-chip span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}',
    '.cx-chip button{border:0;background:transparent;color:#93a3b8;font-size:14px;padding:0 1px}',
    '@media(min-width:521px){.cx{border-radius:0 0 26px 26px}}',
    '.cx-lock{flex:0 0 auto;display:none;gap:8px;align-items:center;padding:9px 14px;background:#fff7e8;border-bottom:1px solid #f2e2c4;font-size:12px;color:#8a6a2f}',
    '.cx-lock.on{display:flex}',
    '.cx-lock input{flex:1 1 auto;min-width:0;border:1px solid #e6d6b6;border-radius:9px;padding:6px 9px;font-size:13px;background:#fff;outline:none}',
    '.cx-lock button{border:0;background:var(--t-ac,#1677f8);color:#fff;border-radius:9px;padding:6px 12px;font-size:12px;font-weight:600}',
    /* ---------- 视觉精修：iOS 消息风，白底 + 柔和卡片（放最后，覆盖上面） ---------- */
    ,'.cx{background:var(--t-bg2,#F5F6F8)}'
    ,'.cx-log{padding:12px 14px 18px;max-width:760px;scrollbar-width:none;-ms-overflow-style:none}'
    ,'.cx-log::-webkit-scrollbar{width:0;height:0;display:none}'
    ,'.cx-intro{margin:9vh auto 0;max-width:320px;background:var(--t-surface,#fff);border:1px solid var(--t-line,#ECEFF3);border-radius:20px;padding:20px 18px;box-shadow:0 2px 10px rgba(16,24,40,.05);line-height:1.9}'
    ,'.cx-intro b{font-size:15.5px;font-weight:700;margin-bottom:8px;letter-spacing:.2px}'
    ,'.cx-msg{margin-bottom:11px}'
    ,'.cx-b{max-width:min(82%,560px);padding:10px 14px;border-radius:20px;font-size:15px;line-height:1.62;letter-spacing:.1px}'
    ,'.cx-msg.user .cx-b{background:var(--t-ac,#0A84FF);border-bottom-right-radius:7px;box-shadow:0 1px 2px rgba(10,132,255,.2)}'
    ,'.cx-msg.ai .cx-b{background:var(--t-surface,#fff);border:1px solid var(--t-line,#ECEFF3);border-bottom-left-radius:7px;box-shadow:0 1px 2px rgba(16,24,40,.045)}'
    ,'.cx-msg .cx-b code{background:var(--t-bg2,#F1F3F7);border-radius:5px;font-size:13px}'
    ,'.cx-msg .cx-b pre{position:relative;border-radius:12px;padding:11px 13px;font-size:12.5px}'
    ,'.cx-meta{font-size:10.5px;color:var(--t-ink3,#78828F);margin:5px 3px 0;letter-spacing:.2px}'
    ,'.cx-think{display:block;font-size:12px;line-height:1.62;color:var(--t-ink2,#6E7683);margin:0 0 6px 2px;padding:7px 11px;background:var(--t-surface,#FFFFFF);border:1px solid var(--t-line,#E9ECF1);border-radius:12px;max-width:min(86%,600px);box-sizing:border-box}'
    ,'.cx-tk{display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden;white-space:pre-wrap;word-break:break-word}'
    ,'.cx-think.open .cx-tk{display:block;-webkit-line-clamp:unset}'
    ,'.cx-think.open{border-color:var(--t-line2,#E2E6EC);color:var(--t-ink2,#6E6E73)}'
    ,'.cx-think-more{font-size:11px;color:var(--t-ink3,#9AA5B5);text-decoration:none;margin:-3px 0 9px 13px;font-weight:500}'
    ,'.cx-steps{gap:5px}'
    ,'.cx-step{border:0;background:var(--t-bg2,#F4F6FA);border-radius:11px;padding:6px 10px}'
    ,'.cx-step.run{background:var(--t-acw,#EDF5FF)}'
    ,'.cx-step.bad{background:#FFF5F5}'
    ,'.cx-sys{background:var(--t-bg2,#EEF1F5);color:var(--t-ink2,#6E6E73);border-radius:20px;padding:6px 12px;font-size:11.5px}'
    ,'.cx-dl{border:0;background:var(--t-acw,#EBF3FF);border-radius:20px;padding:3px 10px;font-weight:500}'
    ,'a.cx-file{border:0;border-radius:20px;padding:6px 11px;background:var(--t-acw,#EBF3FF)}'
    ,'.cx-imgs{gap:7px}'
    ,'.cx-imgs img{width:112px;height:112px;border-radius:14px;border:1px solid var(--t-line,#ECEFF3)}'
    ,'.cx-bar{padding:8px max(12px, calc((100% - 760px) / 2 + 12px)) 10px;background:var(--t-surface,#fff);border-top:1px solid var(--t-line,#EFF1F5);gap:7px}'
    ,'.cx-in{border:0;background:var(--t-bg2,#F2F4F7);border-radius:21px;padding:10px 15px;line-height:22px;min-height:42px;box-sizing:border-box;transition:background .16s,box-shadow .16s}'
    ,'.cx-in:focus{background:var(--t-surface,#fff);border:0;box-shadow:0 0 0 2px rgba(10,132,255,.16)}'
    ,'.cx-in::placeholder{color:var(--t-ink3,#A6AEBC)}'
    ,'.cx-btn{width:42px;height:42px;border:0;background:transparent;color:var(--t-ink2,#6E6E73);border-radius:21px;font-size:20px;line-height:1;transition:transform .12s,background .16s}'
    ,'.cx-btn:active{transform:scale(.93)}'
    ,'.cx-btn{display:inline-flex;align-items:center;justify-content:center;padding:0}'
    ,'.cx-btn svg{display:block}'
    ,'.cx-btn.go svg{transform:translateY(-.5px)}'
    ,'.cx-btn.go{background:var(--t-ac,#0A84FF);width:42px;height:42px;font-size:15px;box-shadow:0 2px 8px rgba(10,132,255,.32)}'
    ,'.cx-btn#cxAdd{color:var(--t-ink3,#8E96A3)}'
    ,'.cx-btn#cxAdd:active{background:var(--t-bg2,#EEF1F5)}'
    ,'.cx-btn.stop{background:#E5484D;box-shadow:0 2px 6px rgba(229,72,77,.3)}'
    ,'.cx-strip{padding:0 max(12px, calc((100% - 760px) / 2 + 12px)) 4px;background:transparent}'
    ,'.cx-chip{border-radius:20px;padding:4px 9px;background:var(--t-bg2,#EEF1F5)}'
    ,'.cx-lock{padding:10px 14px;background:#FFF8E8;border-bottom:1px solid #F3E4C6}',
    ,'.cx-msg .cx-b pre[data-cp]{padding-top:27px}'
    ,'.cx-cp{position:absolute;top:6px;right:6px;border:0;border-radius:6px;background:rgba(255,255,255,.14);color:#cfd9e6;font-size:10.5px;line-height:1;padding:4px 7px;cursor:pointer;font-family:inherit}'
    ,'.cx-cp:active{background:rgba(255,255,255,.26)}'
    ,'.cx-mask{position:absolute;inset:0;background:rgba(16,24,40,.26);z-index:12;display:none}'
    ,'.cx-mask.on{display:block}'
    ,'.cx-sheet{position:absolute;left:12px;right:12px;bottom:14px;z-index:13;display:none;flex-direction:column;gap:7px}'
    ,'.cx-sheet.on{display:flex}'
    ,'.cx-sheet button{border:0;border-radius:15px;background:var(--t-surface,#fff);color:var(--t-ink,#1D1D1F);font-size:16px;font-weight:500;padding:15px 10px;box-shadow:0 4px 18px rgba(16,24,40,.16)}'
    ,'.cx-sheet button.danger{color:#E5484D}'
    ,'.cx-sheet button.cancel{background:var(--t-surface,#fff);color:var(--t-ac,#0A84FF);font-weight:600}'
    ,'.cx-sheet button:active{background:var(--t-bg2,#F2F4F7)}'
    ,'.cx-top{position:absolute;right:15px;width:34px;height:34px;border-radius:50%;background:var(--t-surface,#fff);border:1px solid var(--t-line,#E7EAEF);color:var(--t-ink2,#5B6675);box-shadow:0 3px 12px rgba(16,24,40,.13);display:none;align-items:center;justify-content:center;z-index:9;padding:0}'
    ,'.cx-top.on{display:flex}'
    ,'.cx-top:active{transform:scale(.94)}'
    ,'.cx-day{display:flex;align-items:center;gap:9px;color:#A6AEBC;font-size:10.5px;letter-spacing:.5px;margin:12px 2px 14px}'
    ,'.cx-day:before,.cx-day:after{content:"";flex:1 1 auto;height:1px;background:var(--t-line,#ECEFF3)}',
    '.cx-new{border:0;background:#ffffffd9;backdrop-filter:blur(10px);color:var(--t-ac,#1677f8);font-size:11.5px;font-weight:650;padding:5px 11px;border-radius:11px;box-shadow:0 3px 10px #1677f81f}'
  ].join('');

  /* ---------- 口令（网页对话的 Basic 认证，存在这台设备上） ---------- */
  var AUTH = 'mfm.chat.auth';
  function authB64() { try { return localStorage.getItem(AUTH) || ''; } catch (e) { return ''; } }
  function showLock() { if (els) { els.lock.classList.add('on'); try { els.pass.focus(); } catch (e) { } } }
  function hideLock() { if (els) els.lock.classList.remove('on'); }
  function api(path, opts) {
    opts = opts || {};
    var h = opts.headers || {};
    var a = authB64();
    if (a) h['Authorization'] = 'Basic ' + a;
    opts.headers = h;
    return fetch(API + path.replace(/^\//, ''), opts).then(function (r) {
      if (r.status === 401) {
        try { localStorage.removeItem(AUTH); } catch (e) { }
        showLock();
      }
      return r;
    });
  }

  function injectCSS() {
    if (document.getElementById('cxStyle')) return;
    var s = document.createElement('style');
    s.id = 'cxStyle';
    s.textContent = CSS;
    document.head.appendChild(s);
  }

  /* ---------- 骨架 ---------- */
  function build() {
    if (built) return;
    injectCSS();
    root = document.createElement('div');
    root.className = 'cx';
    root.id = 'cxRoot';
    root.style.display = 'none';
    root.innerHTML =
      '<div class="cx-lock" id="cxLock">口令 <input type="password" id="cxPass" placeholder="网页对话的口令" autocomplete="current-password"><button id="cxUnlock">解锁</button></div>' +
      '<div class="cx-log" id="cxLog"></div>' +
      '<div class="cx-strip" id="cxStrip"></div>' +
      '<div class="cx-bar">' +
        '<button class="cx-btn" id="cxAdd" aria-label="发照片或文件">' + SVG_ATTACH + '</button>' +
        '<textarea class="cx-in" id="cxIn" rows="1" placeholder="发消息…"></textarea>' +
        '<button class="cx-btn go" id="cxSend" aria-label="发送">' + SVG_SEND + '</button>' +
      '</div>' +
      '<input type="file" id="cxFile" multiple hidden>' +
      '<div class="cx-mask" id="cxMask"></div>' +
      '<div class="cx-sheet" id="cxSheet"></div>' +
      '<button class="cx-top" id="cxTop" aria-label="回到最新">' +
        '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14"/><path d="M6 13l6 6 6-6"/></svg>' +
      '</button>';
    document.body.appendChild(root);

    els = {
      log: root.querySelector('#cxLog'),
      strip: root.querySelector('#cxStrip'),
      bar: root.querySelector('.cx-bar'),
      input: root.querySelector('#cxIn'),
      top: root.querySelector('#cxTop'),
      mask: root.querySelector('#cxMask'),
      sheet: root.querySelector('#cxSheet'),
      send: root.querySelector('#cxSend'),
      add: root.querySelector('#cxAdd'),
      file: root.querySelector('#cxFile'),
      lock: root.querySelector('#cxLock'),
      pass: root.querySelector('#cxPass'),
      unlock: root.querySelector('#cxUnlock')
    };

    els.unlock.onclick = function () {
      var v = (els.pass.value || '').trim();
      if (!v) return;
      var b64 = btoa('hermes:' + v);
      fetch('/hermes/', { headers: { Authorization: 'Basic ' + b64 }, cache: 'no-store' })
        .then(function (r) {
          if (r.ok) {
            try { localStorage.setItem(AUTH, b64); } catch (e) { }
            els.pass.value = '';
            hideLock();
            /* 把解锁前失败的那一轮（401 报错）扔掉，别留在记录里 */
            var last = state.messages[state.messages.length - 1];
            if (last && last.role === 'assistant' && /连接出错/.test(last.text || '')) {
              state.messages.pop();
              if (state.messages.length && state.messages[state.messages.length - 1].role === 'user') state.messages.pop();
              save(); paint();
            }
            els.input.focus();
          } else {
            els.pass.value = '';
            els.pass.placeholder = '口令不对，再试一次';
          }
        })
        .catch(function () { els.pass.placeholder = '连不上后端'; });
    };
    els.pass.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { e.preventDefault(); els.unlock.click(); }
    });
    els.add.onclick = function () { els.file.click(); };
    els.file.onchange = function () {
      var fs = Array.prototype.slice.call(els.file.files || []);
      els.file.value = '';
      fs.forEach(addAttachment);
    };
    els.send.onclick = function () { busy ? stop() : send(); };
    bindLongPress();
    if (els.top) {
      els.top.onclick = function () { scrollDown(true); };
      els.log.addEventListener('scroll', onLogScroll, { passive: true });
    }
    els.input.addEventListener('input', function () {
      els.input.style.height = 'auto';
      els.input.style.height = Math.min(els.input.scrollHeight, 104) + 'px';
    });
    els.input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); }
    });
    els.log.addEventListener('click', function (e) {
      /* 下载链接：不能靠浏览器直接跳（会 401），改用带鉴权的 fetch + blob */
      var dl = e.target.closest && e.target.closest('a.cx-dl, a.cx-file.dl');
      if (dl) { e.preventDefault(); saveViaAuth(dl.getAttribute('href')); return; }
      var img = e.target.closest && e.target.closest('.cx-imgs img');
      if (img) { openViewer(img.src); return; }
      /* 审批卡片：允许 / 拒绝 */
      var apb = e.target.closest && e.target.closest('[data-ap]');
      if (apb) { answerApproval(apb.getAttribute('data-ap')); return; }
      /* 点一下步骤卡片，展开/收起完整输出 */
      var st = e.target.closest && e.target.closest('.cx-step');
      if (st) { st.classList.toggle('open'); return; }
      /* 思考文字：点「展开全文」或点那段灰字本身，都能展开/收起 */
      var more = e.target.closest && e.target.closest('.cx-think-more');
      var th = more ? more.previousElementSibling : (e.target.closest && e.target.closest('.cx-think'));
      if (th && th.classList && th.classList.contains('cx-think')) {
        th.classList.toggle('open');
        decorateThinks();
      }
    });

    built = true;
  }

  function openViewer(src) {
    var v = document.createElement('div');
    v.style.cssText = 'position:fixed;inset:0;background:#000000e6;z-index:99;display:grid;place-items:center;padding:14px';
    v.innerHTML = '<img src="' + src + '" style="max-width:100%;max-height:100%;border-radius:12px">';
    v.onclick = function () { v.remove(); };
    document.body.appendChild(v);
  }

  /* ---------- 版式：夹在顶栏与底部导航之间 ---------- */
  var GEOM = { top: 0, bottom: 0, ready: false };
  function layout() {
    if (!root) return;
    var hdr = document.querySelector('.header');
    var nav = document.querySelector('.bottom-nav');
    var app = document.querySelector('.app');
    var vh = window.innerHeight;
    var vv = window.visualViewport;
    /* 键盘高度：要减掉 visualViewport 的 offsetTop，否则键盘一弹、页面被顶上去时算错 */
    var kb = vv ? Math.max(0, Math.round(vh - vv.height - (vv.offsetTop || 0))) : 0;
    /* 键盘弹起时几何冻结：顶边不动，只把底边抬到键盘上沿。
       以前每帧重算 top（来自 sticky 顶栏的 rect），键盘一弹页面滚动→顶栏 rect 变→整块对话层跟着跳，
       表现就是“输入法把云匣顶乱”。 */
    if (kb > 40 && GEOM.ready) {
      root.style.top = GEOM.top + 'px';
      root.style.bottom = (GEOM.bottom + kb) + 'px';
      document.documentElement.classList.add('cx-kb');
      return;
    }
    var top = hdr ? Math.round(hdr.getBoundingClientRect().bottom) : 0;
    var nr = nav ? nav.getBoundingClientRect() : null;
    /* 手机上导航是 fixed 贴底；电脑/平板上它被挪进顶栏（static），这时对话层直接顶到卡片底部 */
    var fixedNav = nr && nr.top > vh * 0.5;
    var bottom = fixedNav
      ? Math.round(vh - nr.top)
      : Math.max(0, Math.round(vh - (app ? app.getBoundingClientRect().bottom : vh)));
    if (kb <= 40) {
      GEOM.top = top; GEOM.bottom = bottom; GEOM.ready = true;
      document.documentElement.classList.remove('cx-kb');
    }
    if (app) {
      var ar = app.getBoundingClientRect();
      root.style.left = Math.round(ar.left) + 'px';
      root.style.width = Math.round(ar.width) + 'px';
    } else {
      root.style.left = '0px';
      root.style.width = '100%';
    }
    root.style.top = top + 'px';
    root.style.bottom = Math.max(bottom, kb) + 'px';
    if (els && els.top && els.bar) {
      var bh = els.bar.getBoundingClientRect().height + (els.strip.getBoundingClientRect().height || 0);
      els.top.style.bottom = Math.round(bh + 12) + 'px';
      /* 输入栏左右和消息列严格对齐（桌面端消息列是居中的 760） */
      var lr = els.log.getBoundingClientRect();
      var padL = Math.max(12, Math.round(lr.left - root.getBoundingClientRect().left) + 14);
      var padR = Math.max(12, Math.round(root.getBoundingClientRect().right - lr.right) + 14);
      els.bar.style.paddingLeft = padL + 'px';
      els.bar.style.paddingRight = padR + 'px';
      if (els.strip) { els.strip.style.paddingLeft = padL + 'px'; els.strip.style.paddingRight = padR + 'px'; }
    }
  }

  /* ---------- 存取 ---------- */
  function save() {
    try {
      localStorage.setItem(STORE, JSON.stringify({
        prevId: state.prevId,
        since: state.since || 0,
        messages: state.messages.map(function (m) {
          return {
            role: m.role, ts: m.ts, rid: m.rid, text: m.text, imgs: m.imgs || [], files: m.files || [],
            steps: m.steps || [], think: m.think || '', elapsed: m.elapsed
          };
        })
      }));
    } catch (e) { }
  }
  function load() {
    try {
      var d = JSON.parse(localStorage.getItem(STORE) || '{}');
      state.prevId = d.prevId || null;
      state.since = d.since || 0;
      state.messages = d.messages || [];
      /* 老记录里存的 tools（只有名字），补成 steps 的形状，不丢显示 */
      state.messages.forEach(function (m) {
        if (!m.steps && m.tools && m.tools.length) {
          m.steps = m.tools.map(function (n) { return { name: n, arg: '', run: false }; });
        }
        /* 断线时还在转的那一步：别一直转下去 */
        (m.steps || []).forEach(function (s) {
          if (s.run) { s.run = false; s.bad = true; s.out = s.out || '（页面断开，这一步的结果没收到）'; }
        });
      });
      /* 上次断在这一轮的回答交给 syncRuns() 从后端补，这里不再写死提示 */
    } catch (e) { }
  }

  /* ---------- 渲染 ---------- */
  function esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  /* 路径 → 下载地址；只认后端愿意放行的位置（HOME、/tmp、/mnt/x），文件名要像文件名 */
  function dlHref(path) {
    path = String(path || '').trim();
    if (!/^(?:\/home\/administrator|\/tmp|\/mnt\/[a-z])\//.test(path)) return '';
    if (!/\.[A-Za-z0-9]{1,8}$/.test(path)) return '';
    if (/[\s<>"'`]/.test(path)) return '';
    return '/hermes/api/dl?path=' + encodeURIComponent(path);
  }
  /* 直接点 <a href="/hermes/api/dl"> 不会带 Basic 头（口令是页面自己存的），会 401。
     所以拦截点击，带鉴权取回二进制，再用 blob 触发保存。 */
  function saveViaAuth(href) {
    var auth = authB64();
    var m = /[?&]path=([^&]*)/.exec(href || '');
    var name = m ? decodeURIComponent(m[1]).split('/').pop() : 'download';
    var sys = { role: 'system', text: '开始下载 ' + name + '…' };
    state.messages.push(sys); paint();
    return fetch(href, { headers: auth ? { Authorization: 'Basic ' + auth } : {}, cache: 'no-store' })
      .then(function (r) {
        if (!r.ok) throw new Error(r.status === 401 ? '口令过期了，请重新解锁' : 'HTTP ' + r.status);
        var cd = r.headers.get('content-disposition') || '';
        var mm = /filename\*=UTF-8''([^;]+)/.exec(cd);
        if (mm) { try { name = decodeURIComponent(mm[1]); } catch (e) { } }
        return r.blob();
      })
      .then(function (b) {
        var u = URL.createObjectURL(b);
        var a = document.createElement('a');
        a.href = u; a.download = name; a.rel = 'noopener';
        document.body.appendChild(a); a.click(); a.remove();
        setTimeout(function () { try { URL.revokeObjectURL(u); } catch (e) { } }, 8000);
        sys.text = '已开始保存 ' + name + '（' + humanSize(b.size) + '）';
        paint();
      })
      .catch(function (err) {
        sys.text = '下载失败：' + (err && err.message ? err.message : err);
        paint();
      });
  }
  function dlLink(path) {
    var name = path.split('/').pop();
    return '<a class="cx-dl" href="/hermes/api/dl?path=' + encodeURIComponent(path) +
      '" download>📎 ' + esc(name) + '</a>';
  }
  /* 网页链接：蓝色可点，新标签打开；句末的标点不算进链接 */
  var URL_RE = /\b((?:https?:\/\/|www\.)[^\s<>"'`（）()【】\[\]，。；;、]+)/gi;
  function linkifyUrls(p) {
    return p.replace(URL_RE, function (m) {
      var tail = '';
      var mm = /[.,;:!?、。；：！？]+$/.exec(m);
      if (mm) { tail = mm[0]; m = m.slice(0, -tail.length); }
      if (!m) return tail;
      var href = /^https?:\/\//i.test(m) ? m : 'https://' + m;
      return '<a class="cx-a" href="' + href + '" target="_blank" rel="noopener noreferrer">' + m + '</a>' + tail;
    });
  }
  var PATH_RE = /(^|[\s(（:：])((?:\/home\/administrator|\/tmp|\/mnt\/[a-z])\/[^\s<>'`()（）]*?\.[A-Za-z0-9]{1,8})(?=$|[\s)）。,，;；:：])/g;
  function linkifyPaths(p) {
    return p.replace(PATH_RE, function (m, pre, path) { return pre + dlLink(path); });
  }
  function md(t) {
    return esc(t).split(/```/).map(function (p, i) {
      if (i % 2 === 1) return '<pre><code>' + p.replace(/^\w*\n/, '') + '</code></pre>';
      /* 行内代码 `…` 里如果是一个可下载的路径，就直接变成下载按钮，不再当纯文本 */
      return p.split(/(`[^`\n]+`)/).map(function (seg) {
        if (seg.length > 2 && seg.charAt(0) === '`' && seg.charAt(seg.length - 1) === '`') {
          var inner = seg.slice(1, -1);
          if (/^(?:https?:\/\/|www\.)\S+$/i.test(inner)) return linkifyUrls(inner);
          var href = dlHref(inner);
          return href ? '<a class="cx-dl" href="' + href + '" download>📎 ' + inner + '</a>'
            : '<code>' + inner + '</code>';
        }
        return linkifyPaths(linkifyUrls(seg));
      }).join('');
    }).join('');
  }
  var AP_LABEL = { once: '允许一次', session: '本会话都允许', always: '以后都允许', deny: '拒绝' };
  function apButtons(ap) {
    var list = (ap.choices && ap.choices.length) ? ap.choices : ['once', 'deny'];
    return '<div class="cx-ap-b">' + list.map(function (c) {
      var cls = c === 'deny' ? 'no' : (c === 'once' ? 'ok' : '');
      return '<button data-ap="' + esc(c) + '"' + (cls ? ' class="' + cls + '"' : '') + '>' +
        esc(AP_LABEL[c] || c) + '</button>';
    }).join('') + '</div>';
  }
  function approvalHtml(ap) {
    var h = '<div class="cx-ap">' +
      '<div class="cx-ap-h">⚠️ 这一步要你点头才能跑' + (ap.description ? '：' + esc(ap.description) : '') + '</div>';
    if (ap.command) h += '<pre class="cx-ap-c">' + esc(ap.command) + '</pre>';
    if (ap.choice) {
      h += '<div class="cx-ap-d">' + (ap.choice === 'deny'
        ? '你拒绝了这一步'
        : '已允许（' + esc(AP_LABEL[ap.choice] || ap.choice) + '）') + '</div>';
    } else if (ap.error) {
      h += '<div class="cx-ap-d err">提交失败：' + esc(ap.error) + '</div>' + apButtons(ap);
    } else {
      h += apButtons(ap);
    }
    return h + '</div>';
  }
  function stepHtml(s, i) {
    var badge = s.run
      ? '<span class="cx-dot"></span>'
      : '<span class="cx-ok">' + (s.bad ? '✕' : '✓') + '</span>';
    var tail = s.run
      ? '<span class="cx-st">运行中</span>'
      : (s.dur ? '<span class="cx-st">' + Number(s.dur).toFixed(1) + 's</span>' : '');
    return '<div class="cx-step' + (s.run ? ' run' : '') + (s.bad ? ' bad' : '') + '" data-step="' + i + '" data-t0="' + (s.t0 || 0) + '">' +
      '<div class="cx-sd">' + badge +
        '<span class="cx-sn">' + esc(s.name || 'tool') + '</span>' +
        '<span class="cx-sa">' + esc(s.arg || '') + '</span>' + tail +
      '</div>' +
      (s.out ? '<div class="cx-so">' + esc(s.out) + '</div>' : '') +
    '</div>';
  }
  var IMG_PATH_RE = /(?:\/home\/administrator|\/tmp|\/mnt\/[a-z])\/[^\s<>"'`()（）,，。；;：:]+?\.(?:png|jpe?g|webp|gif)/gi;
  /* 回复正文里的本地图片路径 → 直接当缩略图显示（取回要带口令，见 hydrateThumbs） */
  function imgPathsOf(t) {
    var out = [], m;
    IMG_PATH_RE.lastIndex = 0;
    while ((m = IMG_PATH_RE.exec(String(t || ''))) && out.length < 6) {
      if (out.indexOf(m[0]) < 0) out.push(m[0]);
    }
    return out;
  }
  function thumbHtml(t) {
    var ps = imgPathsOf(t);
    if (!ps.length) return '';
    return '<div class="cx-imgs">' + ps.map(function (p) {
      return '<img data-hx="' + dlHref(p) + '" alt="" title="' + esc(p.split('/').pop()) + '">';
    }).join('') + '</div>';
  }
  var THUMB_FAIL = {};
  /* 把 fetch/上游的技术错误翻成人话 */
  function errText(e) {
    var m = String((e && e.message) || e || '');
    var c = (m.match(/HTTP (\d{3})/) || [])[1];
    if (c) {
      if (c === '401' || c === '403') return '口令失效了，重新输一下口令';
      if (c === '429') return '发得太快了，缓一分钟再试';
      if (c.charAt(0) === '5') return '服务器出错了（' + c + '），过一会儿再试';
      return '这次没成功（' + c + '），重发试试';
    }
    if (/Failed to fetch|NetworkError|Load failed|network/i.test(m)) return '网络断了，检查一下网络再发一次';
    if (/abort/i.test(m)) return '已取消';
    return '出了点问题，重发试试';
  }
  function copyText(t) {
    var fb = function () {
      var ta = document.createElement('textarea');
      ta.value = t; ta.style.position = 'fixed'; ta.style.opacity = '0'; ta.style.left = '-9999px';
      document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); } catch (e) { }
      ta.remove();
      return Promise.resolve();
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(t).catch(fb);
    }
    return fb();
  }
  function decorateCode() {
    if (!els || !els.log) return;
    Array.prototype.forEach.call(els.log.querySelectorAll('.cx-b pre:not([data-cp])'), function (pre) {
      pre.setAttribute('data-cp', '1');
      var b = document.createElement('button');
      b.type = 'button'; b.className = 'cx-cp'; b.textContent = '复制';
      b.onclick = function (ev) {
        ev.stopPropagation();
        var code = pre.querySelector('code');
        copyText(code ? code.innerText : pre.innerText).then(function () {
          b.textContent = '已复制';
          setTimeout(function () { b.textContent = '复制'; }, 1400);
        });
      };
      pre.appendChild(b);
    });
  }
  function hydrateThumbs() {
    if (!els || !els.log) return;
    var auth = authB64();
    Array.prototype.forEach.call(els.log.querySelectorAll('img[data-hx]:not([data-l])'), function (img) {
      var hx = img.getAttribute('data-hx');
      if (THUMB_FAIL[hx]) { img.remove(); return; }
      img.setAttribute('data-l', '1');
      fetch(img.getAttribute('data-hx'), { headers: auth ? { Authorization: 'Basic ' + auth } : {}, cache: 'force-cache' })
        .then(function (r) { return r.ok ? r.blob() : null; })
        .then(function (b) { if (b) { img.src = URL.createObjectURL(b); } else { THUMB_FAIL[hx] = 1; img.remove(); } })
        .catch(function () { THUMB_FAIL[hx] = 1; img.remove(); });
    });
  }
  function msgHtml(m) {
    var h = '';
    if (m.role === 'system') return '<div class="cx-sys">' + esc(m.text || '') + '</div>';
    if (m.role !== 'user' && !m.text && !m.think && !m.wait && !(m.steps && m.steps.length)) return '';
    if (m.role !== 'user') {
      if (m.think) h += '<div class="cx-think"><span class="cx-tk">' + esc(m.think) + '</span></div>';
      if (m.steps && m.steps.length) {
        h += '<div class="cx-steps">' + m.steps.map(stepHtml).join('') + '</div>';
      }
      if (m.approval) h += approvalHtml(m.approval);
      if (m.wait && !m.text) h += '<div class="cx-b cx-typing"><span class="cx-dots"><i></i><i></i><i></i></span></div>';
    }
    if (m.imgs && m.imgs.length) {
      h += '<div class="cx-imgs">' + m.imgs.map(function (u) {
        return '<img src="' + u + '" loading="lazy">';
      }).join('') + '</div>';
    }
    if (m.role === 'user') {
      if (m.text) h += '<div class="cx-b">' + esc(m.text) + '</div>';
    } else if (m.text) {
      /* 模型常在正文前吐两个空行，渲染时去掉，别留一个「空气泡」 */
      var body = String(m.text).replace(/^[\s\u00a0]+/, '');
      if (body) {
        h += '<div class="cx-b">' + md(body) + '</div>';
        h += thumbHtml(body);
      }
    }
    if (m.files && m.files.length) {
      h += m.files.map(function (f) {
        var hr = dlHref(f.path || f.name);
        var label = '📄 ' + esc(f.name) + ' · ' + esc(f.size) +
          (hr ? ' · <b>下载</b>' : '');
        return hr ? '<a class="cx-file dl" href="' + hr + '" download>' + label + '</a>'
          : '<div class="cx-file">' + label + '</div>';
      }).join('');
    }
    if (m.role !== 'user' && m.elapsed && m.elapsed >= 1) h += '<div class="cx-meta">用时 ' + m.elapsed + ' 秒</div>';
    return h;
  }
  function paint() {
    if (!els) return;
    if (!state.messages.length) {
      els.log.innerHTML = '<div class="cx-intro"><b>在云匣里直接说话</b>' +
        '发文字、照片、文件都行<br>命令和文件操作都在这台机器上真跑<br>' +
        '<span style="opacity:.75">照片我会直接看，文件会存到服务器</span></div>';
      return;
    }
    var lastDay = '';
    els.log.innerHTML = state.messages.map(function (m) {
      var day = '';
      if (m.ts) {
        var d = new Date(m.ts), today = new Date();
        day = d.toDateString() === today.toDateString() ? '今天'
          : (d.getFullYear() + '/' + (d.getMonth() + 1) + '/' + d.getDate());
        if (day === lastDay) day = ''; else lastDay = day;
        if (day) day = '<div class="cx-day">' + day + '</div>';
      }
      return day + '<div class="cx-msg ' + (m.role === 'system' ? 'sys' : (m.role === 'user' ? 'user' : 'ai')) + '">' + msgHtml(m) + '</div>';
    }).join('');
    decorateThinks();
    decorateCode();
    hydrateThumbs();
    scrollDown();
    onLogScroll();
  }
  /* 思考文字默认留两行，超出就补一个「展开全文 / 收起」，点了看全文 */
  function decorateThinks() {
    if (!els || !els.log) return;
    Array.prototype.forEach.call(els.log.querySelectorAll('.cx-think'), function (t) {
      var nx = t.nextElementSibling;
      if (nx && nx.classList && nx.classList.contains('cx-think-more')) {
        nx.textContent = t.classList.contains('open') ? '收起' : '展开全文';
        return;
      }
      var inner = t.querySelector('.cx-tk') || t;
      if (inner.scrollHeight <= inner.clientHeight + 2) return;
      var b = document.createElement('button');
      b.className = 'cx-think-more';
      b.type = 'button';
      b.textContent = '展开全文';
      t.parentNode.insertBefore(b, t.nextSibling);
    });
  }
  function lastEl() { return els.log.lastElementChild; }
  function scrollDown(force) {
    var near = els.log.scrollHeight - els.log.scrollTop - els.log.clientHeight < 260;
    if (force || near) els.log.scrollTop = els.log.scrollHeight;
    if (force) onLogScroll();
  }
  /* 流式更新时只重画最后一条，避免整屏闪烁 */
  function repaintLast(m) {
    var el = lastEl();
    if (!el) return paint();
    el.className = 'cx-msg ' + (m.role === 'system' ? 'sys' : (m.role === 'user' ? 'user' : 'ai'));
    el.innerHTML = msgHtml(m);
    decorateThinks();
    hydrateThumbs();
    scrollDown();
  }

  /* ---------- 附件 ---------- */
  function humanSize(n) {
    if (n < 1024) return n + ' B';
    if (n < 1048576) return Math.round(n / 1024) + ' KB';
    return (n / 1048576).toFixed(1) + ' MB';
  }
  function downscale(file, max, q) {
    return new Promise(function (resolve) {
      var img = new Image();
      img.onload = function () {
        var s = Math.min(1, max / Math.max(img.width, img.height));
        var c = document.createElement('canvas');
        c.width = Math.round(img.width * s);
        c.height = Math.round(img.height * s);
        c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
        try { resolve(c.toDataURL('image/jpeg', q)); } catch (e) { resolve(null); }
      };
      img.onerror = function () { resolve(null); };
      img.src = URL.createObjectURL(file);
    });
  }
  function addAttachment(f) {
    var id = Math.random().toString(36).slice(2);
    var isImg = /^image\//.test(f.type || '');
    var item = { id: id, name: f.name, size: f.size, isImg: isImg, preview: null, path: null, thumbUrl: null };
    if (isImg) item.preview = URL.createObjectURL(f);
    if (f.size > 60 * 1024 * 1024) {
      item.error = true;
      item.errMsg = '超过 60MB 上限';
      state.attachments.push(item);
      paintStrip();
      return;
    }
    state.attachments.push(item);
    paintStrip();

    var up = function (body, ctype) {
      return new Promise(function (resolve, reject) {
        var xhr = new XMLHttpRequest();
        xhr.open('POST', API + 'upload?name=' + encodeURIComponent(f.name) + '&kind=' + (isImg ? 'image' : 'file'));
        var a = authB64();
        if (a) xhr.setRequestHeader('Authorization', 'Basic ' + a);
        xhr.setRequestHeader('Content-Type', ctype || 'application/octet-stream');
        xhr.upload.onprogress = function (ev) {
          if (!ev.lengthComputable) return;
          item.progress = Math.min(99, Math.round(ev.loaded / ev.total * 100));
          paintStrip();
        };
        xhr.onload = function () {
          item.progress = null;
          try { resolve(JSON.parse(xhr.responseText || '{}')); } catch (e) { reject(e); }
        };
        xhr.onerror = function () { item.progress = null; reject(new Error('upload failed')); };
        xhr.send(body);
      });
    };
    var imgPromise = isImg ? downscale(f, 1600, 0.82) : Promise.resolve(null);
    Promise.all([imgPromise, up(f, f.type)]).then(function (res) {
      item.dataUrl = res[0];
      if (res[1] && res[1].ok) {
        item.path = res[1].path;
        item.saved = res[1].name;
        /* 后端给的是相对路径（api/file?…），云匣页面在站点根上，要补 /hermes/ 前缀 */
        item.thumbUrl = res[1].url ? ('/hermes/' + String(res[1].url).replace(/^\/+/, '')) : null;
      }
      else { item.error = true; }
      paintStrip();
    }).catch(function () { item.error = true; paintStrip(); });
  }
  /* 轮询某一轮的结果：后端把 SSE 一直录到磁盘，断了也能取回完整正文 */
  function pollRun(ai, rid, tries) {
    return api('runs?limit=30', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (d) {
      var run = (d.runs || []).filter(function (x) { return x.id === rid; })[0];
      if (run) {
        if (run.text) ai.text = run.text;
        if (run.think) ai.think = run.think;
        ai.rid = rid;
        repaintLast(ai);
        if (run.done) return true;
      }
      if (tries <= 0) return !!(run && run.text);
      return new Promise(function (res) { setTimeout(res, 4000); }).then(function () {
        return pollRun(ai, rid, tries - 1);
      });
    });
  }
  /* 打开页面/切回前台：把后端已经跑完但没送到这里的回答补进对话 */
  function syncRuns() {
    return api('runs?limit=20', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (d) {
      var floor = state.since || 0;
      var runs = (d.runs || []).filter(function (r) { return !floor || (r.ts || 0) > floor; }).sort(function (a, b) { return a.ts - b.ts; });
      var known = {}, texts = {}, pending = 0;
      state.messages.forEach(function (m) {
        if (m.rid) known[m.rid] = 1;
        if (m.role !== 'user' && m.text) texts[String(m.text).replace(/\s+/g, ' ').trim()] = 1;
      });
      var added = 0, touched = 0;
      var byRid = {};
      state.messages.forEach(function (m) { if (m.rid) byRid[m.rid] = m; });
      runs.forEach(function (run) {
        if (!run.text && !run.think) return;
        var key = String(run.text || '').replace(/\s+/g, ' ').trim();
        var m = byRid[run.id];
        if (m) {                                  /* 正在跑的这一轮：原地刷新进度 */
          if (run.text && m.text !== run.text) { m.text = run.text; touched++; }
          if (run.think && m.think !== run.think) { m.think = run.think; touched++; }
          var w = !run.done;
          if (!!m.wait !== w) { m.wait = w; touched++; }
          if (!run.done) pending++;
          return;
        }
        if (known[run.id]) return;
        if (key && texts[key]) return;
        var msg = { role: 'assistant', ts: (run.ts || 0) * 1000 || Date.now(), text: run.text || '', think: run.think || '', rid: run.id };
        if (!run.done) msg.wait = true;           /* 还在跑：先挂一条“正在输入”，看得见进度 */
        state.messages.push(msg);
        if (key) texts[key] = 1;
        added++;
        if (!run.done) pending++;
      });
      if (added || touched) { paint(); save(); scrollDown(added > 0); }
      if (pending) setTimeout(syncRuns, 8000);
      return added;
    }).catch(function () { return 0; });
  }
  /* 长按消息 → 复制 / 重发 / 删除 */
  function closeSheet() {
    if (!els) return;
    els.sheet.classList.remove('on'); els.mask.classList.remove('on'); els.sheet.innerHTML = '';
  }
  function openSheet(idx) {
    var m = state.messages[idx];
    if (!m) return;
    var acts = [{ k: 'copy', t: '复制文字' }];
    if (m.role === 'user' && m.text) acts.push({ k: 'resend', t: '重新发送' });
    acts.push({ k: 'del', t: '删除这条', cls: 'danger' });
    els.sheet.innerHTML = acts.map(function (a) {
      return '<button data-k="' + a.k + '" class="' + (a.cls || '') + '">' + a.t + '</button>';
    }).join('') + '<button data-k="close" class="cancel">取消</button>';
    els.sheet.classList.add('on'); els.mask.classList.add('on');
    Array.prototype.forEach.call(els.sheet.querySelectorAll('button'), function (b) {
      b.onclick = function () {
        var k = b.dataset.k;
        closeSheet();
        if (k === 'copy') copyText(m.text || '');
        else if (k === 'resend') { els.input.value = m.text || ''; els.input.dispatchEvent(new Event('input')); send(); }
        else if (k === 'del') { state.messages.splice(idx, 1); save(); paint(); }
      };
    });
  }
  function bindLongPress() {
    if (!els || els.log.__lp) return;
    els.log.__lp = 1;
    var timer = null, sx = 0, sy = 0, moved = false;
    var start = function (ev) {
      var t = ev.target.closest && ev.target.closest('.cx-msg');
      if (!t || (ev.target.closest && ev.target.closest('a,button'))) return;
      var all = Array.prototype.slice.call(els.log.querySelectorAll('.cx-msg'));
      var idx = all.indexOf(t);
      if (idx < 0) return;
      moved = false;
      var p = ev.touches ? ev.touches[0] : ev;
      sx = p.clientX; sy = p.clientY;
      clearTimeout(timer);
      timer = setTimeout(function () { if (!moved) { try { ev.preventDefault(); } catch (e) { } openSheet(idx); } }, 480);
    };
    var move = function (ev) {
      var p = ev.touches ? ev.touches[0] : ev;
      if (Math.abs(p.clientX - sx) > 8 || Math.abs(p.clientY - sy) > 8) { moved = true; clearTimeout(timer); }
    };
    var end = function () { clearTimeout(timer); };
    els.log.addEventListener('touchstart', start, { passive: true });
    els.log.addEventListener('touchmove', move, { passive: true });
    els.log.addEventListener('touchend', end);
    els.log.addEventListener('touchcancel', end);
    els.log.addEventListener('contextmenu', function (ev) {
      var t = ev.target.closest && ev.target.closest('.cx-msg');
      if (!t) return;
      ev.preventDefault();
      var all = Array.prototype.slice.call(els.log.querySelectorAll('.cx-msg'));
      var idx = all.indexOf(t);
      if (idx >= 0) openSheet(idx);
    });
    els.mask.addEventListener('click', closeSheet);
  }

  /* 向上翻看历史时，右下角给一个「回到最新」 */
  function onLogScroll() {
    if (!els || !els.top) return;
    var l = els.log;
    var far = l.scrollHeight - l.scrollTop - l.clientHeight > 320;
    els.top.classList.toggle('on', far);
  }

  function paintStrip() {
    if (!els) return;
    els.strip.innerHTML = state.attachments.map(function (a) {
      var st = a.error ? (' · ' + (a.errMsg || '失败')) : (a.progress != null ? ' · ' + a.progress + '%' : (a.path ? ' · 已存' : ' · 上传中'));
      return '<div class="cx-chip' + (a.error ? ' bad' : '') + '">' + (a.preview ? '<img src="' + a.preview + '">' : '📄') +
        '<span>' + esc(a.name) + st + '</span><button data-x="' + a.id + '">✕</button></div>';
    }).join('');
    Array.prototype.forEach.call(els.strip.querySelectorAll('button[data-x]'), function (b) {
      b.onclick = function () {
        state.attachments = state.attachments.filter(function (x) { return x.id !== b.dataset.x; });
        paintStrip();
      };
    });
  }

  /* ---------- 斜杠命令（API 通道不解析斜杠命令，这里本地映射） ---------- */
  var CMDS = {
    '/new': '新对话，清空当前记录',
    '/stop': '停掉正在跑的这一轮',
    '/retry': '重发上一条消息',
    '/status': '看当前会话状态',
    '/help': '看这个命令列表'
  };
  function sysMsg(text) {
    state.messages.push({ role: 'system', text: text });
    paint();
    save();
  }
  function lastUserText() {
    for (var i = state.messages.length - 1; i >= 0; i--) {
      if (state.messages[i].role === 'user') return state.messages[i].text || '';
    }
    return '';
  }
  function runCommand(raw) {
    var c = String(raw || '').trim().toLowerCase();
    if (!CMDS[c]) return false;
    if (c === '/new') {
      state = { messages: [], prevId: null, attachments: [], since: Math.floor(Date.now() / 1000) };
      save(); paint(); paintStrip();
      return true;
    }
    if (c === '/stop') {
      if (busy) { stop(); sysMsg('已发出停止。'); } else sysMsg('现在没有在跑的任务。');
      return true;
    }
    if (c === '/retry') {
      var t = lastUserText();
      if (!t) { sysMsg('还没有发过消息。'); return true; }
      if (busy) { sysMsg('上一轮还在跑，先 /stop 再 /retry。'); return true; }
      els.input.value = t;
      els.input.dispatchEvent(new Event('input', { bubbles: true }));
      send();
      return true;
    }
    if (c === '/status') {
      var done = 0, steps = 0;
      state.messages.forEach(function (m) {
        if (m.role !== 'user' && m.role !== 'system') { steps += (m.steps || []).length; if (m.elapsed) done++; }
      });
      sysMsg('消息 ' + state.messages.length + ' 条 · 回答 ' + done + ' 条 · 工具步骤 ' + steps + ' 个' +
        '\n当前' + (busy ? '在跑（可以 /stop）' : '空闲') +
        '\n多轮续接：' + (state.prevId ? '开' : '关') +
        '\n记在这台设备的 localStorage 里，换设备看不到');
      return true;
    }
    if (c === '/help') {
      sysMsg('可用命令：\n' + Object.keys(CMDS).map(function (k) {
        return k + ' — ' + CMDS[k];
      }).join('\n') + '\n（以 / 开头但不是命令的文字照常发给助手）');
      return true;
    }
    return false;
  }
  /* 页面不在前台时，跑完弹一条系统通知 */
  function notifyDone(ai) {
    try {
      if (!document.hidden) return;
      if (!('Notification' in window) || Notification.permission !== 'granted') return;
      var body = (ai.text || '').replace(/\s+/g, ' ').trim().slice(0, 80) || '回云匣看结果';
      new Notification('云匣 · 回答好了', { body: body, tag: 'yunxia-chat' });
    } catch (e) { }
  }
  function askNotifyPermission() {
    try {
      if (!('Notification' in window)) return;
      if (Notification.permission === 'default') Notification.requestPermission();
    } catch (e) { }
  }

  /* ---------- 发送 ---------- */
  function stop() {
    /* 真的停：连上游一起掐断，别让它在后台继续跑（还能省 token） */
    var rid = state.live && state.live.id;
    if (rid) { try { api('cancel?id=' + encodeURIComponent(rid)).catch(function () { }); } catch (e) { } }
    if (abortCtl) abortCtl.abort();
  }

  function send() {
    if (busy) return;
    var text = (els.input.value || '').trim();
    var atts = state.attachments.slice();
    if (!text && !atts.length) return;
    /* 斜杠命令：本地动作，不发网络请求 */
    if (text.charAt(0) === '/' && runCommand(text)) {
      els.input.value = '';
      els.input.style.height = 'auto';
      return;
    }
    askNotifyPermission();

    var userMsg = {
      role: 'user', ts: Date.now(), text: text,
      imgs: atts.filter(function (a) { return a.isImg; }).map(function (a) { return a.thumbUrl || a.preview; }).filter(Boolean),
      files: atts.filter(function (a) { return !a.isImg; }).map(function (a) { return { name: a.saved || a.name, size: humanSize(a.size) }; })
    };
    state.messages.push(userMsg);
    els.input.value = '';
    els.input.style.height = 'auto';
    state.attachments = [];
    paintStrip();

    var ai = { role: 'assistant', ts: Date.now(), text: '', steps: [], think: '', wait: true };
    state.messages.push(ai);
    paint();
    scrollDown(true);
    save();

    var content = [];
    if (text) content.push({ type: 'input_text', text: text });
    atts.forEach(function (a) {
      if (a.isImg && a.dataUrl) content.push({ type: 'input_image', image_url: a.dataUrl });
    });
    var lines = atts.filter(function (a) { return a.path; }).map(function (a) {
      return '（附件已保存到服务器：' + a.path + '，文件名 ' + a.name + '，' + humanSize(a.size) + '）';
    });
    if (lines.length) content.push({ type: 'input_text', text: lines.join('\n') + '\n需要时你可以直接读取这些路径。' });
    /* 用户定的规矩：云匣对话产生的文件只放在 G:\hermes\云匣文件\<日期>\，别处不留副本 */
    content.push({ type: 'input_text', text: '【文件存放规矩】这次对话里你要给我的任何文件（图片、音频、视频、文档、安装包），一律直接写到 /mnt/g/hermes/云匣文件/<今天日期>/ 下面再用完整路径告诉我；不要放进 ~/.hermes/audio_cache、image_cache 等缓存目录，也不要复制副本。' });
    if (!content.length) content.push({ type: 'input_text', text: '（空消息）' });

    busy = true;
    els.send.innerHTML = SVG_STOP;
    els.send.className = 'cx-btn go stop';
    startTick();
    var t0 = Date.now();
    abortCtl = new AbortController();

    api('chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ input: content, previous_response_id: state.prevId }),
      signal: abortCtl.signal
    }).then(function (resp) {
      if (!resp.ok || !resp.body) throw new Error('HTTP ' + resp.status);
      var reader = resp.body.getReader(), dec = new TextDecoder(), buf = '';
      function pump() {
        return reader.read().then(function (r) {
          if (r.done) return;
          buf += dec.decode(r.value, { stream: true });
          var blocks = buf.split('\n\n');
          buf = blocks.pop();
          blocks.forEach(function (b) {
            var line = b.split('\n').filter(function (l) { return l.indexOf('data:') === 0; })[0];
            if (!line) return;
            var raw = line.slice(5).trim();
            if (!raw || raw === '[DONE]') return;
            var ev;
            try { ev = JSON.parse(raw); } catch (e) { return; }
            handle(ev, ai);
          });
          repaintLast(ai);
          return pump();
        });
      }
      return pump();
    }).catch(function (e) {
      if (e.name === 'AbortError') {
        if (!ai.text) ai.text = '（已停止）';
        repaintLast(ai);
        return;
      }
      var rid = state.live && state.live.id;
      if (!rid) {
        ai.text += (ai.text ? '\n' : '') + '⚠️ ' + errText(e);
        repaintLast(ai);
        return;
      }
      /* 后端把这一轮继续录到磁盘（最多 10 分钟），这里轮询把它取回来 */
      ai.text += (ai.text ? '\n' : '') + '⚠️ 连接断了，正在补齐这一轮…';
      repaintLast(ai);
      return pollRun(ai, rid, 60).then(function (ok) {
        ai.text = ai.text.replace(/\n?⚠️ 连接断了[^\n]*/, '');
        repaintLast(ai);
        if (!ok) { ai.text += '\n（这一轮还没跑完，稍等刷新页面会自动补上）'; repaintLast(ai); }
      }).catch(function () {
        ai.text += '\n（刷新页面会自动补上这一轮）';
        repaintLast(ai);
      });
    }).then(function () {
      busy = false; abortCtl = null;
      stopTick();
      els.send.innerHTML = SVG_SEND;
      els.send.className = 'cx-btn go';
      ai.wait = false;
      ai.steps.forEach(function (s) { s.run = false; });
      ai.elapsed = Math.max(1, Math.round((Date.now() - t0) / 1000));
      repaintLast(ai);
      save();
      notifyDone(ai);
    });
  }

  /* 把审批结果送回后端：POST /hermes/api/approval → 上游 /v1/runs/{id}/approval */
  function answerApproval(choice) {
    var m = null, i;
    for (i = state.messages.length - 1; i >= 0; i--) {
      var x = state.messages[i];
      if (x.approval && !x.approval.choice) { m = x; break; }
    }
    if (!m) return;
    var ap = m.approval;
    ap.error = null;
    ap.pending = choice;
    paint();
    api('approval', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ run_id: ap.run_id, request_id: ap.request_id, choice: choice })
    }).then(function (r) {
      if (r.ok) { ap.choice = choice; return; }
      return r.text().then(function (t) { throw new Error('HTTP ' + r.status + ' ' + (t || '').slice(0, 120)); });
    }).catch(function (e) {
      ap.error = e && e.message ? e.message : String(e);
    }).then(function () {
      ap.pending = null;
      paint();
      save();
    });
  }

  /* ---------- 把工具调用摊成终端那样的一行一行 ---------- */
  function shortArg(raw) {
    var o = null;
    try { o = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch (e) { }
    var v = '';
    if (o && typeof o === 'object') {
      var keys = ['command', 'file_path', 'path', 'query', 'pattern', 'url', 'goal', 'prompt',
        'description', 'skill', 'name', 'text', 'code', 'reason'];
      for (var i = 0; i < keys.length; i++) {
        if (typeof o[keys[i]] === 'string' && o[keys[i]]) { v = o[keys[i]]; break; }
      }
      if (!v) { for (var k in o) { if (typeof o[k] === 'string' && o[k]) { v = o[k]; break; } } }
    }
    if (!v) v = (typeof raw === 'string' ? raw : '');
    v = String(v).replace(/\s+/g, ' ').trim();
    return v.length > 140 ? v.slice(0, 140) + '…' : v;
  }
  function outOf(item) {
    var raw = item.output;
    if (Object.prototype.toString.call(raw) === '[object Array]') {
      raw = raw.map(function (p) { return (p && (p.text || p.content)) || ''; }).join('\n');
    } else if (raw && typeof raw === 'object') {
      raw = raw.text || JSON.stringify(raw);
    }
    var s = String(raw || ''), o = null, bad = false, code = null;
    try { o = JSON.parse(s); } catch (e) { }
    if (o && typeof o === 'object') {
      if (typeof o.exit_code === 'number') code = o.exit_code;
      var txt = o.output || o.stdout || o.text || o.result || o.message || '';
      if (!txt && o.error) { txt = typeof o.error === 'string' ? o.error : JSON.stringify(o.error); bad = true; }
      if (typeof txt !== 'string') txt = JSON.stringify(txt);
      if (txt) s = txt;
      if (code !== null && code !== 0) bad = true;
      if (o.error && !code) bad = true;
    }
    s = s.replace(/\r/g, '').replace(/\n{3,}/g, '\n\n').trim();
    if (s.length > 1600) s = s.slice(0, 1600) + '…';
    return { text: s, bad: bad };
  }
  function findStep(ai, call) {
    var i;
    if (call) {
      for (i = ai.steps.length - 1; i >= 0; i--) if (ai.steps[i].call === call) return ai.steps[i];
      return null;
    }
    for (i = ai.steps.length - 1; i >= 0; i--) if (ai.steps[i].run) return ai.steps[i];
    return null;
  }

  /* 跑着的时候秒数要动，终端里也是这么跳的 */
  var ticker = null;
  function stopTick() { if (ticker) { clearInterval(ticker); ticker = null; } }
  function startTick() {
    stopTick();
    ticker = setInterval(function () {
      var el = lastEl();
      if (!el) return;
      var now = Date.now();
      Array.prototype.forEach.call(el.querySelectorAll('.cx-step.run'), function (box) {
        var st = box.querySelector('.cx-st'), t0 = Number(box.getAttribute('data-t0')) || 0;
        if (st && t0) st.textContent = '运行中 ' + Math.max(0, Math.round((now - t0) / 1000)) + 's';
      });
    }, 1000);
  }

  function handle(ev, ai) {
    var t = ev.type || '';
    /* 别一有事件就撤掉「正在输入」：只有真出字、结束或报错时才收 */
    if (/output_text\.delta|reasoning_summary_text\.delta|response\.completed|response\.failed|^error$/.test(t)) ai.wait = false;
    if (t === 'response.created') {
      var rid0 = (ev.response && ev.response.id) || ev.id || '';
      if (rid0) { state.live = { id: rid0 }; ai.rid = rid0; }   /* 断线后靠它 /api/resume 重放 */
    } else if (t === 'response.output_text.delta') {
      var d = ev.delta || '';
      ai.text += ai.text ? d : d.replace(/^\s+/, '');
    } else if (t === 'response.reasoning_summary_text.delta') {
      ai.think = (ai.think || '') + (ev.delta || '');
    } else if (t === 'response.output_item.added' || t === 'response.output_item.done') {
      var it = ev.item || {};
      if (it.type === 'function_call') {
        var st = findStep(ai, it.call_id);
        if (!st) {
          st = { name: it.name || 'tool', arg: shortArg(it.arguments), run: true, call: it.call_id, t0: Date.now() };
          ai.steps.push(st);
        } else if (!st.arg) {
          st.arg = shortArg(it.arguments);
        }
      } else if (it.type === 'function_call_output') {
        var st2 = findStep(ai, it.call_id);
        if (!st2) {
          st2 = { name: 'tool', arg: '', run: true, call: it.call_id, t0: Date.now() };
          ai.steps.push(st2);
        }
        var o = outOf(it);
        st2.out = o.text;
        st2.bad = o.bad;
        st2.run = false;
        st2.dur = st2.t0 ? Math.max(0.1, (Date.now() - st2.t0) / 1000) : null;
      }
    } else if (t === 'approval.request') {
      /* 后端把危险命令的确认请求投影成 SSE：命令本身是服务端脱敏过的 */
      ai.approval = {
        run_id: ev.run_id || '',
        request_id: ev.request_id || '',
        command: ev.command || '',
        description: ev.description || '',
        choices: (ev.choices && ev.choices.length) ? ev.choices : ['once', 'session', 'deny'],
        choice: null,
        error: null
      };
      ai.wait = false;
    } else if (t === 'response.completed') {
      ai.steps.forEach(function (s) { s.run = false; });
      if (ev.response && ev.response.id) state.prevId = ev.response.id;
    } else if (t === 'response.failed') {
      var err = (ev.response && ev.response.error) || ev.error || {};
      ai.text += (ai.text ? '\n' : '') + '⚠️ ' + (err.message || JSON.stringify(err));
      ai.steps.forEach(function (s) { s.run = false; });
    }
  }

  /* 重放一轮：/api/resume?id=<response_id>，从头消费同一套事件把断掉的结果补齐 */
  function replay(ai, rid) {
    return api('resume?id=' + encodeURIComponent(rid), { cache: 'no-store' }).then(function (r) {
      if (!r.ok || !r.body) throw new Error('HTTP ' + r.status);
      ai.text = ''; ai.steps = []; ai.think = ''; ai.approval = null; ai.wait = true;
      repaintLast(ai);
      var reader = r.body.getReader(), dec = new TextDecoder(), buf = '';
      function pump() {
        return reader.read().then(function (x) {
          if (x.done) return;
          buf += dec.decode(x.value, { stream: true });
          var blocks = buf.split('\n\n');
          buf = blocks.pop();
          blocks.forEach(function (b) {
            var line = b.split('\n').filter(function (l) { return l.indexOf('data:') === 0; })[0];
            if (!line) return;
            var raw = line.slice(5).trim();
            if (!raw || raw === '[DONE]') return;
            try { handle(JSON.parse(raw), ai); } catch (e) { }
          });
          repaintLast(ai);
          return pump();
        });
      }
      return pump();
    });
  }

  /* ---------- 对外 ---------- */
  function mount() {
    try {
      build();
      load();
      root.style.display = 'flex';
      layout();
      paint();
      paintStrip();
      /* 字体/导航有可能是挂载后才定高，补量两次，别让输入条跑到屏幕外 */
      setTimeout(layout, 200);
      setTimeout(layout, 600);
      /* 断线/关页面时没收到的回答，这里从后端补回来 */
      setTimeout(function () { if (authB64()) syncRuns(); }, 700);
      if (!window.__cxVisBound) {
        window.__cxVisBound = 1;
        document.addEventListener('visibilitychange', function () {
          if (!document.hidden && authB64()) syncRuns();
        });
      }
      return !!root && getComputedStyle(root).display !== 'none';
    } catch (e) {
      console.error('chat mount', e);
      return false;
    }
  }

  function hide() {
    if (root) root.style.display = 'none';
  }

  var rt;
  window.addEventListener('resize', function () {
    clearTimeout(rt); rt = setTimeout(layout, 120);
  });
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', function () {
      clearTimeout(rt); rt = setTimeout(layout, 60);
    });
  }

  window.MFM_CHAT = {
    mount: function () { try { return mount(); } catch (e) { console.error('chat mount', e); return false; } },
    hide: hide,
    reset: function () {
      state = { messages: [], prevId: null, attachments: [], since: Math.floor(Date.now() / 1000) };
      save(); paint(); paintStrip();
    }
  };
})();
