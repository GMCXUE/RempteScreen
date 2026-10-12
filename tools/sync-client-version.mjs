// Desktop release identity with an optional independent Android release; no signing secrets.
import {readFile,writeFile,copyFile} from 'node:fs/promises';
const root=new URL('../',import.meta.url);
const file=p=>new URL(p,root);
const v=JSON.parse(await readFile(file('config/client-version.json'),'utf8'));
const android=v.android??v;
for(const version of [v,android])if(!/^\d+\.\d+\.\d+$/.test(version.versionName)||!Number.isInteger(version.buildCode)||version.buildCode<1||version.buildCode>2147483647||version.channel!=='stable')throw Error('客户端版本配置无效（当前发行通道仅 stable）');
const pub=file('apps/flutter_client/pubspec.yaml');await writeFile(pub,(await readFile(pub,'utf8')).replace(/^version: .+$/m,`version: ${android.versionName}+${android.buildCode}`));
const cargo=file('apps/desktop-rs/app/src-tauri/Cargo.toml');await writeFile(cargo,(await readFile(cargo,'utf8')).replace(/^(\[package\][\s\S]*?\nversion = )"[^"]+"/m,`$1"${v.versionName}"`));
const config=file('apps/desktop-rs/app/src-tauri/tauri.conf.json');const tauri=JSON.parse(await readFile(config,'utf8'));tauri.version=v.versionName;await writeFile(config,JSON.stringify(tauri,null,2)+'\n');
await copyFile(file('config/update-public-key.json'),file('apps/flutter_client/assets/update-public-key.json'));
console.log(`Desktop ${v.versionName} (${v.buildCode}); Android ${android.versionName} (${android.buildCode}) synchronized. Refresh Cargo.lock before CI --locked builds.`);
