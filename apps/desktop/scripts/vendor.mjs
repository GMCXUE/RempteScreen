// 把 livekit-client 的 UMD 构建复制进渲染层。
//
// 渲染目录因此是自包含的：既能被 Electron 加载，也能原样托管到服务器上
// 供手机浏览器打开（手机打开时页面会自动只显示「连接」那一栏）。
// 这是构建产物，不要提交进版本库。

import { copyFileSync, mkdirSync, existsSync, statSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = resolve(root, 'node_modules', 'livekit-client', 'dist', 'livekit-client.umd.js');
const target = resolve(root, 'src', 'renderer', 'vendor', 'livekit-client.umd.js');

if (!existsSync(source)) {
  console.error('找不到 livekit-client 的 UMD 构建，请先执行 npm install');
  process.exit(1);
}

mkdirSync(dirname(target), { recursive: true });
copyFileSync(source, target);

const kb = (statSync(target).size / 1024).toFixed(0);
console.log(`已复制 livekit-client.umd.js（${kb} KB）到 src/renderer/vendor/`);
