const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_EXECUTABLE});
 try{
  const page=await browser.newPage({viewport:{width:940,height:680}}),errors=[];
  page.on('pageerror',e=>errors.push(String(e)));
  const root=path.resolve(__dirname,'../ui');
  await page.route('http://local.test/**',route=>{
   const pathname=new URL(route.request().url()).pathname;
   if(pathname==='/')return route.fulfill({body:fs.readFileSync(path.join(root,'index.html'),'utf8').replace(/<script\b[^>]*>[\s\S]*?<\/script>/g,''),contentType:'text/html'});
   if(pathname==='/style.css')return route.fulfill({body:fs.readFileSync(path.join(root,'style.css')),contentType:'text/css'});
   return route.abort();
  });
  await page.goto('http://local.test/');
  await page.evaluate(()=>{
   window.commands=[];window.__TAURI__={event:{listen:async()=>{}},core:{invoke:async(command,args)=>{
    window.commands.push({command,args});
    if(command==='get_state')return {logged_in:true,registered:true,account_name:'钢门吹雪',device_id:'123456789',password:'123456',share_height:1080,share_fps:30};
    if(command==='get_watch_state'||command==='get_transfer_state')return {};
    if(command==='list_devices'||command==='get_history'||command==='incoming_requests')return [];
    if(command==='start_watch')return '等待对方同意';
    return [];
   }}};
  });
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'ui-icons.js'),'utf8')});
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'app.js'),'utf8')});
  for (const parent of ['cast', 'watch', 'messages', 'settings']) {
   await page.locator(`[data-page="${parent}"]`).click();
   if (parent === 'watch') await page.locator('#watch-id').fill('522952991');
   await page.locator('[data-page="devices"]').click();
   await page.locator('[data-page="devices"]').click();
   assert.equal(await page.locator('#page-devices').isVisible(), true);
   await page.getByRole('button', {name: '返回上一页面'}).click();
   assert.equal(await page.locator(`#page-${parent}`).isVisible(), true);
   assert.equal(await page.locator(`[data-page="${parent}"]`).getAttribute('aria-pressed'), 'true');
   if (parent === 'watch') assert.equal(await page.locator('#watch-id').inputValue(), '522952991');
  }
  assert.equal(await page.evaluate(()=>window.commands.some(c=>c.command.startsWith('stop_'))), false);
  assert.deepEqual(errors,[]);console.log('Desktop device back navigation, repeat entry, input and session preservation: PASS');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
