const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_EXECUTABLE});
 try{
  const page=await browser.newPage({viewport:{width:980,height:760}}),errors=[];
  page.on('pageerror',e=>errors.push(String(e)));
  const root=path.resolve(__dirname,'../ui');
  await page.route('http://picture.test/**',route=>{
   const file=new URL(route.request().url()).pathname.slice(1);
   if(!['chat-image.html','chat-image.css','chat-image.js','ui-icons.js','motion.js','motion.css'].includes(file))return route.abort();
   return route.fulfill({body:fs.readFileSync(path.join(root,file)),contentType:file.endsWith('.css')?'text/css':file.endsWith('.js')?'text/javascript':'text/html'});
  });
  const preview=process.env.VIEWER_PREVIEW_IMAGE?fs.readFileSync(process.env.VIEWER_PREVIEW_IMAGE).toString('base64'):null;
  await page.addInitScript(({preview})=>{
   window.viewerCalls=[];window.failLoad=false;window.failCopy=false;
   window.fixturePhoto=(async()=>{
    const canvas=document.createElement('canvas');canvas.width=1200;canvas.height=1800;
    const ctx=canvas.getContext('2d');
    if(preview){const img=new Image();img.src='data:image/png;base64,'+preview;await img.decode();canvas.width=img.naturalWidth;canvas.height=img.naturalHeight;ctx.drawImage(img,0,0);}
    else {ctx.fillStyle='#ccd7e1';ctx.fillRect(0,0,1200,1800);ctx.fillStyle='#5e84a1';ctx.fillRect(120,120,960,1560);}
    return canvas.toDataURL('image/jpeg',.9);
   })();
   window.__TAURI__={core:{invoke:async command=>{
    window.viewerCalls.push(command);
    if(command==='get_chat_image'){
     if(window.delayLoad)return new Promise(resolve=>window.releaseImage=resolve);
     if(window.failLoad)throw '暂时无法读取图片';return {image:await window.fixturePhoto};
    }
    if(command==='copy_viewed_chat_image'){if(window.failCopy)throw '复制失败，请重试';window.copies=(window.copies||0)+1;}
   }},event:{listen:async(name,callback)=>{window.onImageContext=callback;return()=>{};}},window:{getCurrentWindow:()=>({close:async()=>{window.closedImage=true;}})}};
  },{preview});
  await page.goto('http://picture.test/chat-image.html');
  await page.waitForFunction(()=>!document.querySelector('#image-photo').hidden);
  const percent=()=>page.locator('#image-scale').evaluate(e=>Number.parseInt(e.textContent));
  const fit=await percent();assert.ok(fit<100);
  assert.equal(await page.getByRole('button',{name:'关闭',exact:true}).innerText(),'');
  if(process.env.VIEWER_SCREENSHOT)await page.screenshot({path:process.env.VIEWER_SCREENSHOT});
  await page.getByRole('button',{name:'放大',exact:true}).click();assert.ok(await percent()>fit);
  await page.getByRole('button',{name:'原始大小',exact:true}).click();assert.equal(await percent(),100);
  const before=await page.locator('#image-photo').getAttribute('style');
  await page.mouse.move(450,350);await page.mouse.down();await page.mouse.move(490,410);await page.mouse.up();assert.notEqual(await page.locator('#image-photo').getAttribute('style'),before);
  await page.getByRole('button',{name:'旋转',exact:true}).click();assert.match(await page.locator('#image-photo').getAttribute('style'),/rotate\(90deg\)/);
  await page.getByRole('button',{name:'复制图片',exact:true}).click();await page.waitForFunction(()=>window.copies===1);assert.equal(await page.locator('#image-toast').innerText(),'图片已复制');
  await page.evaluate(()=>window.failCopy=true);await page.getByRole('button',{name:'复制图片',exact:true}).click();await page.waitForFunction(()=>document.querySelector('#image-toast').textContent==='复制失败，请重试');
  await page.evaluate(()=>{window.failLoad=true;window.onImageContext();});await page.waitForSelector('#image-retry:not([hidden])');assert.equal(await page.locator('#image-photo').isVisible(),false);
  await page.evaluate(()=>window.failLoad=false);await page.getByRole('button',{name:'重试',exact:true}).click();await page.waitForFunction(()=>!document.querySelector('#image-photo').hidden);
  // A late result from a previous image cannot change the newer window state.
  await page.evaluate(()=>{window.delayLoad=true;window.onImageContext();});await page.waitForFunction(()=>!!window.releaseImage);
  await page.evaluate(()=>{window.delayLoad=false;window.onImageContext();});await page.waitForFunction(()=>!document.querySelector('#image-photo').hidden);
  const current=await page.locator('#image-photo').getAttribute('src');await page.evaluate(()=>window.releaseImage({image:'invalid late response'}));assert.equal(await page.locator('#image-photo').getAttribute('src'),current);
  await page.setViewportSize({width:520,height:420});await page.waitForFunction(fit=>Number.parseInt(document.querySelector('#image-scale').textContent)<fit,fit);assert.ok(await percent()<fit);
  await page.keyboard.press('Escape');assert.equal(await page.evaluate(()=>window.closedImage),true);assert.deepEqual(errors,[]);
  console.log('Independent image viewer: zoom / pan / rotation / fit / copy / retry / stale results / close PASS');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
