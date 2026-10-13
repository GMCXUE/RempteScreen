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
   if(['/style.css','/motion.css'].includes(pathname))return route.fulfill({body:fs.readFileSync(path.join(root,pathname.slice(1))),contentType:'text/css'});
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
   window.changes=[];window.calls=[];window.copy=[];window.imageCopy=[];window.accepted=new Map();window.imageCount=0;window.confirm=true;window.failImage=true;window.friendCalls={start:()=>{}};window.askDialog=async()=>window.confirm;
   window.__TAURI__={event:{listen:async()=>{}},core:{invoke:async(command,args)=>{
    if(command==='chat_send_session')return 'synthetic-session';
    if(command==='open_chat_image'){window.imageWindow=args;return;}
    if(command==='close_chat_image'){if(window.imageWindow?.messageId===args.messageId)window.imageWindow=null;return;}
    if(command==='plugin:clipboard-manager|write_text'){window.copy.push(args.text);return;}
    if(command==='copy_chat_image'){if(window.failCopy)throw '复制失败，请重试';window.imageCopy.push(args.image);return;}
    if(command==='pick_chat_media')return window.selectedMedia||[{kind:'image',image:window.photo}];
    if(command==='release_chat_media'){(window.releasedMedia||=[]).push(args.draftId);return;}
    if(command==='open_chat_video'){window.videoWindow=args;return;}
    if(command==='close_chat_video'){if(window.videoWindow?.messageId===args.messageId)window.videoWindow=null;return;}
    if(command==='send_chat_video'){window.calls.push({op:'send-video',body:args,sendSession:args.sendSession});if(window.failVideo){window.failVideo=false;throw '视频发送失败';}if(window.accepted.has(args.clientId))return {message:structuredClone(window.accepted.get(args.clientId))};const message={id:'video1',seq:String(window.rows.length+1),clientId:args.clientId,senderId:'me',kind:'video',text:'[视频]',createdAt:String(Date.now()),video:{thumbnail:window.photo,width:64,height:48,duration:1000,bytes:32}};window.rows.push(message);window.accepted.set(args.clientId,message);return {message:structuredClone(message)};}
    if(command==='read_chat_image'){window.clipboardReads=(window.clipboardReads||0)+1;if(window.clipboardError)throw window.clipboardError;if(window.delayClipboard)return new Promise(resolve=>window.resolveClipboard=resolve);return window.clipboardImage||null;}
    if(command!=='social_api')return {};
    window.calls.push({op:args.operation,body:args.body,sendSession:args.sendSession});
    if(window.failSync?.includes(args.operation))throw '连不上服务器，请检查网络或服务器地址';
    if(args.operation==='state')return {me:window.me,friends:[window.peer],requests:[],outgoing:[],blocked:[]};
    if(args.operation==='messages')return JSON.parse(JSON.stringify({messages:window.rows.filter(m=>!args.body.after||BigInt(m.seq)>BigInt(args.body.after)),hasMore:false,updates:window.changes.filter(m=>Number(m.editSeq)>Number(args.body.syncCursor||0)),syncCursor:String(window.changes.length),serverNow:String(Date.now())}));
    if(args.operation==='send-image'){
     window.imageAttempts=(window.imageAttempts||0)+1;
     if(window.delayUpload){window.delayUpload=false;await new Promise(resolve=>window.resolveUpload=resolve);}
     if(window.failImage||window.failAtImage===window.imageAttempts){window.failImage=false;throw '网络不可用';}
     if(window.accepted.has(args.body.clientId))return {message:structuredClone(window.accepted.get(args.body.clientId))};
     const message={id:'photo'+(++window.imageCount),seq:String(window.rows.length+1),clientId:args.body.clientId,senderId:'me',kind:'image',text:'[图片]',createdAt:String(Date.now()),image:{width:1,height:1,thumbnail:window.photo}};window.rows.push(message);window.accepted.set(args.body.clientId,message);return {message:structuredClone(message)};
    }
    if(args.operation==='send'){if(window.failText){window.failText=false;throw '文字发送失败';}const message={id:'text'+window.rows.length,seq:String(window.rows.length+1),clientId:args.body.clientId,senderId:'me',kind:'text',text:args.body.text,createdAt:String(Date.now())};window.rows.push(message);return {message:structuredClone(message)};}
    if(args.operation==='message-image')return {image:window.photo};
    if(args.operation==='recall'){
     const message=window.rows.find(m=>m.id===args.body.messageId);Object.assign(message,{kind:'recalled',text:'撤回了一条消息',image:null,recalledAt:String(Date.now()),editSeq:String(window.changes.length+1)});window.changes.push({...message});return {message:{...message}};
    }
    return {ok:true};
   }}};
  });
  for(const file of ['motion.js','ui-icons.js','feedback.js','avatars.js','chat-messages.js','chat-settings.js','chat-outbox.js','social.js'])await page.addScriptTag({content:fs.readFileSync(path.join(root,file),'utf8').replace('let followBottom=true;',"let followBottom=true;Object.defineProperty(window,'debugFollow',{get:()=>followBottom});")});
  await page.evaluate(()=>{window.toasts=[];const show=window.showAppToast;window.showAppToast=(text,duration)=>{window.toasts.push({text,duration});return show(text,duration);};});
  await page.locator('[data-page="messages"]').click();await page.waitForSelector('.social-contact');await page.locator('.social-contact').click();await page.waitForSelector('[data-message-id="m1"]');
  assert.equal(await page.locator('#social-error').count(),0,'no permanent error row in the chat header');
  const compactHeight=(await page.locator('#social-draft').boundingBox()).height;
  assert.ok(compactHeight<=46,'empty composer stays one line');
  await page.locator('#social-draft').fill('第一行\n第二行\n第三行');
  const multilineHeight=(await page.locator('#social-draft').boundingBox()).height;
  assert.ok(multilineHeight>compactHeight&&multilineHeight<=108,'composer grows for multiline text');
  await page.locator('#social-draft').fill(Array(8).fill('多行文字').join('\n'));
  assert.equal(await page.locator('#social-draft').evaluate(e=>getComputedStyle(e).overflowY),'auto');
  await page.locator('#social-draft').fill('');
  assert.equal((await page.locator('#social-draft').boundingBox()).height,compactHeight,'cleared composer shrinks back');
  if(process.env.COMPOSER_SCREENSHOT)await page.locator('#social-compose').screenshot({path:process.env.COMPOSER_SCREENSHOT});
  await page.locator('#social-draft').fill('保留未发送的草稿');
  await page.evaluate(()=>{window.failSync=['state','messages'];window.cachedMessage=document.querySelector('[data-message-id="m1"]');});
  await page.clock.runFor(4100);await page.waitForFunction(()=>window.toasts.length===1);
  assert.equal(await page.locator('#ft-toast').isVisible(),true);
  await page.clock.runFor(8200);assert.equal(await page.evaluate(()=>window.toasts.length),1,'polling coalesces identical failures and never repeats them during one outage');
  assert.equal(await page.locator('#ft-toast').isVisible(),false,'sync feedback expires');
  assert.equal(await page.locator('#social-draft').inputValue(),'保留未发送的草稿');
  assert.equal(await page.evaluate(()=>window.cachedMessage===document.querySelector('[data-message-id="m1"]')),true,'failure preserves loaded messages');
  await page.evaluate(()=>window.failSync=['messages']);await page.clock.runFor(4100);assert.equal(await page.evaluate(()=>window.toasts.length),1,'contact recovery cannot reset the message outage');
  await page.evaluate(()=>window.failSync=[]);await page.locator('[data-page="messages"]').click();
  await page.waitForFunction(()=>window.calls.filter(c=>c.op==='messages').length>3);
  await page.evaluate(()=>window.failSync=['messages']);await page.clock.runFor(4100);await page.waitForFunction(()=>window.toasts.length===2);
  await page.evaluate(()=>window.showAppToast('保留新的操作提示',2200));await page.evaluate(()=>window.failSync=[]);await page.locator('[data-page="messages"]').click();
  await page.waitForFunction(()=>!window.failSync.length);
  assert.equal(await page.locator('#ft-toast').isVisible(),true,'sync recovery must not dismiss newer operation feedback');
  assert.equal(await page.locator('#ft-toast').textContent(),'保留新的操作提示');
  await page.evaluate(()=>{window.failSync=['read'];window.rows.push({id:'read-retry',seq:'4',senderId:'peer',kind:'text',text:'重试已读',createdAt:String(Date.now())});});
  await page.clock.runFor(4100);await page.waitForFunction(()=>window.toasts.at(-1)?.text.includes('连不上服务器'));
  const readAttempts=await page.evaluate(()=>window.calls.filter(c=>c.op==='read').length);
  await page.clock.runFor(4100);assert.ok(await page.evaluate(n=>window.calls.filter(c=>c.op==='read').length>n,readAttempts),'read acknowledgement retries even when no new messages arrive');
  const notices=await page.evaluate(()=>window.toasts.length);await page.clock.runFor(4100);assert.equal(await page.evaluate(()=>window.toasts.length),notices,'successful messages do not repeatedly re-show read errors');
  await page.evaluate(()=>window.failSync=[]);await page.locator('[data-page="messages"]').click();await page.waitForFunction(()=>document.querySelector('#ft-toast').classList.contains('hidden'));
  // Clipboard images belong inside the composer and never send on paste.
  await page.locator('#social-draft').fill('保留草稿');
  const pasteNative=()=>page.evaluate(()=>{window.clipboardImage=window.photo;document.querySelector('#social-draft').dispatchEvent(new ClipboardEvent('paste',{clipboardData:new DataTransfer(),bubbles:true,cancelable:true}));});
  await pasteNative();await page.waitForSelector('.chat-draft-image');
  assert.equal(await page.locator('.chat-image-dialog').count(),0);assert.equal(await page.locator('#social-draft').inputValue(),'保留草稿');assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.op==='send-image').length),0);
  const inputBounds=await page.locator('.chat-composer-input').boundingBox(),imageBounds=await page.locator('.chat-draft-image').boundingBox();assert.ok(imageBounds.y>=inputBounds.y&&imageBounds.y+imageBounds.height<=inputBounds.y+inputBounds.height);
  await page.getByRole('button',{name:'移除图片 1',exact:true}).click();assert.equal(await page.locator('.chat-draft-image').count(),0);assert.equal(await page.locator('#social-draft').inputValue(),'保留草稿');
  // WebView image blobs bypass native reads; ordinary text keeps native paste behavior.
  await page.evaluate(()=>{const data=new DataTransfer();data.items.add(new File([Uint8Array.from(atob(window.photo.split(',')[1]),c=>c.charCodeAt(0))],'screenshot.png',{type:'image/png'}));const event=new ClipboardEvent('paste',{clipboardData:data,bubbles:true,cancelable:true});document.querySelector('#social-draft').dispatchEvent(event);window.imagePastePrevented=event.defaultPrevented;});
  await page.waitForSelector('.chat-draft-image');assert.equal(await page.evaluate(()=>window.imagePastePrevented&&window.clipboardReads===1),true);await page.getByRole('button',{name:'移除图片 1',exact:true}).click();
  await page.evaluate(()=>{const data=new DataTransfer();data.setData('text/plain','正常文字');const event=new ClipboardEvent('paste',{clipboardData:data,bubbles:true,cancelable:true});document.querySelector('#social-draft').dispatchEvent(event);window.textPastePrevented=event.defaultPrevented;});
  assert.equal(await page.evaluate(()=>window.textPastePrevented),false);assert.equal(await page.locator('.chat-image-dialog').count(),0);assert.equal(await page.evaluate(()=>window.clipboardReads),1);
  await page.evaluate(()=>{window.clipboardImage=null;document.querySelector('#social-draft').dispatchEvent(new ClipboardEvent('paste',{clipboardData:new DataTransfer(),bubbles:true}));});await page.waitForFunction(()=>window.clipboardReads===2);assert.equal(await page.locator('.chat-draft-image').count(),0);
  await page.evaluate(()=>{const data=new DataTransfer();data.items.add(new File([new Uint8Array(8*1024*1024+1)],'large.png',{type:'image/png'}));document.querySelector('#social-draft').dispatchEvent(new ClipboardEvent('paste',{clipboardData:data,bubbles:true,cancelable:true}));});await page.waitForFunction(()=>document.querySelector('#ft-toast').textContent==='图片过大，请选择 8 MB 以内的图片');assert.equal(await page.locator('.chat-draft-image').count(),0);
  // Cmd+V native fallback also stages its image inside the editor.
  await page.evaluate(()=>window.clipboardImage=window.photo);await page.locator('#social-draft').focus();await page.evaluate(()=>document.querySelector('#social-draft').dispatchEvent(new KeyboardEvent('keydown',{key:'v',metaKey:true,bubbles:true})));await page.clock.runFor(65);await page.waitForSelector('.chat-draft-image');assert.equal(await page.evaluate(()=>window.clipboardReads),3);await page.getByRole('button',{name:'移除图片 1',exact:true}).click();
  // Whole body copy does not include its timestamp. Selecting a substring copies only that selection.
  await page.locator('[data-message-id="m1"] .social-bubble').click({button:'right'});await page.getByRole('menuitem',{name:'复制',exact:true}).click();assert.equal(await page.evaluate(()=>window.copy.at(-1)),'第一行\n第二行');
  await page.evaluate(()=>{const text=document.querySelector('[data-message-id="m1"] .chat-message-text').firstChild;const range=document.createRange();range.setStart(text,0);range.setEnd(text,3);const selection=getSelection();selection.removeAllRanges();selection.addRange(range);});
  await page.evaluate(()=>document.querySelector('[data-message-id="m1"] .social-bubble').dispatchEvent(new MouseEvent('contextmenu',{clientX:650,clientY:300,bubbles:true})));await page.getByRole('menuitem',{name:'复制选中文字'}).click();assert.equal(await page.evaluate(()=>window.copy.at(-1)),'第一行');
  await page.evaluate(()=>getSelection().removeAllRanges());
  await page.locator('[data-message-id="m3"] .social-bubble').focus();await page.keyboard.press('Shift+F10');assert.equal(await page.getByRole('menuitem',{name:'撤回',exact:true}).count(),0);await page.keyboard.press('Escape');
  await page.locator('[data-message-id="m2"] .social-bubble').click({button:'right'});await page.getByRole('menuitem',{name:'撤回',exact:true}).click();await page.waitForSelector('.social-recalled[data-message-id="m2"]');assert.equal(await page.locator('[data-message-id="m2"]').textContent(),'你撤回了一条消息');
  await pasteNative();await page.waitForSelector('.chat-draft-image');await page.locator('#social-send').click();await page.waitForSelector('.chat-send-retry');assert.equal(await page.locator('.chat-draft-image').count(),0);assert.equal(await page.locator('#social-draft').inputValue(),'');
  await page.locator('.chat-send-retry').click();await page.waitForSelector('[data-message-id="photo1"]');await page.waitForFunction(()=>!document.querySelector('#social-draft').value);
  assert.equal(await page.evaluate(()=>{const ids=window.calls.filter(c=>c.op==='send-image').map(c=>c.body.clientId);return ids[0]===ids[1];}),true);assert.equal(await page.locator('.chat-draft-image').count(),0);assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.op==='send').at(-1).body.text),'保留草稿');
  await page.locator('[data-message-id="photo1"] .social-bubble').click({button:'right'});await page.getByRole('menuitem',{name:'复制图片',exact:true}).click();await page.waitForFunction(()=>window.imageCopy.length===1);assert.equal(await page.evaluate(()=>window.imageCopy[0]===window.photo),true);
  await page.evaluate(()=>window.failCopy=true);await page.locator('[data-message-id="photo1"] .social-bubble').click({button:'right'});await page.getByRole('menuitem',{name:'复制图片',exact:true}).click();await page.waitForFunction(()=>document.querySelector('#ft-toast').textContent==='复制失败，请重试');await page.evaluate(()=>window.failCopy=false);
  await page.getByRole('button',{name:'查看图片',exact:true}).click();await page.waitForFunction(()=>window.imageWindow?.messageId==='photo1');assert.equal(await page.locator('.chat-image-dialog').count(),0);assert.equal(await page.evaluate(()=>window.imageWindow.peerId),'peer');
  // Another client retracts the image: incremental polling closes the open preview.
  await page.evaluate(()=>Object.defineProperty(document,'hidden',{configurable:true,value:true}));
  await page.evaluate(()=>{const m=window.rows.find(m=>m.id==='photo1');Object.assign(m,{kind:'recalled',image:null,recalledAt:String(Date.now()),editSeq:String(window.changes.length+1)});window.changes.push({...m});});
  await page.clock.runFor(4100);await page.waitForSelector('.social-recalled[data-message-id="photo1"]');assert.equal(await page.evaluate(()=>window.imageWindow),null);
  await page.evaluate(()=>{delete document.hidden;});
  // Idle polling preserves the actual text node and selection, instead of rebuilding every bubble.
  await page.evaluate(()=>{window.savedTextNode=document.querySelector('[data-message-id="m1"] .chat-message-text');window.savedContact=document.querySelector('.social-contact');window.savedChatAction=document.querySelector('#social-actions button');});
  await page.clock.runFor(4100);assert.equal(await page.evaluate(()=>window.savedTextNode===document.querySelector('[data-message-id="m1"] .chat-message-text')),true);
  assert.equal(await page.evaluate(()=>window.savedContact===document.querySelector('.social-contact')&&window.savedChatAction===document.querySelector('#social-actions button')),true,'idle contact polling preserves focus and hover targets');
  // A later image can fail after the first succeeds: retry sends only the remaining media.
  await page.locator('#social-draft').fill('图片说明');await page.locator('#social-image').click();await page.waitForSelector('.chat-draft-image');await pasteNative();await page.waitForFunction(()=>document.querySelectorAll('.chat-draft-image').length===2);
  await page.evaluate(()=>{window.failAtImage=window.imageAttempts+2;window.failText=true;});await page.locator('#social-send').click();await page.waitForFunction(()=>document.querySelectorAll('.chat-send-retry').length===2);assert.equal(await page.locator('.chat-draft-image').count(),0);
  const failedId=await page.evaluate(()=>window.calls.filter(c=>c.op==='send-image').at(-1).body.clientId),previousAttempts=await page.evaluate(()=>window.imageAttempts);
  await page.locator('.chat-send-retry[title="网络不可用"]').click();await page.waitForFunction(()=>document.querySelectorAll('.chat-send-retry').length===1);assert.equal(await page.evaluate(()=>window.imageAttempts),previousAttempts+1);assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.op==='send-image').at(-1).body.clientId),failedId);
  const textId=await page.evaluate(()=>window.calls.filter(c=>c.op==='send').at(-1).body.clientId);await page.locator('.chat-send-retry').click();await page.waitForFunction(()=>!document.querySelector('.chat-send-retry'));assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.op==='send').at(-1).body.clientId),textId);assert.equal(await page.evaluate(()=>window.imageAttempts),previousAttempts+1);
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>['send','send-image'].includes(c.op)).every(c=>c.sendSession==='synthetic-session')),true,'queued sends remain bound to their login session');
  // A delayed upload cannot hold the composer; new text queues separately.
  await page.locator('#social-image').click();await page.waitForSelector('.chat-draft-image');
  await page.evaluate(()=>window.delayUpload=true);await page.locator('#social-send').click();await page.waitForFunction(()=>!!window.resolveUpload);
  assert.equal(await page.locator('.chat-draft-image').count(),0);assert.equal(await page.locator('#social-draft').inputValue(),'');assert.equal(await page.locator('#social-draft').getAttribute('readonly'),null);
  await page.locator('#social-draft').fill('上传时继续输入');await page.locator('#social-send').click();assert.equal(await page.locator('#social-draft').inputValue(),'');
  await page.evaluate(()=>window.resolveUpload());await page.waitForFunction(()=>window.rows.some(m=>m.text==='上传时继续输入'));
  // Resize and composer expansion keep latest messages visible, while history reading stays put.
  await page.evaluate(()=>{const box=document.querySelector('#social-messages');box.scrollTop=box.scrollHeight;});await page.clock.runFor(160);
  await page.setViewportSize({width:1100,height:600});await page.clock.runFor(160);
  await page.waitForFunction(()=>{const e=document.querySelector('#social-messages');return e.scrollHeight-e.scrollTop-e.clientHeight<2;});
  await page.locator('#social-draft').fill('一\n二\n三\n四');await page.clock.runFor(160);
  await page.waitForFunction(()=>{const e=document.querySelector('#social-messages');return e.scrollHeight-e.scrollTop-e.clientHeight<2;});
  assert.ok(await page.locator('#social-messages').evaluate(e=>e.scrollHeight-e.scrollTop-e.clientHeight<2),JSON.stringify(await page.locator('#social-messages').evaluate(e=>({height:e.clientHeight,top:e.scrollTop,total:e.scrollHeight}))));
  await page.evaluate(()=>{const box=document.querySelector('#social-messages');box.scrollTop=0;});await page.clock.runFor(160);
  await page.waitForFunction(()=>!window.debugFollow);await page.setViewportSize({width:1100,height:740});await page.clock.runFor(160);assert.equal(await page.locator('#social-messages').evaluate(e=>e.scrollTop),0);
  await page.locator('#social-draft').fill('');
  // One gallery selection contains photos and video; failed video retries independently.
  await page.evaluate(()=>{window.selectedMedia=[{kind:'image',image:window.photo},{kind:'video',video:{draftId:'video-registry-1',name:'clip.mp4',bytes:32}},{kind:'image',image:window.photo}];window.failVideo=true;});
  await page.locator('#social-image').click();await page.waitForFunction(()=>document.querySelectorAll('.chat-draft-image').length===3);assert.equal(await page.locator('.chat-draft-video').count(),1);assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.op==='send-video').length),0);
  await page.locator('#social-draft').fill('多媒体说明');await page.locator('#social-send').click();await page.waitForSelector('.chat-send-retry[title="视频发送失败"]');assert.equal(await page.locator('#social-draft').inputValue(),'');assert.equal(await page.locator('.chat-draft-image').count(),0);assert.equal(await page.evaluate(()=>window.releasedMedia?.includes('video-registry-1')||false),false);
  const videoId=await page.evaluate(()=>window.calls.find(c=>c.op==='send-video').body.clientId);await page.locator('.chat-send-retry[title="视频发送失败"]').click();await page.waitForSelector('[data-message-id="video1"]');assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.op==='send-video').at(-1).body.clientId),videoId);assert.equal(await page.evaluate(()=>window.releasedMedia.includes('video-registry-1')),true);
  await page.getByRole('button',{name:'播放视频',exact:true}).click();await page.waitForFunction(()=>window.videoWindow?.messageId==='video1');await page.evaluate(()=>{const m=window.rows.find(m=>m.id==='video1');Object.assign(m,{kind:'recalled',video:null,editSeq:String(window.changes.length+1)});window.changes.push({...m});window.selectedMedia=null;});await page.clock.runFor(4100);await page.waitForFunction(()=>window.videoWindow===null);
  // Pending media is private to its account/session; late clipboard reads cannot resurrect it.
  for(let i=0;i<9;i++){await page.locator('#social-image').click();await page.waitForFunction(n=>document.querySelectorAll('.chat-draft-image').length===n,i+1);}
  await page.locator('#social-image').click();await page.waitForFunction(()=>document.querySelector('#ft-toast').textContent==='最多添加 9 项图片或视频');assert.equal(await page.locator('.chat-draft-image').count(),9);
  await page.evaluate(()=>window.dispatchEvent(new Event('social-account-changed')));assert.equal(await page.locator('.chat-draft-image').count(),0);assert.equal(await page.locator('#social-draft').inputValue(),'');
  await page.locator('[data-page="messages"]').click();await page.locator('.social-contact').click();await page.locator('#social-draft').fill('未发送');
  await page.evaluate(()=>window.delayClipboard=true);await pasteNative();await page.waitForFunction(()=>!!window.resolveClipboard);await page.evaluate(()=>{window.dispatchEvent(new Event('social-account-changed'));window.resolveClipboard(window.photo);});
  await page.waitForFunction(()=>!document.querySelector('#social-draft').readOnly);assert.equal(await page.locator('.chat-draft-image').count(),0);assert.equal(await page.locator('#social-draft').inputValue(),'');
  await page.evaluate(()=>{window.rows=Array.from({length:60},(_,i)=>({id:`history${i}`,seq:String(i+1),senderId:'peer',kind:'text',text:i===59?'最后一条消息':('长消息\n'.repeat(i%5+1)),createdAt:String(Date.now())}));window.changes=[];});
  await page.locator('[data-page="messages"]').click();await page.locator('.social-contact').click();await page.waitForSelector('[data-message-id="history59"]');
  await page.waitForFunction(()=>{const e=document.querySelector('#social-messages');return e.scrollHeight-e.scrollTop-e.clientHeight<2;});
  assert.deepEqual(errors,[]);console.log('Desktop chat media/actions: PASS');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
