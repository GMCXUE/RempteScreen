// Durable account-level messages. Render all remote/user text with textContent.
(() => {
  const el=id=>document.getElementById(id);
  const api=(operation,body={})=>window.__TAURI__.core.invoke('social_api',{operation,body});
  let state=null,peer=null,messages=[],hasMore=false,polling=false,loading=false,mutating=false,generation=0;
  let clearedThrough="0";
  let readSeq=null,accountGeneration=0,friendsTab=false,syncCursor=null;
  let outbox=null,seenConfirmed=new Set(),restoringHistory=false;const outboxes=new Map();
  let contactFingerprint=null,actionFingerprint=null,titleFingerprint=null;
  const node=(tag,text='',cls='')=>{const e=document.createElement(tag);e.textContent=text;e.className=cls;return e;};
  const error=e=>window.showAppToast(String(e),2200);
  const syncFailures=new Map();
  function syncError(source,e) {
    if(document.hidden||el('page-messages').classList.contains('hidden'))return;
    const text=String(e),previous=syncFailures.get(source);
    if(previous?.text===text)return;
    recovered(source);
    const duplicate=[...syncFailures.values()].find(f=>f.text===text);
    syncFailures.set(source,duplicate||{text,dismiss:error(e)});
  }
  function recovered(source) {const failure=syncFailures.get(source);syncFailures.delete(source);if(failure&&![...syncFailures.values()].includes(failure))failure.dismiss?.();}
  const button=(text,action,cls='ghost')=>{const b=node('button',text,cls);b.type='button';b.disabled=mutating;b.onclick=()=>Promise.resolve(action()).catch(error);return b;};
  const name=friend=>friend.remark||friend.name;
  const chatUi=new window.ChatMessages({api,invoke:(command,args)=>window.__TAURI__.core.invoke(command,args),notice:text=>window.showAppToast(text,1200),error,
    context:()=>({accountId:state?.me.id,peerId:peer?.id,generation}),canCompose:()=>!mutating,
    onDraftChanged:()=>renderComposer(),focusDraft:()=>el('social-draft').focus({preventScroll:true})});
  function composeError(text=''){el('social-compose-error').textContent=text;el('social-compose-error').classList.toggle('hidden',!text);}
  function resizeDraft(){
    const draft=el('social-draft');
    draft.style.height='42px';
    if(!draft.clientWidth)return;
    const height=Math.max(42,Math.min(108,draft.scrollHeight));
    draft.style.height=`${height}px`;
    draft.style.overflowY=draft.scrollHeight>108?'auto':'hidden';
    // Composer growth changes the message viewport immediately. Keep the
    // bottom anchored in the same frame instead of waiting for ResizeObserver.
    if(followBottom){const messages=el('social-messages');messages.scrollTop=messages.scrollHeight;}
  }
  function renderComposer(){
    const busy=mutating||chatUi.picking,root=el('social-draft-images');root.replaceChildren();root.classList.toggle('hidden',!chatUi.draftImages.length);
    for(const [index,draft] of chatUi.draftImages.entries()){
      const item=node('div','','chat-draft-image');item.setAttribute('role','listitem');item.dataset.draftId=draft.id;
      const photo=draft.kind==='video'?node('span','▶','chat-draft-video'):node('img');if(draft.kind!=='video'){photo.src=draft.image;photo.alt=`待发送图片 ${index+1}`;}else photo.title=draft.video.name||'视频';
      const remove=node('button','×');remove.type='button';remove.setAttribute('aria-label',`移除${draft.kind==='video'?'视频':'图片'} ${index+1}`);remove.disabled=busy;
      remove.onclick=()=>{chatUi.removeDraftImage(draft.id);composeError();el('social-draft').focus({preventScroll:true});};item.append(photo,remove);root.append(item);
    }
    el('social-image').disabled=busy||!peer;el('social-send').disabled=busy||!peer||(!el('social-draft').value.trim()&&!chatUi.draftImages.length);el('social-send').textContent=mutating?'发送中…':'发送';el('social-draft').readOnly=mutating;
    resizeDraft();
  }
  function renderMessages(animateNew=false){if(!state||!peer)return;chatUi.invalidate(messages);const rows=[...messages,...(outbox?.records()||[])];chatUi.render(el('social-messages'),rows,state.me,peer,async updated=>{const index=messages.findIndex(m=>m.id===updated.id);if(index>=0)messages[index]=updated;renderMessages();await refresh();},id=>outbox?.retry(id),animateNew);}
  function outboxChanged(queue){
    if(queue!==outbox||state?.me.id!==queue.accountId||peer?.id!==queue.peerId)return;
    const box=el('social-messages'),bottom=box.scrollHeight-box.scrollTop-box.clientHeight<80;
    for(const row of queue.confirmed){if(seenConfirmed.has(row.id))continue;seenConfirmed.add(row.id);if(BigInt(row.seq)<=BigInt(clearedThrough))continue;if(!messages.some(m=>m.id===row.id))messages.push(row);}
    messages.sort((a,b)=>BigInt(a.seq)<BigInt(b.seq)?-1:BigInt(a.seq)>BigInt(b.seq)?1:0);
    renderMessages(bottom&&!restoringHistory);if(bottom)box.scrollTop=box.scrollHeight;
  }
  function bindOutbox(){
    const key=`${state.me.id}:${peer.id}`;
    if(!outboxes.has(key)){
      const session=window.__TAURI__.core.invoke('chat_send_session');let queue;
      queue=new window.ChatSendQueue({accountId:state.me.id,peerId:peer.id,sender:session.then(sendSession=>async(operation,body)=>{if(operation==='send-video'){const result=await window.__TAURI__.core.invoke('send_chat_video',{draftId:body.video.draftId,peerId:body.peerId,clientId:body.clientId,sendSession});return result;}return window.__TAURI__.core.invoke('social_api',{operation,body,sendSession});}),onChange:()=>outboxChanged(queue),releaseMedia:item=>{if(item.video)window.__TAURI__.core.invoke('release_chat_media',{draftId:item.video.draftId}).catch(()=>{});}});outboxes.set(key,queue);
    }
    outbox=outboxes.get(key);seenConfirmed=new Set(outbox.confirmed.map(m=>m.id));
  }
  async function change(operation,body) {
    if(mutating)return;mutating=true;
    try{await api(operation,body);await refresh();}
    finally{mutating=false;renderContacts();renderActions();}
  }
  function resetChat() {
    recovered('messages');recovered('read');
    contactFingerprint=actionFingerprint=titleFingerprint=null;
    followBottom=true;settings.close();clearedThrough="0";++generation;loading=false;peer=null;messages=[];outbox=null;seenConfirmed=new Set();readSeq=null;syncCursor=null;hasMore=false;chatUi.close();chatUi.resetRows();chatUi.clearDraft();composeError();
    const empty=node('div','','social-empty');empty.append(node('span','···','social-empty-symbol'),node('strong','选择好友，开始聊天'),node('span','在好友列表选择联系人，即可打开会话'));el('social-messages').replaceChildren(empty);el('social-actions').replaceChildren();
    el('social-chat-title').textContent='聊天';el('social-compose').classList.add('hidden');el('social-older').classList.add('hidden');el('social-draft').value='';
    resizeDraft();
  }
  function renderChatTitle(friend){const fingerprint=JSON.stringify([friend.id,name(friend),friend.avatarId,friend.avatarRevision]);if(titleFingerprint===fingerprint)return;titleFingerprint=fingerprint;const title=el('social-chat-title'),avatar=node('span','','chat-avatar');window.accountAvatars?.render(avatar,friend);title.replaceChildren(avatar,document.createTextNode(name(friend)));}
  async function refresh() {
    if(polling || el('app').classList.contains('hidden'))return;
    polling=true;const accountVersion=accountGeneration;
    try {
      const data=await api('state');
      if(accountVersion!==accountGeneration || el('app').classList.contains('hidden'))return;
      recovered('contacts');
      if(state && state.me.id!==data.me.id)resetChat();
      state=data;
      window.accountAvatars?.update(data.me);
      el('social-account').textContent=`我的账号 ID：${data.me.accountId||'待分配'}`;
      const unread=data.friends.reduce((sum,f)=>sum+(f.blocked?0:f.unread),0)+data.requests.length;
      el('social-unread').textContent=unread>99?'99+':String(unread);
      el('social-unread').classList.toggle('hidden',!unread);
      if(peer) {
        const current=data.friends.find(f=>f.id===peer.id);
        if(!current || current.blocked){resetChat();error('好友关系已变化，聊天已结束');}
        else {peer=current;renderChatTitle(peer);}
      }
      renderContacts();renderActions();
    } catch(e){if(accountVersion===accountGeneration&&!el('app').classList.contains('hidden')){
      syncError('contacts',e);
      if(!state){const empty=node('div','','social-empty');empty.append(node('span','消息暂时无法同步'),button('重试',refresh));el('social-contacts').replaceChildren(empty);}
    }}
    finally{polling=false;}
  }
  function renderContacts() {
    if(!state)return;
    const fingerprint=JSON.stringify([state.me.id,state.friends,state.requests,state.outgoing,state.blocked,friendsTab,peer?.id,mutating]);
    if(contactFingerprint===fingerprint)return;contactFingerprint=fingerprint;
    const root=el('social-contacts');root.replaceChildren();
    const count=state.friends.reduce((sum,f)=>sum+(f.blocked?0:f.unread),0);
    for(const [id,label,total] of [['social-tab-messages','消息',count],['social-tab-friends','好友',state.requests.length]]){const tab=el(id);tab.replaceChildren(node('span',label));if(total)tab.append(node('span',total>99?'99+':String(total),'social-count'));}
    el('social-tab-messages').classList.toggle('selected',!friendsTab);
    el('social-tab-friends').classList.toggle('selected',friendsTab);
    el('social-tab-messages').setAttribute('aria-pressed',String(!friendsTab));
    el('social-tab-friends').setAttribute('aria-pressed',String(friendsTab));
    if(!friendsTab && state.requests.length) {
      root.append(button(`新的好友申请 · ${state.requests.length}`,()=>{friendsTab=true;renderContacts();},'social-request-link'));
    }
    if(friendsTab && state.requests.length)root.append(node('p','新的好友','social-section'));
    if(friendsTab)for(const request of state.requests) {
      const card=node('div','','social-request');const avatar=node('span','','chat-avatar');window.accountAvatars?.render(avatar,request);card.append(avatar,node('strong',request.name),node('p',request.note||'希望添加你为好友'));
      const actions=node('div','','social-request-actions');actions.append(button('拒绝',()=>change('decision',{peerId:request.id,accept:false})),button('同意',()=>change('decision',{peerId:request.id,accept:true}),'primary'));card.append(actions);root.append(card);
    }
    const friends=friendsTab?state.friends:state.friends.filter(friend=>!friend.blocked&&(friend.lastText||friend.unread||friend.pinned));
    root.append(node('p',friendsTab?`全部好友 · ${state.friends.length}`:'最近会话','social-section'));
    if(!friends.length) {
      root.append(node('div',friendsTab?'还没有好友，点击 + 添加':'还没有会话','social-list-empty'));
    }
    for(const friend of friends) {
      const row=node('button','','social-contact'+(peer?.id===friend.id?' selected':''));row.type='button';row.disabled=friend.blocked;
      const avatar=node('span','','social-avatar');window.accountAvatars?.render(avatar,friend);const presence=node('span','','social-presence'+(friend.online?' online':''));presence.title=friend.online?'在线':'离线';presence.setAttribute('role','img');presence.setAttribute('aria-label',presence.title);avatar.append(presence);row.append(avatar);
      const info=node('div','','social-contact-info');info.append(node('strong',name(friend)),node('span',friend.blocked?'已拉黑':friendsTab?`账号 ID：${friend.accountId||'待分配'}`:friend.lastText));row.append(info);
      if(friend.pinned&&!friendsTab)row.append(node('span','置顶','chat-pinned-label'));
      if(friend.unread && !friend.blocked  )row.append(node('span',friend.unread>99?'99+':String(friend.unread),'social-count'));
      row.onclick=()=>select(friend);root.append(row);
    }
    if(friendsTab && state.outgoing.length) {
      const details=node('details','','social-folded');details.append(node('summary',`已发送申请 · ${state.outgoing.length}`));
      for(const request of state.outgoing)details.append(node('p',`${request.name} · 等待对方确认`,'muted small'));root.append(details);
    }
    if(friendsTab && state.blocked.length) {
      const details=node('details','','social-folded');details.append(node('summary',`黑名单 · ${state.blocked.length}`));
      for(const friend of state.blocked) {const row=node('div','','social-request');const avatar=node('span','','chat-avatar');window.accountAvatars?.render(avatar,friend);row.append(avatar,node('span',friend.name),button('解除拉黑',()=>change('profile',{peerId:friend.id,action:'block',blocked:false})));details.append(row);}root.append(details);
    }
  }
  const settings=new window.ChatSettings({root:el('social-chat-settings'),context:()=>({me:state?.me,peer}),
    invoke:(command,args)=>window.__TAURI__.core.invoke(command,args),error,notice:text=>window.showAppToast(text,1400),canChange:()=>!mutating&&!outbox?.running,
    change,profile:friend=>window.showFriendProfile(friend),
    remark:async friend=>{const value=await askDialog({title:'好友备注',defaultValue:friend.remark||''});if(value!==null)await change('profile',{peerId:friend.id,action:'remark',remark:value});},
    block:async friend=>{if(await askDialog({title:'拉黑好友？',message:'拉黑后双方不能发送消息。',danger:true}))await change('profile',{peerId:friend.id,action:'block',blocked:true});},
    remove:async friend=>{if(await askDialog({title:'删除好友？',message:'删除后需要重新申请才能聊天。',danger:true}))await change('profile',{peerId:friend.id,action:'remove'});},
    clear:async friend=>{const v=generation;mutating=true;renderComposer();try{const result=await api('clear-history',{peerId:friend.id});if(v!==generation)return;++generation;loading=false;clearedThrough=result.clearedThrough;outbox?.discardFailures();messages=[];readSeq=null;syncCursor=null;hasMore=false;chatUi.close();renderMessages();el('social-older').classList.add('hidden');await window.__TAURI__.core.invoke('close_chat_history');await refresh();window.showAppToast('聊天记录已清空',1400);}finally{mutating=false;renderComposer();}await load();}
  });
  function renderActions() {
    const fingerprint=JSON.stringify([peer?.id,peer?.name,peer?.remark,peer?.accountId,peer?.avatarId,peer?.avatarRevision,mutating]);
    if(actionFingerprint===fingerprint){settings.refresh();return;}actionFingerprint=fingerprint;
    const root=el('social-actions');root.replaceChildren();if(!peer)return;
    const current=peer;
    const voice=button('语音',()=>window.friendCalls.start(current,'voice'),'social-call-button'),video=button('视频',()=>window.friendCalls.start(current,'video'),'social-call-button');
    window.uiIcons.button(voice,'call','语音通话');window.uiIcons.button(video,'video','视频通话');root.append(voice,video);
    const more=button('•••',()=>settings.toggle(),'social-call-button');more.setAttribute('aria-label','聊天信息');more.title='聊天信息';more.setAttribute('aria-expanded',String(settings.open));root.append(more);settings.refresh();
  }
  async function locateMessage(messageId) {
    if(mutating||!peer)throw '消息正在同步，请稍后再试';
    loading=true;const current=peer,v=++generation;
    try{const data=await api('message-context',{peerId:current.id,messageId});if(v!==generation)return;messages=data.messages;syncCursor=data.syncCursor;clearedThrough=data.clearedThrough;hasMore=data.hasMore;chatUi.close();renderMessages();el('social-older').classList.toggle('hidden',!hasMore);settings.close();
      const row=[...el('social-messages').children].find(e=>e.dataset.messageId===messageId);if(row){row.scrollIntoView({block:'center'});row.classList.add('chat-message-highlight');setTimeout(()=>row.classList.remove('chat-message-highlight'),2200);}
    }finally{if(v===generation)loading=false;}
  }
  async function select(friend) {
    if(mutating)return;
    if(peer?.id===friend.id)return;
    if((el('social-draft').value.trim()||chatUi.draftImages.length) && !(await askDialog({title:'切换会话？',message:'当前未发送的草稿将被清空。'})))return;
    resetChat();peer=friend;bindOutbox();syncNotificationContext();renderChatTitle(friend);el('social-compose').classList.remove('hidden');renderComposer();renderContacts();renderActions();await load();
  }
  async function load(older=false) {
    if(loading || !peer || (document.hidden && !chatUi.nativeImage && !chatUi.nativeVideo) || el('page-messages').classList.contains('hidden'))return;
    loading=true;const current=peer,version=generation;
    try {
      const data=await api('messages',{peerId:current.id,...(syncCursor!==null?{syncCursor,loadedFrom:messages[0]?.seq}:{}),...(messages.length?(older?{before:messages[0].seq}:{after:messages.at(-1).seq}):{})});
      if(version!==generation || peer?.id!==current.id)return;
      if(typeof data.syncError==='string')syncError('messages',data.syncError);else recovered('messages');
      const container=el('social-messages'),atBottom=container.scrollHeight-container.scrollTop-container.clientHeight<80;
      const oldHeight=container.scrollHeight,oldTop=container.scrollTop,initial=messages.length===0;
      const boundary=data.clearedThrough||'0';const cleared=BigInt(boundary)>BigInt(clearedThrough);if(cleared){clearedThrough=boundary;messages=messages.filter(m=>BigInt(m.seq)>BigInt(boundary));chatUi.close();window.__TAURI__.core.invoke('close_chat_history').catch(()=>{});}
      const map=new Map(messages.map(m=>[m.id,m]));let changed=cleared;
      for(const m of [...data.messages,...(data.updates||[])]){const old=map.get(m.id);if(!old&&!(data.messages||[]).some(row=>row.id===m.id))continue;if(old?.kind==='recalled'&&m.kind!=='recalled')continue;if(!old||old.kind!==m.kind||old.text!==m.text||old.recalledAt!==m.recalledAt){map.set(m.id,m);changed=true;}}
      if(data.syncCursor!==undefined)syncCursor=data.syncCursor;
      if(data.serverNow)chatUi.clockOffset=Number(data.serverNow)-Date.now();
      messages=[...map.values()].sort((a,b)=>BigInt(a.seq)<BigInt(b.seq)?-1:BigInt(a.seq)>BigInt(b.seq)?1:0);
      if(older||initial)hasMore=data.hasMore;
      restoringHistory=older||initial;
      try{outbox?.reconcile([...data.messages,...(data.updates||[])]);}finally{restoringHistory=false;}
      if(changed)renderMessages(!older&&!initial&&atBottom);
      if(!messages.length&&!outbox?.items.length){container.replaceChildren();const empty=node('div','','social-empty');empty.append(node('strong','还没有消息'),node('span','发送一条消息，开始聊天'));container.append(empty);}
      if(older)container.scrollTop=oldTop+container.scrollHeight-oldHeight;else if(initial||atBottom){followBottom=true;container.scrollTop=container.scrollHeight;}
      el('social-older').classList.toggle('hidden',!hasMore);
      const last=messages.at(-1);
      if(!older && last && last.seq!==readSeq && !document.hidden && document.hasFocus() && !el('page-messages').classList.contains('hidden')) {
        try{await api('read',{peerId:current.id,seq:last.seq});if(version===generation){readSeq=last.seq;recovered('read');}}
        catch(e){if(version===generation)syncError('read',e);}
      }
    }catch(e){if(version===generation){syncError('messages',e);
      if(!messages.length){const empty=node('div','','social-empty');empty.append(node('span','消息暂时无法同步'),button('重试',()=>load()));el('social-messages').replaceChildren(empty);}
    }}
    finally{if(version===generation)loading=false;}
  }
  const toast=text=>window.showAppToast(text);
  let followBottom=true;
  const messageViewport=el('social-messages');
  let viewportHeight=messageViewport.clientHeight;
  messageViewport.addEventListener('scroll',()=>{
    // A viewport resize may emit scroll before ResizeObserver; it is not a user leaving the bottom.
    if(messageViewport.clientHeight!==viewportHeight)return;
    followBottom=messageViewport.scrollHeight-messageViewport.scrollTop-messageViewport.clientHeight<80;
  });
  new ResizeObserver(()=>{viewportHeight=messageViewport.clientHeight;if(followBottom)messageViewport.scrollTop=messageViewport.scrollHeight;}).observe(messageViewport);
  new ResizeObserver(()=>{document.body.style.setProperty('--chat-composer-height',`${Math.ceil(el('social-compose').getBoundingClientRect().height)+12}px`);}).observe(el('social-compose'));
  let composerWidth=0;
  new ResizeObserver(entries=>{const width=entries[0].contentRect.width;if(width!==composerWidth){composerWidth=width;resizeDraft();}}).observe(el('social-draft').parentElement);
  el('social-alert-settings').onclick=async()=>{
    try{
      const accountId=state?.me.id;
      const value=await window.__TAURI__.core.invoke('notification_settings',{accountId:state?.me.id,value:null});
      const dialog=node('dialog','','alert-settings-dialog');dialog.append(node('h3','消息与来电提醒'));
      for(const [key,label] of [['messageSound','消息提示音'],['messagePreview','通知显示消息内容'],['callSound','来电铃声']]){
        const row=node('label',label);const input=node('input');input.type='checkbox';input.checked=value[key];input.onchange=()=>value[key]=input.checked;row.append(input);dialog.append(row);
      }
      dialog.append(node('p','免打扰可在好友菜单中设置。设置仅应用于本设备。','muted small'));
      const advanced=node('details','','notification-advanced');advanced.append(node('summary','系统通知设置'));
      const diagnostics=node('p','正在检查通知状态…','muted small');advanced.append(diagnostics);dialog.append(advanced);
      const refreshDiagnostics=async()=>{const data=await window.__TAURI__.core.invoke('notification_diagnostics');const p=data.permission||{};diagnostics.textContent=`系统通知：${p.authorization===2?'已允许':p.authorization===1?'已关闭，请在系统通知设置中允许':'等待系统授权'}${p.alerts!==undefined&&p.alerts!==2?'；系统横幅已关闭':''}${p.sounds!==undefined&&p.sounds!==2?'；系统声音已关闭':''}${data.pollError?'；同步失败：'+data.pollError:''}${data.delivery?.error?'；发送失败：'+data.delivery.error:''}`;};refreshDiagnostics().catch(error);
      advanced.append(button('系统通知设置',async()=>{await window.__TAURI__.core.invoke('open_notification_settings');}),button('测试消息通知',async()=>{await window.__TAURI__.core.invoke('test_notification',{accountId,kind:'message'});setTimeout(()=>refreshDiagnostics().catch(error),1000);}),button('测试来电铃声',async()=>{await window.__TAURI__.core.invoke('test_notification',{accountId,kind:'call'});setTimeout(()=>refreshDiagnostics().catch(error),1000);}));
      const actions=node('div','','actions');actions.append(button('取消',()=>dialog.close()),button('保存',async()=>{
        await window.__TAURI__.core.invoke('notification_settings',{accountId,value});dialog.close();
      },'primary'));dialog.append(actions);dialog.onclose=()=>dialog.remove();document.body.append(dialog);dialog.showModal();
    }catch(e){error(e);}
  };
  window.__TAURI__.event?.listen('messaging-notice',event=>{if(state?.me.id===event.payload.accountId){toast(event.payload.text);el('ft-toast').onclick=()=>{if(state?.me.id!==event.payload.accountId)return;const friend=state.friends.find(f=>f.id===event.payload.peerId&&!f.blocked);if(friend){document.querySelector('[data-page="messages"]').click();select(friend).catch(error);}};}});
  el('social-copy-account').onclick=async()=>{
    if(!state?.me.accountId)return;
    try{await navigator.clipboard.writeText(state.me.accountId);el('social-copy-account').textContent='已复制';setTimeout(()=>el('social-copy-account').textContent='复制账号 ID',1500);}catch(e){error(e);}
  };
  el('social-add').onclick=async()=>{
    try {
      const query=await askDialog({title:'输入账号 ID 或邮箱',defaultValue:''});if(!query)return;
      const data=await api('search',{query});if(!data.users.length){error('没有找到该账号');return;}
      const friend=data.users[0];const note=await askDialog({title:`添加 ${friend.name}`,avatarId:friend,message:`账号 ID：${friend.accountId||'待分配'}。填写申请说明，对方同意后成为好友。`,defaultValue:''});
      if(note!==null)await change('request',{peerId:friend.id,note});
    }catch(e){error(e);}
  };
  el('social-tab-messages').onclick=()=>{friendsTab=false;renderContacts();};
  el('social-tab-friends').onclick=()=>{friendsTab=true;renderContacts();};
  el('social-older').onclick=()=>load(true);
  el('social-image').onclick=()=>chatUi.chooseImage().catch(error);
  el('social-draft').addEventListener('input',()=>{composeError();resizeDraft();el('social-send').disabled=mutating||chatUi.picking||!peer||(!el('social-draft').value.trim()&&!chatUi.draftImages.length);});
  let pasteFallback=null;
  el('social-draft').addEventListener('keydown',event=>{
    if(event.key.toLowerCase()!=='v'||!(event.metaKey||event.ctrlKey)||event.altKey||event.shiftKey||event.repeat)return;
    clearTimeout(pasteFallback);
    // Some WebViews do not emit paste when the clipboard contains only native pixels.
    pasteFallback=setTimeout(()=>{if(document.activeElement===el('social-draft'))chatUi.prepareImage(()=>window.__TAURI__.core.invoke('read_chat_image')).catch(error);},60);
  });
  el('social-draft').addEventListener('paste',event=>{
    clearTimeout(pasteFallback);
    chatUi.pasteImage(event).catch(error);
  });
  el('social-compose').onsubmit=event=>{
    event.preventDefault();if(!peer||mutating||chatUi.picking||!outbox)return;
    const text=el('social-draft').value.trim(),images=[...chatUi.draftImages];if(!text&&!images.length)return;
    const id=()=>crypto.randomUUID?.()||Array.from(crypto.getRandomValues(new Uint8Array(24)),b=>b.toString(16).padStart(2,'0')).join('');
    try{
      outbox.enqueue([...images.map(image=>({kind:image.kind||'image',id:image.id,image:image.image,video:image.video})),...(text?[{kind:'text',id:id(),text}]:[])]);
      el('social-draft').value='';chatUi.clearDraft(false);composeError();renderComposer();el('social-messages').scrollTop=el('social-messages').scrollHeight;
    }catch(e){composeError(String(e));}
  };
  window.addEventListener('account-avatar-changed',()=>{refresh().then(()=>{if(state&&peer&&messages.length)renderMessages();return load();});});
  window.addEventListener('account-profile-changed',refresh);
  window.addEventListener('social-account-changed',()=>{
    window.__TAURI__.core.invoke('close_chat_history').catch(()=>{});
    for(const queue of outboxes.values())queue.cancel();outboxes.clear();
    ++accountGeneration;for(const source of syncFailures.keys())recovered(source);state=null;resetChat();el('social-account').textContent='';
    el('social-contacts').replaceChildren();el('social-unread').classList.add('hidden');
  });
  const syncNotificationContext=()=>window.__TAURI__.core.invoke('set_notification_context',{peerId:!document.hidden&&document.hasFocus()&&!el('page-messages').classList.contains('hidden')?peer?.id||null:null}).catch(()=>{});
  setInterval(syncNotificationContext,1000);window.addEventListener('focus',syncNotificationContext);window.addEventListener('blur',syncNotificationContext);document.addEventListener('visibilitychange',syncNotificationContext);document.querySelectorAll('.nav-item').forEach(button=>button.addEventListener('click',()=>queueMicrotask(syncNotificationContext)));
  window.__TAURI__.event?.listen('messaging-action',async event=>{const info=event.payload.extra||{};await refresh();if(state?.me.id!==info.accountId)return;document.querySelector('[data-page="messages"]').click();if(info.kind==='call'){await window.friendCalls?.handleNotification(info.callId,event.payload.action);return;}if(info.kind==='friends'){friendsTab=true;renderContacts();return;}const friend=state.friends.find(f=>f.id===info.peerId&&!f.blocked);if(friend)await select(friend);});
  window.__TAURI__.event?.listen('chat-history-locate',async event=>{try{const info=event.payload;await refresh();if(state?.me.id!==info.accountId)return;const friend=state.friends.find(f=>f.id===info.peerId&&!f.blocked);if(!friend)throw '好友关系已变化';document.querySelector('[data-page="messages"]').click();await select(friend);await locateMessage(info.messageId);}catch(e){error(e);}});
  document.addEventListener('keydown',e=>{if(e.key==='Escape'&&settings.open)settings.close();});
  setInterval(async()=>{
    if(el('app').classList.contains('hidden')) { if(state){for(const queue of outboxes.values())queue.cancel();outboxes.clear();state=null;resetChat();el('social-contacts').replaceChildren();el('social-unread').classList.add('hidden');}return; }
    await refresh();await load();
  },4000);
  document.querySelector('[data-page="messages"]').addEventListener('click',async()=>{await refresh();await load();});
})();
