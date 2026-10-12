// A local layout preference; account, chat and media state stay owned by their existing modules.
(() => {
  const app = document.getElementById('app');
  const toggle = document.getElementById('sidebar-toggle');
  const connection = document.querySelector('.sidebar-connection');
  const connectionText = document.getElementById('server-text');
  const preference = 'remotescreen-sidebar-expanded-v1';
  function apply(expanded) {
    app.classList.toggle('sidebar-collapsed', !expanded);
    toggle.setAttribute('aria-expanded', String(expanded));
    toggle.setAttribute('aria-label', expanded ? '收起侧边栏' : '展开侧边栏');
    toggle.title = expanded ? '收起侧边栏' : '展开侧边栏';
  }
  let expanded = false;
  try { expanded = localStorage.getItem(preference) === 'true'; } catch (_) {}
  apply(expanded);
  toggle.addEventListener('click', () => {
    expanded = toggle.getAttribute('aria-expanded') !== 'true';
    apply(expanded);
    try { localStorage.setItem(preference, String(expanded)); } catch (_) {}
  });
  function updateConnectionLabel() {
    connection.title = connectionText.textContent;
    connection.setAttribute('aria-label', connectionText.textContent);
  }
  new MutationObserver(updateConnectionLabel).observe(connectionText, {childList:true, characterData:true, subtree:true});
  updateConnectionLabel();
})();
