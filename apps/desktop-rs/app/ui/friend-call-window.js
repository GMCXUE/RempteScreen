(() => {
 const {invoke,convertFileSrc}=window.__TAURI__.core,$=id=>document.getElementById(id),stage=$('call-stage');
 let call=null,swapped=false,visible=true,hideTimer=null,fullscreen=false,fill=false,revision=0,disposed=false;
 const fetching={remote:false,local:false},abortFrames={};
 function setControls(show){visible=show;stage.classList.toggle('controls-hidden',!show);for(const id of ['call-header','call-controls'])$(id).inert=!show;armHide();}
 function armHide(){clearTimeout(hideTimer);if(visible&&call&&!call.connecting&&!call.busy)hideTimer=setTimeout(()=>setControls(false),4000);}
 function layout(){$('remote-surface').className=`video-surface ${swapped?'small-video':'main-video'} ${$('remote-video').hidden?'':'has-frame'}`;$('local-surface').className=`video-surface ${swapped?'main-video':'small-video'} ${$('local-video').hidden?'':'has-frame'}`;for(const source of ['remote','local']){const surface=$(source+'-surface');const small=surface.classList.contains('small-video');surface.setAttribute('role',small?'button':'img');surface.tabIndex=small?0:-1;surface.setAttribute('aria-label',small?'切换双方画面':source==='local'?'自己的视频':'对方视频');}}
 function swap(){swapped=!swapped;layout();armHide();}
 function setFit(value){fill=value;stage.classList.toggle('video-fill',fill);window.uiIcons.button($('video-fit'),'expand',fill?'完整画面':'铺满画面');$('video-fit').setAttribute('aria-pressed',String(fill));armHide();}
 setFit(false);$('video-fit').onclick=()=>setFit(!fill);
 for(const source of ['remote','local']){const surface=$(source+'-surface');surface.addEventListener('click',event=>{if(surface.classList.contains('small-video')){event.stopPropagation();swap();}});surface.addEventListener('keydown',event=>{if(surface.classList.contains('small-video')&&['Enter',' '].includes(event.key)){event.preventDefault();event.stopPropagation();swap();}});}
 function clearFrame(source){$(source+'-video').hidden=true;$(source+'-video').removeAttribute('src');$(source+'-surface').classList.remove('has-frame');}
 function frame(source){
  if(!call||!call.visible||disposed||fetching[source]||document.hidden)return;
  if(source==='local'&&!call.camera){clearFrame(source);return;}
  fetching[source]=true;const id=call.id,version=revision,next=new Image();
  const finish=()=>{clearTimeout(timeout);next.onload=next.onerror=null;fetching[source]=false;delete abortFrames[source];};
  const timeout=setTimeout(()=>{finish();if(version===revision)clearFrame(source);next.src='';},3000);abortFrames[source]=()=>{finish();next.src='';};
  next.onload=()=>{if(version===revision&&call?.id===id&&(source!=='local'||call.camera)){$(source+'-video').src=next.src;$(source+'-video').hidden=false;$(source+'-surface').classList.add('has-frame');}finish();};
  next.onerror=()=>{if(version===revision)clearFrame(source);finish();};
  next.src=`${convertFileSrc('latest',source==='local'?'friendlocalcamera':'friendcamera')}?t=${performance.now()}`;
 }
 function clock(){if(!call)return;$('call-status').textContent=call.connecting?'正在连接通话…':(()=>{const seconds=Math.max(0,Math.floor((Date.now()-(call.acceptedAt||Date.now()))/1000));return `${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`;})();}
 function apply(data){
  if(disposed)return;const changed=call?.id!==data?.id,wasConnecting=call?.connecting,wasVisible=call?.visible;
  if(changed){++revision;Object.values(abortFrames).forEach(abort=>abort());clearFrame('remote');clearFrame('local');swapped=false;setFit(false);layout();}
  call=data;if(!call){$('call-status').textContent='通话已结束';return;}
  if(changed){$('peer-name').textContent=call.peerName;window.accountAvatars.render($('remote-avatar'),{id:call.peerId,avatarId:call.peerAvatarId,avatarRevision:call.peerAvatarRevision});window.accountAvatars.render($('local-avatar'),call.me||'cat');$('remote-caption').textContent=call.peerName;setControls(true);}
  $('local-placeholder').textContent=call.camera?'正在打开摄像头…':'摄像头已关闭';if(!call.camera)clearFrame('local');
  $('remote-placeholder').textContent=call.connecting?'正在连接通话…':'等待对方视频';
  window.uiIcons.button($('microphone'),call.microphone?'mic':'micOff',call.microphone?'静音':'取消静音');
  window.uiIcons.button($('camera'),call.camera?'video':'videoOff',call.camera?'关闭摄像头':'打开摄像头');
  window.uiIcons.button($('speaker'),call.speaker?'speaker':'speakerOff',call.speaker?'关闭声音':'打开声音');
  for(const [id,selected] of [['microphone',!call.microphone],['camera',call.camera],['speaker',call.speaker]]){$(id).classList.toggle('selected',selected);$(id).setAttribute('aria-pressed',String(selected));$(id).disabled=call.busy||call.connecting;}
  window.uiIcons.button($('hangup'),'hangup','挂断');$('hangup').disabled=call.busy;
  $('call-error').textContent=call.error||'';$('call-error').hidden=!call.error;
  if(wasConnecting&&!call.connecting)armHide();if(!wasVisible&&call.visible)setControls(true);clock();
 }
 async function action(action){if(!call)return;armHide();try{await invoke('friend_call_window_action',{callId:call.id,action});}catch(error){$('call-error').textContent=String(error);$('call-error').hidden=false;setControls(true);}}
 for(const name of ['microphone','camera','speaker','hangup','fold'])$(name).onclick=()=>action(name);
 window.uiIcons.button($('fold'),'down','收起通话');
 async function setFullscreen(value){try{await window.__TAURI__.window.getCurrentWindow().setFullscreen(value);fullscreen=value;window.uiIcons.button($('fullscreen'),'expand',value?'退出全屏':'全屏');armHide();}catch(error){$('call-error').textContent='无法切换全屏，请重试';$('call-error').hidden=false;setControls(true);}}
 window.uiIcons.button($('fullscreen'),'expand','全屏');$('fullscreen').onclick=()=>setFullscreen(!fullscreen);
 $('hide-controls').onclick=()=>setControls(false);$('show-controls').onclick=()=>setControls(true);
 stage.addEventListener('click',event=>{if(event.target.closest('button')||event.target.closest('.small-video'))return;setControls(!visible);});
 stage.addEventListener('pointermove',()=>{if(visible)armHide();});
 window.addEventListener('keydown',event=>{if(event.key==='Escape'){setFullscreen(false);setControls(true);}else if(event.key===' '&&!event.target.closest('button,[role="button"]')){event.preventDefault();setControls(!visible);}});
 let unlisten,stateReceived=false;const ready=window.__TAURI__.event.listen('friend-call-window:state',({payload})=>{stateReceived=true;apply(payload);});
 ready.then(async stop=>{unlisten=stop;const snapshot=await invoke('get_friend_call_window_state');if(!stateReceived)apply(snapshot);}).catch(error=>{$('call-error').textContent=String(error);$('call-error').hidden=false;});
 const frames=setInterval(()=>{frame('remote');frame('local');},16),timer=setInterval(clock,1000);
 const heartbeat=setInterval(()=>{if(call?.visible)invoke('friend_call_status',{speaker:null}).catch(()=>{});},2000);
 window.addEventListener('beforeunload',()=>{disposed=true;clearInterval(frames);clearInterval(timer);clearInterval(heartbeat);clearTimeout(hideTimer);Object.values(abortFrames).forEach(abort=>abort());unlisten?.();});
})();
