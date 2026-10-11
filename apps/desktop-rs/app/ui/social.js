// Durable account-level messages. Render all remote/user text with textContent.
(() => {
  const el=id=>document.getElementById(id);
  const api=(operation,body={})=>window.__TAURI__.core.invoke('social_api',{operation,body});
  let state=null,peer=null,messages=[],hasMore=false,polling=false,loading=false,mutating=false,generation=0;
  let retry=null,readSeq=null,accountGeneration=0,friendsTab=false,syncCursor=null;
  const node=(tag,text='',cls='')=>{const e=document.createElement(tag);e.textContent=text;e.className=cls;return e;};
  const error=e=>{el('social-error').textContent=String(e);};
  const button=(text,action,cls='ghost')=>{const b=node('button',text,cls);b.type='button';b.disabled=mutating;b.onclick=()=>Promise.resolve(action()).catch(error);return b;};
  const name=friend=>friend.remark||friend.name;
  const chatUi=new window.ChatMessages({api,invoke:(command,args)=>window.__TAURI__.core.invoke(command,args),notice:text=>window.showAppToast(text,1200),error,
    context:()=>({accountId:state?.me.id,peerId:peer?.id,generation})});
  function renderMessages(){chatUi.invalidate(messages);el('social-messages').replaceChildren(...messages.map(m=>chatUi.row(m,state.me,peer,async updated=>{const index=messages.findIndex(m=>m.id===updated.id);if(index>=0)messages[index]=updated;renderMessages();await refresh();})));}
  async function change(operation,body) {
    if(mutating)return;mutating=true;
    try{await api(operation,body);await refresh();el('social-error').textContent='';}
    finally{mutating=false;renderContacts();renderActions();}
  }
  function resetChat() {
    ++generation;peer=null;messages=[];retry=null;readSeq=null;syncCursor=null;hasMore=false;chatUi.close();
    const empty=node('div','','social-empty');empty.append(node('span','···','social-empty-symbol'),node('strong','选择好友，开始聊天'),node('span','在好友列表选择联系人，即可打开会话'));el('social-messages').replaceChildren(empty);el('social-actions').replaceChildren();
    el('social-chat-title').textContent='聊天';el('social-compose').classList.add('hidden');el('social-older').classList.add('hidden');el('social-draft').value='';
  }
  function renderChatTitle(friend){const title=el('social-chat-title'),avatar=node('span','','chat-avatar');window.accountAvatars?.render(avatar,friend);title.replaceChildren(avatar,document.createTextNode(name(friend)));}
  async function refresh() {
    if(polling || el('app').classList.contains('hidden'))return;
    polling=true;const accountVersion=accountGeneration;
    try {
      const data=await api('state');
      if(accountVersion!==accountGeneration || el('app').classList.contains('hidden'))return;
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
    } catch(e){if(!el('page-messages').classList.contains('hidden'))error(e);}
    finally{polling=false;}
  }
  function renderContacts() {
    if(!state)return;
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
    const friends=friendsTab?state.friends:state.friends.filter(friend=>!friend.blocked&&(friend.lastText||friend.unread));
    root.append(node('p',friendsTab?`全部好友 · ${state.friends.length}`:'最近会话','social-section'));
    if(!friends.length) {
      root.append(node('div',friendsTab?'还没有好友，点击 + 添加':'还没有会话','social-list-empty'));
    }
    for(const friend of friends) {
      const row=node('button','','social-contact'+(peer?.id===friend.id?' selected':''));row.type='button';row.disabled=friend.blocked;
      const avatar=node('span','','social-avatar');window.accountAvatars?.render(avatar,friend);const presence=node('span','','social-presence'+(friend.online?' online':''));presence.title=friend.online?'在线':'离线';presence.setAttribute('role','img');presence.setAttribute('aria-label',presence.title);avatar.append(presence);row.append(avatar);
      const info=node('div','','social-contact-info');info.append(node('strong',name(friend)),node('span',friend.blocked?'已拉黑':friendsTab?`账号 ID：${friend.accountId||'待分配'}`:friend.lastText));row.append(info);
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
  function renderActions() {
    const root=el('social-actions');const wasOpen=root.querySelector('details')?.open;root.replaceChildren();if(!peer)return;
    const current=peer,accountId=state?.me.id;
    root.append(button('语音',()=>window.friendCalls.start(current,'voice'),'social-call-button'),button('视频',()=>window.friendCalls.start(current,'video'),'social-call-button'));
    const menu=node('details','','social-menu');menu.open=!!wasOpen;const toggle=node('summary','•••');toggle.setAttribute('aria-label','好友管理');menu.append(toggle);
    const items=node('div','','social-menu-items');menu.append(items);root.append(menu);
    const muteButton=button('免打扰',async()=>{
      const value=await window.__TAURI__.core.invoke('notification_settings',{accountId:state?.me.id,value:null});
      const muted=new Set(value.mutedPeers||[]);const wasMuted=muted.delete(current.id);if(!wasMuted)muted.add(current.id);
      await window.__TAURI__.core.invoke('notification_settings',{accountId,value:{...value,mutedPeers:[...muted]}});
      muteButton.textContent=wasMuted?'开启免打扰':'关闭免打扰';toast(wasMuted?'已关闭好友免打扰':'已开启好友免打扰，消息保留未读，来电静音');
    });menu.ontoggle=async()=>{if(!menu.open)return;try{const value=await window.__TAURI__.core.invoke('notification_settings',{accountId:state?.me.id,value:null});muteButton.textContent=value.mutedPeers?.includes(current.id)?'关闭免打扰':'开启免打扰';}catch(e){error(e);}};
    items.append(button('好友资料',()=>window.showFriendProfile(current)),muteButton,button('备注' ,async()=>{
      const value=await askDialog({title:'好友备注',defaultValue:current.remark||''});
      if(value!==null)await change('profile',{peerId:current.id,action:'remark',remark:value});
    }),button('拉黑',async()=>{
      if(await askDialog({title:'拉黑好友？',message:'拉黑后双方不能发送消息。',danger:true}))await change('profile',{peerId:current.id,action:'block',blocked:true});
    }),button('删除',async()=>{
      if(await askDialog({title:'删除好友？',message:'删除后需要重新申请才能聊天。',danger:true}))await change('profile',{peerId:current.id,action:'remove'});
    }));
  }
  async function select(friend) {
    if(peer?.id===friend.id)return;
    if(el('social-draft').value.trim() && !(await askDialog({title:'切换会话？',message:'当前未发送的草稿将被清空。'})))return;
    resetChat();peer=friend;syncNotificationContext();renderChatTitle(friend);el('social-compose').classList.remove('hidden');renderContacts();renderActions();await load();
  }
  async function load(older=false) {
    if(loading || !peer || document.hidden || el('page-messages').classList.contains('hidden'))return;
    loading=true;const current=peer,version=generation;
    try {
      const data=await api('messages',{peerId:current.id,...(syncCursor!==null?{syncCursor,loadedFrom:messages[0]?.seq}:{}),...(messages.length?(older?{before:messages[0].seq}:{after:messages.at(-1).seq}):{})});
      if(version!==generation || peer?.id!==current.id)return;
      const container=el('social-messages'),atBottom=container.scrollHeight-container.scrollTop-container.clientHeight<80;
      const oldHeight=container.scrollHeight,oldTop=container.scrollTop,initial=messages.length===0;
      const map=new Map(messages.map(m=>[m.id,m]));let changed=false;
      for(const m of [...data.messages,...(data.updates||[])]){const old=map.get(m.id);if(!old&&!(data.messages||[]).some(row=>row.id===m.id))continue;if(old?.kind==='recalled'&&m.kind!=='recalled')continue;if(!old||old.kind!==m.kind||old.text!==m.text||old.recalledAt!==m.recalledAt){map.set(m.id,m);changed=true;}}
      if(data.syncCursor!==undefined)syncCursor=data.syncCursor;
      if(data.serverNow)chatUi.clockOffset=Number(data.serverNow)-Date.now();
      messages=[...map.values()].sort((a,b)=>BigInt(a.seq)<BigInt(b.seq)?-1:BigInt(a.seq)>BigInt(b.seq)?1:0);
      if(older||initial)hasMore=data.hasMore;
      if(changed)renderMessages();
      if(!messages.length){container.replaceChildren();const empty=node('div','','social-empty');empty.append(node('strong','还没有消息'),node('span','发送一条消息，开始聊天'));container.append(empty);}
      if(older)container.scrollTop=oldTop+container.scrollHeight-oldHeight;else if(atBottom)container.scrollTop=container.scrollHeight;
      el('social-older').classList.toggle('hidden',!hasMore);
      const last=data.messages.at(-1);
      if(!older && last && last.seq!==readSeq && !document.hidden && document.hasFocus() && !el('page-messages').classList.contains('hidden')) {
        await api('read',{peerId:current.id,seq:last.seq});if(version===generation)readSeq=last.seq;
      }
    }catch(e){if(version===generation)error(e);}
    finally{loading=false;}
  }
  const toast=text=>window.showAppToast(text);
  el('social-alert-settings').onclick=async()=>{
    try{
      const accountId=state?.me.id;
      const value=await window.__TAURI__.core.invoke('notification_settings',{accountId:state?.me.id,value:null});
      const dialog=node('dialog','','alert-settings-dialog');dialog.append(node('h3','消息与来电提醒'));
      for(const [key,label] of [['messageSound','消息提示音'],['callSound','来电铃声']]){
        const row=node('label',label);const input=node('input');input.type='checkbox';input.checked=value[key];input.onchange=()=>value[key]=input.checked;row.append(input);dialog.append(row);
      }
      dialog.append(node('p','免打扰可在好友菜单中设置。设置仅应用于本设备。','muted small'));
      const diagnostics=node('p','正在检查通知状态…','muted small');dialog.append(diagnostics);
      const refreshDiagnostics=async()=>{const data=await window.__TAURI__.core.invoke('notification_diagnostics');const p=data.permission||{};diagnostics.textContent=`系统通知：${p.authorization===2?'已允许':p.authorization===1?'已关闭，请在系统通知设置中允许':'等待系统授权'}${p.alerts!==undefined&&p.alerts!==2?'；系统横幅已关闭':''}${p.sounds!==undefined&&p.sounds!==2?'；系统声音已关闭':''}${data.pollError?'；同步失败：'+data.pollError:''}${data.delivery?.error?'；发送失败：'+data.delivery.error:''}`;};refreshDiagnostics().catch(error);
      dialog.append(button('系统通知设置',async()=>{await window.__TAURI__.core.invoke('open_notification_settings');}),button('测试消息通知',async()=>{await window.__TAURI__.core.invoke('test_notification',{accountId,kind:'message'});setTimeout(()=>refreshDiagnostics().catch(error),1000);}),button('测试来电铃声',async()=>{await window.__TAURI__.core.invoke('test_notification',{accountId,kind:'call'});setTimeout(()=>refreshDiagnostics().catch(error),1000);}));
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
  el('social-image').onclick=()=>chatUi.chooseImage(async()=>{await load();await refresh();}).catch(error);
  el('social-compose').onsubmit=async event=>{
    event.preventDefault();if(!peer || mutating)return;
    const text=el('social-draft').value.trim();if(!text)return;
    const current=peer,version=generation;
    if(!retry || retry.text!==text || retry.peer!==current.id)retry={text,peer:current.id,id:crypto.randomUUID?.()||Array.from(crypto.getRandomValues(new Uint8Array(24)),b=>b.toString(16).padStart(2,'0')).join('')};
    mutating=true;el('social-send').disabled=true;
    try {
      await api('send',{peerId:current.id,text,clientId:retry.id});
      if(version!==generation)return;
      if(el('social-draft').value.trim()===text)el('social-draft').value='';retry=null;
      el('social-error').textContent='';await load();await refresh();
    }catch(e){if(version===generation)error(e);}
    finally{mutating=false;el('social-send').disabled=false;}
  };
  window.addEventListener('account-avatar-changed',()=>{refresh().then(()=>{if(state&&peer&&messages.length)renderMessages();return load();});});
  window.addEventListener('account-profile-changed',refresh);
  window.addEventListener('social-account-changed',()=>{
    ++accountGeneration;state=null;resetChat();el('social-account').textContent='';
    el('social-contacts').replaceChildren();el('social-error').textContent='';el('social-unread').classList.add('hidden');
  });
  const syncNotificationContext=()=>window.__TAURI__.core.invoke('set_notification_context',{peerId:!document.hidden&&document.hasFocus()&&!el('page-messages').classList.contains('hidden')?peer?.id||null:null}).catch(()=>{});
  setInterval(syncNotificationContext,1000);window.addEventListener('focus',syncNotificationContext);window.addEventListener('blur',syncNotificationContext);document.addEventListener('visibilitychange',syncNotificationContext);document.querySelectorAll('.nav-item').forEach(button=>button.addEventListener('click',()=>queueMicrotask(syncNotificationContext)));
  window.__TAURI__.event?.listen('messaging-action',async event=>{const info=event.payload.extra||{};await refresh();if(state?.me.id!==info.accountId)return;document.querySelector('[data-page="messages"]').click();if(info.kind==='call'){await window.friendCalls?.handleNotification(info.callId,event.payload.action);return;}if(info.kind==='friends'){friendsTab=true;renderContacts();return;}const friend=state.friends.find(f=>f.id===info.peerId&&!f.blocked);if(friend)await select(friend);});
  setInterval(async()=>{
    if(el('app').classList.contains('hidden')) { if(state){state=null;resetChat();el('social-contacts').replaceChildren();el('social-unread').classList.add('hidden');}return; }
    await refresh();await load();
  },4000);
  document.querySelector('[data-page="messages"]').addEventListener('click',async()=>{await refresh();await load();});
})();
