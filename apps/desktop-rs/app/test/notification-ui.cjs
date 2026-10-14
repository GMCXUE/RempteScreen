const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_EXECUTABLE});
 try{
  const page=await browser.newPage({viewport:{width:1300,height:820}}),errors=[];page.on('pageerror',e=>errors.push(String(e)));
  const root=path.resolve(__dirname,'../ui');
  await page.route('http://history.test/**',route=>{const url=new URL(route.request().url());const file=url.pathname==='/'?'index.html':url.pathname.slice(1);if(!/^[\w./-]+$/.test(file)||file.includes('..'))return route.abort();const local=path.join(root,file);if(!fs.existsSync(local))return route.abort();let body=fs.readFileSync(local);if(file==='index.html')body=String(body).replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,'');return route.fulfill({body,contentType:file.endsWith('.css')?'text/css':file.endsWith('.js')?'text/javascript':file.endsWith('.png')?'image/png':'text/html'});});
  await page.goto('http://history.test/');
  await page.evaluate(()=>{
   document.querySelector('#app').classList.remove('hidden');document.querySelector('#login-view').classList.add('hidden');document.querySelector('.content').classList.add('social-content');document.querySelector('.workspace').classList.add('messages-workspace');document.querySelector('#account-name').textContent='测试小夏';document.querySelector('#server-text').textContent='已连接服务器';document.querySelector('#server-dot').classList.add('connected');document.querySelectorAll('.nav-item').forEach(e=>e.classList.toggle('active',e.dataset.page==='messages'));document.querySelectorAll('.page').forEach(e=>e.classList.toggle('hidden',e.id!=='page-messages'));
   window.me={id:'me',name:'测试小夏',accountId:'766054',avatarId:'dog'};window.peer={id:'peer',name:'钢门吹雪',remark:'',accountId:'176101',avatarId:'penguin',unread:0,online:true,lastText:'准备测试',blocked:false,pinned:false};window.rows=[{id:'m1',seq:'1',kind:'text',senderId:'peer',text:'明天一起测试聊天记录',createdAt:String(Date.now())},{id:'m2',seq:'2',kind:'text',senderId:'me',text:'好的，我来准备设备',createdAt:String(Date.now())}];window.calls=[];window.handlers={};window.askDialog=async()=>true;window.muted=[];window.friendCalls={start:()=>{}};
   window.__TAURI__={event:{listen:async(name,fn)=>{window.handlers[name]=fn;}},core:{invoke:async(command,args={})=>{window.calls.push({command,args});if(command==='notification_settings'){if(args.value){window.noticeSettings=args.value;window.muted=args.value.mutedPeers;}return {mutedPeers:window.muted,messageSound:true,...window.noticeSettings};}if(command==='social_api'){if(args.operation==='state')return {me:window.me,friends:[window.peer],requests:[],outgoing:[],blocked:[]};if(args.operation==='messages')return {messages:window.rows.filter(m=>!args.body?.after||Number(m.seq)>Number(args.body.after)),updates:[],hasMore:false,syncCursor:'0',clearedThrough:window.cleared?'2':'0'};if(args.operation==='profile'){window.peer.pinned=args.body.pinned;return {ok:true};}if(args.operation==='clear-history'){window.cleared=true;window.rows=[];window.peer.lastText='';return {clearedThrough:'2'};}if(args.operation==='message-context')return {messages:window.rows,hasMore:false,clearedThrough:'0',syncCursor:'0'};}return {};}}};
  });
  for(const script of ['ui-icons.js','feedback.js','message-notice.js','avatars.js','chat-messages.js','chat-settings.js','chat-outbox.js','social.js'])await page.addScriptTag({content:fs.readFileSync(path.join(root,script),'utf8')});
  await page.evaluate(()=>document.querySelector('.message-entry').click());
  await page.locator('.social-contact').first().click();
  await page.evaluate(()=>{
    for(let i=3;i<=60;i++)window.rows.push({id:'m'+i,seq:String(i),kind:'text',senderId:'peer',text:'较长的历史消息 '.repeat(8)+i,createdAt:String(Date.now())});
    document.querySelector('.message-entry').click();
  });
  await page.waitForFunction(()=>window.calls.some(c=>c.args?.operation==='read'&&c.args?.body?.seq==='60'));
  await page.evaluate(()=>{
    const viewport=document.querySelector('#social-messages');viewport.scrollTop=0;viewport.dispatchEvent(new Event('scroll'));
    window.rows.push({id:'m61',seq:'61',kind:'text',senderId:'peer',text:'还没有看到的新消息',createdAt:String(Date.now())});
    window.calls=[];document.querySelector('.message-entry').click();
  });
  await page.waitForFunction(()=>document.querySelector('[data-message-id="m61"]'));
  assert.equal(await page.evaluate(()=>window.calls.some(c=>c.args?.operation==='read'&&c.args?.body?.seq==='61')),false,'阅读历史不应将新消息标为已读');
  await page.evaluate(()=>{
    const viewport=document.querySelector('#social-messages');viewport.scrollTop=viewport.scrollHeight;viewport.dispatchEvent(new Event('scroll'));
    document.querySelector('.message-entry').click();
  });
  await page.waitForFunction(()=>window.calls.some(c=>c.args?.operation==='read'&&c.args?.body?.seq==='61'));
  await page.evaluate(()=>document.querySelector('#social-alert-settings').click());
  assert.equal(await page.locator('.alert-settings-dialog input[type=checkbox]').count(),5);
  const rows=page.locator('.alert-settings-dialog label');
  await rows.filter({hasText:'聊天消息通知'}).locator('input').uncheck();
  await rows.filter({hasText:'好友申请通知'}).locator('input').uncheck();
  await page.getByRole('button',{name:'保存',exact:true}).click();
  const saved=await page.evaluate(()=>window.calls.findLast(c=>c.command==='notification_settings'&&c.args?.value)?.args.value);
  assert.equal(saved.messageEnabled,false);assert.equal(saved.friendEnabled,false);
  await page.evaluate(()=>{window.noticeSettings={};document.querySelector('#page-messages').classList.add('hidden');document.querySelector('#page-cast').classList.remove('hidden');document.querySelector('.workspace').classList.remove('messages-workspace');document.querySelector('.content').classList.remove('social-content');});
  const emit=(data={})=>page.evaluate(async data=>{await window.handlers['messaging-notice']({payload:{accountId:'me',peerId:'peer',name:'钢门吹雪',message:'你好，今晚一起看电影吗？',avatarId:'penguin',preview:true,sentAt:Date.now()-120000,...data}});},data);
  await emit();
  assert.equal(await page.locator('#message-notice').isVisible(),true);
  assert.equal(await page.locator('#ft-toast').isVisible(),false,'聊天消息不使用普通黑色提示条');
  assert.equal(await page.locator('#message-notice-avatar img').count(),1);
  assert.equal(await page.locator('#message-notice-time').getAttribute('datetime')!==null,true);
  assert.equal(await page.locator('#social-draft').evaluate(e=>e===document.activeElement),false,'提醒不抢焦点');
  await page.locator('#message-notice').hover();
  await page.waitForTimeout(6700);
  assert.equal(await page.locator('#message-notice').isVisible(),true,'悬停时暂停关闭');
  if(process.env.NOTICE_SCREENSHOT_DIR){fs.mkdirSync(process.env.NOTICE_SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.NOTICE_SCREENSHOT_DIR,'desktop-message-card.png')});}
  await page.getByRole('button',{name:'关闭消息提醒',exact:true}).click();
  assert.equal(await page.locator('#message-notice-body').textContent(),'');
  await emit({name:'超长联系人名字'.repeat(15),message:'<img src=x onerror=alert(1)> '+('很长的消息 😀'.repeat(40)),sentAt:Date.now()-86400000});
  await page.setViewportSize({width:820,height:620});
  const rect=await page.locator('#message-notice').boundingBox();assert(rect.x>=0&&rect.x+rect.width<=820);
  assert.equal(await page.locator('#message-notice-body img').count(),0,'消息只能作为文字渲染');
  await page.waitForTimeout(250);
  if(process.env.NOTICE_SCREENSHOT_DIR)await page.screenshot({path:path.join(process.env.NOTICE_SCREENSHOT_DIR,'desktop-message-long.png')});
  await page.evaluate(()=>window.noticeSettings={messagePreview:false});await emit();
  assert.equal(await page.locator('#message-notice-name').textContent(),'RemoteScreen');
  assert.equal(await page.locator('#message-notice-body').textContent(),'收到新消息');
  assert.equal(await page.locator('#message-notice-avatar img').count(),0);
  await page.evaluate(()=>window.noticeSettings={messageEnabled:false});await page.getByRole('button',{name:'关闭消息提醒',exact:true}).click();await emit();
  assert.equal(await page.locator('#message-notice').isVisible(),false);
  await page.evaluate(()=>window.noticeSettings={mutedPeers:['peer']});await emit();assert.equal(await page.locator('#message-notice').isVisible(),false);
  await page.evaluate(()=>window.noticeSettings={});await emit({accountId:'wrong-account'});assert.equal(await page.locator('#message-notice').isVisible(),false);
  await emit();await page.getByRole('button',{name:'查看消息',exact:false}).click();assert.equal(await page.locator('#message-notice').isVisible(),false);
  await page.evaluate(()=>document.querySelector('#page-messages').classList.remove('hidden'));await emit();assert.equal(await page.locator('#message-notice').isVisible(),false,'当前会话不弹出额外提醒');
  await page.evaluate(()=>document.querySelector('#page-messages').classList.add('hidden'));await emit();
  await page.evaluate(()=>window.dispatchEvent(new Event('social-account-changed')));assert.equal(await page.locator('#message-notice').isVisible(),false);assert.equal(await page.locator('#message-notice-body').textContent(),'');
  assert.deepEqual(errors,[]);
  console.log('PASS desktop notification settings, historical read behavior and foreground card interactions');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exit(1);});
