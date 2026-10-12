import assert from 'node:assert/strict';
import pg from 'pg';
import sharp from 'sharp';
// Set database env before loading any configuration-dependent server modules.
const url=new URL(process.env.TEST_DATABASE_URL??'postgres://remotescreen:remotescreen@127.0.0.1:54329/remotescreen_test');
const database=`rs_calls_${process.pid}_${Date.now()}`,admin=new pg.Pool({connectionString:url.toString()});
let db;
try{
 await admin.query(`CREATE DATABASE "${database}"`);url.pathname=`/${database}`;process.env.DATABASE_URL=url.toString();
 const {decodeTokenPayload}=await import('../src/token.mjs');
 db=await import('../src/db.mjs');await db.openDatabase();
 const users=await import('../src/users.mjs');const {createSocialHandler}=await import('../src/social.mjs');
 const people=[];
 for(const name of ['Alice','Bob','Carol']){const {user}=await users.createUser({email:`${name}@example.test`,name,password:'calls-test-secret'});const s=await users.createSession(user.id);people.push({...user,token:s.token});}
 const [a,b,c]=people,c1='client-1111111111111111',c2='client-2222222222222222',c3='client-3333333333333333';let checked=0;
 const api=(actor,op,body={})=>createSocialHandler(op)({request:{headers:{authorization:actor?`Bearer ${actor.token}`:''}},body:{clientId:c1,...body}});
 async function expect(actor,op,body,status=200){const r=await api(actor,op,body);assert.equal(r.status,status,`${op}: ${JSON.stringify(r.body)}`);checked++;return r.body;}
 await expect(null,'call-state',{},401);await expect(a,'call-state',{clientId:'bad'},400);
 await expect(a,'call-start',{peerId:b.id,kind:'voice'},403);await expect(a,'call-start',{peerId:a.id,kind:'voice'},400);
 for(const [x,y] of [[a,b],[a,c],[b,c]]){await expect(x,'request',{peerId:y.id});await expect(y,'decision',{peerId:x.id,accept:true});}
 await expect(a,'avatar',{avatarId:'fox'});await expect(b,'avatar',{avatarId:'rabbit'});
 let call=(await expect(a,'call-start',{peerId:b.id,kind:'voice'})).call;
 assert.equal(call.peerAvatarId,'rabbit');
 assert.equal((await expect(b,'call-state',{})).calls[0].peerAvatarId,'fox');
 const photo=await sharp({create:{width:256,height:256,channels:3,background:'#98aabb'}}).png().toBuffer();
 const avatar=await expect(a,'avatar',{avatarId:'custom',image:'data:image/png;base64,'+photo.toString('base64')});
 const incoming=(await expect(b,'call-state',{})).calls[0];assert.equal(incoming.peerAvatarId,'custom');assert.equal(incoming.peerAvatarRevision,avatar.avatarRevision);
 await expect(a,'avatar',{avatarId:'fox'});
 assert.equal(call.grant,undefined);assert.equal(call.status,'ringing');assert.equal(call.owned,true);
 assert.equal((await expect(a,'call-start',{peerId:b.id,kind:'voice'})).call.id,call.id);
 const other=(await expect(a,'call-state',{clientId:c2})).calls[0];assert.equal(other.owned,false);assert.equal(other.grant,undefined);
 await expect(c,'call-decision',{callId:call.id,accept:true},404);
 await expect(a,'call-decision',{callId:call.id,accept:true},403);
 await expect(a,'call-start',{peerId:c.id,kind:'video'},409);
 await expect(c,'call-start',{peerId:b.id,kind:'voice'},409);
 const decisions=await Promise.all([api(b,'call-decision',{callId:call.id,clientId:c2,accept:true}),api(b,'call-decision',{callId:call.id,clientId:c3,accept:true})]);
 assert.deepEqual(decisions.map(r=>r.status).sort(),[200,409]);checked++;
 const selected=decisions[0].status===200?c2:c3,unselected=selected===c2?c3:c2;
 await expect(b,'call-decision',{callId:call.id,clientId:selected,accept:true});
 const caller=(await expect(a,'call-state',{})).calls[0],callee=(await expect(b,'call-state',{clientId:selected})).calls[0];
 assert.equal(caller.status,'active');assert.ok(caller.grant);assert.ok(callee.grant);
 const jwt=decodeTokenPayload(caller.grant.token);assert.match(jwt.video.room,/^friend-call-/);assert.deepEqual(jwt.video.canPublishSources,['microphone']);assert.equal(jwt.video.canPublishData,true);
 assert.equal(caller.grant.peerIdentity,callee.grant.identity);
 assert.equal((await expect(b,'call-state',{clientId:unselected})).calls[0].grant,undefined);
 await expect(b,'call-end',{callId:call.id,clientId:unselected},403);await expect(a,'call-end',{callId:call.id,clientId:c2},403);
 await db.query('UPDATE friend_calls SET accepted_at=$1 WHERE id=$2',[Date.now()-65000,call.id]);
 await expect(a,'call-end',{callId:call.id});await expect(a,'call-end',{callId:call.id});
 const historyA=(await expect(a,'messages',{peerId:b.id})).messages;
 const historyB=(await expect(b,'messages',{peerId:a.id})).messages;
 assert.equal(historyA.length,1);assert.deepEqual(historyA,historyB);
 assert.equal(historyA[0].kind,'call');assert.equal(historyA[0].call.callId,call.id);
 assert.equal(historyA[0].call.durationSeconds,65);assert.match(historyA[0].text,/1:05/);checked++;

 call=(await expect(a,'call-start',{peerId:b.id,kind:'video'})).call;
 const accepted=await expect(b,'call-decision',{callId:call.id,accept:true});assert.deepEqual(decodeTokenPayload(accepted.call.grant.token).video.canPublishSources,['microphone','camera']);
 await db.closeDatabase();await db.openDatabase();assert.equal((await expect(a,'call-state',{})).calls.find(x=>x.id===call.id).status,'active');
 await db.query('UPDATE friend_calls SET callee_seen=$1 WHERE id=$2',[Date.now()-36000,call.id]);
 const offline=(await expect(a,'call-state',{})).calls.find(x=>x.id===call.id);assert.equal(offline.status,'ended');assert.equal(offline.reason,'offline');assert.equal(offline.grant,undefined);
 call=(await expect(a,'call-start',{peerId:b.id,kind:'voice'})).call;
 await expect(b,'call-end',{callId:call.id},403);assert.equal((await expect(b,'call-decision',{callId:call.id,accept:false})).call.reason,'rejected');
 call=(await expect(a,'call-start',{peerId:b.id,kind:'voice'})).call;
 await db.query('UPDATE friend_calls SET created_at=$1 WHERE id=$2',[Date.now()-46000,call.id]);assert.equal((await expect(b,'call-state',{})).calls.find(x=>x.id===call.id).reason,'unanswered');
 call=(await expect(a,'call-start',{peerId:b.id,kind:'voice'})).call;
 const stale=Date.now()-30000;await db.query('UPDATE friend_calls SET caller_seen=$1 WHERE id=$2',[stale,call.id]);
 await expect(a,'call-state',{skipCallIds:[call.id]});assert.equal((await db.query('SELECT caller_seen FROM friend_calls WHERE id=$1',[call.id]))[0].caller_seen,String(stale));
 await db.query('UPDATE friend_calls SET caller_seen=$1 WHERE id=$2',[Date.now()-36000,call.id]);assert.equal((await expect(a,'call-state',{clientId:c2})).calls.find(x=>x.id===call.id).reason,'offline');
 const crossing=await Promise.all([api(a,'call-start',{peerId:b.id,kind:'voice'}),api(b,'call-start',{peerId:a.id,kind:'voice'})]);assert.deepEqual(crossing.map(r=>r.status).sort(),[200,409]);checked++;
 const winner=crossing[0].status===200?a:b,loser=winner===a?b:a;call=crossing.find(r=>r.status===200).body.call;
 await expect(loser,'call-decision',{callId:call.id,accept:true});
 await expect(a,'profile',{peerId:b.id,action:'block',blocked:true});const blocked=(await expect(winner,'call-state',{})).calls.find(x=>x.id===call.id);assert.equal(blocked.reason,'friend_changed');assert.equal(blocked.grant,undefined);
 await expect(a,'call-start',{peerId:b.id,kind:'voice'},403);
 await expect(a,'call-end',{callId:[]},400);await expect(a,'call-state',{skipCallIds:'bad'},400);
 const ended=(await db.query("SELECT id,reason FROM friend_calls WHERE status='ended'"));
 const records=await db.query("SELECT id,metadata FROM chat_messages WHERE kind='call'");
 assert.equal(records.length,ended.length);
 for(const c of ended){assert.equal(records.find(r=>r.id==='call:'+c.id).metadata.reason,c.reason);}checked++;
 await db.closeDatabase();await db.openDatabase();
 assert.equal((await db.query("SELECT id FROM chat_messages WHERE kind='call'")).length,records.length);checked++;
 // Simulate an older deployment without the history trigger, then verify startup backfill.
 await db.query('DROP TRIGGER friend_call_history ON friend_calls');
 await db.query("INSERT INTO friend_calls(id,caller_id,callee_id,caller_client,kind,status,reason,created_at,ended_at,caller_seen) VALUES('legacy-ended',$1,$2,$3,'video','ended','cancelled',$4,$4,$4)",[a.id,b.id,c1,Date.now()]);
 await db.closeDatabase();await db.openDatabase();
 const legacy=(await db.query("SELECT kind,metadata,text FROM chat_messages WHERE id='call:legacy-ended'"))[0];
 assert.equal(legacy.kind,'call');assert.equal(legacy.metadata.kind,'video');assert.match(legacy.text,/已取消/);checked++;
 console.log(`好友通话信令检查通过：${checked} 项（含多端抢答、交叉呼叫、授权、失联、重启及挂断重试租约）`);
}finally{await db?.closeDatabase();await admin.query(`DROP DATABASE IF EXISTS "${database}" WITH (FORCE)`);await admin.end();}
