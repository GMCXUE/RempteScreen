// Account calls are independent of screen/device rooms. Selected clients hold leases.
import { normalizeAvatarId } from './avatars.mjs';
import { randomUUID } from 'node:crypto';
import { getPool } from './db.mjs';
import { signLiveKitToken } from './token.mjs';
import { config } from './config.mjs';
export const callSchema = `
CREATE TABLE IF NOT EXISTS friend_calls (
 id TEXT PRIMARY KEY, caller_id TEXT NOT NULL REFERENCES users(id), callee_id TEXT NOT NULL REFERENCES users(id),
 caller_client TEXT NOT NULL, callee_client TEXT, kind TEXT NOT NULL CHECK(kind IN ('voice','video')),
 status TEXT NOT NULL CHECK(status IN ('ringing','active','ended')), reason TEXT NOT NULL DEFAULT '',
 created_at BIGINT NOT NULL, accepted_at BIGINT, ended_at BIGINT, caller_seen BIGINT NOT NULL, callee_seen BIGINT,
 CHECK(caller_id<>callee_id)
);
CREATE INDEX IF NOT EXISTS idx_friend_calls_caller ON friend_calls(caller_id,status);
CREATE INDEX IF NOT EXISTS idx_friend_calls_callee ON friend_calls(callee_id,status);
CREATE OR REPLACE FUNCTION record_friend_call(call_id TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE c friend_calls%ROWTYPE; duration INTEGER; label TEXT; outcome TEXT;
BEGIN
 SELECT * INTO c FROM friend_calls WHERE id=call_id AND status='ended';
 IF NOT FOUND OR EXISTS(SELECT 1 FROM chat_messages WHERE id='call:' || c.id) THEN RETURN; END IF;
 duration := CASE WHEN c.accepted_at IS NULL THEN 0 ELSE
  GREATEST(0,FLOOR((CASE WHEN c.reason='offline' THEN LEAST(c.ended_at,c.caller_seen,c.callee_seen) ELSE c.ended_at END-c.accepted_at)/1000.0)) END;
 label := CASE WHEN c.kind='video' THEN '视频通话' ELSE '语音通话' END;
 outcome := CASE c.reason WHEN 'rejected' THEN '已拒绝' WHEN 'cancelled' THEN '已取消'
  WHEN 'unanswered' THEN '未接听' WHEN 'offline' THEN '连接中断'
  WHEN 'friend_changed' THEN '好友关系变化，通话结束' ELSE '已结束' END;
 IF c.accepted_at IS NOT NULL THEN
  outcome := CASE WHEN c.reason='hangup' THEN '通话时长' ELSE outcome || ' · ' END || ' ' ||
   (duration/60)::text || ':' || LPAD((duration%60)::text,2,'0');
 END IF;
 INSERT INTO chat_messages(id,sender_id,recipient_id,client_id,text,created_at,kind,metadata)
 VALUES('call:' || c.id,c.caller_id,c.callee_id,'server-call:' || c.id,label || ' · ' || outcome,
  c.ended_at,'call',jsonb_build_object('callId',c.id,'kind',c.kind,'reason',c.reason,
  'accepted',c.accepted_at IS NOT NULL,'durationSeconds',duration)) ON CONFLICT DO NOTHING;
 UPDATE friend_links SET updated_at=GREATEST(updated_at,c.ended_at)
 WHERE low_id=LEAST(c.caller_id,c.callee_id) AND high_id=GREATEST(c.caller_id,c.callee_id);
END $$;
CREATE OR REPLACE FUNCTION on_friend_call_ended() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.status='ended' THEN PERFORM record_friend_call(NEW.id); END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS friend_call_history ON friend_calls;
CREATE TRIGGER friend_call_history AFTER INSERT OR UPDATE OF status ON friend_calls
 FOR EACH ROW EXECUTE FUNCTION on_friend_call_ended();
DO $$ DECLARE c RECORD; BEGIN
 FOR c IN SELECT id FROM friend_calls WHERE status='ended' ORDER BY ended_at,id LOOP
  PERFORM record_friend_call(c.id);
 END LOOP;
END $$;
`;
const fail=(status,message)=>{throw Object.assign(new Error(message),{statusCode:status});};
const clientId=body=>{
 if(typeof body.clientId!=='string'||! /^[a-zA-Z0-9_-]{16,100}$/.test(body.clientId))fail(400,'通话客户端标识无效');
 return body.clientId;
};
async function sweep(db,now) {
 await db.query(`UPDATE friend_calls SET status='ended',reason=CASE WHEN status='ringing' AND created_at<$1 THEN 'unanswered' ELSE 'offline' END,ended_at=$2
 WHERE (status='ringing' AND (created_at<$1 OR caller_seen<$3)) OR (status='active' AND (caller_seen<$3 OR callee_seen<$3))`,[now-45000,now,now-35000]);
 await db.query(`UPDATE friend_calls c SET status='ended',reason='friend_changed',ended_at=$1 WHERE status IN ('ringing','active') AND
 (NOT EXISTS(SELECT 1 FROM friend_links f WHERE f.low_id=LEAST(c.caller_id,c.callee_id) AND f.high_id=GREATEST(c.caller_id,c.callee_id) AND f.state='accepted')
 OR EXISTS(SELECT 1 FROM friend_profiles p WHERE p.blocked AND ((p.owner_id=c.caller_id AND p.peer_id=c.callee_id) OR (p.owner_id=c.callee_id AND p.peer_id=c.caller_id))))`,[now]);
}
function dto(call,user,client) {
 const caller=call.caller_id===user.id;
 const owned=caller?call.caller_client===client:call.callee_client===client;
 const role=caller?'caller':'callee';
 const result={id:call.id,peerId:caller?call.callee_id:call.caller_id,peerName:caller?call.callee_name:call.caller_name,
 peerAvatarId:normalizeAvatarId(caller?call.callee_avatar:call.caller_avatar),peerAvatarRevision:(caller?call.callee_avatar_revision:call.caller_avatar_revision)??'',
 kind:call.kind,status:call.status,reason:call.reason,role,owned,createdAt:Number(call.created_at),acceptedAt:call.accepted_at?Number(call.accepted_at):null};
 if(owned && call.status==='active') {
  const identity=`friend-${call.id}-${role}`;
  result.grant={livekitUrl:config.livekit.url,identity,peerIdentity:`friend-${call.id}-${caller?'callee':'caller'}`,
   token:signLiveKitToken({identity,room:`friend-call-${call.id}`,name:user.name,canPublish:true,canPublishData:true,
    canPublishSources:call.kind==='video'?['microphone','camera']:['microphone'],ttlSec:90})};
 }
 return result;
}
async function fetchCall(db,id){return (await db.query(`SELECT c.*,a.name AS caller_name,b.name AS callee_name,a.avatar_id AS caller_avatar,b.avatar_id AS callee_avatar,a.avatar_revision AS caller_avatar_revision,b.avatar_revision AS callee_avatar_revision FROM friend_calls c JOIN users a ON a.id=c.caller_id JOIN users b ON b.id=c.callee_id WHERE c.id=$1`,[id])).rows[0];}
export async function callOperation(operation,user,body) {
 const client=clientId(body),db=await getPool().connect(),now=Date.now();
 try {
  await db.query('BEGIN');
  // Two crossing calls and multiple answering devices must be decided atomically.
  await db.query("SELECT pg_advisory_xact_lock(hashtextextended('remotescreen:friend-calls',0))");
  await sweep(db,now);
  let result;
  if(operation==='call-start') {
   const peer=body.peerId;
   if(typeof peer!=='string'||peer===user.id||!['voice','video'].includes(body.kind))fail(400,'请选择好友和通话类型');
   const [low,high]=[user.id,peer].sort();
   await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[`${low}:${high}`]);
   const friend=(await db.query("SELECT 1 FROM friend_links WHERE low_id=$1 AND high_id=$2 AND state='accepted'",[low,high])).rows.length;
   const blocked=(await db.query('SELECT 1 FROM friend_profiles WHERE blocked AND ((owner_id=$1 AND peer_id=$2) OR (owner_id=$2 AND peer_id=$1))',[user.id,peer])).rows.length;
   if(!friend||blocked)fail(403,'无法与该好友通讯，请检查好友关系');
   const own=(await db.query("SELECT * FROM friend_calls WHERE status IN ('ringing','active') AND (caller_id=$1 OR callee_id=$1)",[user.id])).rows[0];
   if(own && own.caller_id===user.id && own.caller_client===client && own.callee_id===peer && own.kind===body.kind){result={call:dto(await fetchCall(db,own.id),user,client)};}
   else {
    if(own)fail(409,'你正在通话，请先结束当前通话');
    if((await db.query("SELECT 1 FROM friend_calls WHERE status IN ('ringing','active') AND (caller_id=$1 OR callee_id=$1)",[peer])).rows.length)fail(409,'对方正在通话，请稍后再试');
    const id=randomUUID();
    await db.query("INSERT INTO friend_calls(id,caller_id,callee_id,caller_client,kind,status,created_at,caller_seen) VALUES($1,$2,$3,$4,$5,'ringing',$6,$6)",[id,user.id,peer,client,body.kind,now]);
    result={call:dto(await fetchCall(db,id),user,client)};
   }
  } else if(operation==='call-state') {
   const skip=body.skipCallIds??[];
   if(!Array.isArray(skip)||skip.length>20||skip.some(id=>typeof id!=='string'||id.length>100))fail(400,'通话标识无效');
   await db.query("UPDATE friend_calls SET caller_seen=$3 WHERE caller_id=$1 AND caller_client=$2 AND status IN ('ringing','active') AND NOT(id=ANY($4::text[]))",[user.id,client,now,skip]);
   await db.query("UPDATE friend_calls SET callee_seen=$3 WHERE callee_id=$1 AND callee_client=$2 AND status='active' AND NOT(id=ANY($4::text[]))",[user.id,client,now,skip]);
   const rows=(await db.query(`SELECT c.*,a.name AS caller_name,b.name AS callee_name,a.avatar_id AS caller_avatar,b.avatar_id AS callee_avatar,a.avatar_revision AS caller_avatar_revision,b.avatar_revision AS callee_avatar_revision FROM friend_calls c JOIN users a ON a.id=c.caller_id JOIN users b ON b.id=c.callee_id
    WHERE (caller_id=$1 OR callee_id=$1) AND (status<>'ended' OR ended_at>$2) ORDER BY created_at DESC`,[user.id,now-60000])).rows;
   result={calls:rows.map(c=>dto(c,user,client))};
  } else {
   if(typeof body.callId!=='string'||body.callId.length>100)fail(400,'通话标识无效');
   const call=await fetchCall(db,body.callId);
   if(!call || ![call.caller_id,call.callee_id].includes(user.id))fail(404,'通话不存在');
   if(operation==='call-decision') {
    if(call.callee_id!==user.id || typeof body.accept!=='boolean')fail(403,'只有被呼叫方可以接听或拒绝');
    if(call.status!=='ringing') {
     if(!(body.accept && call.status==='active' && call.callee_client===client))fail(409,'通话已结束或已在其他设备接听');
    } else if(body.accept) {
     await db.query("UPDATE friend_calls SET status='active',callee_client=$2,callee_seen=$3,accepted_at=$3 WHERE id=$1",[call.id,client,now]);
    } else await db.query("UPDATE friend_calls SET status='ended',reason='rejected',ended_at=$2 WHERE id=$1",[call.id,now]);
   } else if(operation==='call-end') {
    const owned=call.caller_id===user.id?call.caller_client===client:call.callee_client===client;
    if(!owned)fail(403,'请在发起或接听通话的设备上挂断');
    if(call.status!=='ended')await db.query("UPDATE friend_calls SET status='ended',reason=$2,ended_at=$3 WHERE id=$1",[call.id,call.status==='ringing'?'cancelled':'hangup',now]);
   } else fail(404,'通话操作不存在');
   result={call:dto(await fetchCall(db,call.id),user,client)};
  }
  await db.query('COMMIT');return result;
 } catch(e){await db.query('ROLLBACK');throw e;}finally{db.release();}
}
