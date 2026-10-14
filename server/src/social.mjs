// Account-level friendship and durable private messages. Pair mutations are serialized
// in PostgreSQL, including authorization, so deletion/blocking cannot race a send.
import { validateAccountProfile, profileFields } from './account_profile.mjs';
import { toPublicUser } from './users.mjs';
import { avatarIds, avatarFields, normalizeAvatarImage } from './avatars.mjs';
import { callOperation } from './calls.mjs';
import { localChatOperations } from './chat_local.mjs';
import { chatHistoryOperations } from './chat_history.mjs';
import { chatVideoHandlers } from './chat_video.mjs';
import { normalizeChatImage } from './chat_image.mjs';
import { randomUUID, createHash } from 'node:crypto';
import { getPool, query } from './db.mjs';
import { resolveSession } from './users.mjs';
import { config } from './config.mjs';


const requestBudgets = new Map();
function budget(userId, operation) {
 const limits = {history:120,'message-context':60,'clear-history':10,avatar:30,'account-profile':30,'avatar-image':180,search:30, request:10, send:120,'send-image':120,'send-video':30,'message-image':180,recall:60, "call-start":20};
 const limit = limits[operation]; if (!limit) return;
 const key = `${userId}:${operation}`, now = Date.now();
 if (requestBudgets.size > 5000) for (const [key,value] of requestBudgets) if (now-value.start>60000) requestBudgets.delete(key);
 let window = requestBudgets.get(key);
 if (!window || now-window.start>60000) { window={start:now,count:0};requestBudgets.set(key,window); }
 if (++window.count>limit) problem(429,'操作过于频繁，请稍后再试');
}
const success = body => ({status:200,body});
const problem = (status, message) => { throw Object.assign(new Error(message), {statusCode:status}); };
const textValue = (value, max, label) => {
 if (typeof value !== 'string' || value.trim().length > max) problem(400, `${label}格式不正确或过长`);
 return value.trim();
};
async function pair(user, peer, action) {
 if (typeof peer !== 'string' || !peer || peer.length > 100 || peer === user.id) problem(400,'请选择其他账号');
 const db = await getPool().connect();
 try {
  await db.query('BEGIN');
  await db.query('SELECT pg_advisory_xact_lock(72831013001)');
  const [low,high] = [user.id,peer].sort();
  await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[`${low}:${high}`]);
  if (!(await db.query('SELECT id FROM users WHERE id=$1',[peer])).rows.length) problem(404,'账号不存在');
  const link = (await db.query('SELECT * FROM friend_links WHERE low_id=$1 AND high_id=$2',[low,high])).rows[0];
  const profiles = (await db.query('SELECT * FROM friend_profiles WHERE (owner_id=$1 AND peer_id=$2) OR (owner_id=$2 AND peer_id=$1)',[user.id,peer])).rows;
  const result = await action({db,low,high,link,profiles});
  await db.query('COMMIT'); return result;
 } catch(error) { await db.query('ROLLBACK'); throw error; }
 finally { db.release(); }
}
function requireFriend(link,profiles) {
 if (link?.state !== 'accepted') problem(403,'请先添加对方为好友');
 if (profiles.some(p=>p.blocked)) problem(403,'无法与该好友通讯，请检查好友关系');
}
export function createSocialHandler(operation) {
 return async ({request,body={},query:params}) => {
  const token = /^Bearer\s+(.+)$/i.exec(request.headers.authorization ?? '')?.[1];
  const session = await resolveSession(token);
  if (!session) return {status:401,body:{error:{code:'unauthorized',message:'请先登录'}}};
  const user = session.user;
  try {
   if(operation !== 'state' && (!body || typeof body !== 'object' || Array.isArray(body))) problem(400,'请求格式不正确');
   budget(user.id,operation); return success(operation.startsWith('call-') ? await callOperation(operation,user,body) : await operations[operation](user,body,params));
  }
  catch(error) { if (error.code === "23505") error=Object.assign(new Error("消息标识已经用于其他消息"), {statusCode:409}); if (!error.statusCode) throw error; return {status:error.statusCode,body:{error:{code:'social_error',message:error.message}}}; }
 };
}
const messageColumns = `seq::text,id,sender_id AS "senderId",client_id AS "clientId",kind,
 CASE WHEN kind='call' THEN metadata END AS call,
 CASE WHEN kind='video' THEN metadata END AS video,
 CASE WHEN kind='image' THEN metadata END AS image,text,created_at::text AS "createdAt",recalled_at::text AS "recalledAt"`;
const clientIdValid = value => typeof value==='string' && /^[a-zA-Z0-9_-]{8,80}$/.test(value);
const payloadHash = text => createHash('sha256').update('text:'+text).digest('hex');
export const videoHandlers=chatVideoHandlers({pair,requireFriend,messageColumns,clientIdValid,budget});
const operations = {
 ...localChatOperations({problem,messageColumns}),
 'message-video':videoHandlers.metadata,
 'local-video':videoHandlers.archiveMetadata,
 ...chatHistoryOperations({pair,requireFriend,problem,messageColumns}),
 async 'account-profile'(user,body) {
  const profile=validateAccountProfile(body);
  const rows=await query('UPDATE users SET name=$2,bio=$3,region=$4,gender=$5,birthday=$6 WHERE id=$1 RETURNING *',[user.id,profile.name,profile.bio,profile.region,profile.gender,profile.birthday]);
  return {user:toPublicUser(rows[0])};
 },
 async 'avatar-image'(user,body) {
  if(typeof body.peerId!=='string'||body.peerId.length>100||! /^[a-f0-9]{64}$/.test(body.revision??''))problem(400,'头像请求不正确');
  const rows=await query("SELECT avatar_image FROM users WHERE id=$1 AND avatar_id='custom' AND avatar_revision=$2",[body.peerId,body.revision]);
  if(!rows[0]?.avatar_image)problem(404,'头像已更新，请刷新后重试');
  return {image:'data:image/png;base64,'+rows[0].avatar_image.toString('base64')};
 },
 async avatar(user,body) {
  if(body.avatarId==='custom') {
   if(body.image===undefined && user.avatar_id==='custom')return avatarFields(user);
   const {png,revision}=await normalizeAvatarImage(body.image);
   await query("UPDATE users SET avatar_id='custom',avatar_revision=$2,avatar_image=$3 WHERE id=$1",[user.id,revision,png]);
   return {avatarId:'custom',avatarRevision:revision};
  }
  if (!avatarIds.includes(body.avatarId)) problem(400,'请选择默认头像或上传图片');
  await query("UPDATE users SET avatar_id=$2,avatar_revision='',avatar_image=NULL WHERE id=$1",[user.id,body.avatarId]);
  return {avatarId:body.avatarId,avatarRevision:''};
 },
 async state(user) {
  const rows=await query(`SELECT u.id,u.account_id AS "accountId",u.name,u.avatar_id AS "avatarId",u.avatar_revision AS "avatarRevision",u.bio,u.region,u.gender,u.birthday, l.state,l.requester_id,l.note,l.updated_at,
   COALESCE(p.remark,'') AS remark,COALESCE(p.blocked,FALSE) AS blocked,COALESCE(p.pinned,FALSE) AS pinned,
   EXISTS(SELECT 1 FROM devices d WHERE d.user_id=u.id AND d.last_heartbeat_at>$2) AS online,
   COALESCE((SELECT count(*)::int FROM chat_messages m WHERE m.sender_id=u.id AND m.recipient_id=$1 AND m.seq>GREATEST(COALESCE(p.read_seq,0),COALESCE(p.cleared_seq,0)) AND m.kind<>'recalled'),0) AS unread,
   (SELECT seq::text FROM chat_messages m WHERE m.sender_id=u.id AND m.recipient_id=$1 AND m.seq>COALESCE(p.cleared_seq,0) ORDER BY seq DESC LIMIT 1) AS incoming_seq,
   (SELECT text FROM chat_messages m WHERE m.sender_id=u.id AND m.recipient_id=$1 AND m.seq>COALESCE(p.cleared_seq,0) ORDER BY seq DESC LIMIT 1) AS incoming_text,
   (SELECT kind FROM chat_messages m WHERE m.sender_id=u.id AND m.recipient_id=$1 AND m.seq>COALESCE(p.cleared_seq,0) ORDER BY seq DESC LIMIT 1) AS incoming_kind,
   COALESCE(p.read_seq,0)::text AS notification_read_seq,
   COALESCE((SELECT jsonb_agg(jsonb_build_object('seq',n.seq::text,'text',left(n.text,300),'kind',n.kind,'createdAt',n.created_at) ORDER BY n.seq)
     FROM (SELECT m.seq,m.text,m.kind,m.created_at FROM chat_messages m WHERE m.sender_id=u.id AND m.recipient_id=$1 AND m.seq>COALESCE(p.cleared_seq,0) AND m.kind NOT IN ('call','recalled') ORDER BY m.seq DESC LIMIT 5) n),'[]'::jsonb) AS incoming_messages,
   (SELECT text FROM chat_messages m WHERE ((m.sender_id=u.id AND m.recipient_id=$1) OR (m.sender_id=$1 AND m.recipient_id=u.id)) AND m.seq>COALESCE(p.cleared_seq,0) ORDER BY seq DESC LIMIT 1) AS last_text
   FROM friend_links l JOIN users u ON u.id=CASE WHEN l.low_id=$1 THEN l.high_id ELSE l.low_id END
   LEFT JOIN friend_profiles p ON p.owner_id=$1 AND p.peer_id=u.id
   WHERE (l.low_id=$1 OR l.high_id=$1) AND l.state IN ('pending','accepted') ORDER BY COALESCE(p.pinned,FALSE) DESC,l.updated_at DESC`,[user.id,Date.now()-config.heartbeat.timeoutSec*1000]);
  const blocked=await query('SELECT u.id,u.account_id AS "accountId",u.name,u.avatar_id AS "avatarId",u.avatar_revision AS "avatarRevision" FROM friend_profiles p JOIN users u ON u.id=p.peer_id WHERE p.owner_id=$1 AND p.blocked=TRUE',[user.id]);
  return {me:{id:user.id,accountId:user.account_id,name:user.name,...avatarFields(user),...profileFields(user),email:user.email},friends:rows.filter(r=>r.state==='accepted').map(r=>({id:r.id,accountId:r.accountId,name:r.name,...avatarFields(r),...profileFields(r),remark:r.remark,blocked:r.blocked,pinned:r.pinned,online:r.online,unread:r.unread,lastText:r.last_text??'',lastIncomingSeq:r.incoming_seq??'0',lastIncomingText:r.incoming_text??'',lastIncomingKind:r.incoming_kind??'text',notificationReadSeq:r.notification_read_seq??'0',incomingMessages:r.blocked?[]:r.incoming_messages})),
   requests:rows.filter(r=>r.state==='pending' && r.requester_id!==user.id && !r.blocked).map(r=>({id:r.id,accountId:r.accountId,name:r.name,...avatarFields(r),note:r.note,createdAt:String(r.updated_at)})),
   outgoing:rows.filter(r=>r.state==='pending' && r.requester_id===user.id).map(r=>({id:r.id,accountId:r.accountId,name:r.name,...avatarFields(r)})),blocked};
 },
 async search(user,body) {
  const key=textValue(body.query,100,'账号 ID 或邮箱');
  if(!key) problem(400,'请输入账号 ID 或邮箱');
  const rows=await query('SELECT id,account_id AS "accountId",name,avatar_id AS "avatarId",avatar_revision AS "avatarRevision" FROM users WHERE (account_id=$1 OR id=$1 OR email=$2) AND id<>$3 LIMIT 1',[key,key.toLowerCase(),user.id]);
  return {users:rows};
 },
 async request(user,body) {
  const note=textValue(body.note??'',160,'申请说明');
  return pair(user,body.peerId,async({db,low,high,link,profiles})=>{
   if(profiles.some(p=>p.blocked)) problem(403,'无法发送好友申请');
   if(link?.state==='accepted') return {ok:true};
   if(link?.state==='pending') problem(409,link.requester_id===user.id?'好友申请已发送，请等待对方确认':'对方已发送申请，请在好友申请中处理');
   if(link && Date.now()-Number(link.updated_at)<60000) problem(429,'请稍后再发送好友申请');
   await db.query(`INSERT INTO friend_links(low_id,high_id,requester_id,state,note,created_at,updated_at) VALUES($1,$2,$3,'pending',$4,$5,$5)
    ON CONFLICT(low_id,high_id) DO UPDATE SET requester_id=$3,state='pending',note=$4,updated_at=$5`,[low,high,user.id,note,Date.now()]);
   return {ok:true};
  });
 },
 async decision(user,body) {
  if(typeof body.accept!=='boolean') problem(400,'请选择同意或拒绝');
  return pair(user,body.peerId,async({db,low,high,link,profiles})=>{
   if(link?.state!=='pending' || link.requester_id===user.id) problem(409,'申请不存在或已经处理');
   if(profiles.some(p=>p.blocked)) problem(403,'请先解除拉黑');
   await db.query('UPDATE friend_links SET state=$3,updated_at=$4 WHERE low_id=$1 AND high_id=$2',[low,high,body.accept?'accepted':'declined',Date.now()]);
   return {ok:true};
  });
 },
 async profile(user,body) {
  return pair(user,body.peerId,async({db,low,high,link})=>{
   if(body.action==='remove') {
    if(link?.state!=='accepted') problem(409,'好友关系已结束');
    await db.query("UPDATE friend_links SET state='removed',updated_at=$3 WHERE low_id=$1 AND high_id=$2",[low,high,Date.now()]);return {ok:true};
   }
   if(body.action==='remark') {
    if(link?.state!=='accepted') problem(403,'请先添加对方为好友');
    const remark=textValue(body.remark??'',32,'好友备注');
    await db.query('INSERT INTO friend_profiles(owner_id,peer_id,remark) VALUES($1,$2,$3) ON CONFLICT(owner_id,peer_id) DO UPDATE SET remark=$3',[user.id,body.peerId,remark]);
   } else if(body.action==='pin') {
    if(link?.state!=='accepted') problem(403,'请先添加对方为好友');
    if(typeof body.pinned!=='boolean') problem(400,'置顶状态不正确');
    await db.query('INSERT INTO friend_profiles(owner_id,peer_id,pinned) VALUES($1,$2,$3) ON CONFLICT(owner_id,peer_id) DO UPDATE SET pinned=$3',[user.id,body.peerId,body.pinned]);
   } else if(body.action==='block') {
    if(typeof body.blocked!=='boolean') problem(400,'拉黑状态不正确');
    await db.query('INSERT INTO friend_profiles(owner_id,peer_id,blocked) VALUES($1,$2,$3) ON CONFLICT(owner_id,peer_id) DO UPDATE SET blocked=$3',[user.id,body.peerId,body.blocked]);
   } else problem(400,'不支持的好友操作');
   return {ok:true};
  });
 },
 async messages(user,body) {
  return pair(user,body.peerId,async({db,link,profiles})=>{
   requireFriend(link,profiles);
   const before=body.before==null?null:String(body.before),after=body.after==null?null:String(body.after);
   const sync=body.syncCursor==null?null:String(body.syncCursor);
   const loadedFrom=body.loadedFrom==null?null:String(body.loadedFrom);
   if ([before,after,sync,loadedFrom].some(v=>v!==null&&!/^\d{1,18}$/.test(v)) || (before!==null && after!==null)) problem(400,'消息游标不正确');
   const pairWhere='((sender_id=$1 AND recipient_id=$2) OR (sender_id=$2 AND recipient_id=$1)) AND seq>COALESCE((SELECT cleared_seq FROM friend_profiles WHERE owner_id=$1 AND peer_id=$2),0)';
   const rows=(await db.query(`SELECT ${messageColumns} FROM chat_messages WHERE ${pairWhere}
    AND ($3::bigint IS NULL OR seq<$3::bigint) AND ($4::bigint IS NULL OR seq>$4::bigint)
    ORDER BY chat_messages.seq ${after!==null?'ASC':'DESC'} LIMIT 51`,[user.id,body.peerId,before,after])).rows;
   const selected=rows.slice(0,50);
   const changes=sync===null?[]:(await db.query(`SELECT ${messageColumns},edit_seq::text AS "editSeq" FROM chat_messages
    WHERE ${pairWhere} AND edit_seq>$3::bigint AND ($4::bigint IS NULL OR seq>=$4::bigint)
    ORDER BY edit_seq ASC LIMIT 51`,[user.id,body.peerId,sync,loadedFrom])).rows;
   const updates=changes.slice(0,50);
   const cursor=changes.length>50?updates.at(-1).editSeq:(await db.query(`SELECT COALESCE(MAX(edit_seq),0)::text AS cursor FROM chat_messages WHERE ${pairWhere}`,[user.id,body.peerId])).rows[0].cursor;
   const clearedThrough=String(profiles.find(p=>p.owner_id===user.id)?.cleared_seq??'0');
   return {clearedThrough,hasMore:rows.length>50,messages:after!==null?selected:selected.reverse(),updates,syncCursor:cursor,serverNow:String(Date.now())};
  });
 },
 async send(user,body) {
  const text=textValue(body.text,2000,'消息');
  if(!text) problem(400,'消息不能为空');
  if(!clientIdValid(body.clientId)) problem(400,'消息标识不正确');
  if((await query('SELECT 1 FROM chat_delivery_dedup WHERE sender_id=$1 AND client_id=$2',[user.id,body.clientId])).length)problem(409,'消息已投递并超过服务器暂存期限，请查看本地记录');
  return pair(user,body.peerId,async({db,link,profiles,low,high})=>{
   requireFriend(link,profiles);
   if((await db.query('SELECT 1 FROM chat_delivery_dedup WHERE sender_id=$1 AND client_id=$2',[user.id,body.clientId])).rows.length)problem(409,'消息已投递并超过服务器暂存期限，请查看本地记录');
   const hash=payloadHash(text);
   const existing=(await db.query(`SELECT ${messageColumns},recipient_id,payload_hash FROM chat_messages WHERE sender_id=$1 AND client_id=$2`,[user.id,body.clientId])).rows[0];
   if(existing) {
    if(existing.recipient_id!==body.peerId || (existing.payload_hash?existing.payload_hash!==hash:existing.kind!=='text'||existing.text!==text)) problem(409,'消息标识已经用于其他消息');
    delete existing.recipient_id;delete existing.payload_hash;return {message:existing};
   }
   const row=(await db.query(`INSERT INTO chat_messages(id,sender_id,recipient_id,client_id,text,created_at,payload_hash) VALUES($1,$2,$3,$4,$5,$6,$7)
    RETURNING ${messageColumns}`,[randomUUID(),user.id,body.peerId,body.clientId,text,Date.now(),hash])).rows[0];
   await db.query('UPDATE friend_links SET updated_at=$3 WHERE low_id=$1 AND high_id=$2',[low,high,Date.now()]);
   return {message:row};
  });
 },
 async 'send-image'(user,body) {
  if(!clientIdValid(body.clientId)) problem(400,'消息标识不正确');
  if((await query('SELECT 1 FROM chat_delivery_dedup WHERE sender_id=$1 AND client_id=$2',[user.id,body.clientId])).length)problem(409,'消息已投递并超过服务器暂存期限，请查看本地记录');
  return pair(user,body.peerId,async({db,link,profiles,low,high})=>{
   requireFriend(link,profiles);
   if((await db.query('SELECT 1 FROM chat_delivery_dedup WHERE sender_id=$1 AND client_id=$2',[user.id,body.clientId])).rows.length)problem(409,'消息已投递并超过服务器暂存期限，请查看本地记录');
   const image=await normalizeChatImage(body.image),hash='image:'+image.hash;
   const existing=(await db.query(`SELECT ${messageColumns},recipient_id,payload_hash FROM chat_messages WHERE sender_id=$1 AND client_id=$2`,[user.id,body.clientId])).rows[0];
   if(existing) {
    if(existing.recipient_id!==body.peerId || existing.payload_hash!==hash) problem(409,'消息标识已经用于其他消息');
    delete existing.recipient_id;delete existing.payload_hash;return {message:existing};
   }
   const row=(await db.query(`INSERT INTO chat_messages(id,sender_id,recipient_id,client_id,text,created_at,kind,metadata,payload_hash)
    VALUES($1,$2,$3,$4,'[图片]',$5,'image',$6,$7) RETURNING ${messageColumns}`,[randomUUID(),user.id,body.peerId,body.clientId,Date.now(),image.metadata,hash])).rows[0];
   await db.query('INSERT INTO chat_images(message_id,data) VALUES($1,$2)',[row.id,image.data]);
   await db.query('UPDATE friend_links SET updated_at=$3 WHERE low_id=$1 AND high_id=$2',[low,high,Date.now()]);
   return {message:row};
  });
 },
 async 'message-image'(user,body) {
  return pair(user,body.peerId,async({db,link,profiles})=>{
   requireFriend(link,profiles);
   const row=(await db.query('SELECT m.kind,i.data FROM chat_messages m LEFT JOIN chat_images i ON i.message_id=m.id WHERE m.seq>COALESCE((SELECT cleared_seq FROM friend_profiles WHERE owner_id=$2 AND peer_id=$3),0) AND m.id=$1 AND ((m.sender_id=$2 AND m.recipient_id=$3) OR (m.sender_id=$3 AND m.recipient_id=$2))',[typeof body.messageId==='string'?body.messageId:'',user.id,body.peerId])).rows[0];
   if(!row) problem(404,'消息不存在');
   if(row.kind==='recalled') problem(410,'图片已撤回');
   if(row.kind!=='image'||!row.data) problem(404,'图片不存在');
   return {image:'data:image/jpeg;base64,'+row.data.toString('base64')};
  });
 },
 async recall(user,body) {
  return pair(user,body.peerId,async({db,link,profiles})=>{
   requireFriend(link,profiles);
   const row=(await db.query(`SELECT ${messageColumns} FROM chat_messages WHERE id=$1 AND sender_id=$2 AND recipient_id=$3`,[typeof body.messageId==='string'?body.messageId:'',user.id,body.peerId])).rows[0];
   if(!row) problem(403,'只能撤回自己的消息');
   if(row.kind==='recalled') return {message:row};
   if(!['text','image','video'].includes(row.kind)) problem(400,'该消息不支持撤回');
   if(Date.now()-Number(row.createdAt)>120000) problem(409,'消息已超过 2 分钟，无法撤回');
   const updated=(await db.query(`UPDATE chat_messages SET kind='recalled',text='撤回了一条消息',metadata=NULL,recalled_at=$2,payload_hash=COALESCE(payload_hash,$3),edit_seq=nextval('chat_change_seq') WHERE id=$1 RETURNING ${messageColumns}`,[row.id,Date.now(),row.kind==='text'?payloadHash(row.text):null])).rows[0];
   await db.query('DELETE FROM chat_images WHERE message_id=$1',[row.id]);
   await db.query('DELETE FROM chat_videos WHERE message_id=$1',[row.id]);
   return {message:updated};
  });
 },
 async read(user,body) {
  if(!/^\d{1,18}$/.test(String(body.seq))) problem(400,'消息游标不正确');
  return pair(user,body.peerId,async({db,link,profiles})=>{
   requireFriend(link,profiles);
   // Never accept a cursor for another conversation or a future message.
   const row=(await db.query('SELECT seq FROM chat_messages WHERE seq=$1 AND ((sender_id=$2 AND recipient_id=$3) OR (sender_id=$3 AND recipient_id=$2))',[body.seq,user.id,body.peerId])).rows[0];
   if(!row&&!(await db.query('SELECT 1 FROM chat_delivery_dedup WHERE seq=$1 AND ((sender_id=$2 AND recipient_id=$3) OR (sender_id=$3 AND recipient_id=$2))',[body.seq,user.id,body.peerId])).rows.length) problem(400,'消息不存在');
   await db.query('INSERT INTO friend_profiles(owner_id,peer_id,read_seq) VALUES($1,$2,$3) ON CONFLICT(owner_id,peer_id) DO UPDATE SET read_seq=GREATEST(friend_profiles.read_seq,$3)',[user.id,body.peerId,body.seq]);return {ok:true};
  });
 },
};
