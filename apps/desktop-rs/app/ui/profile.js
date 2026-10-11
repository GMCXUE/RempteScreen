(() => {
 const el=id=>document.getElementById(id);
 let editing=false,viewing=false,version=0;
 function profileFields(person,own=false){
  const list=document.createElement('dl');list.className='friend-profile-fields';
  const rows=[['账号 ID',person.accountId],['个人简介',person.bio],['性别',person.gender==='male'?'男':person.gender==='female'?'女':''],['生日',person.birthday],['地区',person.region]];
  if(own)rows.push(['邮箱',person.email]);
  for(const [label,value] of rows){const term=document.createElement('dt');term.textContent=label;const desc=document.createElement('dd');desc.textContent=value||'未设置';list.append(term,desc);}return list;
 }
 async function overview(){
  if(viewing||editing)return;viewing=true;const session=version;el('user-menu').classList.add('hidden');
  const dialog=document.createElement('dialog');dialog.className='profile-dialog profile-overview';
  try{
   const {me}=await window.__TAURI__.core.invoke('social_api',{operation:'state',body:{}});
   if(session!==version){viewing=false;return;}window.accountAvatars.update(me);
   const title=document.createElement('h2');title.textContent='个人资料';
   const hero=document.createElement('div');hero.className='profile-hero';
   const avatar=document.createElement('div');avatar.className='avatar-preview';window.accountAvatars.render(avatar,me);
   const name=document.createElement('strong');name.textContent=me.name;hero.append(avatar,name);
   const actions=document.createElement('div');actions.className='avatar-dialog-actions';
   const close=document.createElement('button');close.className='ghost';close.textContent='关闭';close.onclick=()=>dialog.close();
   const editButton=document.createElement('button');editButton.className='primary';editButton.textContent='编辑资料';editButton.onclick=()=>{dialog.close();edit();};actions.append(close,editButton);
   dialog.append(title,hero,profileFields(me,true),actions);dialog.addEventListener('close',()=>{dialog.remove();viewing=false;},{once:true});document.body.append(dialog);dialog.showModal();
  }catch(error){viewing=false;dialog.remove();window.showAppToast(String(error));}
 }
 async function edit(){
  if(editing)return;editing=true;const session=version;el('user-menu').classList.add('hidden');
  const dialog=document.createElement('dialog');dialog.className='profile-dialog';let saving=false;
  try{
   const {me}=await window.__TAURI__.core.invoke('social_api',{operation:'state',body:{}});
   if(session!==version){editing=false;return;}
   window.accountAvatars.update(me);
   const title=document.createElement('h2');title.textContent='个人资料';
   const hero=document.createElement('div');hero.className='profile-hero';
   const avatar=document.createElement('div');avatar.className='avatar-preview';window.accountAvatars.render(avatar,me);
   const change=document.createElement('button');change.type='button';change.className='ghost';change.textContent='更换头像';change.onclick=()=>window.accountAvatars.choose();hero.append(avatar,change);
   const form=document.createElement('form');form.className='profile-form';form.id='account-profile-form';
   const fields={};
   function field(key,label,kind,value,{max,readonly=false}={}){
    const wrap=document.createElement('label');wrap.className='profile-field';wrap.append(document.createTextNode(label));
    const input=document.createElement(kind==='textarea'?'textarea':kind==='select'?'select':'input');if(kind!=='textarea'&&kind!=='select')input.type=kind;
    input.name=key;input.value=value||'';input.readOnly=readonly;if(max)input.maxLength=max;fields[key]=input;wrap.append(input);form.append(wrap);return input;
   }
   const nickname=field('name','昵称','text',me.name,{max:32});nickname.required=true;nickname.parentElement.classList.add('full');
   const gender=field('gender','性别','select',me.gender);
   for(const [value,text] of [['','不设置'],['male','男'],['female','女']]){const option=document.createElement('option');option.value=value;option.textContent=text;gender.append(option);}gender.value=me.gender||'';
   const birthday=field('birthday','生日','date',me.birthday);birthday.min='1900-01-01';const today=new Date();birthday.max=`${today.getFullYear()}-${String(today.getMonth()+1).padStart(2,'0')}-${String(today.getDate()).padStart(2,'0')}`;
   field('region','地区','text',me.region,{max:32}).placeholder='可填写城市或地区';
   const bio=field('bio','个人简介','textarea',me.bio,{max:160});bio.placeholder='介绍一下自己';bio.rows=3;bio.parentElement.classList.add('full');
   field('accountId','账号 ID','text',me.accountId,{readonly:true});field('email','邮箱','text',me.email,{readonly:true});
   const heading=text=>{const h=document.createElement('h3');h.className='profile-section-title';h.textContent=text;return h;};
   form.replaceChildren(heading('基本资料'),fields.name.parentElement,fields.bio.parentElement,heading('更多资料'),fields.gender.parentElement,fields.birthday.parentElement,fields.region.parentElement,heading('账号信息'),fields.accountId.parentElement,fields.email.parentElement);
   const note=document.createElement('p');note.className='muted small profile-note';note.textContent='昵称和个人资料会显示在好友资料中，生日、性别、地区可以留空。';
   const error=document.createElement('p');error.className='error';error.setAttribute('role','status');
   const actions=document.createElement('div');actions.className='avatar-dialog-actions';const cancel=document.createElement('button');cancel.type='button';cancel.textContent='取消';cancel.className='ghost';cancel.onclick=()=>dialog.close();
   const save=document.createElement('button');save.type='submit';save.setAttribute('form',form.id);save.textContent='保存资料';save.className='primary';actions.append(cancel,save);form.append(note,error);
   form.onsubmit=async event=>{event.preventDefault();if(saving||session!==version)return;saving=true;save.textContent='保存中…';for(const f of [...Object.values(fields),cancel,save,change])f.disabled=true;error.textContent='';try{const body={};for(const key of ['name','gender','birthday','region','bio'])body[key]=fields[key].value;const result=await window.__TAURI__.core.invoke('social_api',{operation:'account-profile',body});if(session!==version)return;window.accountAvatars.update(result.user);el('account-name').textContent=el('menu-name').textContent=result.user.name;window.dispatchEvent(new Event('account-profile-changed'));dialog.close();window.showAppToast('资料已更新');}catch(e){error.textContent=String(e);}finally{saving=false;save.textContent='保存资料';for(const f of [...Object.values(fields),cancel,save,change])f.disabled=false;}};
   const refreshAvatar=()=>window.accountAvatars.render(avatar,window.accountAvatars.me());window.addEventListener('account-avatar-changed',refreshAvatar);
   dialog.addEventListener('cancel',event=>{if(saving)event.preventDefault();});dialog.addEventListener('close',()=>{dialog.remove();editing=false;window.removeEventListener('account-avatar-changed',refreshAvatar);},{once:true});dialog.append(title,hero,form,actions);document.body.append(dialog);dialog.showModal();fields.name.focus();
  }catch(e){editing=false;window.showAppToast(String(e));dialog.remove();}
 }
 el('edit-profile').onclick=overview;el('social-edit-profile').onclick=overview;el('settings-profile').onclick=overview;
 window.showFriendProfile=person=>{
  const dialog=document.createElement('dialog');dialog.className='profile-dialog';
  const title=document.createElement('h2');title.textContent='好友资料';
  const hero=document.createElement('div');hero.className='profile-hero';const avatar=document.createElement('div');avatar.className='avatar-preview';window.accountAvatars.render(avatar,person);const name=document.createElement('strong');name.textContent=person.name;hero.append(avatar,name);
  const list=profileFields(person);
  const close=document.createElement('button');close.className='ghost';close.textContent='关闭';close.onclick=()=>dialog.close();dialog.append(title,hero,list,close);dialog.addEventListener('close',()=>dialog.remove(),{once:true});document.body.append(dialog);dialog.showModal();
 };
 window.addEventListener('social-account-changed',()=>{++version;document.querySelectorAll('.profile-dialog').forEach(d=>d.close());});
})();
