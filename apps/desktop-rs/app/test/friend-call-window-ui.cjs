const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
(async()=>{
 const root=path.resolve(__dirname,'../ui');
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_EXECUTABLE});
 try {
  const page=await browser.newPage({viewport:{width:960,height:720}}),errors=[];
  page.on('pageerror',e=>errors.push(String(e)));await page.clock.install();
  await page.addInitScript(()=>{
   window.commands=[];window.listeners={};window.failFullscreen=false;
   window.call={id:'call-test',peerId:'friend-test',peerName:'测试好友',peerAvatarId:'penguin',me:{id:'me',avatarId:'dog'},acceptedAt:Date.now()-162000,camera:true,microphone:true,speaker:true,connecting:false,busy:false,visible:true};
   window.__TAURI__={core:{convertFileSrc:(_,scheme)=>`http://local.test/${scheme}.svg`,invoke:async(command,args)=>{window.commands.push({command,args});if(command==='get_friend_call_window_state')return window.call;if(command==='friend_call_status')return {status:'connected'};return {}; }},
    event:{listen:async(type,fn)=>{window.listeners[type]=fn;return ()=>delete window.listeners[type];}},
    window:{getCurrentWindow:()=>({setFullscreen:async(value)=>{if(window.failFullscreen)throw Error('failed');window.commands.push({command:'fullscreen',value});}})}};
  });
  await page.route('http://local.test/**',route=>{
   const name=new URL(route.request().url()).pathname.slice(1)||'friend-call.html';
   if(name.endsWith('.svg'))return route.fulfill({contentType:'image/svg+xml',body:`<svg xmlns="http://www.w3.org/2000/svg" width="640" height="480"><rect width="640" height="480" fill="${name.includes('local')?'#4b7168':'#46617a'}"/><circle cx="320" cy="205" r="90" fill="#bdd3dc"/></svg>`});
   return route.fulfill({body:fs.readFileSync(path.join(root,name)),contentType:name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':name.endsWith('.png')?'image/png':'text/html'});
  });
  await page.goto('http://local.test/');await page.clock.runFor(250);
  await page.waitForFunction(()=>!document.getElementById('remote-video').hidden&&!document.getElementById('local-video').hidden);
  const large=await page.locator('#remote-surface').boundingBox();assert.deepEqual(large,{x:0,y:0,width:960,height:720});
  assert.ok((await page.locator('#local-surface').boundingBox()).width<200);
  assert.ok((await page.locator('#local-video').getAttribute('src')).includes('friendlocalcamera'));
  assert.equal(await page.locator('#remote-video').evaluate(e=>getComputedStyle(e).transform),'matrix(-1, 0, 0, 1, 0, 0)','peer and self preview share the same direction');
  assert.equal(await page.locator('#local-video').evaluate(e=>getComputedStyle(e).transform),'matrix(-1, 0, 0, 1, 0, 0)','self preview follows selfie movements');
  await page.locator('#local-surface').click();assert.equal(await page.locator('#local-surface').evaluate(e=>e.classList.contains('main-video')),true);
  assert.equal(await page.locator('#local-video').evaluate(e=>getComputedStyle(e).transform),'matrix(-1, 0, 0, 1, 0, 0)','swapping retains the self preview orientation');
  assert.equal(await page.locator('#remote-video').evaluate(e=>getComputedStyle(e).transform),'matrix(-1, 0, 0, 1, 0, 0)','swapping retains peer direction');
  assert.equal(await page.evaluate(()=>window.commands.filter(c=>c.command==='friend_call_window_action').length),0,'swapping does not change capture');
  await page.locator('#hide-controls').click();assert.equal(await page.locator('#call-controls').evaluate(e=>e.inert),true);
  await page.locator('#remote-surface').click();assert.equal(await page.locator('#call-controls').evaluate(e=>e.inert),true,'PiP remains usable when controls hide');
  await page.locator('#show-controls').click();assert.equal(await page.locator('#call-controls').evaluate(e=>e.inert),false);
  await page.locator('#fullscreen').click();assert.equal(await page.locator('#fullscreen').getAttribute('aria-label'),'退出全屏');
  await page.keyboard.press('Escape');assert.equal(await page.locator('#fullscreen').getAttribute('aria-label'),'全屏');
  await page.evaluate(()=>window.failFullscreen=true);await page.locator('#fullscreen').click();assert.equal(await page.locator('#fullscreen').getAttribute('aria-label'),'全屏');
  await page.locator('#microphone').click();assert.ok(await page.evaluate(()=>window.commands.some(c=>c.command==='friend_call_window_action'&&c.args.action==='microphone'&&c.args.callId==='call-test')));
  await page.evaluate(()=>window.listeners['friend-call-window:state']({payload:{...window.call,camera:false}}));assert.equal(await page.locator('#local-video').isVisible(),false);
  for(const size of [{width:520,height:380},{width:960,height:720}]){
   await page.setViewportSize(size);await page.locator('#show-controls').click({force:true}).catch(()=>{});
   await page.clock.runFor(250);
   await page.locator('.small-video').evaluate(e=>e.getAnimations().forEach(animation=>animation.finish()));
   const rect=await page.locator('#call-controls').boundingBox();assert.ok(rect.x>=0&&rect.x+rect.width<=size.width&&rect.y+rect.height<=size.height);
   const hangup=await page.locator('#hangup').boundingBox(),camera=await page.locator('#camera').boundingBox();
   assert.ok(hangup.y>camera.y+camera.height,'hangup appears below the three media controls');
   assert.ok(Math.abs(hangup.x+hangup.width/2-size.width/2)<.1,'hangup is centered');
   assert.ok((await page.locator('#hangup svg').boundingBox()).width>(await page.locator('#camera svg').boundingBox()).width,'hangup is larger');
   const pip=await page.locator('.small-video').boundingBox();
   for(const id of ['microphone','camera','speaker','hangup']){
    const button=await page.locator(`#${id}`).boundingBox();
    assert.ok(button.y>=0&&button.y+button.height<=size.height);
    assert.ok(button.x+button.width<=pip.x||button.x>=pip.x+pip.width||button.y+button.height<=pip.y||button.y>=pip.y+pip.height,`${id} stays clear of PiP: ${JSON.stringify({size,button,pip})}`);
   }
  }
  await page.evaluate(()=>{window.failFullscreen=false;window.listeners['friend-call-window:state']({payload:window.call});});await page.clock.runFor(250);
  if(process.env.CALL_SCREENSHOT)await page.screenshot({path:process.env.CALL_SCREENSHOT});
  await page.clock.runFor(4300);assert.equal(await page.locator('#call-controls').evaluate(e=>e.inert),true,'controls auto-hide');
  await page.locator('#show-controls').click();await page.locator('#hangup').click();assert.ok(await page.evaluate(()=>window.commands.some(c=>c.command==='friend_call_window_action'&&c.args.action==='hangup')));
  await page.evaluate(()=>window.listeners['friend-call-window:state']({payload:null}));assert.equal(await page.locator('#remote-video').isVisible(),false);assert.equal(await page.locator('#local-video').isVisible(),false);
  assert.deepEqual(errors,[]);

  const main=await browser.newPage();main.on('pageerror',e=>errors.push(String(e)));await main.clock.install();
  await main.route('http://local.test/**',route=>route.fulfill({contentType:'text/html',body:'<!doctype html><html><body></body></html>'}));
  await main.goto('http://local.test/main');
  const callMarkup=fs.readFileSync(path.join(root,'index.html'),'utf8').match(/<aside id="friend-call-bar"[\s\S]*?<\/aside>/)[0];
  await main.setContent('<div id="app"></div>'+callMarkup+'<p id="social-compose-error"></p>');
  await main.addStyleTag({path:path.join(root,'style.css')});
  await main.evaluate(()=>{
   window.commands=[];window.listeners={};window.serverCall={id:'call-test',peerName:'测试好友',kind:'video',status:'active',owned:true,acceptedAt:Date.now(),grant:{livekitUrl:'test',token:'test',peerIdentity:'peer'}};
   window.accountAvatars={render:()=>{},me:()=>({id:'me',avatarId:'dog'})};window.toasts=[];window.showAppToast=(text,duration)=>window.toasts.push({text,duration});
   window.__TAURI__={core:{convertFileSrc:()=>'',invoke:async(command,args)=>{window.commands.push({command,args});if(command==='social_api'){if(args.operation==='call-state')return {calls:window.serverCall?[window.serverCall]:[]};if(args.operation==='call-end'){window.serverCall=null;return {};}}if(command==='friend_call_status')return {status:'connected'};if(command==='call_state')return {microphone:true,camera:true,speaker:true,remote_camera:true};return {};}},event:{listen:async(type,fn)=>{window.listeners[type]=fn;return ()=>{};}}};
  });
  await main.addScriptTag({content:fs.readFileSync(path.join(root,'ui-icons.js'),'utf8')});await main.addScriptTag({content:fs.readFileSync(path.join(root,'friend-calls.js'),'utf8')});await main.clock.runFor(1200);
  await main.waitForFunction(()=>window.commands.some(c=>c.command==='set_friend_call_window_state'&&c.args.data?.id==='call-test'));
  assert.equal(await main.locator('#friend-call-bar').evaluate(e=>e.classList.contains('hidden')),true);
  await main.evaluate(()=>window.listeners['friend-call-window:action']({payload:{action:'fold',callId:'call-test'}}));
  await main.waitForFunction(()=>window.commands.filter(c=>c.command==='set_friend_call_window_state').at(-1).args.visible===false);
  assert.equal(await main.locator('#friend-call-bar').evaluate(e=>e.classList.contains('folded')),true);
  assert.equal(await main.locator('#friend-call-bar').isVisible(),false,'video returns through its mini player without a duplicate bar');
  await main.evaluate(()=>window.listeners['friend-call-window:action']({payload:{action:'restore',callId:'call-test'}}));await main.waitForFunction(()=>window.commands.filter(c=>c.command==='set_friend_call_window_state').at(-1).args.visible===true);
  assert.equal(await main.evaluate(()=>window.commands.filter(c=>c.command==='friend_call_start').length),1,'restoring never opens another media session');
  await main.evaluate(()=>window.listeners['friend-call-window:action']({payload:{action:'hangup',callId:'stale-call'}}));assert.equal(await main.evaluate(()=>window.commands.some(c=>c.command==='friend_call_stop')),false);
  await main.evaluate(()=>window.listeners['friend-call-window:action']({payload:{action:'hangup',callId:'call-test'}}));await main.waitForFunction(()=>window.commands.some(c=>c.command==='friend_call_stop'));
  assert.equal(await main.evaluate(()=>window.commands.filter(c=>c.command==='set_friend_call_window_state').at(-1).args.data),null);
  await main.evaluate(()=>{window.serverCall={id:'normal-end',peerName:'测试好友',kind:'voice',status:'ringing',role:'caller',owned:true};});await main.clock.runFor(2200);
  await main.waitForFunction(()=>!document.getElementById('friend-call-bar').classList.contains('hidden'));
  await main.evaluate(()=>window.serverCall={...window.serverCall,status:'ended',reason:'hangup'});await main.clock.runFor(2200);
  await main.waitForFunction(()=>document.getElementById('friend-call-bar').classList.contains('hidden'));
  assert.deepEqual(await main.evaluate(()=>window.toasts),[],'normal hangup needs no duplicate ended notice');
  assert.equal(await main.locator('#social-compose-error').textContent(),'');
  await main.evaluate(()=>{window.serverCall={id:'offline-end',peerName:'测试好友',kind:'voice',status:'ringing',role:'caller',owned:true};});await main.clock.runFor(2200);
  await main.waitForFunction(()=>!document.getElementById('friend-call-bar').classList.contains('hidden'));
  await main.evaluate(()=>window.serverCall={...window.serverCall,status:'ended',reason:'offline'});await main.clock.runFor(2200);
  await main.waitForFunction(()=>window.toasts.length===1);
  assert.deepEqual(await main.evaluate(()=>window.toasts.at(-1)),{text:'对方已离线，通话已结束',duration:2200});
  assert.equal(await main.locator('#social-compose-error').textContent(),'','call notices do not occupy the chat error row');
  await main.evaluate(()=>{window.serverCall={id:'voice-mini',peerName:'测试好友',kind:'voice',status:'active',owned:true,acceptedAt:Date.now(),grant:{livekitUrl:'test',token:'test',peerIdentity:'peer'}};});await main.clock.runFor(2200);
  await main.waitForFunction(()=>!document.getElementById('friend-call-bar').classList.contains('hidden'));
  await main.locator('#friend-call-fold').click();
  await main.waitForFunction(()=>window.commands.filter(c=>c.command==='set_friend_call_window_state').at(-1).args.data?.kind==='voice');
  assert.equal(await main.locator('#friend-call-bar').isVisible(),false,'folded voice has one native return entrance');
  const count=await main.evaluate(()=>window.commands.filter(c=>c.command==='friend_call_start').length);
  await main.evaluate(()=>window.listeners['friend-call-window:action']({payload:{action:'restore',callId:'voice-mini'}}));
  await main.waitForFunction(()=>!document.getElementById('friend-call-bar').classList.contains('hidden'));
  assert.equal(await main.evaluate(()=>window.commands.filter(c=>c.command==='friend_call_start').length),count,'voice restore reuses its media session');
  await main.locator('#friend-call-hangup').click();

  await main.locator('#social-compose-error').evaluate(e=>e.textContent='好友加载失败');
  await main.evaluate(()=>window.dispatchEvent(new CustomEvent('friend-call-notice',{detail:'通话连接已断开'})));
  assert.equal(await main.locator('#social-compose-error').textContent(),'好友加载失败','real chat errors are preserved');
  await main.evaluate(()=>{window.serverCall={id:'incoming-style',peerName:'名称很长的测试好友',peerAvatarId:'penguin',kind:'video',status:'ringing',role:'callee',owned:false};});await main.clock.runFor(2200);
  await main.waitForFunction(()=>document.getElementById('friend-call-bar').classList.contains('incoming'));
  const avatar=await main.locator('#friend-call-avatar').boundingBox(),answer=await main.locator('#friend-call-answer').boundingBox(),reject=await main.locator('#friend-call-hangup').boundingBox();
  assert.equal(avatar.width,44);assert.equal(answer.width,36);assert.equal(reject.width,36);
  assert.ok(Math.abs(avatar.y+avatar.height/2-answer.y-answer.height/2)<.1,'avatar and incoming actions share a compact row');
  assert.ok(avatar.x+avatar.width<answer.x&&answer.x+answer.width<reject.x);
  assert.ok((await main.locator('#friend-call-bar').boundingBox()).height<90);
  assert.deepEqual(errors,[]);
  console.log('PASS: two feeds, full viewport, swap, hidden controls, fullscreen, action routing, fold/restore, stale actions and end cleanup');
 } finally {await browser.close();}
})();
