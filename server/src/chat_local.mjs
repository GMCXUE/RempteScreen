// Account-wide durable delivery. Saving is distinct from reading a conversation.
import { getPool, query } from './db.mjs';
export const localChatSchema=`
CREATE INDEX IF NOT EXISTS idx_chat_sender_seq ON chat_messages(sender_id,seq);
CREATE TABLE IF NOT EXISTS chat_local_accounts (
 owner_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
 activated_at BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS chat_local_receipts (
 owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 message_id TEXT NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
 saved_at BIGINT NOT NULL, PRIMARY KEY(owner_id,message_id)
);
CREATE TABLE IF NOT EXISTS chat_delivery_dedup (
 sender_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,client_id TEXT NOT NULL,recipient_id TEXT REFERENCES users(id) ON DELETE CASCADE,seq BIGINT,PRIMARY KEY(sender_id,client_id)
);
ALTER TABLE chat_delivery_dedup ADD COLUMN IF NOT EXISTS recipient_id TEXT REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE chat_delivery_dedup ADD COLUMN IF NOT EXISTS seq BIGINT;
CREATE INDEX IF NOT EXISTS idx_chat_dedup_pair ON chat_delivery_dedup(sender_id,recipient_id,seq);
-- Sequence values normally reflect allocation, not commit order. Serialize and
-- allocate inside the trigger so a durable client cursor cannot skip a slow send.
CREATE OR REPLACE FUNCTION chat_delivery_order() RETURNS trigger AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(72831013001);
 IF TG_OP='INSERT' THEN NEW.seq=nextval(pg_get_serial_sequence('chat_messages','seq'));
 ELSIF NEW.kind IS DISTINCT FROM OLD.kind OR NEW.text IS DISTINCT FROM OLD.text
  OR NEW.metadata IS DISTINCT FROM OLD.metadata THEN NEW.edit_seq=nextval('chat_change_seq');
 END IF;
 RETURN NEW;
END; $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS chat_delivery_order ON chat_messages;
CREATE TRIGGER chat_delivery_order BEFORE INSERT OR UPDATE ON chat_messages
 FOR EACH ROW EXECUTE FUNCTION chat_delivery_order();
`;
export function localChatOperations({problem,messageColumns}) {
 const cursor=v=>{const s=String(v??'0');if(!/^\d{1,18}$/.test(s))problem(400,'消息游标不正确');return s;};
 return {
  async 'local-feed'(user,body) {
   const after=cursor(body.after),edit=cursor(body.edit);
   const db=await getPool().connect();
   try {
    await db.query('BEGIN');await db.query('SELECT pg_advisory_xact_lock(72831013001)');
    const where=`(sender_id=$1 OR recipient_id=$1) AND seq>COALESCE((SELECT cleared_seq FROM friend_profiles WHERE owner_id=$1 AND peer_id=CASE WHEN sender_id=$1 THEN recipient_id ELSE sender_id END),0)`;
    const columns=`${messageColumns},CASE WHEN sender_id=$1 THEN recipient_id ELSE sender_id END AS "peerId",edit_seq::text AS "editSeq"`;
    const rows=(await db.query(`SELECT ${columns} FROM chat_messages WHERE ${where} AND seq>$2 ORDER BY seq LIMIT 101`,[user.id,after])).rows;
    const edits=(await db.query(`SELECT ${columns} FROM chat_messages WHERE ${where} AND edit_seq>$2 ORDER BY edit_seq LIMIT 101`,[user.id,edit])).rows;
    const clears=(await db.query('SELECT peer_id AS "peerId",cleared_seq::text AS seq FROM friend_profiles WHERE owner_id=$1 AND cleared_seq>0',[user.id])).rows;
    const reads=(await db.query('SELECT peer_id AS "peerId",read_seq::text AS seq FROM friend_profiles WHERE owner_id=$1',[user.id])).rows;
    await db.query('COMMIT');
    return {messages:rows.slice(0,100),updates:edits.slice(0,100),clears,reads,
     after:rows.slice(0,100).at(-1)?.seq??after,edit:edits.slice(0,100).at(-1)?.editSeq??edit,
     hasMore:rows.length>100||edits.length>100,retentionDays:7};
   }catch(e){await db.query('ROLLBACK');throw e;}finally{db.release();}
  },
  async 'local-activate'(user) {
   await query('INSERT INTO chat_local_accounts(owner_id,activated_at) VALUES($1,$2) ON CONFLICT DO NOTHING',[user.id,Date.now()]);
   return {ok:true,retentionDays:7};
  },
  async 'local-saved'(user,body) {
   if(!Array.isArray(body.ids)||body.ids.length>100||body.ids.some(id=>typeof id!=='string'||id.length>100))problem(400,'落盘确认不正确');
   await query(`INSERT INTO chat_local_receipts(owner_id,message_id,saved_at)
    SELECT $1,id,$3 FROM chat_messages WHERE id=ANY($2::text[]) AND (sender_id=$1 OR recipient_id=$1)
    ON CONFLICT DO NOTHING`,[user.id,body.ids,Date.now()]);
   return {ok:true};
  },
  async 'local-image'(user,body) {
   const rows=await query(`SELECT m.kind,i.data FROM chat_messages m LEFT JOIN chat_images i ON i.message_id=m.id
    WHERE m.id=$2 AND (m.sender_id=$1 OR m.recipient_id=$1) AND m.seq>COALESCE((SELECT cleared_seq FROM friend_profiles WHERE owner_id=$1 AND peer_id=CASE WHEN m.sender_id=$1 THEN m.recipient_id ELSE m.sender_id END),0)`,[user.id,body.messageId]);
   const row=rows[0];if(!row)problem(404,'图片未下载或已过期');if(row.kind==='recalled')problem(410,'图片已撤回');
   if(!row.data)problem(404,'图片未下载或已过期');return {image:'data:image/jpeg;base64,'+row.data.toString('base64')};
  }
 };
}
// Legacy rows are protected until BOTH parties saved them, including media.
// New rows use a TTL only when both accounts opted into local storage.
export async function purgeLocalChat(now=Date.now()) {
 const db=await getPool().connect();try {
  await db.query('BEGIN');await db.query('SELECT pg_advisory_xact_lock(72831013001)');
  const rows=(await db.query(`SELECT m.id,m.sender_id,m.client_id FROM chat_messages m
   JOIN chat_local_accounts a ON a.owner_id=m.sender_id JOIN chat_local_accounts b ON b.owner_id=m.recipient_id
   LEFT JOIN chat_local_receipts r1 ON r1.owner_id=m.sender_id AND r1.message_id=m.id
   LEFT JOIN chat_local_receipts r2 ON r2.owner_id=m.recipient_id AND r2.message_id=m.id
   WHERE (m.created_at>=GREATEST(a.activated_at,b.activated_at) AND m.created_at<$1)
    OR (r1.saved_at IS NOT NULL AND r2.saved_at IS NOT NULL AND GREATEST(r1.saved_at,r2.saved_at)<$1)
   ORDER BY m.seq LIMIT 500`,[now-7*86400000])).rows;
  if(rows.length){const ids=rows.map(r=>r.id);await db.query('INSERT INTO chat_delivery_dedup(sender_id,client_id,recipient_id,seq) SELECT sender_id,client_id,recipient_id,seq FROM chat_messages WHERE id=ANY($1::text[]) ON CONFLICT DO NOTHING',[ids]);await db.query('DELETE FROM chat_messages WHERE id=ANY($1::text[])',[ids]);}
  await db.query('COMMIT');return rows.length;
 }catch(e){await db.query('ROLLBACK');throw e;}finally{db.release();}
}
