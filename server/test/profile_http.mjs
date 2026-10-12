// Real HTTP routing/body limits with an isolated database; no production access.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import net from 'node:net';
import pg from 'pg';
import sharp from 'sharp';
const url=new URL(process.env.TEST_DATABASE_URL??'postgres://remotescreen:remotescreen@127.0.0.1:54329/remotescreen_test');
const database=`rs_profile_http_${process.pid}_${Date.now()}`,admin=new pg.Pool({connectionString:url.toString()});
let db,child;
try {
 await admin.query(`CREATE DATABASE "${database}"`);url.pathname=`/${database}`;process.env.DATABASE_URL=url.toString();
 db=await import('../src/db.mjs');await db.openDatabase();
 const users=await import('../src/users.mjs');const {user}=await users.createUser({name:'HTTP 测试',email:'http@example.test',password:'http-test-password'});const session=await users.createSession(user.id);
 const listener=net.createServer();await new Promise(resolve=>listener.listen(0,'127.0.0.1',resolve));const port=listener.address().port;await new Promise(resolve=>listener.close(resolve));
 child=spawn(process.execPath,['src/index.mjs'],{env:{...process.env,PORT:String(port),HOST:'127.0.0.1'},stdio:['ignore','pipe','pipe']});
 let logs='';child.stdout.on('data',data=>logs+=data);child.stderr.on('data',data=>logs+=data);
 const base=`http://127.0.0.1:${port}`;
 let ready=false;
 for(let n=0;n<100;n++){try{ready=(await fetch(base+'/v1/health')).ok;if(ready)break;}catch{}await new Promise(resolve=>setTimeout(resolve,100));}
 assert.ok(ready,logs);
 const post=async(op,body)=>{const r=await fetch(base+'/v1/social/'+op,{method:'POST',headers:{authorization:`Bearer ${session.token}`,'content-type':'application/json'},body:JSON.stringify(body)});return {status:r.status,body:await r.json()};};
 const bytes=await sharp(randomBytes(256*256*3),{raw:{width:256,height:256,channels:3}}).png().toBuffer();
 const body={avatarId:'custom',image:'data:image/png;base64,'+bytes.toString('base64')};assert.ok(JSON.stringify(body).length>16*1024);
 const uploaded=await post('avatar',body);assert.equal(uploaded.status,200,JSON.stringify(uploaded));assert.equal(uploaded.body.avatarId,'custom');
 const image=await post('avatar-image',{peerId:user.id,revision:uploaded.body.avatarRevision});assert.equal(image.status,200);assert.ok(image.body.image.length>16*1024);
 const saved=await post('account-profile',{name:'新的昵称',bio:'HTTP 资料',gender:'',birthday:'',region:'上海'});assert.equal(saved.status,200);assert.equal(saved.body.user.bio,'HTTP 资料');
 assert.equal((await post('avatar',{avatarId:'custom',image:'bad'})).status,400);
 console.log('头像和资料 HTTP 检查通过：大于 16 KB 的头像正常传输、图片读取、资料更新及无效图片处理');
} finally {
 if(child){child.kill('SIGTERM');await new Promise(resolve=>{child.once('exit',resolve);setTimeout(resolve,4000).unref();});}
 await db?.closeDatabase();await admin.query(`DROP DATABASE IF EXISTS "${database}" WITH (FORCE)`);await admin.end();
}
