/* The native updater verifies signed metadata, package hashes and installed versions. */
(() => {
  const invoke = window.__TAURI__.core.invoke;
  const dialog = document.createElement('dialog');
  dialog.className = 'app-update-dialog';
  dialog.setAttribute('aria-labelledby', 'app-update-title');
  dialog.innerHTML = `<div class="app-update-mark" aria-hidden="true">↑</div><h2 id="app-update-title" class="app-update-title">检查更新</h2><p class="app-update-required"></p><div class="app-update-notes"></div><progress max="1" value="0" hidden></progress><p class="app-update-notice" role="status"></p><p class="app-update-error" role="alert"></p><div class="app-update-actions"><button class="app-update-later ghost">稍后</button><button class="app-update-retry ghost">重新检查更新</button><button class="app-update-primary">下载更新</button></div>`;
  document.body.append(dialog);
  const el = name => dialog.querySelector('.app-update-' + name);
  let initializing = true;
  let release = null, busy = false, checking = false, prepared = false, error = '', notice = '', progress = 0, away = false;
  let allowStartup;
  const ready = new Promise(resolve => { allowStartup = resolve; });
  const forced = () => release?.forceUpdate === true;
  function render() {
    el('title').textContent = release ? `发现新版本 ${release.versionName}` : '检查更新';
    el('required').textContent = forced() ? '此版本需要更新后才能继续使用。' : '';
    el('notes').textContent = release?.notes || '';
    el('notice').textContent = notice;
    el('error').textContent = error;
    el('later').hidden = forced() || initializing; el('later').disabled = busy;
    el('later').textContent = release ? '稍后' : '关闭';
    el('retry').hidden = !error; el('retry').disabled = busy || checking;
    el('retry').textContent = checking ? '正在检查…' : '重新检查更新';
    el('primary').hidden = !release; el('primary').disabled = busy || checking;
    el('primary').textContent = busy ? (prepared ? '正在准备安装…' : `正在下载 ${Math.floor(progress * 100)}%`) : prepared ? '结束会话并安装更新' : '下载更新';
    dialog.querySelector('progress').hidden = !busy || prepared;
    dialog.querySelector('progress').value = progress;
  }
  function show() { render(); if (!dialog.open) dialog.showModal(); }
  function defer() { if (forced() || busy || initializing) return; dialog.close(); allowStartup(); }
  dialog.addEventListener('cancel', event => { event.preventDefault(); defer(); });
  // Only explicit choices dismiss an optional update. Backdrop clicks never dismiss a requirement.
  el('later').onclick = defer;
  async function check(manual = false) {
    if (checking || busy) return;
    checking = true; error = ''; if (manual) {notice = '正在检查更新…'; show();}
    try {
      const result = await invoke('update_check');
      if (release?.sha256 !== result.release?.sha256) prepared = false;
      release = result.release; error = result.error || ''; notice = !release && !error ? '已是最新版本' : '';
      if (release || manual || forced()) show(); else if (dialog.open) dialog.close();
      if (!forced()) allowStartup();
    } catch (_) { error = '暂时无法检查更新，请检查网络后重试'; if (manual || forced()) show(); if (!forced()) allowStartup(); }
    finally { initializing = false; checking = false; render(); }
  }
  el('retry').onclick = () => check(true);
  el('primary').onclick = async () => {
    if (busy || !release) return;
    busy = true; error = ''; render();
    try {
      if (prepared) {
        await window.friendCalls?.logout();
        await invoke('update_install');
      } else {
        await invoke('update_download'); prepared = true;
        notice = '下载完成。安装前将结束当前通话、投屏和文件传输。';
      }
    } catch (e) { error = String(e); }
    finally { busy = false; render(); }
  };
  window.__TAURI__.event.listen('app-update:progress', event => { progress = event.payload; render(); });
  document.getElementById('settings-check-update').onclick = () => check(true);
  invoke('update_info').then(info => {document.getElementById('settings-version').textContent = info.versionName;}).catch(() => {});
  // Debounce brief focus changes (menus, permission panels). Each genuine return checks once.
  let focusTimer;
  window.addEventListener('blur', () => { clearTimeout(focusTimer); focusTimer = setTimeout(() => {away = true;}, 700); });
  window.addEventListener('focus', () => { clearTimeout(focusTimer); if (away) {away = false; check();} });
  window.appUpdates = {ready, check: () => check(true), get required() {return forced();}};
  notice = '正在检查更新…'; show();
  check();
})();
