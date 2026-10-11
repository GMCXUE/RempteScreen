(() => {
 const {invoke,convertFileSrc}=window.__TAURI__.core,$=id=>document.getElementById(id),mini=$('mini');
 let call=null,docked=false,disposed=false,busy=false,revision=0,pointer=null,dragging=false,dockTimer=null,abortFrame=null;
 function clearFrame(){$('video').hidden=true;$('video').removeAttribute('src');$('placeholder').hidden=false;}
 function layout(data){docked=!!data.docked;mini.classList.toggle('docked',docked);$('handle').hidden=!docked;$('handle').textContent=data.dockSide<0?'›':'‹';mini.setAttribute('aria-label',docked?'展开视频悬浮窗':'视频通话，点击返回，拖到边缘收起');}
 function apply(data){const changed=call?.id!==data?.id;if(changed){++revision;abortFrame?.();clearFrame();}call=data;if(!call)return;layout(call);if(changed){window.accountAvatars.render($('avatar'),{id:call.peerId,avatarId:call.peerAvatarId,avatarRevision:call.peerAvatarRevision});$('name').textContent=call.peerName;}if(!call.remoteCamera)clearFrame();}
 async function open(){if(!call)return;try{if(docked)layout(await invoke('dock_friend_call_mini',{callId:call.id,restore:true}));else await invoke('friend_call_window_action',{callId:call.id,action:'restore'});}catch(error){console.error(error);}}
 function armDock(){if(!dragging)return;clearTimeout(dockTimer);dockTimer=setTimeout(async()=>{dragging=false;if(!call||call.visible)return;try{layout(await invoke('dock_friend_call_mini',{callId:call.id,restore:false}));}catch(_){}},400);}
 mini.addEventListener('pointerdown',e=>{if(e.button!==0)return;pointer={x:e.clientX,y:e.clientY,id:e.pointerId};dragging=false;mini.setPointerCapture(e.pointerId);});
 mini.addEventListener('pointermove',e=>{if(!pointer||Math.hypot(e.clientX-pointer.x,e.clientY-pointer.y)<4)return;pointer=null;dragging=true;window.__TAURI__.window.getCurrentWindow().startDragging().then(armDock).catch(()=>{dragging=false;});});
 mini.addEventListener('pointerup',()=>{if(pointer&&!dragging)open();pointer=null;});mini.addEventListener('pointercancel',()=>{pointer=null;});
 mini.addEventListener('keydown',e=>{if(['Enter',' '].includes(e.key)){e.preventDefault();open();}});
 const stops=[];let stateReceived=false;
 window.__TAURI__.event.listen('friend-call-window:state',({payload})=>{stateReceived=true;apply(payload);}).then(async stop=>{stops.push(stop);const snapshot=await invoke('get_friend_call_window_state');if(!stateReceived)apply(snapshot);});
 window.__TAURI__.event.listen('friend-call-mini:layout',({payload})=>layout(payload)).then(stop=>stops.push(stop));
 window.__TAURI__.event.listen('friend-call-mini:moved',armDock).then(stop=>stops.push(stop));
 const frames=setInterval(()=>{
  if(!call||call.visible||docked||disposed||busy||document.hidden)return;
  if(!call.remoteCamera){clearFrame();return;}busy=true;const id=call.id,version=revision,frame=new Image();
  const finish=()=>{clearTimeout(timeout);frame.onload=frame.onerror=null;busy=false;abortFrame=null;};
  const timeout=setTimeout(()=>{finish();clearFrame();frame.src='';},3000);abortFrame=()=>{finish();frame.src='';};
  frame.onload=()=>{if(call?.id===id&&version===revision&&call.remoteCamera){$('video').src=frame.src;$('video').hidden=false;$('placeholder').hidden=true;}finish();};
  frame.onerror=()=>{if(call?.id===id&&version===revision)clearFrame();finish();};
  frame.src=`${convertFileSrc('latest','friendcamera')}?t=${performance.now()}`;
 },80);
 const clock=setInterval(()=>{if(!call)return;const seconds=Math.max(0,Math.floor((Date.now()-(call.acceptedAt||Date.now()))/1000));$('clock').textContent=`${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`;},1000);
 const heartbeat=setInterval(()=>{if(call&&!call.visible)invoke('friend_call_status',{speaker:null}).catch(()=>{});},2000);
 window.addEventListener('beforeunload',()=>{disposed=true;++revision;abortFrame?.();clearTimeout(dockTimer);[frames,clock,heartbeat].forEach(clearInterval);stops.forEach(stop=>stop());});
})();
