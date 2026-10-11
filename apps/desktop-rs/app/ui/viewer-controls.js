// Media-independent visibility: hiding the controls never mutes/disconnects.
class ViewerControls {
  constructor({ root, stage, toolbar, delay = 4000 }) {
    this.root = root;
    this.stage = stage;
    this.toolbar = toolbar;
    this.delay = delay;
    this.manual = false;
    this.busy = false;
    this.available = true;
    this.timer = null;
    this.visible = true;
    this.apply();
    this.schedule();
  }
  apply() {
    this.root.classList.toggle('controls-visible', this.visible);
    this.toolbar.inert = !this.visible;
    this.toolbar.setAttribute('aria-hidden', String(!this.visible));
    const heading = document.getElementById('viewer-heading');
    if (heading) { heading.inert = !this.visible; heading.setAttribute('aria-hidden', String(!this.visible)); }
  }
  schedule() {
    clearTimeout(this.timer);
    if (!this.visible || this.busy || !this.available) return;
    this.timer = setTimeout(() => {
      if (this.toolbar.matches(':hover') || this.toolbar.querySelector(':focus-visible')) {
        this.schedule(); return;
      }
      this.visible = false;
      this.apply();
    }, this.delay);
  }
  show() { this.manual = false; this.visible = true; this.apply(); this.schedule(); }
  hide() { this.manual = true; this.visible = false; clearTimeout(this.timer); this.apply(); }
  toggle() { if (this.visible) this.hide(); else this.show(); }
  interact() { if (!this.manual) this.show(); }
  setBusy(busy) { this.busy = busy; if (busy) this.show(); else this.schedule(); }
  setAvailable(available) {
    if (this.available === available) return;
    this.available = available;
    if (!available) this.show(); else this.schedule();
  }
}
if (typeof module !== 'undefined') module.exports = { ViewerControls };
