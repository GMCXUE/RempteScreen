// Shared chat rendering/actions. Only data-URI images and textContent reach the DOM.
(() => {
 const node=(tag,text='',cls='')=>{const e=document.createElement(tag);e.textContent=text;e.className=cls;return e;};
 const imageSource=value=>typeof value==='string'&&/^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$/.test(value)?value:'';
 const canRecall=(message,accountId,now=Date.now())=>message.senderId===accountId&&['text','image'].includes(message.kind||'text')&&now-Number(message.createdAt)<=120000;
 class ChatMessages {
  constructor(options){Object.assign(this,options);this.menu=null;this.dialog=null;this.dialogMessage=null;this.clockOffset=0;this.picking=false;this.copyingImage=false;this.recalled=new Set();document.addEventListener('pointerdown',e=>{if(this.menu&&!this.menu.contains(e.target))this.closeMenu();});document.addEventListener('keydown',e=>{if(e.key==='Escape')this.closeMenu();});}
  valid(context){const current=this.context();return current.accountId===context.accountId&&current.peerId===context.peerId&&current.generation===context.generation;}
  closeMenu(){this.menu?.remove();this.menu=null;this.menuMessage=null;}
  close(){this.closeMenu();const dialog=this.dialog;this.dialog=null;this.dialogMessage=null;dialog?.close();dialog?.remove();}
  invalidate(messages){for(const m of messages)if(m.kind==='recalled')this.recalled.add(m.id);if(messages.some(m=>m.id===this.dialogMessage&&m.kind==='recalled'))this.close();else if(messages.some(m=>m.id===this.menuMessage&&m.kind==='recalled'))this.closeMenu();}
  async copy(text){try{await this.invoke('plugin:clipboard-manager|write_text',{text});this.notice('已复制');}catch{this.error('复制失败，请重试');}}
  async copyImage(message){
   if(this.copyingImage)return;const context=this.context();this.copyingImage=true;
   try{const result=await this.api('message-image',{peerId:context.peerId,messageId:message.id});if(!this.valid(context))return;
    if(this.recalled.has(message.id))throw '图片已撤回';
    await this.invoke('copy_chat_image',{image:result.image});if(this.valid(context))this.notice('图片已复制');
   }catch(error){if(this.valid(context))this.error(String(error));}finally{this.copyingImage=false;}
  }
  row(message,me,peer,onRecall){
   const mine=message.senderId===me.id,row=node('div','','social-message-row'+(mine?' mine':''));row.dataset.messageId=message.id;
   if(message.kind==='recalled'){row.className='social-recalled';row.append(node('span',mine?'你撤回了一条消息':'对方撤回了一条消息'));return row;}
   const avatar=node('span','','chat-avatar');window.accountAvatars?.render(avatar,mine?me:peer);
   const bubble=node('div','','social-bubble'+(mine?' mine':''));bubble.tabIndex=0;bubble.setAttribute('aria-label','消息，右键或 Shift+F10 打开菜单');
   if(message.kind==='image'){
    bubble.classList.add('image-bubble');const photo=node('button','','chat-image-open');photo.type='button';photo.setAttribute('aria-label','查看图片');
    const image=node('img');image.src=imageSource(message.image?.thumbnail);image.alt='聊天图片';image.width=Math.min(message.image?.width||240,240);image.style.aspectRatio=`${message.image?.width||1} / ${message.image?.height||1}`;photo.append(image);photo.onclick=()=>this.preview(message).catch(this.error);bubble.append(photo);
   }else{
    if(message.kind==='call'){bubble.classList.add('call-record');bubble.append(node('span',message.call?.kind==='video'?'▣ 视频通话':'◖ 语音通话','call-record-type'));}
    bubble.append(node('span',message.text,'chat-message-text'));
   }
   bubble.append(node('small',new Date(Number(message.createdAt)).toLocaleString([], {month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'})));
   const more=node('button','•••','chat-message-more');more.type='button';more.setAttribute('aria-label','消息操作');more.onclick=()=>this.showMenu(message,bubble,onRecall,more.getBoundingClientRect());
   bubble.oncontextmenu=e=>{e.preventDefault();this.showMenu(message,bubble,onRecall,{left:e.clientX,bottom:e.clientY});};
   bubble.onkeydown=e=>{if(e.key==='ContextMenu'||(e.shiftKey&&e.key==='F10')){e.preventDefault();this.showMenu(message,bubble,onRecall,bubble.getBoundingClientRect());}};
   row.append(avatar,bubble,more);return row;
  }
  showMenu(message,bubble,onRecall,anchor){
   this.closeMenu();const context=this.context();const menu=node('div','','chat-context-menu');menu.setAttribute('role','menu');this.menu=menu;this.menuMessage=message.id;
   const add=(label,action)=>{const b=node('button',label);b.type='button';b.setAttribute('role','menuitem');b.onclick=()=>{this.closeMenu();Promise.resolve(action()).catch(this.error);};menu.append(b);};
   if(message.kind==='image'){add('查看图片',()=>this.preview(message));add('复制图片',()=>this.copyImage(message));}
   else {const selection=window.getSelection(),body=bubble.querySelector('.chat-message-text');const selected=selection&&!selection.isCollapsed&&body?.contains(selection.anchorNode)&&body.contains(selection.focusNode)?selection.toString():'';add(selected?'复制选中文字':'复制',()=>this.copy(selected||message.text));}
   if(canRecall(message,context.accountId,Date.now()+this.clockOffset))add('撤回',async()=>{
    if(!(await window.askDialog({title:'撤回消息？',message:'撤回后，对方将无法在聊天中查看这条消息。',danger:true}))||!this.valid(context))return;
    const response=await this.api('recall',{peerId:context.peerId,messageId:message.id});if(this.valid(context))await onRecall(response.message);
   });
   document.body.append(menu);menu.style.left=`${Math.max(8,Math.min(anchor.left,innerWidth-menu.offsetWidth-8))}px`;menu.style.top=`${Math.max(8,Math.min(anchor.bottom,innerHeight-menu.offsetHeight-8))}px`;menu.querySelector('button')?.focus({preventScroll:true});
  }
  createDialog(title){this.close();const dialog=node('dialog','','chat-image-dialog');const heading=node('div','','chat-image-heading');heading.append(node('strong',title));const close=node('button','关闭','ghost');close.type='button';close.onclick=()=>dialog.close();heading.append(close);dialog.append(heading);dialog.onclose=()=>{dialog.remove();if(this.dialog===dialog){this.dialog=null;this.dialogMessage=null;}};document.body.append(dialog);this.dialog=dialog;dialog.showModal();return dialog;}
  async preview(message){
   const context=this.context(),dialog=this.createDialog('查看图片');this.dialogMessage=message.id;const copy=node('button','复制图片','ghost');copy.type='button';copy.disabled=true;copy.onclick=()=>this.copyImage(message);dialog.querySelector('.chat-image-heading').insertBefore(copy,dialog.querySelector('.chat-image-heading button'));
   const image=node('img');image.alt='聊天图片';image.src=imageSource(message.image?.thumbnail);dialog.append(image);const status=node('p','正在加载图片…','muted small');dialog.append(status);
   try{const result=await this.api('message-image',{peerId:context.peerId,messageId:message.id});if(!this.valid(context)||this.dialog!==dialog)return;image.src=imageSource(result.image);status.remove();copy.disabled=false;}
   catch(error){if(this.dialog===dialog)status.textContent=String(error);}
  }
  async chooseImage(onSent){
   if(this.picking)return;const context=this.context();if(!context.peerId)return;this.picking=true;
   try{
    const image=await this.invoke('pick_chat_image');if(!image||!this.valid(context))return;
    const dialog=this.createDialog('发送图片'),photo=node('img');photo.alt='待发送图片';photo.src=imageSource(image);dialog.append(photo);
    const status=node('p','','chat-image-error');dialog.append(status);const send=node('button','发送','primary');send.type='button';dialog.append(send);const clientId=crypto.randomUUID?.()||Array.from(crypto.getRandomValues(new Uint8Array(24)),b=>b.toString(16).padStart(2,'0')).join('');let busy=false;
    dialog.addEventListener('cancel',e=>{if(busy)e.preventDefault();});
    send.onclick=async()=>{
     if(busy||!this.valid(context))return;busy=true;send.disabled=true;dialog.querySelector('.chat-image-heading button').disabled=true;status.textContent='';send.textContent='发送中…';
     try{const data=await this.api('send-image',{peerId:context.peerId,image,clientId});if(this.dialog!==dialog||!this.valid(context))return;dialog.close();await onSent(data.message);}
     catch(error){if(this.dialog===dialog&&this.valid(context))status.textContent=String(error);}
     finally{busy=false;send.disabled=false;send.textContent='发送';dialog.querySelector('.chat-image-heading button').disabled=false;}
    };
   }finally{this.picking=false;}
  }
 }
 window.ChatMessages=ChatMessages;
})();
