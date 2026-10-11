// Crop the selected local photo before upload; no original file leaves the device.
window.cropAvatarPhoto = source => new Promise((resolve,reject) => {
 const photo=new Image();photo.onerror=()=>reject(new Error('无法读取图片，请选择 JPG、PNG 或 WebP 图片'));
 photo.onload=()=>{
  if(photo.naturalWidth*photo.naturalHeight>24000000){reject(new Error('图片尺寸过大，请选择较小的图片'));return;}
  const dialog=document.createElement('dialog');dialog.className='avatar-dialog crop-dialog';
  const title=document.createElement('h2');title.textContent='调整头像';
  const hint=document.createElement('p');hint.textContent='拖动图片调整位置';hint.className='muted small';
  const canvas=document.createElement('canvas');canvas.width=canvas.height=256;canvas.className='avatar-crop-canvas';canvas.setAttribute('aria-label','头像裁剪预览');
  const slider=document.createElement('input');slider.type='range';slider.min='1';slider.max='4';slider.step='.01';slider.value='1';slider.setAttribute('aria-label','缩放图片');
  let zoom=1,cx=photo.naturalWidth/2,cy=photo.naturalHeight/2,drag=null;
  const side=()=>Math.min(photo.naturalWidth,photo.naturalHeight)/zoom;
  const paint=()=>{const s=side();cx=Math.max(s/2,Math.min(photo.naturalWidth-s/2,cx));cy=Math.max(s/2,Math.min(photo.naturalHeight-s/2,cy));const ctx=canvas.getContext('2d');ctx.clearRect(0,0,256,256);ctx.drawImage(photo,cx-s/2,cy-s/2,s,s,0,0,256,256);};
  slider.oninput=()=>{zoom=Number(slider.value);paint();};
  canvas.onpointerdown=e=>{drag={x:e.clientX,y:e.clientY};canvas.setPointerCapture(e.pointerId);};
  canvas.onpointermove=e=>{if(!drag)return;const factor=side()/canvas.getBoundingClientRect().width;cx-=(e.clientX-drag.x)*factor;cy-=(e.clientY-drag.y)*factor;drag={x:e.clientX,y:e.clientY};paint();};
  canvas.onpointerup=canvas.onpointercancel=()=>{drag=null;};
  const actions=document.createElement('div');actions.className='avatar-dialog-actions';
  const cancel=document.createElement('button');cancel.textContent='取消';cancel.className='ghost';cancel.onclick=()=>dialog.close();
  const done=document.createElement('button');done.textContent='使用照片';done.className='primary';done.onclick=()=>{resolve(canvas.toDataURL('image/png'));dialog.close();};
  dialog.addEventListener('close',()=>{dialog.remove();resolve(null);},{once:true});actions.append(cancel,done);dialog.append(title,hint,canvas,slider,actions);document.body.append(dialog);dialog.showModal();paint();done.focus();
 };
 photo.src=source;
});
