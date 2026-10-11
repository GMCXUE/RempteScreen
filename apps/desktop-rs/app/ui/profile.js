(() => {
 const el=id=>document.getElementById(id);
 let editing=false,version=0;
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
   field('name','昵称','text',me.name,{max:32}).required=true;
   const gender=field('gender','性别','select',me.gender);
   for(const [value,text] of [['','不设置'],['male','男'],['female','女']]){const option=document.createElement('option');option.value=value;option.textContent=text;gender.append(option);}gender.value=me.gender||'';
   const birthday=field('birthday','生日','date',me.birthday);birthday.min='1900-01-01';const today=new Date();birthday.max=`${today.getFullYear()}-${String(today.getMonth()+1).padStart(2,'0')}-${String(today.getDate()).padStart(2,'0')}`;
   field('region','地区','text',me.region,{max:32}).placeholder='可填写城市或地区';
   const bio=field('bio','个人简介','textarea',me.bio,{max:160});bio.placeholder='介绍一下自己';bio.rows=3;bio.parentElement.classList.add('full');
   field('accountId','账号 ID','text',me.accountId,{readonly:true});field('email','邮箱','text',me.email,{readonly:true});
   const note=document.createElement('p');note.className='muted small profile-note';note.textContent='昵称和个人资料会显示在好友资料中，生日、性别、地区可以留空。';
   const error=document.createElement('p');error.className='error';error.setAttribute('role','status');
   const actions=document.createElement('div');actions.className='avatar-dialog-actions';const cancel=document.createElement('button');cancel.type='button';cancel.textContent='取消';cancel.className='ghost';cancel.onclick=()=>dialog.close();
   const save=document.createElement('button');save.type='submit';save.setAttribute('form',form.id);save.textContent='保存资料';save.className='primary';actions.append(cancel,save);form.append(note,error);
   form.onsubmit=async event=>{event.preventDefault();if(saving||session!==version)return;saving=true;save.textContent='保存中…';for(const f of [...Object.values(fields),cancel,save,change])f.disabled=true;error.textContent='';try{const body={};for(const key of ['name','gender','birthday','region','bio'])body[key]=fields[key].value;const result=await window.__TAURI__.core.invoke('social_api',{operation:'account-profile',body});if(session!==version)return;window.accountAvatars.update(result.user);el('account-name').textContent=el('menu-name').textContent=result.user.name;window.dispatchEvent(new Event('account-profile-changed'));dialog.close();window.showAppToast('资料已更新');}catch(e){error.textContent=String(e);}finally{saving=false;save.textContent='保存资料';for(const f of [...Object.values(fields),cancel,save,change])f.disabled=false;}};
   const refreshAvatar=()=>window.accountAvatars.render(avatar,window.accountAvatars.me());window.addEventListener('account-avatar-changed',refreshAvatar);
   dialog.addEventListener('cancel',event=>{if(saving)event.preventDefault();});dialog.addEventListener('close',()=>{dialog.remove();editing=false;window.removeEventListener('account-avatar-changed',refreshAvatar);},{once:true});dialog.append(title,hero,form,actions);document.body.append(dialog);dialog.showModal();fields.name.focus();
  }catch(e){editing=false;window.showAppToast(String(e));dialog.remove();}
 }
 el('edit-profile').onclick=edit;el('social-edit-profile').onclick=edit;
 window.showFriendProfile=person=>{
  const dialog=document.createElement('dialog');dialog.className='profile-dialog';
  const title=document.createElement('h2');title.textContent='好友资料';
  const hero=document.createElement('div');hero.className='profile-hero';const avatar=document.createElement('div');avatar.className='avatar-preview';window.accountAvatars.render(avatar,person);const name=document.createElement('strong');name.textContent=person.name;hero.append(avatar,name);
  const list=document.createElement('dl');list.className='friend-profile-fields';
  for(const [label,value] of [['账号 ID',person.accountId],['个人简介',person.bio],['性别',person.gender==='male'?'男':person.gender==='female'?'女':''],['生日',person.birthday],['地区',person.region]]){const term=document.createElement('dt');term.textContent=label;const desc=document.createElement('dd');desc.textContent=value||'未设置';list.append(term,desc);}
  const close=document.createElement('button');close.className='ghost';close.textContent='关闭';close.onclick=()=>dialog.close();dialog.append(title,hero,list,close);dialog.addEventListener('close',()=>dialog.remove(),{once:true});document.body.append(dialog);dialog.showModal();
 };
 window.addEventListener('social-account-changed',()=>{++version;document.querySelectorAll('.profile-dialog').forEach(d=>d.close());});
})();
