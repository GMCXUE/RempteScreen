/* Resource patches activate on process restart, never while a media session owns the UI. */
(() => {
  const invoke = window.__TAURI__.core.invoke;
  let startupFailed = false;
  window.addEventListener('error', () => { startupFailed = true; });
  const dialog = document.createElement('dialog');
  dialog.className = 'app-update-dialog';
  dialog.innerHTML = '<h2>界面更新</h2><div class="app-update-notes"></div><p class="app-update-notice" role="status"></p><p class="app-update-error" role="alert"></p><div class="app-update-actions"><button class="ghost" data-later>稍后</button><button data-apply>下载更新</button></div>';
  document.body.append(dialog);
  let busy = false, checking = false, staged = false, revision = null;
  const notice = dialog.querySelector('.app-update-notice'), failure = dialog.querySelector('.app-update-error');
  const primary = dialog.querySelector('[data-apply]');
  function close() { if (!busy) dialog.close(); }
  dialog.querySelector('[data-later]').onclick = close;
  dialog.addEventListener('cancel', e => { e.preventDefault(); close(); });
  primary.onclick = async () => {
    if (busy) return;
    busy = true; primary.disabled = true; failure.textContent = '';
    try {
      if (staged) {
        if (window.friendCalls?.current) throw Error('请先结束当前通话，再重新打开应用以应用更新');
        await invoke('hot_update_restart');
      } else {
        await invoke('hot_update_stage'); staged = true;
        notice.textContent = '更新已准备好，下次打开应用时生效。当前通话、投屏和文件传输可继续。';
        primary.textContent = '重新打开应用';
      }
    } catch (e) { failure.textContent = String(e); }
    finally { busy = false; primary.disabled = false; }
  };
  async function check(manual = false) {
    if (busy || checking) return false;
    checking = true;
    try {
      const result = await invoke('hot_update_check');
      if (!result.patch) return false;
      if (revision !== result.patch.revision) staged = result.staged;
      revision = result.patch.revision;
      dialog.querySelector('.app-update-notes').textContent = result.patch.notes;
      notice.textContent = staged ? '更新已准备好，下次打开应用时生效。' : '这次更新无需下载安装包，下次打开应用时生效。';
      failure.textContent = ''; primary.textContent = staged ? '重新打开应用' : '下载更新';
      if (!dialog.open) dialog.showModal();
      return true;
    } catch (_) {
      if (manual) window.showAppToast?.('暂时无法检查界面更新，请稍后重试');
      return false;
    } finally { checking = false; }
  }
  window.hotUpdates = { check };
  document.addEventListener('DOMContentLoaded', () => {
    // Missing essential UI initialization leaves the boot marker intact for native rollback.
    if (startupFailed || !window.appUpdates || !window.friendCalls || !document.getElementById('settings-check-update')) return;
    invoke('hot_update_ready').then(info => {
      if (info.rolledBack) window.showAppToast?.('界面更新启动失败，已恢复原有界面');
    }).catch(() => {});
    window.appUpdates.ready.then(() => {
      if (!window.appUpdates.hasRelease && !window.appUpdates.required) check();
    });
  });
})();
