// Conversation drawer; all account/peer text is rendered with textContent.
(() => {
 const node=(tag,text='',cls='')=>{const e=document.createElement(tag);e.textContent=text;e.className=cls;return e;};
 window.ChatSettings=class {
  constructor(options){Object.assign(this,options);this.open=false;this.busy=false;this.version=0;this.muted=false;}
  close(){this.open=false;++this.version;this.root.replaceChildren();this.root.classList.add('hidden');this.root.closest('.social-chat').classList.remove('settings-open');document.querySelector('#social-actions [aria-label="聊天信息"]')?.setAttribute('aria-expanded','false');}
  async toggle(){if(this.open){this.close();return;}this.open=true;this.root.classList.remove('hidden');this.root.closest('.social-chat').classList.add('settings-open');document.querySelector('#social-actions [aria-label="聊天信息"]')?.setAttribute('aria-expanded','true');this.render();const current=this.context(),version=++this.version;
   try{const value=await this.invoke('notification_settings',{accountId:current.me.id,value:null});if(this.valid(current,version)){this.muted=value.mutedPeers?.includes(current.peer.id)||false;this.render();}}catch(e){if(this.valid(current,version))this.error(e);}
  }
  valid(current,version=this.version){const now=this.context();return this.open&&version===this.version&&now.me?.id===current.me?.id&&now.peer?.id===current.peer?.id;}
  refresh(){const {me,peer}=this.context();if(this.open&&!this.busy&&this.fingerprint!==JSON.stringify([me?.id,peer?.id,peer?.name,peer?.remark,peer?.pinned,this.muted]))this.render();}
  async run(action){if(this.busy||!this.canChange())return;this.busy=true;this.render();try{await action();}catch(e){this.error(e);}finally{this.busy=false;if(this.open)this.render();}}
  render(){const {me,peer}=this.context();if(!me||!peer){this.close();return;}this.fingerprint=JSON.stringify([me.id,peer.id,peer.name,peer.remark,peer.pinned,this.muted]);this.root.replaceChildren();
   const person=node('button','','chat-settings-person');person.type='button';person.onclick=()=>this.profile(peer);const avatar=node('span','','chat-avatar');window.accountAvatars.render(avatar,peer);person.append(avatar,node('strong',peer.remark||peer.name),node('span',`账号 ID：${peer.accountId}`,'muted small'));this.root.append(person);
   const entry=(label,action,cls='')=>{const b=node('button',label,'chat-setting-row '+cls);b.type='button';b.disabled=this.busy;b.onclick=()=>this.run(action);this.root.append(b);return b;};
   entry('查找聊天记录',()=>this.invoke('open_chat_history',{peerId:peer.id})).append(node('span','›'));
   const toggle=(label,on,action)=>{const b=entry(label,action);b.setAttribute('role','switch');b.setAttribute('aria-checked',String(on));b.append(node('span','','chat-setting-switch'+(on?' on':'')));};
   toggle('消息免打扰',this.muted,async()=>{const current=this.context(),version=this.version;const value=await this.invoke('notification_settings',{accountId:me.id,value:null});if(!this.valid(current,version))return;const muted=new Set(value.mutedPeers||[]);this.muted?muted.delete(peer.id):muted.add(peer.id);await this.invoke('notification_settings',{accountId:me.id,value:{...value,mutedPeers:[...muted]}});if(this.valid(current,version)){this.muted=!this.muted;this.notice(this.muted?'已开启好友免打扰，消息保留未读，来电静音':'已关闭好友免打扰');}});
   toggle('置顶聊天',peer.pinned===true,()=>this.change('profile',{peerId:peer.id,action:'pin',pinned:peer.pinned!==true}));
   entry('清空聊天记录',async()=>{const current=this.context(),version=this.version;if(await window.askDialog({title:'清空聊天记录？',message:'将清空你与该好友的聊天记录，并同步到你登录的其他设备。对方的记录不受影响，清空后无法恢复。',danger:true})&&this.valid(current,version))await this.clear(peer);},'chat-clear-history');
   const extras=node('div','','chat-settings-extra');for(const [label,action] of [['好友资料',()=>this.profile(peer)],['设置备注',()=>this.remark(peer)],['拉黑好友',()=>this.block(peer)],['删除好友',()=>this.remove(peer)]]){const b=node('button',label,'ghost');b.type='button';b.disabled=this.busy;b.onclick=()=>this.run(action);extras.append(b);}this.root.append(extras);
   const close=node('button','收起','chat-settings-close');close.type='button';close.onclick=()=>this.close();this.root.append(close);
  }
 };
})();
