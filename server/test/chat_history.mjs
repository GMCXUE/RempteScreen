// Only synthetic accounts in a newly created isolated database are mutated.
import assert from 'node:assert/strict';
import pg from 'pg';
const url=new URL(process.env.TEST_DATABASE_URL??'postgres://remotescreen:remotescreen@127.0.0.1:54329/remotescreen_test');
const name=`rs_history_${process.pid}_${Date.now()}`,admin=new pg.Pool({connectionString:url.toString()});let db;
try{
 await admin.query(`CREATE DATABASE "${name}"`);url.pathname='/'+name;process.env.DATABASE_URL=url.toString();
 db=await import('../src/db.mjs');await db.openDatabase();
 const users=await import('../src/users.mjs'),{createSocialHandler}=await import('../src/social.mjs');
 const people=[];for(const name of ['Alice','Bob','Carol']){const {user}=await users.createUser({email:`${name}@history.test`,name,password:'synthetic-test-secret'});const {token}=await users.createSession(user.id);people.push({...user,token});}
 const [a,b,c]=people;let checked=0;
 async function api(actor,op,body={},status=200){const result=await createSocialHandler(op)({request:{headers:{authorization:actor?`Bearer ${actor.token}`:''}},body});assert.equal(result.status,status,`${op}: ${JSON.stringify(result.body)}`);checked++;return result.body;}
 await api(a,'request',{peerId:b.id});await api(b,'decision',{peerId:a.id,accept:true});
 await api(null,'history',{peerId:b.id},401);await api(c,'history',{peerId:b.id},403);await api(c,'clear-history',{peerId:b.id},403);
 const start=new Date('2026-10-12T00:00:00+08:00').getTime();
 for(let i=0;i<112;i++)await db.query(`INSERT INTO chat_messages(id,sender_id,recipient_id,client_id,text,created_at,kind,metadata) VALUES($1,$2,$3,$1,$4,$5,$6,$7)`,[`history_${i}`,i%2?a.id:b.id,i%2?b.id:a.id,i===1?'literal 100%_test \\ 你好':i===2?'<script>alert(1)</script> 中文':i===3?'https://example.test/path':`记录 ${i}`,start+(i<60?i*1000:86400000+i*1000),i===4?'image':i===5?'call':i===6?'recalled':'text',i===4?{width:100,height:80}:i===5?{kind:'voice',durationSec:30}:null]);
 let all=[],before;do{const r=await api(a,'history',{peerId:b.id,before});all.push(...r.messages);before=r.messages.at(-1)?.seq;if(!r.hasMore)break;}while(true);
 assert.equal(all.length,111);assert.equal(new Set(all.map(m=>m.id)).size,111);assert.equal(all[0].id,'history_111');assert.equal(all.at(-1).id,'history_0');
 assert.equal((await api(a,'history',{peerId:b.id,query:'%_test'})).messages.length,1);
 assert.equal((await api(a,'history',{peerId:b.id,query:'你好'})).messages[0].id,'history_1');
 assert.equal((await api(a,'history',{peerId:b.id,query:'\\'})).messages[0].id,'history_1');
 assert.equal((await api(a,'history',{peerId:b.id,query:"' OR 1=1 --"})).messages.length,0);
 assert.equal((await api(a,'history',{peerId:b.id,kind:'link'})).messages[0].id,'history_3');
 assert.equal((await api(a,'history',{peerId:b.id,kind:'image'})).messages[0].id,'history_4');
 assert.equal((await api(a,'history',{peerId:b.id,kind:'call'})).messages[0].call.durationSec,30);
 const day=await api(a,'history',{peerId:b.id,from:start,to:start+86400000});assert.equal(day.messages.length,50);assert.equal(day.hasMore,true);assert(day.messages.every(m=>Number(m.createdAt)<start+86400000));
 for(const invalid of [{kind:'music'},{query:{}},{before:'abc'},{from:1,to:0},{from:'x'}])await api(a,'history',{peerId:b.id,...invalid},400);
 const middle=await api(a,'message-context',{peerId:b.id,messageId:'history_55'});assert.equal(middle.messages.length,50);assert(middle.messages.some(m=>m.id==='history_55'));assert.equal(middle.hasMore,true);assert.equal(middle.hasNewer,true);
 await api(c,'message-context',{peerId:b.id,messageId:'history_55'},403);
 await api(a,'profile',{peerId:b.id,action:'pin',pinned:true});assert.equal((await api(a,'state')).friends[0].pinned,true);assert.equal((await api(b,'state')).friends[0].pinned,false);
 await api(a,'profile',{peerId:b.id,action:'pin',pinned:'yes'},400);
 await api(a,'request',{peerId:c.id});await api(c,'decision',{peerId:a.id,accept:true});
 assert.equal((await api(a,'state')).friends[0].id,b.id);
 await api(a,'message-context',{peerId:c.id,messageId:'history_55'},404);
 const clear=await api(a,'clear-history',{peerId:b.id});assert(BigInt(clear.clearedThrough)>0n);
 assert.equal((await api(a,'history',{peerId:b.id})).messages.length,0);
 assert.equal((await api(a,'messages',{peerId:b.id,after:'0',syncCursor:'0'})).messages.length,0);
 assert.equal((await api(a,'state')).friends[0].lastText,'');assert.equal((await api(a,'state')).friends[0].unread,0);assert.equal((await api(a,'state')).friends[0].pinned,true);
 assert.equal((await api(b,'history',{peerId:a.id})).messages.length,50);
 await api(a,'message-context',{peerId:b.id,messageId:'history_55'},404);await api(a,'message-image',{peerId:b.id,messageId:'history_4'},404);
 const fresh=(await api(b,'send',{peerId:a.id,clientId:'after_clear_message',text:'新消息'})).message;
 assert.equal((await api(a,'history',{peerId:b.id})).messages[0].id,fresh.id);assert.equal((await api(a,'state')).friends[0].unread,1);
 await db.closeDatabase();await db.openDatabase();assert.equal((await api(a,'history',{peerId:b.id})).messages.length,1);
 const [boundary,racing]=await Promise.all([api(a,'clear-history',{peerId:b.id}),api(b,'send',{peerId:a.id,clientId:'racing_clear_message',text:'并发消息'})]);
 const visible=await api(a,'history',{peerId:b.id});assert.equal(visible.messages.some(m=>m.id===racing.message.id),BigInt(racing.message.seq)>BigInt(boundary.clearedThrough));
 assert((await api(b,'history',{peerId:a.id})).messages.some(m=>m.id===racing.message.id));
 await api(a,'profile',{peerId:b.id,action:'block',blocked:true});await api(a,'history',{peerId:b.id},403);await api(b,'clear-history',{peerId:a.id},403);
 console.log(`聊天历史 PostgreSQL 集成检查通过：${checked} 项（完整分页、日期、字面搜索、越权、置顶、清空隔离及持久化）`);
}finally{await db?.closeDatabase();await admin.query(`DROP DATABASE IF EXISTS "${name}" WITH (FORCE)`);await admin.end();}
