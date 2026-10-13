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
    if(command==='ft_history'){if(window.historyFail)throw Error('offline');return {items:[{id:args.before||'2',name:args.before?'older.zip':'合同.pdf',size:52428800,createdAt:1700000000000,senderId:'123',senderName:'甲',senderDeviceName:'甲电脑',senderDeviceId:'111111111',recipientId:'456',recipientName:'乙',recipientDeviceName:'乙手机',recipientDeviceId:'222222222',status:args.before?'unconfirmed':'completed'}],next:args.before?null:'2'};}
    if(command==='start_watch')return '等待对方同意';
    return [];
   }}};
  });
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'ui-icons.js'),'utf8')});
  await page.addScriptTag({content:fs.readFileSync(path.join(root,'app.js'),'utf8')});
  await page.locator('[data-page="transfer"]').click();
  await page.locator('#transfer-records').getByText('合同.pdf',{exact:true}).waitFor();
  assert.match(await page.locator('#transfer-records').textContent(),/甲电脑/);
  assert.match(await page.locator('#transfer-records').textContent(),/乙手机/);
  assert.equal(await page.locator('#transfer-records button').count(),0);
  await page.locator('#transfer-records-more').click();
  await page.locator('#transfer-records').getByText('older.zip',{exact:true}).waitFor();
  assert.match(await page.locator('#transfer-records').textContent(),/未确认完成/);
  await page.evaluate(()=>window.historyFail=true);
  await page.locator('#transfer-records-refresh').click();
  await page.waitForFunction(()=>document.getElementById('transfer-records-error').textContent.includes('加载失败'));
  assert.match(await page.locator('#transfer-records').textContent(),/合同/);
  await page.evaluate(()=>{transferRecordGeneration++;transferRecordOwner='';transferRecordItems=[];renderTransferRecords();});
  assert.doesNotMatch(await page.locator('#transfer-records').textContent(),/合同/);
  assert.deepEqual(errors,[]);console.log('Desktop transfer metadata history, pagination, retry and account reset: PASS');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
