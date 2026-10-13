// Finite, interruptible motion. No animation is responsible for hiding an element:
// existing view state stays authoritative, so closing never leaves a hit target.
(() => {
  const preference = window.matchMedia('(prefers-reduced-motion: reduce)');
  const active = new Map();
  const visibleState = new WeakMap();
  const selector = '.page, .login-card, .modal, dialog, .user-menu, .chat-context-menu, .chat-settings, .ft-toast, #image-toast, .pending';
  const easing = 'cubic-bezier(.2, .8, .2, 1)';
  const visible = element => element.isConnected && !document.hidden &&
    !element.closest('.hidden, [hidden], dialog:not([open])') && element.getClientRects().length > 0;

  function cancel(element) {
    const animation = active.get(element);
    if (animation) { active.delete(element); animation.cancel(); }
  }
  function enter(element, kind = 'content') {
    cancel(element);
    if (preference.matches || !visible(element) || typeof element.animate !== 'function') return;
    // Keep existing positioning transforms (for example a horizontally centred toast).
    const transform = getComputedStyle(element).transform;
    const base = transform === 'none' ? '' : transform;
    const surface = kind === 'surface', fade = kind === 'fade';
    // A negative message offset stays inside the scrollable content's bottom
    // edge; a positive offset would briefly inflate scrollHeight and detach it.
    const offset = kind === 'message' ? 'translateY(-4px)' : kind === 'drawer' ? 'translateX(16px)' :
      kind === 'toast' ? 'translateY(-6px)' : surface ? 'translateY(8px) scale(.985)' : 'translateY(6px)';
    const animation = element.animate([
      { opacity: 0, transform: `${base} ${fade ? '' : offset}`.trim() || 'none' },
      { opacity: 1, transform: base || 'none' },
    ], { duration: surface || kind === 'drawer' ? 240 : kind === 'menu' ? 120 : 200, easing });
    active.set(element, animation);
    animation.onfinish = animation.oncancel = () => {
      if (active.get(element) === animation) active.delete(element);
    };
  }
  function continueOn(previous, element) {
    const animation = active.get(previous);
    if (!animation) return;
    const frames = animation.effect.getKeyframes(), timing = animation.effect.getTiming(), time = animation.currentTime;
    cancel(previous);
    if (preference.matches || document.hidden) return;
    const replacement = element.animate(frames, timing);
    replacement.currentTime = time;
    active.set(element, replacement);
    replacement.onfinish = replacement.oncancel = () => {
      if (active.get(element) === replacement) active.delete(element);
    };
  }

  function inspect(element) {
    const showing = visible(element), wasShowing = visibleState.get(element) === true;
    visibleState.set(element, showing);
    if (!showing) {
      for (const target of active.keys()) if (target === element || element.contains(target)) cancel(target);
      return;
    }
    if (wasShowing) return;
    if (element.matches('.modal')) {
      enter(element, 'fade');
      const card = element.querySelector('.modal-card');
      if (card) enter(card, 'surface');
    } else enter(element, element.matches('dialog, .login-card') ? 'surface' :
      element.matches('.chat-settings') ? 'drawer' : element.matches('.user-menu, .chat-context-menu') ? 'menu' :
      element.matches('.ft-toast, #image-toast') ? 'toast' : 'content');
  }
  function collect(element, targets) {
    if (!(element instanceof Element)) return;
    if (element.matches(selector)) targets.add(element);
    for (const candidate of element.querySelectorAll(selector)) targets.add(candidate);
  }
  // Do not replay on every polling render, text change or video frame. Inspect
  // only registered surfaces whose visibility (or an ancestor's) could change.
  const observer = new MutationObserver(records => {
    const targets = new Set();
    for (const record of records) {
      if (record.type === 'attributes') collect(record.target, targets);
      else for (const added of record.addedNodes) collect(added, targets);
    }
    for (const target of active.keys()) if (!target.isConnected || !visible(target)) cancel(target);
    for (const target of targets) inspect(target);
  });
  for (const element of document.querySelectorAll(selector)) visibleState.set(element, visible(element));
  observer.observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ['class', 'hidden', 'open'] });
  const stop = () => { for (const target of active.keys()) cancel(target); };
  preference.addEventListener('change', () => { if (preference.matches) stop(); });
  document.addEventListener('visibilitychange', () => { if (document.hidden) stop(); });
  window.addEventListener('pagehide', stop);
  window.appMotion = { enter, cancel, continueOn, get reduced() { return preference.matches; } };
})();
