(() => {
 const $=id=>document.getElementById(id),invoke=(name,args)=>window.__TAURI__.core.invoke(name,args),stage=$('image-stage'),photo=$('image-photo');
 let version=0,ready=false,scale=1,rotation=0,x=0,y=0,fitted=true,drag=null,toastTimer;
 const paths={out:['M10 3a7 7 0 1 0 0 14a7 7 0 1 0 0-14','m15 15 6 6','M7 10h6'],in:['M10 3a7 7 0 1 0 0 14a7 7 0 1 0 0-14','m15 15 6 6','M7 10h6M10 7v6'],rotate:['M4 11a8 8 0 1 1 3 7','M4 5v6h6'],close:['m6 6 12 12M6 18 18 6']};
 function icon(id,name){const button=$(id);if(!paths[name])button.append(window.uiIcons.create(name));else{const svg=window.uiIcons.create('file');svg.replaceChildren();for(const d of paths[name]){const p=document.createElementNS(svg.namespaceURI,'path');p.setAttribute('d',d);svg.append(p);}button.append(svg);}}
 for(const [id,name] of [['image-fit','expand'],['image-out','out'],['image-in','in'],['image-rotate','rotate'],['image-copy','copy'],['image-close','close']])icon(id,name);
 function bounds(){return rotation%180?{w:photo.naturalHeight,h:photo.naturalWidth}:{w:photo.naturalWidth,h:photo.naturalHeight};}
 function fitScale(){const b=bounds();return Math.min(1,(stage.clientWidth-32)/b.w,(stage.clientHeight-32)/b.h);}
 function render(){if(!ready)return;const b=bounds();x=Math.max(-Math.max(0,(b.w*scale-stage.clientWidth)/2),Math.min(Math.max(0,(b.w*scale-stage.clientWidth)/2),x));y=Math.max(-Math.max(0,(b.h*scale-stage.clientHeight)/2),Math.min(Math.max(0,(b.h*scale-stage.clientHeight)/2),y));photo.style.width=`${photo.naturalWidth}px`;photo.style.height=`${photo.naturalHeight}px`;photo.style.transform=`translate(-50%,-50%) translate(${x}px,${y}px) rotate(${rotation}deg) scale(${scale})`;$('image-scale').textContent=`${Math.round(scale*100)}%`;$('image-out').disabled=scale<=.05;$('image-in').disabled=scale>=8;stage.classList.toggle('zoomed',b.w*scale>stage.clientWidth||b.h*scale>stage.clientHeight);}
 function fit(){if(!ready)return;fitted=true;scale=fitScale();x=y=0;render();}
 function zoom(value){if(!ready)return;fitted=false;scale=Math.max(.05,Math.min(8,value));render();}
 function notice(text){clearTimeout(toastTimer);$('image-toast').textContent=text;$('image-toast').hidden=false;toastTimer=setTimeout(()=>$('image-toast').hidden=true,1400);}
 async function load(){const v=++version;ready=false;photo.hidden=true;photo.removeAttribute('src');rotation=0;x=y=0;drag=null;stage.classList.remove('dragging','zoomed');$('image-state').hidden=false;$('image-status').textContent='正在加载图片…';$('image-retry').hidden=true;$('image-scale').textContent='—';for(const b of document.querySelectorAll('.image-tools button'))b.disabled=true;
  try{const result=await invoke('get_chat_image');if(v!==version)return;if(typeof result.image!=='string'||!result.image.startsWith('data:image/jpeg;base64,'))throw '无法读取图片';const image=new Image();image.src=result.image;await image.decode();if(v!==version)return;photo.src=result.image;await photo.decode();if(v!==version)return;ready=true;photo.hidden=false;$('image-state').hidden=true;for(const b of document.querySelectorAll('.image-tools button'))b.disabled=false;fit();}
  catch(error){if(v!==version)return;$('image-status').textContent=String(error);$('image-retry').hidden=false;}
 }
 $('image-fit').onclick=fit;$('image-original').onclick=()=>{x=y=0;zoom(1);};$('image-in').onclick=()=>zoom(scale*1.25);$('image-out').onclick=()=>zoom(scale/1.25);$('image-rotate').onclick=()=>{rotation=(rotation+90)%360;fit();};$('image-retry').onclick=load;
 $('image-copy').onclick=async()=>{const v=version;$('image-copy').disabled=true;try{await invoke('copy_viewed_chat_image');if(v===version)notice('图片已复制');}catch(error){if(v===version)notice(String(error));}finally{if(v===version)$('image-copy').disabled=!ready;}};
 $('image-close').onclick=()=>window.__TAURI__.window.getCurrentWindow().close();
 stage.addEventListener('wheel',e=>{e.preventDefault();zoom(scale*(e.deltaY<0?1.15:1/1.15));},{passive:false});
 stage.ondblclick=()=>{if(fitted){x=y=0;zoom(1);}else fit();};
 stage.onpointerdown=e=>{if(!ready||e.button!==0||!stage.classList.contains('zoomed'))return;drag={id:e.pointerId,x:e.clientX,y:e.clientY,px:x,py:y};stage.setPointerCapture(e.pointerId);stage.classList.add('dragging');};
 stage.onpointermove=e=>{if(!drag||e.pointerId!==drag.id)return;x=drag.px+e.clientX-drag.x;y=drag.py+e.clientY-drag.y;render();};
 stage.onpointerup=stage.onpointercancel=()=>{drag=null;stage.classList.remove('dragging');};
 new ResizeObserver(()=>{if(fitted)fit();else render();}).observe(stage);
 document.addEventListener('keydown',e=>{if(e.key==='Escape')$('image-close').click();else if(e.key==='+'||e.key==='=')zoom(scale*1.25);else if(e.key==='-')zoom(scale/1.25);else if(e.key==='0')fit();else if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='c'){e.preventDefault();if(ready&&!$('image-copy').disabled)$('image-copy').click();}});
 window.__TAURI__.event.listen('chat-image-context',()=>load()).then(load).catch(error=>{$('image-status').textContent=String(error);$('image-retry').hidden=false;});
})();
