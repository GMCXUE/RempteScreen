// Shared chat rendering/actions. Only data-URI images and textContent reach the DOM.
(() => {
 const node=(tag,text='',cls='')=>{const e=document.createElement(tag);e.textContent=text;e.className=cls;return e;};
 const imageSource=value=>typeof value==='string'&&/^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$/.test(value)?value:'';
 const canRecall=(message,accountId,now=Date.now())=>message.senderId===accountId&&['text','image'].includes(message.kind||'text')&&now-Number(message.createdAt)<=120000;
 class ChatMessages {
  constructor(options){Object.assign(this,options);this.menu=null;this.dialog=null;this.dialogMessage=null;this.clockOffset=0;this.picking=false;this.draftImages=[];this.copyingImage=false;this.recalled=new Set();document.addEventListener('pointerdown',e=>{if(this.menu&&!this.menu.contains(e.target))this.closeMenu();});document.addEventListener('keydown',e=>{if(e.key==='Escape')this.closeMenu();});}
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
   const add=(label,action)=>{const b=node('button');window.uiIcons.button(b,label==='撤回'?'undo':label==='查看图片'?'expand':'copy',label);b.type='button';b.setAttribute('role','menuitem');b.onclick=()=>{this.closeMenu();Promise.resolve(action()).catch(this.error);};menu.append(b);};
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
  removeDraftImage(id){this.draftImages=this.draftImages.filter(image=>image.id!==id);this.onDraftChanged?.();}
  clearDraft(){this.draftImages=[];this.onDraftChanged?.();}
  async pasteImage(event){
   const items=Array.from(event.clipboardData?.items||[]),file=items.find(item=>item.kind==='file'&&item.type.startsWith('image/'))?.getAsFile();
   if(file){event.preventDefault();return this.prepareImage(async()=>{
    if(!['image/jpeg','image/png','image/webp'].includes(file.type))throw '请选择 JPG、PNG 或 WebP 图片';
    if(file.size>8*1024*1024)throw '图片过大，请选择 8 MB 以内的图片';
    return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject('无法读取剪贴板图片，请重新复制');reader.readAsDataURL(file);});
   });}
   // Leave ordinary text paste (including the caret and selected text) to the WebView.
   if(event.clipboardData?.getData('text/plain'))return;
   return this.prepareImage(()=>this.invoke('read_chat_image'));
  }
  async chooseImage(){return this.prepareImage(()=>this.invoke('pick_chat_image'));}
  async prepareImage(read){
   if(this.picking||this.canCompose?.()===false)return;const context=this.context();if(!context.peerId)return;
   if(this.draftImages.length>=9)throw '最多添加 9 张图片';
   this.picking=true;this.onDraftChanged?.();
   try{
    const image=await read();if(!image||!this.valid(context))return;
    if(!imageSource(image))throw '请选择 JPG、PNG 或 WebP 图片';
    const id=crypto.randomUUID?.()||Array.from(crypto.getRandomValues(new Uint8Array(24)),b=>b.toString(16).padStart(2,'0')).join('');
    this.draftImages.push({image,id});this.onDraftChanged?.();this.focusDraft?.();
   }catch(error){if(this.valid(context))throw error;}finally{this.picking=false;this.onDraftChanged?.();}
  }
 }
 window.ChatMessages=ChatMessages;
})();
