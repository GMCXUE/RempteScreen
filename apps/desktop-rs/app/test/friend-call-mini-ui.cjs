const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
(async()=>{
 const root=path.resolve(__dirname,'../ui'),browser=await chromium.launch({executablePath:process.env.CHROMIUM_EXECUTABLE});
 try {
  const page=await browser.newPage({viewport:{width:180,height:240}}),errors=[];
  page.on('pageerror',e=>errors.push(String(e)));await page.clock.install();
  await page.addInitScript(()=>{
   window.commands=[];window.listeners={};window.call={id:'mini-test',peerId:'peer',peerName:'测试好友',peerAvatarId:'dog',remoteCamera:true,visible:false,docked:false,acceptedAt:Date.now()-61000};
   window.__TAURI__={core:{convertFileSrc:()=> 'http://local.test/frame.svg',invoke:async(command,args)=>{
    window.commands.push({command,args});if(command==='get_friend_call_window_state')return window.call;
    if(command==='dock_friend_call_mini'){const layout={docked:!args.restore,dockSide:args.restore?0:-1};Object.assign(window.call,layout);return layout;}return {};
   }},event:{listen:async(type,fn)=>{window.listeners[type]=fn;return ()=>{};}},window:{getCurrentWindow:()=>({startDragging:async()=>{window.commands.push({command:'drag'});window.listeners['friend-call-mini:moved']?.();}})}};
  });
  await page.route('http://local.test/**',route=>{
   const name=new URL(route.request().url()).pathname.slice(1)||'friend-call-mini.html';
   if(name==='frame.svg')return route.fulfill({contentType:'image/svg+xml',body:'<svg xmlns="http://www.w3.org/2000/svg" width="180" height="240"><rect width="180" height="240" fill="#46617a"/></svg>'});
   return route.fulfill({body:fs.readFileSync(path.join(root,name)),contentType:name.endsWith('.js')?'text/javascript':name.endsWith('.png')?'image/png':'text/html'});
  });
  await page.goto('http://local.test/');assert.equal(await page.locator('#video').evaluate(e=>getComputedStyle(e).transform),'matrix(-1, 0, 0, 1, 0, 0)','mini uses the same peer direction');await page.clock.runFor(300);await page.waitForFunction(()=>!document.getElementById('video').hidden);
  await page.locator('#mini').click();assert.equal(await page.evaluate(()=>window.commands.filter(c=>c.command==='friend_call_window_action'&&c.args.action==='restore').length),1,'tap returns to the same call');
  await page.mouse.move(80,100);await page.mouse.down();await page.mouse.move(100,130);await page.mouse.up();await page.clock.runFor(450);
  assert.equal(await page.evaluate(()=>window.commands.filter(c=>c.command==='friend_call_window_action').length),1,'drag does not enter the call');
  assert.equal(await page.locator('#mini').evaluate(e=>e.classList.contains('docked')),true);
  await page.setViewportSize({width:28,height:64});assert.equal(await page.locator('#video').isVisible(),false);
  await page.locator('#mini').click();assert.equal(await page.locator('#mini').evaluate(e=>e.classList.contains('docked')),false);
  assert.equal(await page.evaluate(()=>window.commands.filter(c=>c.command==='friend_call_window_action').length),1,'edge handle only expands video');
  await page.setViewportSize({width:180,height:240});await page.locator('#mini').click();
  assert.equal(await page.evaluate(()=>window.commands.filter(c=>c.command==='friend_call_window_action').length),2);
  await page.evaluate(()=>window.listeners['friend-call-window:state']({payload:{...window.call,remoteCamera:false}}));assert.equal(await page.locator('#video').isVisible(),false);
  assert.equal(await page.locator('#placeholder').isVisible(),true);
  await page.evaluate(()=>window.listeners['friend-call-window:state']({payload:{...window.call,kind:'voice',remoteCamera:false}}));
  assert.equal(await page.locator('#mini').evaluate(e=>e.classList.contains('voice')),true);
  assert.equal(await page.locator('#kind').textContent(),'语音通话中');
  assert.equal(await page.locator('#video').isVisible(),false,'voice mini never shows a stale camera frame');
  await page.evaluate(()=>window.listeners['friend-call-window:state']({payload:null}));assert.equal(await page.locator('#video').getAttribute('src'),null);
  assert.equal(await page.evaluate(()=>window.commands.some(c=>c.command==='friend_call_start')),false);
  assert.deepEqual(errors,[]);console.log('PASS: mini video return, drag, edge collapse/expand, camera mute and call cleanup');
 } finally {await browser.close();}
})();
