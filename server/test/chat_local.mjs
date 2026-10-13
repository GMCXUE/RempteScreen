import assert from 'node:assert/strict';
import pg from 'pg';
const url=new URL(process.env.TEST_DATABASE_URL??'postgres://remotescreen:remotescreen@127.0.0.1:54329/remotescreen_test');
const name=`rs_local_${process.pid}_${Date.now()}`,admin=new pg.Pool({connectionString:url.toString()});let db;
try {
 await admin.query(`CREATE DATABASE "${name}"`);url.pathname='/'+name;process.env.DATABASE_URL=url.toString();
 db=await import('../src/db.mjs');await db.openDatabase();const users=await import('../src/users.mjs'),{createSocialHandler}=await import('../src/social.mjs'),{purgeLocalChat}=await import('../src/chat_local.mjs');
 const people=[];for(const name of ['a','b','c']){const {user}=await users.createUser({email:`${name}@local.test`,name,password:'test-secret123'});const {token}=await users.createSession(user.id);people.push({...user,token});}const [a,b,c]=people;
 let checks=0;async function api(actor,op,body={},status=200){const result=await createSocialHandler(op)({request:{headers:{authorization:actor?`Bearer ${actor.token}`:''}},body});assert.equal(result.status,status,`${op}:${JSON.stringify(result.body)}`);checks++;return result.body;}
 await api(a,'request',{peerId:b.id});await api(b,'decision',{peerId:a.id,accept:true});
 await api(null,'local-feed',{},401);await api(a,'local-feed',{after:'bad'},400);await api(a,'local-saved',{ids:'bad'},400);
 const old=(await api(a,'send',{peerId:b.id,text:'迁移旧记录',clientId:'old_local_message'})).message;
 await api(a,'local-activate');await api(b,'local-activate');
 await db.query('UPDATE chat_local_accounts SET activated_at=$1',[Date.now()+1000]);
 const fresh=(await api(b,'send',{peerId:a.id,text:'新消息',clientId:'new_local_message'})).message;
 const feed=await api(a,'local-feed');assert.equal(feed.messages.length,2);assert(feed.messages.every(r=>r.peerId===b.id));assert.equal((await api(c,'local-feed')).messages.length,0);
 // Reliable receipt is not a read receipt, and cannot acknowledge another account.
 await api(c,'local-saved',{ids:[old.id]});assert.equal((await db.query('SELECT count(*)::int AS n FROM chat_local_receipts'))[0].n,0);
 await api(a,'local-saved',{ids:[old.id]});assert.equal((await api(a,'state')).friends[0].unread,1);
 await api(a,'local-saved',{ids:[old.id]});assert.equal((await db.query('SELECT count(*)::int AS n FROM chat_local_receipts'))[0].n,1);
 const future=Date.now()+8*86400000;
 assert.equal(await purgeLocalChat(future),0); // old rows and not-yet-opted-in time protected
 await api(b,'local-saved',{ids:[old.id]});assert.equal(await purgeLocalChat(future),1);
 await api(a,'send',{peerId:b.id,text:'迁移旧记录',clientId:'old_local_message'},409);
 assert.equal((await db.query('SELECT count(*)::int AS n FROM chat_messages WHERE id=$1',[fresh.id]))[0].n,1);
 await db.query('UPDATE chat_local_accounts SET activated_at=$1',[Date.now()-1000]);
 assert.equal(await purgeLocalChat(future),1); // new records expire even if a device is offline
 await api(a,'read',{peerId:b.id,seq:fresh.seq});
 assert.equal((await api(a,'clear-history',{peerId:b.id})).clearedThrough,fresh.seq);
 // Commit-order test: a slow insertion must not be skipped behind a faster one.
 const p1=await db.getPool().connect(),p2=await db.getPool().connect();
 try {await p1.query('BEGIN');const r1=(await p1.query("INSERT INTO chat_messages(id,sender_id,recipient_id,client_id,text,created_at) VALUES('slow',$1,$2,'slow_local','slow',$3) RETURNING seq",[a.id,b.id,Date.now()])).rows[0];
  const insertion=p2.query("INSERT INTO chat_messages(id,sender_id,recipient_id,client_id,text,created_at) VALUES('fast',$1,$2,'fast_local','fast',$3) RETURNING seq",[b.id,a.id,Date.now()]);
  await p1.query('COMMIT');const r2=(await insertion).rows[0];assert(BigInt(r2.seq)>BigInt(r1.seq));
 }finally{p1.release();p2.release();}
 let current=await api(a,'local-feed');assert.deepEqual(current.messages.map(m=>m.id),['slow','fast']);
 const recalled=(await api(a,'recall',{peerId:b.id,messageId:'slow'})).message;
 const edits=await api(b,'local-feed',{after:current.after,edit:current.edit});assert(edits.updates.some(m=>m.id===recalled.id&&m.kind==='recalled'));
 const clear=await api(a,'clear-history',{peerId:b.id});current=await api(a,'local-feed');assert.equal(current.messages.length,0);assert.equal(current.clears[0].seq,clear.clearedThrough);
 assert.equal((await api(b,'local-feed')).messages.length,2);
 await db.closeDatabase();await db.openDatabase();assert.equal((await api(a,'local-feed')).clears[0].seq,clear.clearedThrough);
 console.log(`本地投递/隔离/持久化/清理及游标检查通过：${checks} 个接口断言`);
}finally{await db?.closeDatabase();await admin.query(`DROP DATABASE IF EXISTS "${name}" WITH(FORCE)`);await admin.end();}
