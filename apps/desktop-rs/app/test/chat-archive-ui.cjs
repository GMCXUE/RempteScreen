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
    if(command==='chat_archive'){if(args.action==='status'||args.action==='sync')return {messages:123,missing:2};return {message:'已完成'};}
    if(command==='get_state')return {logged_in:true,registered:true,account_name:'钢门吹雪',device_id:'123456789',password:'123456',share_height:1080,share_fps:30};
    if(command==='get_watch_state'||command==='get_transfer_state')return {};
    if(command==='list_devices'||command==='get_history'||command==='incoming_requests')return [];
    if(command==='start_watch')return '等待对方同意';
    return [];
   }}};
  });
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'ui-icons.js'),'utf8')});
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'app.js'),'utf8')});
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'feedback.js'),'utf8')});
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'chat-archive.js'),'utf8')});
  await page.locator('[data-page="settings"]').click();
  await page.waitForFunction(()=>document.getElementById('chat-archive-status').textContent.includes('123'));
  await page.locator('#chat-archive-export').click();
  assert.equal(await page.locator('#modal-input').getAttribute('type'),'password');
  await page.locator('#modal-input').fill(' cross-password ');await page.locator('#modal-confirm').click();
  await page.locator('#modal-input').fill(' cross-password ');await page.locator('#modal-confirm').click();
  await page.waitForFunction(()=>window.commands.some(c=>c.command==='chat_archive'&&c.args.action==='export'));
  assert.equal(await page.evaluate(()=>window.commands.find(c=>c.command==='chat_archive'&&c.args.action==='export').args.password),' cross-password ');
  assert.equal(await page.locator('#modal-input').inputValue(),'');
  await page.locator('#chat-archive-import').click();await page.locator('#modal-input').fill('cross-password');await page.locator('#modal-confirm').click();
  await page.waitForFunction(()=>window.commands.some(c=>c.command==='chat_archive'&&c.args.action==='import'));
  await page.locator('#chat-archive-sync').click();await page.waitForFunction(()=>window.commands.some(c=>c.command==='chat_archive'&&c.args.action==='sync'));
  assert.equal(await page.evaluate(()=>window.commands.some(c=>c.command.startsWith('stop_'))), false);
  assert.deepEqual(errors,[]);console.log('Desktop local archive entry, status, password masking, export/import and manual sync: PASS');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
