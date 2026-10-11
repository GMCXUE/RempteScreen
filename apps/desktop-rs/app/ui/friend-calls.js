// Global account call controls stay available while switching pages.
(() => {
 const invoke=window.__TAURI__.core.invoke,el=id=>document.getElementById(id);
 const stored=localStorage.getItem('friend-call-client');
 const clientId=stored||(crypto.randomUUID?.()||Array.from(crypto.getRandomValues(new Uint8Array(24)),b=>b.toString(16).padStart(2,'0')).join(''));localStorage.setItem('friend-call-client',clientId);
 const api=(operation,body={})=>invoke('social_api',{operation,body:{...body,clientId}});
 let current=null,joined=null,polling=false,busy=false,version=0,joining=false,lastSuccess=Date.now(),lastError='',cameraFetch=false;
 let mic=false,camera=false,speaker=true,remoteCamera=false,mediaConnecting=false,folded=false;
 let windowQueue=Promise.resolve(),windowSignature='',windowFailed=false,windowError='',windowVersion=0,closedVideoId=null;
 const ending=new Map();
 const reasons={hangup:'通话已结束',cancelled:'对方取消了通话',rejected:'对方拒绝了通话',unanswered:'对方未接听',offline:'对方已离线，通话已结束',friend_changed:'好友关系已变化，通话已结束'};
 function separateVideo(){return current?.kind==='video'&&current.status==='active'&&current.owned&&current.id!==closedVideoId;}
 function syncVideoWindow(data){
  const signature=JSON.stringify(data);if(signature===windowSignature)return windowQueue;
  windowSignature=signature;const request=++windowVersion;
  windowQueue=windowQueue.catch(()=>{}).then(async()=>{if(request!==windowVersion)return;await invoke('set_friend_call_window_state',{data,visible:!!data?.visible});if(request!==windowVersion)return;if(windowFailed&&lastError===windowError){lastError='';windowSignature='';}windowFailed=false;windowError='';}).catch(error=>{if(request!==windowVersion)return;windowSignature='';windowFailed=true;windowError=lastError=String(error);});
  return windowQueue;
 }
 function render(){
  invoke('set_call_notification_context',{ownedCallId:current?.status==='active'&&current.owned?current.id:null,dismissedCallId:null}).catch(()=>{});
  const separate=separateVideo();
  const me=window.accountAvatars?.me();
  syncVideoWindow(separate?{id:current.id,peerId:current.peerId,peerName:current.peerName,peerAvatarId:current.peerAvatarId,peerAvatarRevision:current.peerAvatarRevision,me:me?{id:me.id,avatarId:me.avatarId,avatarRevision:me.avatarRevision}:null,acceptedAt:current.acceptedAt,microphone:mic,camera,speaker,remoteCamera,connecting:joining||mediaConnecting,busy,visible:!folded,error:lastError}:null);
  const bar=el('friend-call-bar');bar.classList.toggle('hidden',!current||(separate&&!windowFailed));
  bar.classList.toggle('incoming',current?.status==='ringing'&&current.role==='callee');
  bar.classList.toggle('folded',folded);window.uiIcons.button(el('friend-call-fold'),folded?'return':'down',folded?'返回通话':'收起通话');
  if(!current)return;
  el('friend-call-name').textContent=current.peerName;
  window.accountAvatars?.render(el('friend-call-avatar'),{id:current.peerId,avatarId:current.peerAvatarId,avatarRevision:current.peerAvatarRevision});
  el('friend-call-status').textContent=lastError||(current.status==='ringing'?(current.role==='callee'?'邀请你进行':'正在等待对方接听 · ')+(current.kind==='video'?'视频通话':'语音通话'):(joining||mediaConnecting?'正在连接通话…':(current.kind==='video'?'视频通话中':'语音通话中')));
  el('friend-call-answer').classList.toggle('hidden',!(current.status==='ringing'&&current.role==='callee'));
  window.uiIcons.button(el('friend-call-answer'),'call','接通');
  window.uiIcons.button(el('friend-call-hangup'),'hangup',current.status==='ringing'?(current.role==='callee'?'挂断':'取消'):'挂断');
  el('friend-call-controls').classList.toggle('hidden',current.status!=='active');
  window.uiIcons.button(el('friend-call-mic'),mic?'mic':'micOff',mic?'静音':'取消静音');
  window.uiIcons.button(el('friend-call-camera'),camera?'video':'videoOff',camera?'关闭摄像头':'打开摄像头');
  el('friend-call-camera').classList.toggle('hidden',current.kind!=='video');
  window.uiIcons.button(el('friend-call-speaker'),speaker?'speaker':'speakerOff',speaker?'关闭声音':'打开声音');
  for(const [id,selected] of [['friend-call-mic',!mic],['friend-call-camera',camera],['friend-call-speaker',speaker]]){el(id).classList.toggle('selected',selected);el(id).setAttribute('aria-pressed',String(selected));}
  if(current.status==='active'&&!lastError&&!joining&&!mediaConnecting){const seconds=Math.max(0,Math.floor((Date.now()-(current.acceptedAt||Date.now()))/1000));el('friend-call-status').textContent=`${folded?'返回通话 · ':''}${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`;}
  bar.querySelectorAll('button').forEach(b=>b.disabled=busy||joining||mediaConnecting);
  // Hanging up must remain possible while media permissions/connect are pending.
  el('friend-call-hangup').disabled=busy;el('friend-call-fold').disabled=false;
 }
 async function closeLocal(restore=true){closedVideoId=current?.id||closedVideoId;syncVideoWindow(null);await invoke('close_friend_call_window').catch(()=>{});await invoke('set_call_notification_context',{ownedCallId:null,dismissedCallId:current?.id||null}).catch(()=>{});if(current)await invoke('stop_notification_ring',{callId:current.id}).catch(()=>{});folded=false;joined=null;mediaConnecting=false;joining=false;mic=camera=remoteCamera=false;el('friend-call-video').classList.add('hidden');el('friend-call-video').removeAttribute('src');const old=el('friend-call-video').dataset.url;if(old){URL.revokeObjectURL(old);delete el('friend-call-video').dataset.url;}await invoke('friend_call_stop',{restore});}
 async function sync(){
  if(polling||el('app').classList.contains('hidden'))return;
  polling=true;const generation=version;
  try{
   for(const [id,request] of ending){try{await api(request.operation,request.body);ending.delete(id);}catch(_){}}
   const data=await api('call-state',{skipCallIds:[...ending.keys()]});if(generation!==version)return;lastSuccess=Date.now();for(const c of data.calls){if(c.status==='ended')ending.delete(c.id);}
   const previous=current;
   const next=data.calls.find(c=>!ending.has(c.id)&&c.status!=='ended'&&(c.owned||(c.status==='ringing'&&c.role==='callee')));
   if(!next){
    if(previous){const ended=data.calls.find(c=>c.id===previous.id);lastError=ended?.status==='ended'?(ended.reason==='hangup'?'':(reasons[ended.reason]||'通话已结束')):'通话已在其他设备接听';
     await closeLocal();if(lastError)window.dispatchEvent(new CustomEvent('friend-call-notice',{detail:lastError}));}
    current=null;render();return;
   }
   current=next;if(current.status==='active')await invoke('stop_notification_ring',{callId:current.id}).catch(()=>{});
   if(current.status==='active'&&current.owned&&joined!==current.id&&!joining){
    joining=true;joined=current.id;render();
    const call=current;
    try{await invoke('friend_call_start',{url:call.grant.livekitUrl,token:call.grant.token,peerIdentity:call.grant.peerIdentity,video:call.kind==='video'});}
    catch(error){if(generation===version){lastError=String(error);await api('call-end',{callId:call.id});await closeLocal();current=null;window.dispatchEvent(new CustomEvent('friend-call-notice',{detail:lastError}));}}
    finally{joining=false;}
   }
   if(current?.status==='active'&&joined){
    const status=await invoke('friend_call_status',{speaker:null});
    mediaConnecting=status.status==='connecting';
    if(status.status==='ended'){lastError=status.error||'通话连接已断开';await api('call-end',{callId:current.id});await closeLocal();current=null;window.dispatchEvent(new CustomEvent('friend-call-notice',{detail:lastError}));}
    else{const media=await invoke('call_state',{scope:'friend'});mic=media.microphone;camera=media.camera;remoteCamera=media.remote_camera;speaker=media.speaker;if(status.error)lastError=status.error;}
   }
   render();
  }catch(error){
   if(generation!==version)return;lastError=String(error);
   if(current&&Date.now()-lastSuccess>30000){await closeLocal();current=null;window.dispatchEvent(new CustomEvent('friend-call-notice',{detail:'网络已断开，通话已结束'}));}
   render();
  }finally{polling=false;}
 }
 async function action(work){if(busy)return;busy=true;lastError='';render();try{await work();}catch(e){lastError=String(e);if(!current)window.dispatchEvent(new CustomEvent('friend-call-notice',{detail:lastError}));}finally{busy=false;render();}}
 window.friendCalls={handleNotification:async(id,actionId)=>{const deadline=Date.now()+16000;while(polling&&Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,50));await sync();if(current?.id!==id||!((current.status==='ringing'&&current.role==='callee')||(current.status==='active'&&current.owned))){window.dispatchEvent(new CustomEvent('friend-call-notice',{detail:'通话已结束或已在其他设备接通'}));return;}folded=false;render();if(actionId==='answer'&&current.status==='ringing')el('friend-call-answer').click();else if(actionId==='hangup'||(actionId==='reject'&&current.status==='ringing'))el('friend-call-hangup').click();},logout:async()=>{await invoke('set_call_notification_context',{ownedCallId:null,dismissedCallId:current?.id||null}).catch(()=>{});if(current)await invoke('stop_notification_ring',{callId:current.id}).catch(()=>{});if(current?.owned){try{await api('call-end',{callId:current.id});}catch(_){}}++version;current=null;ending.clear();await closeLocal(false);render();},start:(peer,kind)=>action(async()=>{if(current)throw new Error('你正在通话，请先结束当前通话');const generation=version;const result=await api('call-start',{peerId:peer.id,kind});if(generation!==version)return;current=result.call;await sync();})};
 el('friend-call-fold').onclick=()=>{folded=!folded;render();};
 window.__TAURI__.event.listen('friend-call-window:action',({payload})=>{
  if(!current||(payload.callId&&payload.callId!==current.id))return;
  if(payload.action==='fold'){folded=true;render();return;}
  if(payload.action==='restore'){folded=false;render();return;}
  const id={microphone:'friend-call-mic',camera:'friend-call-camera',speaker:'friend-call-speaker',hangup:'friend-call-hangup'}[payload.action];
  if(id)el(id).click();
 }).catch(()=>{});
 el('friend-call-answer').onclick=()=>action(async()=>{await invoke('prepare_call_notification_answer',{callId:current.id}).catch(()=>{});await invoke('stop_notification_ring',{callId:current.id});await api('call-decision',{callId:current.id,accept:true});await sync();});
 el('friend-call-hangup').onclick=()=>action(async()=>{
  const call=current;await invoke('stop_notification_ring',{callId:call.id}); // Stop capture immediately, even if the signaling request fails.
  const operation=call.status==='ringing'&&call.role==='callee'?'call-decision':'call-end';
  const body=operation==='call-decision'?{callId:call.id,accept:false}:{callId:call.id};
  ending.set(call.id,{operation,body});
  await closeLocal();
  try{await api(operation,body);ending.delete(call.id);}
  finally{current=null;render();}
 });
 el('friend-call-mic').onclick=()=>action(async()=>{await invoke('call_set_microphone',{scope:'friend',enabled:!mic});lastError='';await sync();});
 el('friend-call-camera').onclick=()=>action(async()=>{await invoke('call_set_camera',{scope:'friend',enabled:!camera});lastError='';await sync();});
 el('friend-call-speaker').onclick=()=>action(async()=>{await invoke('friend_call_status',{speaker:!speaker});speaker=!speaker;});
 window.addEventListener('social-account-changed',()=>{invoke('set_call_notification_context',{ownedCallId:null,dismissedCallId:current?.id||null}).catch(()=>{});if(current)invoke('stop_notification_ring',{callId:current.id}).catch(()=>{});++version;current=null;ending.clear();lastError='';closeLocal(false).catch(()=>{});render();});
 // Call outcomes belong in chat history; transient notices must not occupy its error row.
 window.addEventListener('friend-call-notice',event=>{window.showAppToast(event.detail,2200);});
 setInterval(()=>{if(current)render();},1000);
 setInterval(sync,2000);setTimeout(sync,800);
 setInterval(async()=>{
  if(!current||current.status!=='active'||separateVideo()||cameraFetch)return;cameraFetch=true;const id=current.id,generation=version;
  // Tauri maps custom protocols to WebView2 localhost origins on Windows.
  // Keep image loading for the same cross-platform frame transport.
  const image=el('friend-call-video'),frame=new Image();
  const valid=()=>current?.id===id&&current.status==='active'&&generation===version;
  const timeout=setTimeout(()=>{frame.onload=frame.onerror=null;cameraFetch=false;},3000);
  frame.onload=()=>{clearTimeout(timeout);if(valid()){image.src=frame.src;image.classList.remove('hidden');}cameraFetch=false;};
  frame.onerror=()=>{clearTimeout(timeout);if(valid())image.classList.add('hidden');cameraFetch=false;};
  frame.src=`${window.__TAURI__.core.convertFileSrc('latest', 'friendcamera')}?t=${Date.now()}`;
 },120);
})();
