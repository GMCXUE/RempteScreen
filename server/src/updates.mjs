import {createHash,createPrivateKey,createPublicKey,sign} from 'node:crypto';
import {mkdir,readFile,rename,stat,unlink,open} from 'node:fs/promises';
import {createReadStream} from 'node:fs';
import {resolve} from 'node:path';
import {pipeline} from 'node:stream/promises';
import {config} from './config.mjs';
import {getPool,query} from './db.mjs';
import {newId,safeEqual} from './security.mjs';

const fail=(statusCode,message)=>{throw Object.assign(Error(message),{statusCode});};
const ok=body=>({status:200,body});
const enumValue=(value,values,label)=>{if(!values.includes(value))fail(400,`${label}无效`);return value;};
const platforms=['android','macos','windows'],arches=['arm64','x64','armv7'],channels=['stable','beta'];
export function target(body) {return {platform:enumValue(body.platform,platforms,'平台'),arch:enumValue(body.arch,arches,'架构'),channel:enumValue(body.channel??'stable',channels,'发布通道')};}
const code=value=>{if(!Number.isSafeInteger(value)||value<0||value>2147483647)fail(400,'版本编号无效');return value;};
const boolean=value=>{if(typeof value!=='boolean')fail(400,'强制更新标记必须是布尔值');return value;};
const notes=value=>{if(typeof value!=='string'||!value.trim()||value.length>12000)fail(400,'请填写更新内容，最多 12000 字');return value.trim();};
const idValue=value=>{if(!/^rel_[a-f0-9]{18}$/.test(value??''))fail(400,'发布记录编号无效');return value;};
const packagePath=(sha,extension)=>resolve(config.updates.packageDir,`${sha}.${extension}`);
let signingKey;
async function key() {
 if(!config.updates.privateKeyFile)fail(503,'更新服务尚未配置');
 if(!signingKey){signingKey=createPrivateKey(await readFile(config.updates.privateKeyFile));if(signingKey.asymmetricKeyType!=='ed25519')fail(503,'更新签名配置无效');}
 return signingKey;
}
export async function signUpdatePayload(value) {
 const signing=await key(),publicKey=createPublicKey(signing).export({type:'spki',format:'der'}).subarray(-32);
 const payload=Buffer.from(JSON.stringify(value));
 return {algorithm:'ed25519',keyId:createHash('sha256').update(publicKey).digest('hex').slice(0,16),payload:payload.toString('base64'),signature:sign(null,payload,signing).toString('base64')};
}
export async function requireUpdateAdmin(request) {
 const expected=config.updates.adminToken||(config.updates.adminTokenFile?String(await readFile(config.updates.adminTokenFile)).trim():'');
 if(expected.length<32)fail(503,'版本管理接口尚未配置');
 const candidate=/^Bearer (.+)$/.exec(request.headers.authorization??'')?.[1];
 if(!candidate||!safeEqual(candidate,expected))fail(403,'无版本管理权限');
}
function view(row) {return {id:row.id,platform:row.platform,arch:row.arch,channel:row.channel,versionName:row.version_name,buildCode:Number(row.build_code),notes:row.notes,forceUpdate:row.force_update,status:row.status,sha256:row.package_sha256,sizeBytes:Number(row.size_bytes),extension:row.extension,revision:row.revision,publishedAt:row.published_at===null?null:Number(row.published_at),createdAt:Number(row.created_at),updatedAt:Number(row.updated_at)};}
const columns='r.*,p.size_bytes,p.extension';
export function effectiveRelease(rows,currentBuild) {
 const newer=rows.filter(r=>Number(r.build_code)>currentBuild);
 if(!newer.length)return null;
 const latest=view(newer[0]);
 latest.forceUpdate=newer.some(r=>r.force_update);
 return latest;
}
export async function checkUpdate({query:params}) {
 if(!/^\d+$/.test(params.get('buildCode')??''))fail(400,'版本编号无效');
 const selection=target(Object.fromEntries(params)),current=code(Number(params.get('buildCode')));
 const rows=await query(`SELECT ${columns} FROM app_releases r JOIN update_packages p ON p.sha256=r.package_sha256 WHERE r.platform=$1 AND r.arch=$2 AND r.channel=$3 AND r.status='published' AND r.published_at<=$4 ORDER BY r.build_code DESC`,[selection.platform,selection.arch,selection.channel,Date.now()]);
 const release=effectiveRelease(rows,current);
 if(release){release.downloadPath=`/v1/updates/packages/${release.id}`;delete release.status;}
 const signing=await key(),publicKey=createPublicKey(signing).export({type:'spki',format:'der'}).subarray(-32);
 const payload=Buffer.from(JSON.stringify({schema:1,target:selection,checkedAt:Date.now(),expiresAt:Date.now()+15*60*1000,release}));
 return ok({algorithm:'ed25519',keyId:createHash('sha256').update(publicKey).digest('hex').slice(0,16),payload:payload.toString('base64'),signature:sign(null,payload,signing).toString('base64')});
}
export async function uploadUpdatePackage({request,params,query:values}) {
 await requireUpdateAdmin(request);
 const sha=params.sha256;if(!/^[a-f0-9]{64}$/.test(sha??''))fail(400,'安装包校验值无效');
 const selection=target(Object.fromEntries(values));
 const extension=({android:'apk',windows:'exe',macos:'zip'})[selection.platform];
 if(!request.headers['content-type']?.startsWith('application/octet-stream'))fail(415,'请上传安装包文件');
 if(Number(request.headers['content-length']??0)>config.updates.maxPackageBytes)fail(413,'安装包过大');
 await mkdir(config.updates.packageDir,{recursive:true,mode:0o700});
 const path=packagePath(sha,extension),temporary=path+'.'+newId('upload')+'.part';
 let file,size=0;
 try {
  file=await open(temporary,'wx',0o600);const hash=createHash('sha256');
  for await(const chunk of request){size+=chunk.length;if(size>config.updates.maxPackageBytes)fail(413,'安装包过大');hash.update(chunk);await file.writeFile(chunk);}
  await file.close();file=null;
  if(!size||hash.digest('hex')!==sha)fail(400,'安装包校验失败');
  const db=await getPool().connect();
  try {
   await db.query('BEGIN');
   await db.query('SELECT pg_advisory_xact_lock(hashtext($1))',[sha]);
   const existing=(await db.query('SELECT * FROM update_packages WHERE sha256=$1',[sha])).rows[0];
   if(existing&&(existing.platform!==selection.platform||existing.arch!==selection.arch))fail(409,'该安装包已属于其他平台或架构');
   await rename(temporary,path);
   await db.query(`INSERT INTO update_packages(sha256,platform,arch,extension,size_bytes,uploaded_at) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(sha256) DO NOTHING`,[sha,selection.platform,selection.arch,extension,size,Date.now()]);
   await db.query('COMMIT');
  }catch(error){await db.query('ROLLBACK');throw error;}finally{db.release();}
  return ok({sha256:sha,sizeBytes:size,...selection,extension});
 } finally {await file?.close().catch(()=>{});await unlink(temporary).catch(()=>{});}
}
export async function createRelease({request,body}) {
 await requireUpdateAdmin(request);await key();
 const selection=target(body),build=code(body.buildCode);if(!build)fail(400,'版本编号必须大于零');
 if(typeof body.versionName!=='string'||!/^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$/.test(body.versionName)||body.versionName.length>64)fail(400,'版本名称无效');
 const content=notes(body.notes),forced=boolean(body.forceUpdate??false);
 const status=enumValue(body.status??'draft',['draft','published'],'发布状态');
 const pkg=(await query('SELECT * FROM update_packages WHERE sha256=$1',[body.sha256]))[0];
 if(!pkg||pkg.platform!==selection.platform||pkg.arch!==selection.arch)fail(400,'请先上传对应平台的安装包');
 await stat(packagePath(pkg.sha256,pkg.extension));
 const now=Date.now(),id=newId('rel');
 try {await query(`INSERT INTO app_releases(id,platform,arch,channel,version_name,build_code,notes,package_sha256,force_update,status,created_at,updated_at,published_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$11,$12)`,[id,selection.platform,selection.arch,selection.channel,body.versionName,build,content,pkg.sha256,forced,status,now,status==='published'?now:null]);}
 catch(error){if(error.code==='23505')fail(409,'该平台版本编号已存在');throw error;}
 return getRelease({request,params:{releaseId:id}});
}
export async function getRelease({request,params}) {
 await requireUpdateAdmin(request);const id=idValue(params.releaseId);
 const row=(await query(`SELECT ${columns} FROM app_releases r JOIN update_packages p ON p.sha256=r.package_sha256 WHERE r.id=$1`,[id]))[0];
 if(!row)fail(404,'发布记录不存在');return ok({release:view(row)});
}
export async function listReleases({request,query:params}) {
 await requireUpdateAdmin(request);
 const limit=Number(params.get('limit')??50),before=Number(params.get('before')??Number.MAX_SAFE_INTEGER),beforeId=params.get('beforeId')??'~';
 if(!Number.isInteger(limit)||limit<1||limit>100||!Number.isSafeInteger(before)||before<0)fail(400,'分页参数无效');
 const rows=await query(`SELECT ${columns} FROM app_releases r JOIN update_packages p ON p.sha256=r.package_sha256 WHERE (r.created_at,r.id)<($1,$2) ORDER BY r.created_at DESC,r.id DESC LIMIT $3`,[before,beforeId,limit]);
 const last=rows.at(-1);
 return ok({releases:rows.map(view),next:rows.length===limit?{before:Number(last.created_at),beforeId:last.id}:null});
}
export async function editRelease({request,params,body}) {
 await requireUpdateAdmin(request);const id=idValue(params.releaseId);
 const allowed=['notes','forceUpdate','status'];if(!Object.keys(body).length||Object.keys(body).some(k=>!allowed.includes(k)))fail(400,'仅可修改更新内容、强制更新及发布状态');
 if(body.notes!==undefined)notes(body.notes);if(body.forceUpdate!==undefined)boolean(body.forceUpdate);
 if(body.status!==undefined)enumValue(body.status,['draft','published','withdrawn'],'发布状态');
 const db=await getPool().connect();
 try {
  await db.query('BEGIN');const old=(await db.query('SELECT * FROM app_releases WHERE id=$1 FOR UPDATE',[id])).rows[0];if(!old)fail(404,'发布记录不存在');
  const status=body.status??old.status;const published=status==='published'?(old.published_at??Date.now()):old.published_at;
  await db.query('UPDATE app_releases SET notes=$2,force_update=$3,status=$4,published_at=$5,updated_at=$6,revision=revision+1 WHERE id=$1',[id,body.notes===undefined?old.notes:notes(body.notes),body.forceUpdate??old.force_update,status,published,Date.now()]);
  await db.query('COMMIT');
 }catch(error){await db.query('ROLLBACK');throw error;}finally{db.release();}
 return getRelease({request,params});
}
export async function withdrawRelease(context) {return editRelease({...context,body:{status:'withdrawn'}});}
export function parseRange(header,size) {
 if(!header)return null;
 const m=/^bytes=(\d+)-(\d*)$/.exec(header);if(!m)return false;
 const start=Number(m[1]),end=m[2]?Math.min(Number(m[2]),size-1):size-1;
 if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start<0||start> end||start>=size)return false;
 return {start,end};
}
export async function downloadUpdatePackage({request,response,params}) {
 const id=idValue(params.releaseId);
 const row=(await query(`SELECT r.id,r.platform,p.* FROM app_releases r JOIN update_packages p ON p.sha256=r.package_sha256 WHERE r.id=$1 AND r.status='published' AND r.published_at<=$2`,[id,Date.now()]))[0];
 if(!row)fail(404,'安装包已撤回，请重新检查更新');
 const file=packagePath(row.sha256,row.extension),info=await stat(file);
 if(info.size!==Number(row.size_bytes))fail(503,'安装包暂不可用');
 const range=parseRange(request.headers.range,info.size);
 if(range===false){response.writeHead(416,{'Content-Range':`bytes */${info.size}`}).end();return {__sse:true};}
 const headers={'Content-Type':'application/octet-stream','Content-Disposition':`attachment; filename="RemoteScreen-${id}.${row.extension}"`,'Accept-Ranges':'bytes','Content-Length':range?range.end-range.start+1:info.size,'ETag':`"${row.sha256}"`,'Cache-Control':'private, no-store'};
 if(range)headers['Content-Range']=`bytes ${range.start}-${range.end}/${info.size}`;
 response.writeHead(range?206:200,headers);
 if(request.method==='HEAD')response.end();else await pipeline(createReadStream(file,range??{}),response).catch(error=>{if(!response.destroyed)response.destroy(error);});
 return {__sse:true};
}
