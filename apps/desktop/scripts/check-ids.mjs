// 校验：JS 里 $('...') 引用的元素在 HTML 里是否都存在
import fs from 'node:fs';

const html = fs.readFileSync('src/renderer/index.html', 'utf8');
const js = fs.readFileSync('src/renderer/app.js', 'utf8');

const htmlIds = new Set([...html.matchAll(/id="([^"]+)"/g)].map((m) => m[1]));
const jsIds = new Set([...js.matchAll(/\$\('([^']+)'\)/g)].map((m) => m[1]));

const missing = [...jsIds].filter((id) => !htmlIds.has(id));
if (missing.length) {
  console.log('  ✗ JS 引用了但 HTML 没有：' + missing.join(', '));
  process.exit(1);
}
console.log('  ✓ JS 引用的元素在 HTML 里全部存在（' + jsIds.size + ' 个）');

// 顺带检查标签配平
const pairs = [['div', '<div'], ['section', '<section'], ['button', '<button'], ['label', '<label']];
let balanced = true;
for (const [name, open] of pairs) {
  const a = html.split(open).length - 1;
  const b = html.split(`</${name}>`).length - 1;
  if (a !== b) {
    balanced = false;
    console.log(`  ✗ ${name} ${a}/${b} 不配平`);
  }
}
if (balanced) console.log('  ✓ 主要标签配平');
