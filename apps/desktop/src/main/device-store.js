// 本地凭据持久化。
//
// 设备目录服务每次注册都会轮换 sessionToken，所以这里必须在每次注册后覆盖写入，
// 否则下次启动认不出自己，设备 ID 会变。

const fs = require('node:fs');
const path = require('node:path');
const { app } = require('electron');

const filePath = () => path.join(app.getPath('userData'), 'device.json');

function load() {
  try {
    const parsed = JSON.parse(fs.readFileSync(filePath(), 'utf8'));
    return {
      deviceId: typeof parsed.deviceId === 'string' && /^\d{9}$/.test(parsed.deviceId) ? parsed.deviceId : null,
      sessionToken: typeof parsed.sessionToken === 'string' ? parsed.sessionToken : null,
    };
  } catch {
    return { deviceId: null, sessionToken: null };
  }
}

function save(patch) {
  const next = { ...load(), ...patch };
  const target = filePath();
  fs.mkdirSync(path.dirname(target), { recursive: true });
  // 0600：凭据只允许当前用户读写
  fs.writeFileSync(target, JSON.stringify(next, null, 2), { mode: 0o600 });
  return next;
}

module.exports = { load, save, filePath };
