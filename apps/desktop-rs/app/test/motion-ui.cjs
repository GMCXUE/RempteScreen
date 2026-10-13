const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs = require('fs'), path = require('path'), assert = require('assert');
(async () => {
 const root = path.resolve(__dirname, '../ui');
 const browser = await chromium.launch({executablePath: process.env.CHROMIUM_EXECUTABLE});
 try {
  const page = await browser.newPage({viewport: {width: 1100, height: 740}}), errors = [];
  page.on('pageerror', error => errors.push(String(error)));
  await page.route('http://motion.test/**', route => {
   const name = new URL(route.request().url()).pathname.slice(1) || 'index.html';
   const source = fs.readFileSync(path.join(root, name));
   return route.fulfill({body: name === 'index.html' ? source.toString().replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '') : source,
    contentType: name.endsWith('.css') ? 'text/css' : name.endsWith('.js') ? 'text/javascript' : name.endsWith('.png') ? 'image/png' : 'text/html'});
  });
  await page.goto('http://motion.test/');
  await page.evaluate(() => {
   window.motionStarts = [];
   const animate = Element.prototype.animate;
   Element.prototype.animate = function (...args) { window.motionStarts.push(this.dataset.messageId || this.id || this.className); return animate.apply(this, args); };
   window.__TAURI__ = {event: {listen: async () => {}}, core: {invoke: async command => {
    if (command === 'get_state') return {logged_in: true, registered: true, account_name: '测试', device_id: '123456789', password: '123456', share_height: 1080, share_fps: 30};
    if (command === 'get_watch_state' || command === 'get_transfer_state') return {};
    return [];
   }}};
  });
  for (const name of ['motion', 'ui-icons', 'app', 'feedback', 'chat-messages']) await page.addScriptTag({path: path.join(root, `${name}.js`)});
  await page.waitForFunction(() => !document.querySelector('#app').classList.contains('hidden'));
  await page.evaluate(() => {
   for (const name of ['watch', 'settings', 'messages', 'cast', 'watch', 'settings']) document.querySelector(`[data-page="${name}"]`).click();
  });
  assert.equal(await page.locator('.page:visible').count(), 1);
  assert.equal(await page.locator('#page-settings').isVisible(), true);
  await page.waitForFunction(() => document.getAnimations().every(animation => !animation.effect.target.closest('.hidden')));
  await page.waitForFunction(() => document.getAnimations().length === 0);

  // Modal state owns focus immediately; animation never delays cancel or reopen.
  await page.locator('#chat-archive-export').focus();
  await page.evaluate(() => { window.askDialog({title: '密码', defaultValue: '', inputType: 'password'}); });
  assert.equal(await page.locator('#app').evaluate(element => element.inert), true);
  assert.equal(await page.locator('#modal-input').evaluate(element => element === document.activeElement), true);
  await page.locator('#modal-confirm').focus(); await page.keyboard.press('Tab');
  assert.equal(await page.locator('#modal-input').evaluate(element => element === document.activeElement), true);
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('#modal').isVisible(), false);
  assert.equal(await page.locator('#modal').evaluate(element => element.inert), true);
  assert.equal(await page.locator('#chat-archive-export').evaluate(element => element === document.activeElement), true);
  await page.evaluate(() => { window.askDialog({title: '第一次'}); document.querySelector('#modal-cancel').click(); window.askDialog({title: '再次打开'}); });
  await page.waitForFunction(() => document.querySelector('#modal-title').textContent === '再次打开');
  assert.equal(await page.locator('#app').evaluate(element => element.inert), true);
  await page.keyboard.press('Escape');

  await page.evaluate(() => { const dismiss = window.showAppToast('第一条', 0); window.showAppToast('保留最新提示', 0); dismiss(); });
  assert.equal(await page.locator('#ft-toast').isVisible(), true);
  const toast = await page.locator('#ft-toast').boundingBox();
  assert.ok(Math.abs(toast.x + toast.width / 2 - 550) < 1, 'toast entry preserves its centring transform');

  // Changes to a live dialog never replay its entry; native focus trapping remains.
  await page.evaluate(() => { const dialog = document.createElement('dialog'); dialog.id = 'test-dialog'; dialog.innerHTML = '<button>关闭</button>'; document.body.append(dialog); dialog.showModal(); });
  await page.waitForFunction(() => window.motionStarts.includes('test-dialog'));
  const dialogStarts = await page.evaluate(() => window.motionStarts.filter(id => id === 'test-dialog').length);
  await page.evaluate(() => { document.querySelector('#test-dialog button').textContent = '已就绪'; });
  assert.equal(await page.evaluate(() => window.motionStarts.filter(id => id === 'test-dialog').length), dialogStarts);
  await page.evaluate(() => { const dialog = document.querySelector('#test-dialog'); dialog.close(); dialog.remove(); });

  await page.locator('[data-page="messages"]').click();
  await page.evaluate(() => {
   window.chat = new window.ChatMessages({context: () => ({accountId: 'me', peerId: 'peer'}), invoke: async () => {}, error: () => {}});
   window.me = {id: 'me'}, window.peer = {id: 'peer'};
   window.rows = [{id: 'old', senderId: 'peer', kind: 'text', text: '历史消息', createdAt: '1'}];
   window.renderChat = (animate = false) => window.chat.render(document.querySelector('#social-messages'), window.rows, window.me, window.peer, () => {}, () => {}, animate);
   window.renderChat(); window.savedRow = document.querySelector('[data-message-id="old"]');
  });
  assert.equal(await page.evaluate(() => window.motionStarts.includes('old')), false, 'history opens immediately');
  await page.evaluate(() => { window.rows.push({id: 'new', senderId: 'peer', kind: 'text', text: '新消息', createdAt: '2'}); window.renderChat(true); window.renderChat(true); });
  await page.waitForFunction(() => window.motionStarts.includes('new'));
  assert.equal(await page.evaluate(() => window.motionStarts.filter(id => id === 'new').length), 1);
  assert.equal(await page.evaluate(() => window.savedRow === document.querySelector('[data-message-id="old"]')), true, 'new messages preserve old DOM and media nodes');
  await page.evaluate(() => { window.rows.unshift({id: 'older', senderId: 'peer', kind: 'text', text: '更早记录', createdAt: '0'}); window.renderChat(); });
  assert.equal(await page.evaluate(() => window.motionStarts.includes('older')), false, 'pagination never animates old records');
  await page.waitForFunction(() => document.getAnimations().length === 0);
  await page.evaluate(() => { window.rows.push({id: 'local_a', clientId: 'a', senderId: 'me', kind: 'text', text: '发送', createdAt: '3', localStatus: 'queued'}); window.renderChat(true); window.rows.at(-1).localStatus = 'sending'; window.renderChat(true); });
  await page.waitForFunction(() => document.querySelector('[data-message-id="local_a"]').getAnimations().some(animation => animation.currentTime >= 30));
  const timing = await page.evaluate(() => {
   const before = document.querySelector('[data-message-id="local_a"]').getAnimations()[0].currentTime;
   Object.assign(window.rows.at(-1), {id: 'confirmed', localStatus: null}); window.renderChat(true);
   return [before, document.querySelector('[data-message-id="confirmed"]').getAnimations()[0].currentTime];
  });
  assert.ok(timing[0] >= 30 && timing[1] >= timing[0], 'server acknowledgement continues entry instead of restarting');
  await page.waitForFunction(() => document.getAnimations().length === 0);
  await page.evaluate(() => { window.renderChat(true); });
  assert.equal(await page.locator('[data-message-id="confirmed"]').evaluate(element => element.getAnimations().length), 0);

  if (process.env.MOTION_SCREENSHOT_DIR) {
   fs.mkdirSync(process.env.MOTION_SCREENSHOT_DIR, {recursive: true});
   await page.locator('[data-page="settings"]').click();
   await page.evaluate(() => { window.askDialog({title: '备份聊天记录', message: '设置备份密码，在另一台设备登录同一账号后即可恢复记录。', defaultValue: '', inputType: 'password', confirmText: '继续'}); });
   await page.waitForFunction(() => document.querySelector('.modal-card').getAnimations().length > 0);
   await page.evaluate(() => { window.previewAnimations = document.getAnimations().filter(animation => animation.effect.target.closest('#modal')); for (const animation of window.previewAnimations) animation.pause(); });
   for (const time of [0, 100, 240]) {
    await page.evaluate(time => { for (const animation of window.previewAnimations) animation.currentTime = Math.min(time, animation.effect.getTiming().duration); }, time);
    await page.screenshot({path: path.join(process.env.MOTION_SCREENSHOT_DIR, `desktop-motion-${time}ms.png`)});
   }
   await page.evaluate(() => { for (const animation of window.previewAnimations) animation.finish(); });
   await page.keyboard.press('Escape');
  }

  // Change the OS preference during an active entry, then exercise new surfaces.
  await page.evaluate(() => { window.askDialog({title: '减少动态'}); });
  await page.waitForFunction(() => document.getAnimations().length > 0);
  await page.emulateMedia({reducedMotion: 'reduce'});
  await page.waitForFunction(() => document.getAnimations().length === 0);
  await page.keyboard.press('Escape');
  await page.locator('[data-page="settings"]').click();
  await page.evaluate(() => { window.askDialog({title: '立即显示'}); });
  assert.equal(await page.evaluate(() => document.getAnimations().length), 0);
  assert.equal(await page.locator('#modal').evaluate(element => getComputedStyle(element).opacity), '1');
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('#app').evaluate(element => element.inert), false);
  assert.deepEqual(errors, []);
  console.log('PASS: rapid navigation, modal focus/cancel/reopen, toast placement, native dialogs, keyed messages/history/ack, live reduced motion');
 } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
