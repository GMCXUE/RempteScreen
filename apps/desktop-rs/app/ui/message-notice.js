// Chat previews have their own surface; operation/error feedback keeps its toast.
(() => {
  const card = document.getElementById('message-notice');
  if (!card) return;
  const get = id => document.getElementById(`message-notice-${id}`);
  let current = null, timer, remaining = 6500, started = 0;
  function dismiss(peerId) {
    if (peerId && current?.peerId !== peerId) return;
    clearTimeout(timer);
    current = null;
    card.classList.add('hidden');
    for (const id of ['avatar', 'name', 'body', 'time']) get(id).replaceChildren();
    get('time').removeAttribute('datetime');
    get('time').removeAttribute('title');
  }
  function resume() {
    clearTimeout(timer);
    if (!current || card.matches(':hover, :focus-within')) return;
    started = performance.now();
    timer = setTimeout(() => dismiss(), remaining);
  }
  function pause() {
    clearTimeout(timer);
    if (started) remaining = Math.max(0, remaining - (performance.now() - started));
    started = 0;
  }
  function show(notice, open) {
    dismiss();
    current = {...notice, open};
    const preview = notice.preview !== false;
    get('name').textContent = preview ? String(notice.name || '好友') : 'RemoteScreen';
    get('body').textContent = preview ? String(notice.message || '新消息') : '收到新消息';
    if (preview) window.accountAvatars?.render(get('avatar'), {id: notice.peerId, avatarId: notice.avatarId, avatarRevision: notice.avatarRevision});
    else get('avatar').append(window.uiIcons.create('message'));
    const sent = new Date(Number(notice.sentAt)), now = new Date();
    if (Number(notice.sentAt) > 0 && !Number.isNaN(sent.getTime())) {
      const sameDay = sent.toDateString() === now.toDateString();
      get('time').textContent = sent.toLocaleString('zh-CN', {...(!sameDay ? {month: '2-digit', day: '2-digit', ...(sent.getFullYear() !== now.getFullYear() ? {year: 'numeric'} : {})} : {}), hour: '2-digit', minute: '2-digit', hour12: false});
      get('time').dateTime = sent.toISOString();
      get('time').title = sent.toLocaleString('zh-CN', {hour12: false});
    } else get('time').textContent = '时间未知';
    remaining = 6500; started = 0;
    card.classList.remove('hidden');
    resume();
  }
  get('close').onclick = () => dismiss();
  get('open').onclick = async () => {
    const action = current?.open;
    dismiss();
    if (action) await action();
  };
  card.addEventListener('mouseenter', pause);
  card.addEventListener('mouseleave', resume);
  card.addEventListener('focusin', pause);
  card.addEventListener('focusout', () => queueMicrotask(resume));
  card.addEventListener('keydown', event => { if (event.key === 'Escape') { dismiss(); event.stopPropagation(); } });
  window.addEventListener('social-account-changed', () => dismiss());
  window.addEventListener('blur', () => dismiss());
  document.addEventListener('visibilitychange', () => { if (document.hidden) dismiss(); });
  window.messageNotices = {show, dismiss};
})();
