// Management client. Never bundle this script or the admin token in a client app.
import {readFile,stat} from 'node:fs/promises';
import {createReadStream} from 'node:fs';
import {createHash} from 'node:crypto';
const [command,...args]=process.argv.slice(2);
const base=new URL(process.env.UPDATE_ADMIN_URL??'http://127.0.0.1:8787');
if(base.protocol!=='https:'&&!['127.0.0.1','localhost','[::1]'].includes(base.hostname))throw Error('管理接口请使用 HTTPS 或 SSH 本地隧道');
const token=String(await readFile(process.env.UPDATE_ADMIN_TOKEN_FILE??new URL('../.local/update-admin-token',import.meta.url))).trim();
async function request(path,method='GET',body,raw=false){
 const response=await fetch(new URL(path,base),{method,redirect:'error',headers:{Authorization:`Bearer ${token}`,...(body?{'Content-Type':raw?'application/octet-stream':'application/json'}:{})},body:raw?body:body?JSON.stringify(body):undefined,...(raw?{duplex:'half'}:{})});
 const result=await response.json();if(!response.ok)throw Error(JSON.stringify(result));return result;
}
if(command==='upload'){
 const [file,platform,arch]=args;
 if(!file||!['android','macos','windows'].includes(platform)||!['arm64','x64','armv7'].includes(arch))throw Error('upload <安装包> <android|macos|windows> <arm64|x64|armv7>');
 const info=await stat(file);if(!info.isFile()||info.size>512*1024*1024)throw Error('安装包无效或超过 512 MB');
 const hash=createHash('sha256');for await(const chunk of createReadStream(file))hash.update(chunk);const sha=hash.digest('hex');
 console.log(JSON.stringify(await request(`/v1/admin/update-packages/${sha}?platform=${platform}&arch=${arch}`,'PUT',createReadStream(file),true),null,2));
}else if(command==='create'){
 console.log(JSON.stringify(await request('/v1/admin/releases','POST',JSON.parse(await readFile(args[0],'utf8'))),null,2));
}else if(command==='edit'){
 console.log(JSON.stringify(await request(`/v1/admin/releases/${args[0]}`,'PATCH',JSON.parse(await readFile(args[1],'utf8'))),null,2));
}else if(command==='withdraw'){
 console.log(JSON.stringify(await request(`/v1/admin/releases/${args[0]}`,'DELETE'),null,2));
}else if(command==='list'){
 console.log(JSON.stringify(await request('/v1/admin/releases'),null,2));
}else throw Error('命令：upload / create <JSON文件> / edit <记录ID> <JSON文件> / withdraw <记录ID> / list');
