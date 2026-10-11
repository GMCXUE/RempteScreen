// Shared UI feedback must be available before avatar/profile modules run.
(() => {
  let timer;
  window.showAppToast = (text, duration = 3500) => {
    const element = document.getElementById('ft-toast');
    if (!element) return;
    clearTimeout(timer);
    element.onclick = null;
    element.textContent = String(text);
    element.classList.remove('hidden');
    if (duration > 0) timer = setTimeout(() => element.classList.add('hidden'), duration);
  };
  window.addEventListener('social-account-changed', () => {
    clearTimeout(timer);
    const element = document.getElementById('ft-toast');
    if (element) {
      element.onclick = null;
      element.classList.add('hidden');
    }
  });
})();
