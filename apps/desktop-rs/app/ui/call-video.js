const video = document.getElementById('video');
const shell = document.getElementById('shell');
let busy = false;
let disposed = false;
let abortFrame = null;
const frames = setInterval(() => {
  if (busy || disposed || document.hidden) return;
  busy = true;
  const frame = new Image();
  const finish = () => { clearTimeout(timeout); frame.onload = frame.onerror = null; busy = false; abortFrame = null; };
  const timeout = setTimeout(() => { finish(); frame.src = ''; }, 3000);
  abortFrame = () => { finish(); frame.src = ''; };
  frame.onload = () => { video.src = frame.src; video.hidden = false; shell.classList.add('connected'); finish(); };
  frame.onerror = () => { video.hidden = true; shell.classList.remove('connected'); finish(); };
  frame.src = `${window.__TAURI__.core.convertFileSrc('latest', 'callcamera')}?t=${performance.now()}`;
}, 16);
window.addEventListener('beforeunload', () => { disposed = true; clearInterval(frames); abortFrame?.(); });

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
