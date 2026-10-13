import assert from 'node:assert/strict';
import pg from 'pg';
const url=new URL(process.env.TEST_DATABASE_URL??'postgres://remotescreen:remotescreen@127.0.0.1:54329/remotescreen_test');
const name=`rs_file_records_${process.pid}_${Date.now()}`,admin=new pg.Pool({connectionString:url.toString()});let db;
try {
 await admin.query(`CREATE DATABASE "${name}"`);url.pathname='/'+name;process.env.DATABASE_URL=url.toString();
 db=await import('../src/db.mjs');await db.openDatabase();
 const users=await import('../src/users.mjs'),store=await import('../src/store.mjs'),handlers=await import('../src/handlers.mjs'),records=await import('../src/file_transfers.mjs');
 const {signLiveKitToken,decodeTokenPayload,verifyFileTransferGrant}=await import('../src/token.mjs');
 const people=[];for(const name of ['a','b','c']){const {user}=await users.createUser({email:`${name}@files.test`,name,password:'test-secret123'});const {token}=await users.createSession(user.id);people.push({...user,token});}
 const [a,b,c]=people,request=user=>({headers:{authorization:user?`Bearer ${user.token}`:''}});
 const source=await store.registerDevice({userId:a.id,platform:'macos',deviceName:'A Mac'});
 const target=await store.registerDevice({userId:b.id,platform:'android',deviceName:'B Phone'});
 let checks=0;
 async function api(user,op,body={},id='',before=null,expected=200){let result;try{result=await records[op]({request:request(user),body,params:{id},query:new URLSearchParams(before?{before}:{})});}catch(e){result={status:e.statusCode??500,body:{message:e.message}};}assert.equal(result.status,expected,JSON.stringify(result));checks++;return result.body;}
 const grant=(await handlers.connect({request:request(a),body:{purpose:'files',deviceId:target.deviceId,password:target.password}})).body.token;
 assert(verifyFileTransferGrant(grant,a.id));assert.equal(verifyFileTransferGrant(grant,c.id),null);
 const body={clientId:'file_test_0001',grant,senderDeviceId:source.deviceId,name:'合同.pdf',size:50*1024*1024};
 await api(null,'create',body,'',null,401);
 await api(c,'create',body,'',null,403);
 await api(a,'create',{...body,grant:grant.slice(0,-4)+'xxxx'},'',null,403);
 await api(a,'create',{...body,senderDeviceId:target.deviceId},'',null,403);
 await api(a,'create',{...body,size:body.size+1},'',null,413);
 await api(a,'create',{...body,size:-1},'',null,400);
 await api(a,'create',{...body,name:'../秘密.pdf'},'',null,400);
 const claims=decodeTokenPayload(grant).fileTransfer;
 const expired=signLiveKitToken({identity:'viewer-expired',room:`files-${target.deviceId}`,canPublish:false,canPublishData:true,fileTransfer:claims,ttlSec:-1});
 await api(a,'create',{...body,grant:expired},'',null,403);
 const row=(await api(a,'create',body)).transfer;
 assert.equal(row.senderName,a.name);assert.equal(row.recipientName,b.name);assert.equal(row.senderDeviceName,'A Mac');assert.equal(row.recipientDeviceName,'B Phone');
 assert.equal((await api(a,'create',body)).transfer.id,row.id);
 await api(a,'create',{...body,name:'different.pdf'},'',null,409);
 assert.equal((await api(b,'list')).items[0].id,row.id);assert.equal((await api(c,'list')).items.length,0);
 await api(b,'finish',{status:'completed'},row.id,null,404);
 await api(a,'finish',{status:'completed'},row.id);
 await api(a,'finish',{status:'completed'},row.id);
 await api(a,'finish',{status:'failed'},row.id,null,409);
 // Approval-based connection must carry the same user-bound capability.
 const req=(await handlers.createConnectRequest({request:request(a),body:{purpose:'files',deviceId:target.deviceId}})).body;
 await handlers.decideConnectRequest({params:{requestId:req.requestId},body:{sessionToken:target.sessionToken,approve:true}});
 const approved=(await handlers.getConnectRequest({params:{requestId:req.requestId},query:new URLSearchParams()})).body.token;
 assert(verifyFileTransferGrant(approved,a.id));
 for(let i=2;i<=53;i++)await api(a,'create',{...body,grant:approved,clientId:`file_test_${String(i).padStart(4,'0')}`,size:0});
 const page=(await api(a,'list'));assert.equal(page.items.length,50);assert(page.next);
 const rest=await api(a,'list',{},'',page.next);assert.equal(rest.items.length,3);assert.equal(rest.next,null);
 assert.equal(new Set([...page.items,...rest.items].map(r=>r.id)).size,53);
 await api(a,'list',{},'','9223372036854775808',400);
 // Device rename and server restart preserve event-time names and old records.
 await db.query('UPDATE devices SET name=$1 WHERE device_id=$2',['New Phone',target.deviceId]);
 await db.query('UPDATE file_transfers SET created_at=$1',[Date.now()-400*86400000]);
 await db.closeDatabase();await db.openDatabase();
 const saved=(await api(a,'list')).items;
 assert(saved.every(r=>r.recipientDeviceName==='B Phone'));assert(saved.some(r=>r.status==='unconfirmed'));
 const columns=await db.query("SELECT column_name,data_type FROM information_schema.columns WHERE table_name='file_transfers'");
 assert(!columns.some(c=>c.data_type==='bytea'||/path|content|data|blob|hash/.test(c.column_name)));
 console.log(`File metadata permissions, limits, idempotency, paging, snapshots and persistence: ${checks} checks PASS`);
}finally{await db?.closeDatabase();await admin.query(`DROP DATABASE IF EXISTS "${name}" WITH(FORCE)`);await admin.end();}
