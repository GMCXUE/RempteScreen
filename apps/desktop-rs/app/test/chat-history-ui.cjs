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
   window.__TAURI__={event:{listen:async(name,fn)=>{window.handlers[name]=fn;}},core:{invoke:async(command,args={})=>{window.calls.push({command,args});if(command==='notification_settings'){if(args.value)window.muted=args.value.mutedPeers;return {mutedPeers:window.muted,messageSound:true};}if(command==='social_api'){if(args.operation==='state')return {me:window.me,friends:[window.peer],requests:[],outgoing:[],blocked:[]};if(args.operation==='messages')return {messages:window.rows.filter(m=>!args.body?.after||Number(m.seq)>Number(args.body.after)),updates:[],hasMore:false,syncCursor:'0',clearedThrough:window.cleared?'2':'0'};if(args.operation==='profile'){window.peer.pinned=args.body.pinned;return {ok:true};}if(args.operation==='clear-history'){window.cleared=true;window.rows=[];window.peer.lastText='';return {clearedThrough:'2'};}if(args.operation==='message-context')return {messages:window.rows,hasMore:false,clearedThrough:'0',syncCursor:'0'};}return {};}}};
  });
  for(const script of ['ui-icons.js','feedback.js','avatars.js','chat-messages.js','chat-settings.js','chat-outbox.js','social.js'])await page.addScriptTag({content:fs.readFileSync(path.join(root,script),'utf8')});
  await page.evaluate(()=>document.querySelector('.message-entry').click());await page.locator('.social-contact').first().click();await page.getByRole('button',{name:'聊天信息',exact:true}).click();
  assert(await page.locator('#social-chat-settings').isVisible());assert.equal(await page.locator('.chat-setting-row').count(),4);assert.equal(await page.locator('#social-chat-settings').getByRole('switch').count(),2);
  await page.getByRole('switch',{name:'置顶聊天',exact:true}).click();assert.equal(await page.getByRole('switch',{name:'置顶聊天',exact:true}).getAttribute('aria-checked'),'true');
  await page.getByRole('switch',{name:'消息免打扰',exact:true}).click();assert.deepEqual(await page.evaluate(()=>window.muted),['peer']);
  await page.getByRole('button',{name:'查找聊天记录',exact:false}).click();assert(await page.evaluate(()=>window.calls.some(c=>c.command==='open_chat_history'&&c.args.peerId==='peer')));
  const drawer=await page.locator('#social-chat-settings').boundingBox();assert(drawer.width<=300);assert(drawer.height>500);
  if(process.env.CHAT_HISTORY_SCREENSHOTS){fs.mkdirSync(process.env.CHAT_HISTORY_SCREENSHOTS,{recursive:true});await page.waitForFunction(()=>document.querySelector('#ft-toast').classList.contains('hidden'));await page.screenshot({path:path.join(process.env.CHAT_HISTORY_SCREENSHOTS,'chat-settings-desktop.png')});}
  await page.locator('.chat-clear-history').click();assert.equal(await page.locator('.social-message-row').count(),0);assert(await page.evaluate(()=>window.calls.some(c=>c.command==='close_chat_history')));assert.equal(await page.getByRole('switch',{name:'置顶聊天',exact:true}).getAttribute('aria-checked'),'true');
  await page.getByRole('button',{name:'收起',exact:true}).click();assert.equal(await page.locator('#social-chat-settings').isVisible(),false);
  await page.evaluate(async()=>{window.rows=[{id:'located-old',seq:'10',kind:'text',senderId:'peer',text:'定位原会话中的历史消息',createdAt:String(Date.now())}];await window.handlers['chat-history-locate']({payload:{accountId:'me',peerId:'peer',messageId:'located-old'}});});
  assert.equal(await page.locator('.chat-message-highlight[data-message-id="located-old"]').count(),1);
  // Independent window uses the scoped bridge rather than main-window credentials.
  await page.addInitScript(()=>{
   window.historyCalls=[];window.context={me:{id:'me',name:'测试小夏',avatarId:'dog'},peer:{id:'peer',name:'钢门吹雪',avatarId:'penguin'}};
   window.__TAURI__={event:{listen:async()=>{}},core:{invoke:async(command,args)=>{window.historyCalls.push({command,args});if(command==='get_chat_history_context')return window.context;if(command==='chat_history_api'){if(args.operation==='history'){if(args.body.before)return {messages:[{id:'m0',seq:'1',senderId:'me',kind:'text',text:'较早的消息',createdAt:String(Date.now())}],hasMore:false};return {messages:window.previewRows||[{id:'m2',seq:'3',senderId:'peer',kind:'text',text:'<script>unsafe</script> 找到记录',createdAt:String(Date.now())}],hasMore:true};}return {};}return {};}}};
  });
  await page.goto('http://history.test/chat-history.html');await page.waitForFunction(()=>document.querySelectorAll('.history-row').length===1);assert.equal(await page.locator('.history-content script').count(),0);
  await page.locator('#history-query').fill('找到');await page.locator('#history-search button').click();await page.waitForFunction(()=>document.querySelector('mark')?.textContent==='找到');
  await page.getByRole('button',{name:'链接',exact:true}).click();await page.waitForFunction(()=>window.historyCalls.some(c=>c.args?.body?.kind==='link'));
  await page.locator('#history-date').fill('2026-10-12');await page.locator('#history-date').dispatchEvent('change');await page.waitForFunction(()=>window.historyCalls.some(c=>c.args?.body?.from));
  await page.locator('.history-jump').click();assert(await page.evaluate(()=>window.historyCalls.some(c=>c.command==='locate_chat_message'&&c.args.messageId==='m2')));
  await page.locator('#history-more').click();await page.waitForFunction(()=>document.querySelectorAll('.history-row').length===2);assert.equal(await page.locator('#history-more').isVisible(),false);
  if(process.env.CHAT_HISTORY_SCREENSHOTS){
    await page.setViewportSize({width:760,height:720});
    await page.evaluate(()=>{const time=new Date('2026-10-12T12:00:00+08:00').getTime();window.previewRows=[
      {id:'p5',seq:'5',senderId:'peer',kind:'text',text:'好的，下午一起测试新版聊天功能。',createdAt:String(time)},
      {id:'p4',seq:'4',senderId:'me',kind:'text',text:'聊天记录里也可以直接定位原消息。',createdAt:String(time-60000)},
      {id:'p3',seq:'3',senderId:'peer',kind:'call',text:'视频通话 · 通话时长 2:35',createdAt:String(time-120000)},
      {id:'p2',seq:'2',senderId:'me',kind:'text',text:'这个版本支持文字、图片、链接和通话筛选。',createdAt:String(time-300000)},
      {id:'p1',seq:'1',senderId:'peer',kind:'text',text:'可以按日期找之前的聊天吗？',createdAt:String(time-360000)}];});
    await page.locator('#history-reset').click();await page.waitForFunction(()=>document.querySelectorAll('.history-row').length===5);
    await page.screenshot({path:path.join(process.env.CHAT_HISTORY_SCREENSHOTS,'chat-history-desktop.png')});
  }
  assert.deepEqual(errors,[]);console.log('Desktop chat drawer/history checks passed: pin, mute, clear, search, literal rendering, date, pagination, native locate bridge.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
