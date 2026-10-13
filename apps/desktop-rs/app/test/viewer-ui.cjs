const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs = require('fs'), path = require('path'), assert = require('assert');
(async () => {
  const root = path.resolve(__dirname, '../ui');
  const browser = await chromium.launch({executablePath: process.env.CHROMIUM_EXECUTABLE});
  try {
    const page = await browser.newPage({viewport: {width: 940, height: 620}});
    const errors = []; page.on('pageerror', e => errors.push(String(e)));
    await page.clock.install();
    await page.addInitScript(() => {
      window.commands = []; window.failFullscreen = false;
      window.__TAURI__ = {
        core: { convertFileSrc: () => 'http://local.test/frame.svg', invoke: async (command, args) => {
          window.commands.push({command, args});
          if (command === 'get_watch_state') return {watching: true, frames: 1, width: 640, height: 360, fps: 30, device_name: '测试 Mac', has_audio: true};
          if (command === 'call_state') return {remote_camera: false, microphone: false, speaker: true, camera: false};
          if (command === 'set_viewer_fullscreen' && window.failFullscreen) throw 'test failure';
          return {};
        }}, event: { listen: async () => {} },
      };
    });
    await page.route('http://local.test/**', route => {
      const url = new URL(route.request().url());
      if (url.pathname === '/frame.svg') return route.fulfill({contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360"><rect width="640" height="360" fill="#203040"/></svg>'});
      const name = url.pathname === '/' ? 'viewer.html' : url.pathname.slice(1);
      return route.fulfill({body: fs.readFileSync(path.join(root, name)), contentType: name.endsWith('.css') ? 'text/css' : name.endsWith('.js') ? 'text/javascript' : 'text/html'});
    });
    await page.goto('http://local.test/');
    await page.clock.runFor(4500);
    assert.equal(await page.locator('#controls').evaluate(e => e.inert), true);
    await page.locator('#show-controls').click();
    assert.equal(await page.locator('#controls').evaluate(e => e.inert), false);
    await page.locator('#hide-btn').click();
    await page.mouse.move(200, 100);
    assert.equal(await page.locator('#controls').evaluate(e => e.inert), true, 'manual hide survives mouse movement');
    await page.locator('#compact-full-btn').click();
    assert.equal(await page.locator('#full-btn').getAttribute('aria-label'), '退出全屏');
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('#full-btn').getAttribute('aria-label'), '全屏');
    await page.evaluate(() => window.failFullscreen = true);
    await page.locator('#full-btn').click();
    assert.equal(await page.locator('#full-btn').getAttribute('aria-label'), '全屏', 'failure must not change fullscreen state');
    assert.equal(await page.locator('#meta').textContent(), '无法切换全屏，请重试');
    await page.locator('#stop-btn').click();
    assert.equal(await page.locator('#close-modal').isVisible(), true);
    await page.locator('#close-cancel').click();
    assert.equal(await page.evaluate(() => window.commands.some(c => c.command === 'stop_watch')), false);
    for (const size of [{width: 390, height: 844}, {width: 844, height: 390}]) {
      await page.setViewportSize(size);
      await page.locator('#show-controls').click({force: true}).catch(() => {});
      await page.evaluate(() => controls.show());
      const rect = await page.locator('#controls').boundingBox();
      assert.ok(rect.x >= 0 && rect.x + rect.width <= size.width && rect.y + rect.height <= size.height);
    }
    if (process.env.VIEWER_SCREENSHOT) {
      await page.setViewportSize({width: 940, height: 620});
      await page.evaluate(() => { callError = ''; controls.show(); });
      await page.clock.runFor(300);
      await page.screenshot({path: process.env.VIEWER_SCREENSHOT});
    }
    await page.emulateMedia({reducedMotion: 'reduce'});
    await page.evaluate(() => controls.hide());
    assert.equal(await page.locator('#controls').evaluate(e => e.inert), true);
    assert.equal(await page.locator('#controls').evaluate(e => getComputedStyle(e).transitionDuration), '0s');
    await page.evaluate(() => controls.show());
    assert.equal(await page.locator('#controls').evaluate(e => getComputedStyle(e).opacity), '1');
    assert.equal(await page.locator('#screen').evaluate(e => e.getAnimations().length), 0);
    assert.deepEqual(errors, []);
    console.log('PASS: auto-hide, reveal, manual hide, native fullscreen/Escape/failure, cancel disconnect, responsive bounds');
  } finally { await browser.close(); }
})();
