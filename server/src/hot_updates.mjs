import {createHash} from 'node:crypto';
import {query} from './db.mjs';
import {newId} from './security.mjs';
import {requireUpdateAdmin,signUpdatePayload,target} from './updates.mjs';
const fail=(message,statusCode=400)=>{throw Object.assign(Error(message),{statusCode});};
const positive=v=>Number.isSafeInteger(v)&&v>0&&v<=2147483647;
export function validateResource(resource,platform) {
 if(platform==='android') {
  if(!resource||Object.keys(resource).some(k=>k!=='patchNumber')||!positive(resource.patchNumber))fail('移动端补丁编号无效');
  return resource;
 }
 if(!resource||Object.keys(resource).some(k=>k!=='files')||!Array.isArray(resource.files)||!resource.files.length||resource.files.length>256)fail('界面资源无效');
 const names=new Set();let total=0;
 for(const f of resource.files) {
  if(!f||typeof f.path!=='string'||!/^[-a-zA-Z0-9_./]+\.(html|css|js|json|svg|png|jpg|jpeg|webp|woff2)$/.test(f.path)||f.path.split('/').some(p=>!p||p==='.'||p==='..')||names.has(f.path))fail('界面资源路径无效');
  if(typeof f.base64!=='string'||!/^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(f.base64))fail('界面资源编码无效');
  const bytes=Buffer.from(f.base64,'base64');total+=bytes.length;
  if(bytes.length>2*1024*1024||total>4*1024*1024||createHash('sha256').update(bytes).digest('hex')!==f.sha256)fail('界面资源校验失败');
  names.add(f.path);
 }
 for(const name of ['index.html','app.js','style.css','hot-updates.js','updates.js','viewer.html','friend-call.html','chat-history.html'])if(!names.has(name))fail(`缺少界面资源 ${name}`);
 return resource;
}
function selection(body) {
 const s=target(body);
 if(!positive(body.nativeBuild))fail('基础版本编号无效');
 return {...s,nativeBuild:body.nativeBuild};
}
export async function publish({request,body}) {
 await requireUpdateAdmin(request);
 const s=selection(body);
 if(!positive(body.revision)||typeof body.notes!=='string'||!body.notes.trim()||body.notes.length>12000)fail('补丁编号或更新内容无效');
 const resource=validateResource(body.resource,s.platform),now=Date.now(),id=newId('hot');
 // Verify signing configuration before changing any release state.
 await signUpdatePayload({schema:1});
 try {await query(`INSERT INTO hot_releases(id,platform,arch,channel,native_build,revision,notes,resource,status,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,'published',$9,$9)`,[id,s.platform,s.arch,s.channel,s.nativeBuild,body.revision,body.notes.trim(),JSON.stringify(resource),now]);}
 catch(e){if(e.code==='23505')fail('该基础版本的补丁编号已存在',409);throw e;}
 return {status:200,body:{id,...s,revision:body.revision,notes:body.notes.trim()}};
}
export async function check({query:params}) {
 const body=Object.fromEntries(params);body.nativeBuild=Number(body.nativeBuild);const s=selection(body);
 const row=(await query(`SELECT * FROM hot_releases WHERE platform=$1 AND arch=$2 AND channel=$3 AND native_build=$4 AND status='published' ORDER BY revision DESC LIMIT 1`,[s.platform,s.arch,s.channel,s.nativeBuild]))[0];
 const patch=row?{revision:row.revision,notes:row.notes,resource:row.resource}:null;
 const now=Date.now();return {status:200,body:await signUpdatePayload({schema:1,kind:'hot-update',target:s,checkedAt:now,expiresAt:now+900000,patch})};
}
export async function list({request}) {
 await requireUpdateAdmin(request);
 const releases=await query('SELECT id,platform,arch,channel,native_build AS "nativeBuild",revision,notes,status,created_at AS "createdAt" FROM hot_releases ORDER BY created_at DESC LIMIT 100');
 return {status:200,body:{releases}};
}
export async function withdraw({request,params}) {
 await requireUpdateAdmin(request);
 if(!/^hot_[a-f0-9]{18}$/.test(params.releaseId??''))fail('补丁记录编号无效');
 const rows=await query("UPDATE hot_releases SET status='withdrawn',updated_at=$2 WHERE id=$1 RETURNING id",[params.releaseId,Date.now()]);
 if(!rows.length)fail('补丁记录不存在',404);
 return {status:200,body:{id:rows[0].id,status:'withdrawn'}};
}
