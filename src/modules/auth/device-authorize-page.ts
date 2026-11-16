/**
 * 手机浏览器打开的设备授权页（`GET /device?code=...`）。
 *
 * 由 NAS 内核自身托管（不依赖任何公网站点、无外链资源）：
 * - 如果同一浏览器里已经登录过 ColaNasOs Web（localStorage `colanas.settings` 带 token），
 *   直接显示「允许登录」；
 * - 否则在本页登录一次（账号密码 + 可选 TOTP），再允许；
 * - 授权码一次性、5 分钟有效，电视取消 / 超时后页面会提示失效。
 */
export function renderDeviceAuthorizePage(): string {
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>授权电视登录 · ColaNasOs</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
    padding: 24px 16px; background: #0f1115; color: #e8eaf0;
    font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
  }
  .card { width: 100%; max-width: 420px; background: #191c23; border: 1px solid #2a2f3a; border-radius: 18px; padding: 24px; }
  h1 { margin: 0 0 6px; font-size: 20px; }
  .muted { color: #9aa3b2; margin: 0; font-size: 14px; }
  .code {
    margin: 18px 0 8px; padding: 14px; text-align: center; letter-spacing: 8px;
    font: 700 28px/1.2 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    background: #10131a; border: 1px dashed #3a4150; border-radius: 12px; color: #8fd3ff;
  }
  .state { margin: 10px 0 4px; font-size: 14px; color: #9aa3b2; min-height: 21px; }
  label { display: block; margin: 12px 0 0; font-size: 13px; color: #9aa3b2; }
  input {
    width: 100%; margin-top: 6px; padding: 12px; border-radius: 10px; border: 1px solid #333a47;
    background: #10131a; color: #e8eaf0; font-size: 16px;
  }
  input:focus { outline: 2px solid #4c8dff; outline-offset: 1px; }
  button {
    width: 100%; margin-top: 16px; padding: 13px; border: 0; border-radius: 12px;
    background: #2a2f3a; color: #e8eaf0; font-size: 16px; font-weight: 600;
  }
  button.primary { background: #3d7bfd; color: #fff; }
  button:disabled { opacity: .55; }
  .hidden { display: none !important; }
  .who { margin: 14px 0 0; font-size: 15px; }
  .err { color: #ff8a8a; font-size: 14px; min-height: 20px; margin: 10px 0 0; }
  .ok { color: #6ee7a8; }
  .small { font-size: 12px; margin-top: 16px; }
</style>
</head>
<body>
<main class="card">
  <h1>授权电视登录</h1>
  <p class="muted">确认电视上显示的短码与下方一致，再点「允许登录」。</p>
  <div class="code" id="code">------</div>
  <div class="state" id="state">正在检查本机登录状态…</div>

  <section id="shortWrap" class="hidden">
    <label>电视上显示的短码<input id="short" inputmode="latin" maxlength="6" autocomplete="off" placeholder="例如 K7M2Q9"></label>
  </section>

  <section id="login" class="hidden">
    <label>账号<input id="u" autocomplete="username"></label>
    <label>密码<input id="p" type="password" autocomplete="current-password"></label>
    <label>两步验证码（未开启可留空）<input id="t" inputmode="numeric" maxlength="6" autocomplete="one-time-code"></label>
    <button id="loginBtn">登录</button>
  </section>

  <section id="confirm" class="hidden">
    <p class="who">当前账号：<b id="who"></b></p>
    <button id="allowBtn" class="primary">允许登录</button>
  </section>

  <p class="err" id="err"></p>
  <p class="muted small">授权码一次性使用，5 分钟内有效。电视取消或超时后需要重新生成。</p>
</main>
<script>
(function () {
  var query = new URLSearchParams(location.search);
  var codeFromUrl = query.get('code') || '';
  var useShort = !codeFromUrl;
  var codeInput = '';
  var token = '';
  var username = '';
  var busy = false;

  var $ = function (id) { return document.getElementById(id); };
  var elCode = $('code');
  var elState = $('state');
  var elErr = $('err');
  var elShortWrap = $('shortWrap');
  var elShort = $('short');
  var elLogin = $('login');
  var elConfirm = $('confirm');
  var elWho = $('who');
  var elAllow = $('allowBtn');
  var elLoginBtn = $('loginBtn');

  function setErr(text) { elErr.textContent = text || ''; }
  function setState(text, ok) {
    elState.textContent = text || '';
    elState.className = ok ? 'state ok' : 'state';
  }
  function currentCode() {
    if (!useShort) return codeFromUrl;
    return (codeInput || '').trim().toUpperCase();
  }
  function paintCode() {
    var c = currentCode();
    if (useShort) {
      elCode.textContent = c || '------';
    } else {
      elCode.textContent = c ? c.slice(0, 6).toUpperCase() : '------';
    }
  }

  function api(path, opts) {
    opts = opts || {};
    var headers = { 'content-type': 'application/json' };
    if (token) headers.authorization = 'Bearer ' + token;
    return fetch(path, {
      method: opts.method || 'GET',
      headers: headers,
      body: opts.body ? JSON.stringify(opts.body) : undefined,
    }).then(function (res) {
      return res.text().then(function (text) {
        var data = null;
        try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
        if (!res.ok) {
          var msg = (data && (data.message || data.error)) || ('HTTP ' + res.status);
          var err = new Error(msg);
          err.status = res.status;
          throw err;
        }
        return data;
      });
    });
  }

  function savedToken() {
    try {
      var raw = localStorage.getItem('colanas.settings');
      if (!raw) return '';
      var parsed = JSON.parse(raw);
      var t = parsed && parsed['auth.token'];
      return typeof t === 'string' ? t : '';
    } catch (e) {
      return '';
    }
  }

  function showConfirm(who) {
    elWho.textContent = who || '';
    elLogin.classList.add('hidden');
    elConfirm.classList.remove('hidden');
    elAllow.disabled = false;
    setState(useShort ? '确认短码无误后允许登录。' : '确认是同一台设备后允许登录。');
  }

  function showLogin() {
    elConfirm.classList.add('hidden');
    elLogin.classList.remove('hidden');
    setState('请先登录 ColaNasOs 账号。');
  }

  function checkExisting() {
    var saved = savedToken();
    if (!saved) return Promise.resolve(false);
    token = saved;
    return api('/api/v1/auth/me').then(function (me) {
      username = (me && me.username) || '';
      if (!username) return false;
      showConfirm(username);
      return true;
    }).catch(function () {
      token = '';
      return false;
    });
  }

  function login() {
    if (busy) return;
    var u = $('u').value.trim();
    var p = $('p').value;
    var t = $('t').value.trim();
    if (!u || !p) { setErr('请填写账号和密码'); return; }
    busy = true;
    elLoginBtn.disabled = true;
    setErr('');
    api('/api/v1/auth/login', { method: 'POST', body: { username: u, password: p, totp: t || undefined } })
      .then(function (res) {
        token = res.token;
        username = (res.user && res.user.username) || u;
        showConfirm(username);
      })
      .catch(function (e) { setErr(e.message || '登录失败'); })
      .then(function () { busy = false; elLoginBtn.disabled = false; });
  }

  function approve() {
    if (busy) return;
    var c = currentCode();
    if (!c) { setErr('请先填写电视上的短码'); return; }
    busy = true;
    elAllow.disabled = true;
    setErr('');
    var body = useShort ? { userCode: c } : { code: c };
    api('/api/v1/auth/device/approve', { method: 'POST', body: body })
      .then(function (res) {
        setState('已允许「' + ((res && res.username) || username) + '」登录，电视即将自动进入。', true);
        elConfirm.classList.add('hidden');
      })
      .catch(function (e) { setErr(e.message || '授权失败'); elAllow.disabled = false; })
      .then(function () { busy = false; });
  }

  elLoginBtn.addEventListener('click', login);
  elAllow.addEventListener('click', approve);
  elShort.addEventListener('input', function () {
    codeInput = elShort.value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6);
    elShort.value = codeInput;
    paintCode();
  });

  paintCode();
  if (useShort) {
    elShortWrap.classList.remove('hidden');
    setState('请输入电视上显示的 6 位短码。');
  }
  checkExisting().then(function (ok) {
    if (ok) return;
    if (!useShort) paintCode();
    showLogin();
  });
})();
</script>
</body>
</html>`;
}
