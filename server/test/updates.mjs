import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {generateKeyPairSync,createHash,verify,randomBytes} from 'node:crypto';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import net from 'node:net';
import pg from 'pg';
const url=new URL(process.env.TEST_DATABASE_URL??'postgres://remotescreen:remotescreen@127.0.0.1:54329/remotescreen_test');
if(!['127.0.0.1','localhost'].includes(url.hostname))throw Error('Update integration tests require a local isolated database');
const database=`rs_updates_${process.pid}_${Date.now()}`,admin=new pg.Pool({connectionString:url.toString()});
const dir=await mkdtemp(join(tmpdir(),'rs-updates-')),token=randomBytes(32).toString('hex');
const {privateKey,publicKey}=generateKeyPairSync('ed25519');
let child,created=false;
try {
 await admin.query(`CREATE DATABASE "${database}"`);created=true;url.pathname=`/${database}`;
 const keyFile=join(dir,'key.pem');await writeFile(keyFile,privateKey.export({type:'pkcs8',format:'pem'}),{mode:0o600});
 const listener=net.createServer();await new Promise(r=>listener.listen(0,'127.0.0.1',r));const port=listener.address().port;await new Promise(r=>listener.close(r));
 const env={...process.env,DATABASE_URL:url.toString(),PORT:String(port),HOST:'127.0.0.1',UPDATE_SIGNING_KEY_FILE:keyFile,UPDATE_ADMIN_TOKEN:token,UPDATE_PACKAGE_DIR:join(dir,'packages')};
 function start(){const p=spawn(process.execPath,['src/index.mjs'],{env,stdio:['ignore','pipe','pipe']});return p;}
 let logs='';function capture(p){p.stdout.on('data',d=>logs+=d);p.stderr.on('data',d=>logs+=d);}
 child=start();capture(child);
 const base=`http://127.0.0.1:${port}`;
 async function ready(){for(let n=0;n<100;n++){try{if((await fetch(base+'/v1/health')).ok)return;}catch{}await new Promise(r=>setTimeout(r,100));}throw Error(logs);}
 await ready();
 async function call(path,method='GET',body,auth=true,headers={}){const r=await fetch(base+path,{method,headers:{...(auth?{authorization:`Bearer ${token}`} : {}),...(body?{'content-type':Buffer.isBuffer(body)?'application/octet-stream':'application/json'}:{}),...headers},body:body?(Buffer.isBuffer(body)?body:JSON.stringify(body)):undefined});return {status:r.status,body:await r.json()};}
 const check=async(build=1)=>{
  const response=await call(`/v1/updates/check?platform=android&arch=arm64&channel=stable&buildCode=${build}`,'GET',null,false);
  assert.equal(response.status,200,JSON.stringify(response));const e=response.body;
  assert.ok(verify(null,Buffer.from(e.payload,'base64'),publicKey,Buffer.from(e.signature,'base64')));
  const payload=JSON.parse(Buffer.from(e.payload,'base64'));assert.equal(payload.target.platform,'android');return payload;
 };
 assert.equal((await call('/v1/admin/releases','GET',null,false)).status,403);
 assert.equal((await check()).release,null);
 assert.equal((await call('/v1/updates/check?platform=android&arch=arm64','GET',null,false)).status,400);
 const bytes=randomBytes(65539),sha=createHash('sha256').update(bytes).digest('hex');
 const upload=`/v1/admin/update-packages/${sha}?platform=android&arch=arm64`;
 assert.equal((await call(upload,'PUT',Buffer.from('bad'))).status,400);
 assert.equal((await call(upload,'PUT',bytes)).status,200);
 assert.equal((await call(upload.replace('arm64','x64'),'PUT',bytes)).status,409);
 const create=async(build,forceUpdate=false,status='published')=>{
  const r=await call('/v1/admin/releases','POST',{platform:'android',arch:'arm64',channel:'stable',versionName:`0.2.${build}`,buildCode:build,notes:'修复通话\n优化更新提示',sha256:sha,forceUpdate,status});assert.equal(r.status,200,JSON.stringify(r));return r.body.release;
 };
 const forced=await create(2,true),latest=await create(3,false);
 const offer=await check();assert.equal(offer.release.id,latest.id);assert.equal(offer.release.forceUpdate,true);assert.equal(offer.release.notes,'修复通话\n优化更新提示');
 assert.equal((await check(2)).release.forceUpdate,false);assert.equal((await check(3)).release,null);
 const draft=await create(4,false,'draft');assert.equal((await check()).release.id,latest.id);
 const full=await fetch(base+offer.release.downloadPath);assert.deepEqual(Buffer.from(await full.arrayBuffer()),bytes);
 const head=await fetch(base+offer.release.downloadPath,{method:'HEAD'});assert.equal(Number(head.headers.get('content-length')),bytes.length);assert.equal((await head.text()),'');
 const range=await fetch(base+offer.release.downloadPath,{headers:{Range:'bytes=10-19'}});assert.equal(range.status,206);assert.deepEqual(Buffer.from(await range.arrayBuffer()),bytes.subarray(10,20));
 assert.equal((await fetch(base+offer.release.downloadPath,{headers:{Range:'bytes=999999-'}})).status,416);
 assert.equal((await call('/v1/admin/releases/'+forced.id,'PATCH',{forceUpdate:'true'})).status,400);
 assert.equal((await call('/v1/admin/releases/'+forced.id,'DELETE')).status,200);
 assert.equal((await check()).release.forceUpdate,false);
 assert.equal((await call('/v1/admin/releases/'+draft.id,'PATCH',{status:'published',notes:'上线新的更新'})).status,200);
 assert.equal((await check()).release.id,draft.id);
 const list=await call('/v1/admin/releases?limit=2');assert.equal(list.body.releases.length,2);assert.ok(list.body.next);
 const next=await call('/v1/admin/releases?'+new URLSearchParams({...list.body.next,limit:2}));assert.equal(next.body.releases.length,1);
 assert.equal((await call('/v1/admin/releases?limit=1.5')).status,400);
 const files=['index.html','app.js','style.css','hot-updates.js','updates.js','viewer.html','friend-call.html','chat-history.html'].map(path=>{
  const bytes=Buffer.from(path);return {path,base64:bytes.toString('base64'),sha256:createHash('sha256').update(bytes).digest('hex')};
 });
 const hotBody={platform:'macos',arch:'arm64',channel:'stable',nativeBuild:123,revision:1,notes:'隐藏消息页面顶部栏',resource:{files}};
 assert.equal((await call('/v1/admin/hot-releases','POST',hotBody,false)).status,403);
 assert.equal((await call('/v1/admin/hot-releases','POST',{...hotBody,resource:{files:[{...files[0],path:'../index.html'},...files.slice(1)]}})).status,400);
 assert.equal((await call('/v1/admin/hot-releases','POST',{...hotBody,resource:{files:[{...files[0],sha256:'0'.repeat(64)},...files.slice(1)]}})).status,400);
 const hot=await call('/v1/admin/hot-releases','POST',hotBody);assert.equal(hot.status,200,JSON.stringify(hot));
 assert.equal((await call('/v1/admin/hot-releases','POST',hotBody)).status,409);
 const checkHot=async(platform='macos',nativeBuild=123)=>{
  const r=await call(`/v1/hot-updates/check?platform=${platform}&arch=arm64&nativeBuild=${nativeBuild}`,'GET',null,false);
  assert.equal(r.status,200);assert.ok(verify(null,Buffer.from(r.body.payload,'base64'),publicKey,Buffer.from(r.body.signature,'base64')));
  return JSON.parse(Buffer.from(r.body.payload,'base64'));
 };
 assert.equal((await checkHot()).patch.notes,hotBody.notes);
 assert.equal((await checkHot('macos',124)).patch,null);
 assert.equal((await checkHot('windows')).patch,null);
 const androidHot=await call('/v1/admin/hot-releases','POST',{...hotBody,platform:'android',resource:{patchNumber:2}});
 assert.equal(androidHot.status,200);assert.equal((await checkHot('android')).patch.resource.patchNumber,2);
 assert.equal((await call('/v1/admin/hot-releases/'+hot.body.id,'DELETE')).status,200);
 assert.equal((await checkHot()).patch,null);
 // Restart process: releases, notes, force and packages are persisted, not process memory.
 child.kill('SIGTERM');await new Promise(r=>child.once('exit',r));child=start();capture(child);await ready();
 assert.equal((await check()).release.notes,'上线新的更新');
 assert.equal((await call('/v1/admin/releases/'+forced.id)).body.release.status,'withdrawn');
 assert.equal((await checkHot('android')).patch.resource.patchNumber,2);
 assert.ok((await call('/v1/admin/hot-releases')).body.releases.find(r=>r.id===hot.body.id&&r.status==='withdrawn'));
 console.log('Update HTTP integration PASS: auth, signed metadata, persisted releases, mandatory upgrade chain, withdraw, upload hash, range and pagination');
} finally {
 if(child&&child.exitCode===null){child.kill('SIGTERM');await new Promise(r=>{child.once('exit',r);setTimeout(r,4000).unref();});}
 if(created)await admin.query(`DROP DATABASE IF EXISTS "${database}" WITH (FORCE)`);await admin.end();await rm(dir,{recursive:true,force:true});
}
