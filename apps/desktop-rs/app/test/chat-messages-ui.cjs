const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_EXECUTABLE});
 try{
  const page=await browser.newPage({viewport:{width:1100,height:740}}),errors=[];
  page.on('pageerror',e=>errors.push(String(e)));
  const root=path.resolve(__dirname,'../ui');
  const source=fs.readFileSync(path.join(root,'index.html'),'utf8');
  assert.ok(source.indexOf('chat-messages.js')<source.indexOf('social.js'));
  await page.route('http://chat.test/**',route=>{
   const pathname=new URL(route.request().url()).pathname;
   if(pathname==='/')return route.fulfill({body:source.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,''),contentType:'text/html'});
   if(pathname==='/style.css')return route.fulfill({body:fs.readFileSync(path.join(root,'style.css')),contentType:'text/css'});
   if(/^\/avatars\/[a-z]+\.png$/.test(pathname))return route.fulfill({body:fs.readFileSync(path.join(root,pathname.slice(1))),contentType:'image/png'});
   return route.abort();
  });
  await page.clock.install();await page.goto('http://chat.test/');
  await page.evaluate(()=>{
   document.querySelector('#app').classList.remove('hidden');document.querySelector('#login-view').classList.add('hidden');document.querySelector('.content').classList.add('social-content');
   document.querySelectorAll('.page').forEach(e=>e.classList.toggle('hidden',e.id!=='page-messages'));
   window.me={id:'me',name:'我',accountId:'123456',avatarId:'cat'};window.peer={id:'peer',name:'小林',remark:'',accountId:'234567',avatarId:'rabbit',unread:0,online:true,lastText:'第一行',blocked:false};
   window.photo='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=';
   window.rows=[{id:'m1',seq:'1',senderId:'peer',kind:'text',text:'第一行\n第二行',createdAt:String(Date.now())},{id:'m2',seq:'2',senderId:'me',kind:'text',text:'我的消息',createdAt:String(Date.now())},{id:'m3',seq:'3',senderId:'me',kind:'text',text:'过期消息',createdAt:String(Date.now()-130000)}];
   window.changes=[];window.calls=[];window.copy=[];window.confirm=true;window.failImage=true;window.friendCalls={start:()=>{}};window.askDialog=async()=>window.confirm;
   window.__TAURI__={event:{listen:async()=>{}},core:{invoke:async(command,args)=>{
    if(command==='plugin:clipboard-manager|write_text'){window.copy.push(args.text);return;}
    if(command==='pick_chat_image')return window.photo;
    if(command!=='social_api')return {};
    window.calls.push({op:args.operation,body:args.body});
    if(args.operation==='state')return {me:window.me,friends:[window.peer],requests:[],outgoing:[],blocked:[]};
    if(args.operation==='messages')return JSON.parse(JSON.stringify({messages:window.rows.filter(m=>!args.body.after||BigInt(m.seq)>BigInt(args.body.after)),hasMore:false,updates:window.changes.filter(m=>Number(m.editSeq)>Number(args.body.syncCursor||0)),syncCursor:String(window.changes.length),serverNow:String(Date.now())}));
    if(args.operation==='send-image'){
     if(window.failImage){window.failImage=false;throw '网络不可用';}
     const message={id:'photo1',seq:String(window.rows.length+1),senderId:'me',kind:'image',text:'[图片]',createdAt:String(Date.now()),image:{width:1,height:1,thumbnail:window.photo}};window.rows.push(message);return {message};
    }
    if(args.operation==='message-image')return {image:window.photo};
    if(args.operation==='recall'){
     const message=window.rows.find(m=>m.id===args.body.messageId);Object.assign(message,{kind:'recalled',text:'撤回了一条消息',image:null,recalledAt:String(Date.now()),editSeq:String(window.changes.length+1)});window.changes.push({...message});return {message:{...message}};
    }
    return {ok:true};
   }}};
  });
  for(const file of ['feedback.js','avatars.js','chat-messages.js','social.js'])await page.addScriptTag({content:fs.readFileSync(path.join(root,file),'utf8')});
  await page.locator('[data-page="messages"]').click();await page.waitForSelector('.social-contact');await page.locator('.social-contact').click();await page.waitForSelector('[data-message-id="m1"]');
  // Whole body copy does not include its timestamp. Selecting a substring copies only that selection.
  await page.locator('[data-message-id="m1"] .social-bubble').click({button:'right'});await page.getByRole('menuitem',{name:'复制',exact:true}).click();assert.equal(await page.evaluate(()=>window.copy.at(-1)),'第一行\n第二行');
  await page.evaluate(()=>{const text=document.querySelector('[data-message-id="m1"] .chat-message-text').firstChild;const range=document.createRange();range.setStart(text,0);range.setEnd(text,3);const selection=getSelection();selection.removeAllRanges();selection.addRange(range);});
  await page.evaluate(()=>document.querySelector('[data-message-id="m1"] .social-bubble').dispatchEvent(new MouseEvent('contextmenu',{clientX:650,clientY:300,bubbles:true})));await page.getByRole('menuitem',{name:'复制选中文字'}).click();assert.equal(await page.evaluate(()=>window.copy.at(-1)),'第一行');
  await page.evaluate(()=>getSelection().removeAllRanges());
  await page.locator('[data-message-id="m3"] .social-bubble').focus();await page.keyboard.press('Shift+F10');assert.equal(await page.getByRole('menuitem',{name:'撤回',exact:true}).count(),0);await page.keyboard.press('Escape');
  await page.locator('[data-message-id="m2"] .social-bubble').click({button:'right'});await page.getByRole('menuitem',{name:'撤回',exact:true}).click();await page.waitForSelector('.social-recalled[data-message-id="m2"]');assert.equal(await page.locator('[data-message-id="m2"]').textContent(),'你撤回了一条消息');
  await page.locator('#social-image').click();await page.waitForSelector('.chat-image-dialog');await page.locator('.chat-image-dialog .primary').click();await page.waitForFunction(()=>document.querySelector('.chat-image-error')?.textContent==='网络不可用');
  await page.locator('.chat-image-dialog .primary').click();await page.waitForSelector('[data-message-id="photo1"]');
  assert.equal(await page.evaluate(()=>{const ids=window.calls.filter(c=>c.op==='send-image').map(c=>c.body.clientId);return ids[0]===ids[1];}),true);
  await page.getByRole('button',{name:'查看图片',exact:true}).click();await page.waitForFunction(()=>!document.querySelector('.chat-image-dialog p'));assert.ok(await page.locator('.chat-image-dialog img').getAttribute('src'));
  // Another client retracts the image: incremental polling closes the open preview.
  await page.evaluate(()=>{const m=window.rows.find(m=>m.id==='photo1');Object.assign(m,{kind:'recalled',image:null,recalledAt:String(Date.now()),editSeq:String(window.changes.length+1)});window.changes.push({...m});});
  await page.clock.runFor(4100);await page.waitForSelector('.social-recalled[data-message-id="photo1"]');assert.equal(await page.locator('.chat-image-dialog').count(),0);
  // Idle polling preserves the actual text node and selection, instead of rebuilding every bubble.
  await page.evaluate(()=>window.savedTextNode=document.querySelector('[data-message-id="m1"] .chat-message-text'));
  await page.clock.runFor(4100);assert.equal(await page.evaluate(()=>window.savedTextNode===document.querySelector('[data-message-id="m1"] .chat-message-text')),true);
  await page.locator('#social-image').click();await page.waitForSelector('.chat-image-dialog');await page.evaluate(()=>window.dispatchEvent(new Event('social-account-changed')));await page.waitForSelector('.chat-image-dialog',{state:'detached'});
  assert.deepEqual(errors,[]);console.log('Desktop chat media/actions: PASS');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
