(() => {
 const catalog=[['cat','默认头像 1'],['dog','默认头像 2'],['fox','默认头像 3'],['rabbit','默认头像 4'],['bear','默认头像 5'],['panda','默认头像 6'],['penguin','默认头像 7'],['owl','默认头像 8']];
 const normalize=id=>id==='custom'||catalog.some(item=>item[0]===id)?id:'cat';
 let me=null,version=0,picking=false;
 const images=new Map();
 function customImage(person){
  const key=`${version}:${person.id}:${person.avatarRevision}`;
  if(!images.has(key)){
   if(images.size>64)images.delete(images.keys().next().value);
   const promise=window.__TAURI__.core.invoke('social_api',{operation:'avatar-image',body:{peerId:person.id,revision:person.avatarRevision}}).then(result=>{
    if(typeof result.image!=='string'||result.image.length>410000||!/^data:image\/png;base64,[A-Za-z0-9+/]+={0,2}$/.test(result.image))throw new Error('头像图片无效');return result.image;
   }).catch(error=>{images.delete(key);throw error;});images.set(key,promise);
  }
  return images.get(key);
 }
 function image(value){
  const person=typeof value==='object'&&value?value:{avatarId:value};
  const id=normalize(person.avatarId),img=document.createElement('img');img.src=`avatars/${id==='custom'?'cat':id}.png`;img.alt='';img.draggable=false;img.className='avatar-art';
  if(person.image)img.src=person.image;
  else if(id==='custom'&&person.id&&person.avatarRevision){const session=version;customImage(person).then(data=>{if(session===version)img.src=data;}).catch(()=>{});}
  return img;
 }
 function render(element,value){if(element)element.replaceChildren(image(value));}
 function renderOwn(){render(document.getElementById('account-avatar'),me);render(document.getElementById('settings-avatar'),me);const name=document.getElementById('settings-account-name'),id=document.getElementById('settings-account-id');if(name)name.textContent=me?.name||'个人资料';if(id)id.textContent=me?.accountId?`账号 ID：${me.accountId}`:'查看与编辑个人资料';}
 function update(value){me=value;renderOwn();}
 async function choose(){
  if(picking)return;document.getElementById('user-menu').classList.add('hidden');picking=true;const session=version;
  const dialog=document.createElement('dialog');dialog.className='avatar-dialog';let saving=false,selecting=false;
  dialog.addEventListener('cancel',event=>{if(saving||selecting)event.preventDefault();});
  const close=()=>{dialog.close();dialog.remove();picking=false;};
  try{
   const data=await window.__TAURI__.core.invoke('social_api',{operation:'state',body:{}});if(session!==version){picking=false;return;}
   update(data.me);let selected={...me,avatarId:normalize(me.avatarId)};
   const title=document.createElement('h2');title.textContent='更换头像';
   const preview=document.createElement('div');preview.className='avatar-preview';render(preview,selected);
   const upload=document.createElement('button');upload.type='button';upload.textContent='从图片选择';upload.className='avatar-upload';
   const grid=document.createElement('div');grid.className='avatar-grid';grid.setAttribute('role','group');grid.setAttribute('aria-label','默认头像');const buttons=[];
   const select=value=>{selected=value;render(preview,value);for(const b of buttons){const on=b.dataset.avatar===value.avatarId&&!value.image;b.classList.toggle('selected',on);b.setAttribute('aria-pressed',String(on));}};
   for(const [id,label] of catalog){const b=document.createElement('button');b.type='button';b.dataset.avatar=id;b.className='avatar-option';b.setAttribute('aria-label',label);b.append(image(id));b.onclick=()=>select({avatarId:id});buttons.push(b);grid.append(b);}
   if(me.avatarId==='custom'){const b=document.createElement('button');b.type='button';b.dataset.avatar='custom';b.className='avatar-option';b.setAttribute('aria-label','当前头像');b.append(image(me));b.onclick=()=>select({...me});buttons.push(b);grid.prepend(b);}
   select(selected);const error=document.createElement('p');error.className='error';error.setAttribute('role','status');
   upload.onclick=async()=>{if(selecting||saving)return;selecting=true;for(const b of [...buttons,upload,cancel,save])b.disabled=true;error.textContent='';try{const photo=await window.__TAURI__.core.invoke('pick_avatar_image');if(!photo||session!==version||!dialog.isConnected)return;const result=await window.cropAvatarPhoto(photo);if(result&&session===version&&dialog.isConnected)select({avatarId:'custom',image:result});}catch(e){error.textContent=String(e);}finally{selecting=false;for(const b of [...buttons,upload,cancel,save])b.disabled=false;}};
   const actions=document.createElement('div');actions.className='avatar-dialog-actions';const cancel=document.createElement('button');cancel.textContent='取消';cancel.className='ghost';cancel.onclick=close;
   const save=document.createElement('button');save.textContent='保存头像';save.className='primary';
   save.onclick=async()=>{if(saving)return;saving=true;save.textContent='保存中…';for(const b of [...buttons,upload,cancel,save])b.disabled=true;error.textContent='';try{const result=await window.__TAURI__.core.invoke('social_api',{operation:'avatar',body:{avatarId:selected.avatarId,...(selected.image?{image:selected.image}:{})}});if(session===version){update({...me,...result});window.dispatchEvent(new Event('account-avatar-changed'));}close();if(session===version)window.showAppToast('头像已更新');}catch(e){error.textContent=String(e);}finally{saving=false;save.textContent='保存头像';for(const b of [...buttons,upload,cancel,save])b.disabled=false;}};
   actions.append(cancel,save);dialog.append(title,preview,upload,grid,error,actions);document.body.append(dialog);dialog.showModal();save.focus();dialog.addEventListener('close',()=>{dialog.remove();picking=false;},{once:true});
  }catch(error){picking=false;window.showAppToast(String(error));}
 }
 window.accountAvatars={catalog,normalize,image,render,renderOwn,update,choose,me:()=>me};
 document.getElementById('choose-avatar').onclick=choose;document.getElementById('social-choose-avatar').onclick=choose;
 window.addEventListener('social-account-changed',()=>{++version;me=null;images.clear();renderOwn();document.querySelectorAll('.avatar-dialog').forEach(d=>d.close());});
})();
