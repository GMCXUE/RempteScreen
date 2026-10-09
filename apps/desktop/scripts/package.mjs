// 把应用打包成免安装版本。
//
// 用 @electron/packager 而不是 electron-builder：后者打 Windows 安装程序需要 Wine，
// 而免安装版只需要把 Electron 运行时与源码复制到一起，跨平台就能做。
//
// 用法：
//   node scripts/package.mjs win32 x64      → Windows 免安装版
//   node scripts/package.mjs darwin arm64   → macOS 版
//   node scripts/package.mjs darwin x64     → Intel Mac 版

import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { packager } from '@electron/packager';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const platform = process.argv[2] ?? 'win32';
const arch = process.argv[3] ?? 'x64';

// 先把 LiveKit 的 UMD 构建准备好 —— 渲染层靠它工作，产物里必须包含
execFileSync(process.execPath, [resolve(root, 'scripts', 'vendor.mjs')], { stdio: 'inherit' });

console.log(`\n正在打包 ${platform}-${arch} …\n`);

const [appPath] = await packager({
  dir: root,
  name: 'RemoteScreen',
  platform,
  arch,
  out: resolve(root, 'dist'),
  overwrite: true,
  // 运行时不依赖 node_modules：主进程只用 Electron 与 Node 内置模块，
  // 渲染层的 LiveKit 来自 vendor/ 下已构建的 UMD。
  // 不显式排除的话，打包工具会把自身的传递依赖一并塞进 app.asar。
  prune: true,
  ignore: [
    /^\/node_modules($|\/)/,
    /^\/dist($|\/)/,
    /^\/scripts($|\/)/,
    /^\/\.workbuddy($|\/)/,
    /^\/package-lock\.json$/,
    /\.md$/,
  ],
});

const archive = resolve(root, 'dist', `RemoteScreen-${platform}-${arch}.zip`);
execFileSync('zip', ['-r', '-q', archive, '.'], { cwd: appPath });

console.log(`\n产物目录：${appPath}`);
console.log(`压缩包　：${archive}`);
