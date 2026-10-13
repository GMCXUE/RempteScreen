const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_EXECUTABLE});
 try {
  const page=await browser.newPage({viewport:{width:940,height:620}}),errors=[];
  page.on('pageerror',e=>errors.push(String(e)));
  await page.setContent('<button id="background">后台</button><button id="settings-check-update">检查更新</button><button id="settings-update-history">更新历史</button><span id="settings-version"></span>');
  await page.addStyleTag({content:fs.readFileSync(path.resolve(__dirname,'../ui/style.css'),'utf8')});
  await page.evaluate(()=>{
   window.actions=[];window.force=true;window.failure=false;window.backgroundClicks=0;
   document.getElementById('background').onclick=()=>window.backgroundClicks++;
   window.__TAURI__={event:{listen:async()=>{}},core:{invoke:async (command,args)=>{
    window.actions.push(command);
    if(command==='update_info')return {versionName:'0.2.0',buildCode:5};
    if(command==='update_history'){
     window.cursors??=[];window.cursors.push(args.beforeBuild);
     if(args.beforeBuild===5&&!window.historyFailed){window.historyFailed=true;throw Error('offline');}
     return {items:[{buildCode:args.beforeBuild===null?5:4,versionName:args.beforeBuild===null?'0.2.0':'0.1.0',notes:'第一行\n<img src=x onerror=alert(1)>',publishedAt:1700000000000}],next:args.beforeBuild===null?5:null};
    }
    if(command==='update_check')return {release:{versionName:'0.3.0',forceUpdate:window.force,notes:'修复通话\n优化界面',sha256:'test'},error:''};
    if(command==='update_install')throw Error('系统安装已取消');
   }}};
  });
  await page.addScriptTag({content:fs.readFileSync(path.resolve(__dirname,'../ui/updates.js'),'utf8')});
  await page.waitForSelector('dialog[open]');
  assert.equal(await page.locator('.app-update-later').isVisible(),false);
  await page.keyboard.press('Escape');assert.equal(await page.locator('dialog').evaluate(e=>e.open),true);
  await page.mouse.click(2,2);assert.equal(await page.evaluate(()=>window.backgroundClicks),0);
  await page.locator('.app-update-primary').click();
  await page.waitForFunction(()=>document.querySelector('.app-update-primary').textContent.includes('安装更新'));
  await page.locator('.app-update-primary').click();
  await page.waitForFunction(()=>document.querySelector('.app-update-error').textContent.includes('取消'));
  assert.equal(await page.locator('dialog').evaluate(e=>e.open),true);assert.equal(await page.locator('.app-update-later').isVisible(),false);
  await page.locator('.app-update-history').click();
  await page.waitForSelector('.history-current');
  assert.equal(await page.locator('.history-release img').count(),0);
  await page.locator('.history-more').click();
  await page.waitForFunction(()=>document.querySelector('.history-more').textContent==='重试');
  assert.equal(await page.locator('.history-release').count(),1);
  await page.locator('.history-more').click();
  await page.waitForFunction(()=>document.querySelectorAll('.history-release').length===2);
  assert.deepEqual(await page.evaluate(()=>window.cursors),[null,5,5]);
  if(process.env.UPDATE_HISTORY_SCREENSHOT)await page.screenshot({path:process.env.UPDATE_HISTORY_SCREENSHOT});
  await page.keyboard.press('Escape');
  await page.waitForSelector('.update-history-dialog',{state:'detached'});
  assert.equal(await page.locator('.app-update-primary').textContent(),'结束会话并安装更新');
  assert.equal(await page.locator('.app-update-later').isVisible(),false);
  // Server can withdraw mandatory status without leaving users permanently trapped.
  await page.evaluate(()=>{window.force=false;});await page.locator('.app-update-retry').click();
  await page.waitForSelector('.app-update-later:visible');
  assert.equal(await page.locator('.app-update-notes').textContent(),'修复通话\n优化界面');
  await page.locator('.app-update-later').click();assert.equal(await page.locator('dialog').evaluate(e=>e.open),false);
  await page.locator('#settings-check-update').click();await page.waitForSelector('dialog[open]');
  await page.keyboard.press('Escape');assert.equal(await page.locator('dialog').evaluate(e=>e.open),false);
  await page.locator('#settings-update-history').click();await page.waitForSelector('.history-current');
  await page.locator('.history-close').click();
  assert.deepEqual(errors,[]);console.log('Desktop updater UI PASS: mandatory Escape/backdrop, cancel installer, optional defer, manual check and notes');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
