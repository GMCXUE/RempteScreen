const video = document.getElementById('video');
const shell = document.getElementById('shell');
let busy = false;
setInterval(() => {
  if (busy) return;
  busy = true;
  const frame = new Image();
  frame.onload = () => { video.src = frame.src; video.hidden = false; shell.classList.add('connected'); busy = false; };
  frame.onerror = () => { video.hidden = true; shell.classList.remove('connected'); busy = false; };
  frame.src = `callcamera://localhost/latest?t=${performance.now()}`;
}, 100);

let folded = false;
async function toggleFold() {
  const next = !folded;
  await window.__TAURI__.core.invoke('fold_call_window', { folded: next });
  folded = next;
  shell.classList.toggle('folded', folded);
}
document.getElementById('fold').addEventListener('click', (event) => {
  event.stopPropagation(); toggleFold().catch(console.error);
});
let pointer = null;
shell.addEventListener('pointerdown', (event) => {
  if (event.target.closest('button') || event.button !== 0) return;
  pointer = { x: event.clientX, y: event.clientY };
  shell.setPointerCapture(event.pointerId);
});
shell.addEventListener('pointermove', (event) => {
  if (!pointer || Math.hypot(event.clientX - pointer.x, event.clientY - pointer.y) < 4) return;
  pointer = null;
  window.__TAURI__.window.getCurrentWindow().startDragging().catch(console.error);
});
shell.addEventListener('pointerup', () => {
  if (pointer && folded) toggleFold().catch(console.error);
  pointer = null;
});
shell.addEventListener('pointercancel', () => { pointer = null; });
