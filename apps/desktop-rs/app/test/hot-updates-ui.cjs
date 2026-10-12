const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_EXECUTABLE});
 try{
  const page=await browser.newPage({viewport:{width:940,height:620}}),errors=[];
  page.on('pageerror',e=>errors.push(String(e)));
  await page.setContent('<button id="settings-check-update">检查更新</button><span id="settings-version"></span>');
  await page.addStyleTag({content:fs.readFileSync(path.resolve(__dirname,'../ui/style.css'),'utf8')});
  await page.evaluate(()=>{
   window.actions=[];window.restartBusy=false;
   window.appUpdates={ready:Promise.resolve(),hasRelease:false,required:false};window.friendCalls={current:null};
   window.__TAURI__={core:{invoke:async command=>{
    window.actions.push(command);
    if(command==='hot_update_ready')return {revision:0,rolledBack:false};
    if(command==='hot_update_check')return {patch:{revision:1,notes:'隐藏消息页顶部栏'},staged:window.actions.includes('hot_update_stage')};
    if(command==='hot_update_restart'&&window.restartBusy)throw Error('请先结束通话、投屏和文件传输');
   }}};
  });
  await page.addScriptTag({content:fs.readFileSync(path.resolve(__dirname,'../ui/hot-updates.js'),'utf8')});
  await page.evaluate(()=>document.dispatchEvent(new Event('DOMContentLoaded')));
  await page.waitForSelector('dialog[open]');
  assert.equal(await page.evaluate(()=>window.actions.includes('hot_update_stage')),false);
  await page.locator('[data-later]').click();assert.equal(await page.locator('dialog').evaluate(e=>e.open),false);
  await page.evaluate(()=>window.hotUpdates.check(true));await page.locator('[data-apply]').click();
  assert.equal(await page.evaluate(()=>window.actions.includes('hot_update_stage')),true);
  assert.equal(await page.evaluate(()=>window.actions.includes('hot_update_restart')),false);
  assert.match(await page.locator('.app-update-notice').textContent(),/当前通话/);
  await page.evaluate(()=>{window.restartBusy=true;});await page.locator('[data-apply]').click();
  assert.match(await page.locator('.app-update-error').textContent(),/结束通话/);
  await page.evaluate(()=>{window.friendCalls.current={status:'ringing'};window.actions=[];});await page.locator('[data-apply]').click();
  assert.equal(await page.evaluate(()=>window.actions.includes('hot_update_restart')),false);
  await page.evaluate(()=>{window.friendCalls.current=null;window.restartBusy=false;});await page.locator('[data-apply]').click();
  assert.equal(await page.evaluate(()=>window.actions.includes('hot_update_restart')),true);
  assert.deepEqual(errors,[]);console.log('Hot update UI PASS: opt-in, staging, no automatic restart, active/ringing session guards');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
