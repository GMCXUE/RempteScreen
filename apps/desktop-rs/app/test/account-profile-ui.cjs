const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs=require('fs'),assert=require('assert'),path=require('path');
(async()=>{
 const root=path.resolve(__dirname,'../ui')+path.sep;
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_EXECUTABLE});
 try{
  const page=await browser.newPage({viewport:{width:940,height:620},deviceScaleFactor:2});
  const errors=[];page.on('pageerror',e=>errors.push(String(e)));
  const source=fs.readFileSync(root+'index.html','utf8');
  const scripts=[...source.matchAll(/<script src="([^"]+)"/g)].map(match=>match[1]);
  for(const file of ['avatars.js','profile.js','chat-messages.js','chat-settings.js','chat-outbox.js','social.js','app.js','friend-calls.js'])assert.ok(scripts.indexOf('feedback.js')>=0&&scripts.indexOf('feedback.js')<scripts.indexOf(file));
  const html=source.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'');
  await page.route('http://local.test/**',route=>{
   const url=new URL(route.request().url());
   if(url.pathname==='/')return route.fulfill({body:html,contentType:'text/html'});
   if(url.pathname==='/style.css')return route.fulfill({body:fs.readFileSync(root+'style.css','utf8'),contentType:'text/css'});
   if(/^\/avatars\/[a-z]+\.png$/.test(url.pathname))return route.fulfill({body:fs.readFileSync(root+url.pathname.slice(1)),contentType:'image/png'});
   return route.abort();
  });
  await page.goto('http://local.test/');
  await page.evaluate(()=>{
   document.querySelector('#app').classList.remove('hidden');document.querySelector('#login-view').classList.add('hidden');document.querySelector('.content').classList.add('social-content');
   document.querySelectorAll('.page').forEach(e=>e.classList.toggle('hidden',e.id!=='page-messages'));
   window.me={id:'me',name:'测试账号',accountId:'123456',email:'me@example.test',avatarId:'cat',bio:'',region:'',gender:'',birthday:''};
   window.friend={id:'peer',name:'小林',remark:'',accountId:'234567',avatarId:'rabbit',online:true,blocked:false,unread:0,lastText:'你好'};
   window.failSave=false;window.saved=[];window.listeners={};window.askDialog=async()=>null;window.friendCalls={start:()=>{}};
   window.__TAURI__={event:{listen:async(type,fn)=>window.listeners[type]=fn},core:{invoke:async(command,args)=>{
    if(command==='pick_avatar_image')return window.testPhoto;
    if(command==='social_api'){
     if(args.operation==='state'){if(window.failState)throw '资料读取失败';return {me:{...window.me},friends:[{...window.friend}],requests:[],outgoing:[],blocked:[]};}
     if(args.operation==='avatar'){if(window.failSave)throw '网络不可用';window.saved.push(args.body.avatarId);window.me.avatarId=args.body.avatarId;window.me.avatarRevision=args.body.avatarId==='custom'?'a'.repeat(64):'';if(args.body.image)window.avatarImage=args.body.image;return {avatarId:window.me.avatarId,avatarRevision:window.me.avatarRevision};}
     if(args.operation==='avatar-image')return {image:window.avatarImage};
     if(args.operation==='account-profile'){if(window.failProfile)throw '保存失败';window.profileBody=args.body;Object.assign(window.me,args.body);return {user:{...window.me}};}
     if(args.operation==='messages')return {hasMore:false,messages:[{seq:'1',id:'m1',senderId:'peer',text:'你好',createdAt:'1791680000000'},{seq:'2',id:'m2',senderId:'me',text:'你好！',createdAt:'1791680000001'}]};
     return {ok:true};
    }
   }}};
  });
  for(const file of scripts.filter(file=>['ui-icons.js','feedback.js','avatar-crop.js','avatars.js','profile.js','chat-messages.js','chat-settings.js','chat-outbox.js','social.js'].includes(file)))await page.addScriptTag({content:fs.readFileSync(root+file,'utf8')});
  assert.equal(await page.evaluate(()=>typeof window.toast),'undefined');
  await page.locator('[data-page="messages"]').click();
  await page.waitForFunction(()=>document.querySelector('#account-avatar img'));
  await page.locator('.social-contact').click();await page.waitForFunction(()=>document.querySelectorAll('.social-message-row').length===2);
  assert.ok((await page.locator('.social-contact img').getAttribute('src')).endsWith('rabbit.png'));
  assert.ok((await page.locator('.social-message-row.mine img').getAttribute('src')).endsWith('cat.png'));
  await page.evaluate(()=>window.accountAvatars.choose());await page.waitForSelector('.avatar-dialog');
  assert.equal(await page.locator('.avatar-option').count(),8);
  await page.locator('[data-avatar="fox"]').click();
  assert.equal(await page.locator('[data-avatar="fox"]').getAttribute('aria-pressed'),'true');
  assert.equal((await page.evaluate(()=>window.saved)).length,0);
  await page.evaluate(()=>window.failSave=true);await page.getByRole('button',{name:'保存头像',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('.avatar-dialog .error').textContent==='网络不可用');
  assert.ok((await page.locator('#account-avatar img').getAttribute('src')).endsWith('cat.png'));
  await page.evaluate(()=>window.failSave=false);await page.getByRole('button',{name:'保存头像',exact:true}).click();
  await page.waitForFunction(()=>!document.querySelector('.avatar-dialog'));
  assert.ok((await page.locator('#account-avatar img').getAttribute('src')).endsWith('fox.png'));
  assert.equal(await page.locator('#ft-toast').innerText(),'头像已更新');
  assert.equal(await page.locator('#ft-toast').evaluate(el=>el.onclick),null);
  await page.evaluate(()=>window.accountAvatars.choose());await page.waitForSelector('.avatar-dialog');
  assert.equal(await page.locator('[data-avatar="fox"]').getAttribute('aria-pressed'),'true');
  await page.getByRole('button',{name:'取消',exact:true}).click();
  await page.evaluate(()=>{const el=document.createElement('span');window.accountAvatars.render(el,'../unknown');window.fallback=el.firstChild.getAttribute('src');});assert.equal(await page.evaluate(()=>window.fallback),'avatars/cat.png');
  await page.evaluate(data=>window.testPhoto=data,'data:image/png;base64,'+fs.readFileSync(root+'avatars/fox.png').toString('base64'));
  await page.evaluate(()=>window.accountAvatars.choose());await page.waitForSelector('.avatar-dialog');
  assert.equal((await page.locator('.avatar-grid').innerText()).trim(),'');
  await page.getByRole('button',{name:'从图片选择',exact:true}).click();await page.waitForSelector('.crop-dialog');
  await page.locator('.crop-dialog input').fill('2');
  const box=await page.locator('.avatar-crop-canvas').boundingBox();await page.mouse.move(box.x+100,box.y+100);await page.mouse.down();await page.mouse.move(box.x+130,box.y+110);await page.mouse.up();
  await page.getByRole('button',{name:'使用照片',exact:true}).click();await page.waitForFunction(()=>!document.querySelector('.crop-dialog'));
  assert.ok((await page.locator('.avatar-preview img').getAttribute('src')).startsWith('data:image/png;base64,'));
  await page.getByRole('button',{name:'保存头像',exact:true}).click();await page.waitForFunction(()=>!document.querySelector('.avatar-dialog'));
  await page.waitForFunction(()=>document.querySelector('#account-avatar img').src.startsWith('data:image/png;base64,'));
  assert.equal(await page.locator('#account-avatar img').evaluate(img=>img.naturalWidth),256);
  assert.equal(await page.locator('#ft-toast').innerText(),'头像已更新');
  assert.deepEqual(await page.evaluate(()=>window.saved),['fox','custom']);
  await page.locator('.social-identity summary').click();await page.locator('#social-edit-profile').click();await page.waitForSelector('.profile-dialog');
  await page.getByRole('button',{name:'编辑资料',exact:true}).click();await page.waitForSelector('.profile-form');
  assert.equal(await page.locator('input[name="accountId"]').getAttribute('readonly'),'');
  await page.locator('input[name="name"]').fill('新的昵称');await page.locator('textarea[name="bio"]').fill('这是个人简介');await page.locator('input[name="region"]').fill('上海');
  const saveBox=await page.getByRole('button',{name:'保存资料',exact:true}).boundingBox();assert.ok(saveBox.y+saveBox.height<=620);
  await page.evaluate(()=>window.failProfile=true);await page.getByRole('button',{name:'保存资料',exact:true}).click();await page.waitForFunction(()=>document.querySelector('.profile-dialog .error').textContent==='保存失败');
  assert.equal(await page.locator('input[name="name"]').inputValue(),'新的昵称');
  await page.evaluate(()=>window.failProfile=false);await page.getByRole('button',{name:'保存资料',exact:true}).click();await page.waitForFunction(()=>!document.querySelector('.profile-dialog'));
  assert.equal(await page.locator('#account-name').innerText(),'新的昵称');
  assert.equal(await page.locator('#ft-toast').innerText(),'资料已更新');
  assert.deepEqual(Object.keys(await page.evaluate(()=>window.profileBody)).sort(),['bio','birthday','gender','name','region']);
  await page.evaluate(()=>window.showFriendProfile({...window.friend,bio:'朋友的简介',region:'杭州'}));await page.waitForSelector('.profile-dialog');assert.ok((await page.locator('.profile-dialog').innerText()).includes('朋友的简介'));await page.getByRole('button',{name:'关闭',exact:true}).click();
  await page.evaluate(()=>{window.failState=true;});await page.evaluate(()=>window.accountAvatars.choose());
  assert.equal(await page.locator('.avatar-dialog').count(),0);assert.equal(await page.locator('#ft-toast').innerText(),'资料读取失败');
  await page.locator('#social-edit-profile').click();await page.waitForFunction(()=>document.querySelector('#ft-toast').textContent==='资料读取失败');
  await page.evaluate(()=>{window.failState=false;window.showAppToast('旧提示',20);window.showAppToast('新提示',1000);});
  await page.waitForTimeout(50);assert.equal(await page.locator('#ft-toast').innerText(),'新提示');assert.equal(await page.locator('#ft-toast').evaluate(e=>e.classList.contains('hidden')),false);
  await page.evaluate(()=>window.dispatchEvent(new Event('social-account-changed')));assert.equal(await page.locator('#ft-toast').evaluate(e=>e.classList.contains('hidden')),true);
  assert.deepEqual(errors,[]);console.log('桌面真实提示回归检查通过：无全局 toast 模拟，默认和自定义头像保存、失败重试、资料保存、读取失败、提示计时及退出清理');
 }finally{await browser.close();}
})();
