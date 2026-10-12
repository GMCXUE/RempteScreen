// Shared UI feedback must be available before avatar/profile modules run.
(() => {
  let timer, revision = 0;
  window.showAppToast = (text, duration = 3500) => {
    const element = document.getElementById('ft-toast');
    if (!element) return;
    const current = ++revision;
    clearTimeout(timer);
    element.onclick = null;
    element.textContent = String(text);
    element.classList.remove('hidden');
    if (duration > 0) timer = setTimeout(() => element.classList.add('hidden'), duration);
    // Recovery may dismiss its own notice without hiding a newer operation's feedback.
    return () => {
      if (current !== revision) return;
      clearTimeout(timer);
      element.onclick = null;
      element.classList.add('hidden');
    };
  };
  window.addEventListener('social-account-changed', () => {
    ++revision;
    clearTimeout(timer);
    const element = document.getElementById('ft-toast');
    if (element) {
      element.onclick = null;
      element.classList.add('hidden');
    }
  });
})();
