const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_EXECUTABLE});
 try{
  const page=await browser.newPage({viewport:{width:960,height:640}}),errors=[],root=path.resolve(__dirname,'../ui');
  const fixture=fs.readFileSync(process.env.VIDEO_FIXTURE);
  page.on('pageerror',e=>errors.push(String(e)));
  await page.route('http://video.test/**',route=>{
   const name=new URL(route.request().url()).pathname.slice(1);
   if(name==='sample.mp4')return route.fulfill({body:fixture,contentType:'video/mp4'});
   if(!['chat-video.html','chat-video.js','ui-icons.js','motion.js','motion.css'].includes(name))return route.abort();
   return route.fulfill({body:fs.readFileSync(path.join(root,name)),contentType:name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':'text/html'});
  });
  await page.addInitScript(()=>{
   window.fullscreen=false;window.recalled=false;window.failed=true;
   window.__TAURI__={core:{convertFileSrc:()=> 'http://video.test/sample.mp4',invoke:async command=>{
    if(command==='get_chat_video'){if(window.failed)throw '视频下载失败，请重试';return {path:'private-cache/video.mp4'};}
    if(command==='check_chat_video'&&window.recalled)throw '视频已撤回';
   }},window:{getCurrentWindow:()=>({close:async()=>window.wasClosed=true,isFullscreen:async()=>window.fullscreen,setFullscreen:async value=>window.fullscreen=value})}};
  });
  await page.goto('http://video.test/chat-video.html');
  await page.getByRole('button',{name:'重试',exact:true}).waitFor();
  await page.evaluate(()=>window.failed=false);await page.getByRole('button',{name:'重试',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('video').videoWidth===64&&document.querySelector('video').readyState>=2);
  assert.equal(await page.locator('video').evaluate(v=>v.videoHeight),48);
  assert.equal(await page.locator('video').evaluate(v=>v.controls),true);
  await page.locator('video').evaluate(async v=>{await v.play();v.pause();v.currentTime=.5;v.muted=true;});
  assert.equal(await page.locator('video').evaluate(v=>v.paused&&v.muted),true);
  await page.getByRole('button',{name:'全屏',exact:true}).click();assert.equal(await page.evaluate(()=>window.fullscreen),true);
  await page.keyboard.press('Escape');assert.equal(await page.evaluate(()=>window.fullscreen),false);
  await page.evaluate(()=>window.recalled=true);await page.waitForFunction(()=>document.querySelector('#status').textContent.includes('视频已撤回'));
  assert.equal(await page.locator('video').getAttribute('src'),null);assert.equal(await page.locator('#retry').isVisible(),false);
  await page.getByRole('button',{name:'关闭',exact:true}).click();assert.equal(await page.evaluate(()=>window.wasClosed),true);assert.deepEqual(errors,[]);
  console.log('Video viewer: actual H264/AAC decode, retry, controls, fullscreen, recall and close PASS');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
