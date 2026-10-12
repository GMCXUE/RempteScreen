// Each owner has a monotonic visibility boundary. Clearing never deletes the
// other participant's messages; pair() serializes clear with sends and recalls.
export function chatHistoryOperations({pair,requireFriend,problem,messageColumns}) {
 const where=`((sender_id=$1 AND recipient_id=$2) OR (sender_id=$2 AND recipient_id=$1))
   AND seq>COALESCE((SELECT cleared_seq FROM friend_profiles WHERE owner_id=$1 AND peer_id=$2),0)`;
 const cursor=value=>{
  if(value==null)return null;
  const s=String(value);if(!/^\d{1,18}$/.test(s))problem(400,'消息游标不正确');return s;
 };
 return {
  async history(user,body) {
   return pair(user,body.peerId,async({db,link,profiles})=>{
    requireFriend(link,profiles);
    const kind=body.kind??'all',q=body.query??'';
    if(!['all','text','image','media','video','link','call'].includes(kind)||typeof q!=='string'||q.length>200)problem(400,'查找条件不正确');
    const before=cursor(body.before);
    const bound=value=>{if(value==null)return null;if(!Number.isSafeInteger(value)||value<0||value>8640000000000000)problem(400,'日期范围不正确');return value;};
    const from=bound(body.from),to=bound(body.to);
    if(from!==null&&to!==null&&from>=to)problem(400,'日期范围不正确');
    const pattern=q.trim()?`%${q.trim().replace(/[\\%_]/g,'\\$&')}%`:null;
    const rows=(await db.query(`SELECT ${messageColumns} FROM chat_messages WHERE ${where}
      AND kind<>'recalled' AND ($3::bigint IS NULL OR seq<$3)
      AND ($4::text='all' OR kind=$4 OR ($4='media' AND kind IN ('image','video')) OR ($4='link' AND kind='text' AND text~*'https?://'))
      AND ($5::text IS NULL OR text ILIKE $5)
      AND ($6::bigint IS NULL OR created_at>=$6) AND ($7::bigint IS NULL OR created_at<$7)
      ORDER BY chat_messages.seq DESC LIMIT 51`,[user.id,body.peerId,before,kind,pattern,from,to])).rows;
    return {messages:rows.slice(0,50),hasMore:rows.length>50};
   });
  },
  async 'message-context'(user,body) {
   return pair(user,body.peerId,async({db,link,profiles})=>{
    requireFriend(link,profiles);
    if(typeof body.messageId!=='string'||body.messageId.length>100)problem(400,'消息标识不正确');
    const target=(await db.query(`SELECT seq FROM chat_messages WHERE ${where} AND id=$3`,[user.id,body.peerId,body.messageId])).rows[0];
    if(!target)problem(404,'消息已清空或不存在');
    const lower=(await db.query(`SELECT ${messageColumns} FROM chat_messages WHERE ${where} AND seq<=$3 ORDER BY chat_messages.seq DESC LIMIT 26`,[user.id,body.peerId,target.seq])).rows;
    const upper=(await db.query(`SELECT ${messageColumns} FROM chat_messages WHERE ${where} AND seq>$3 ORDER BY chat_messages.seq ASC LIMIT 26`,[user.id,body.peerId,target.seq])).rows;
    const sync=(await db.query(`SELECT COALESCE(MAX(edit_seq),0)::text AS cursor FROM chat_messages WHERE ${where}`,[user.id,body.peerId])).rows[0].cursor;
    return {messages:[...lower.slice(0,25).reverse(),...upper.slice(0,25)],hasMore:lower.length>25,hasNewer:upper.length>25,syncCursor:sync,clearedThrough:String(profiles.find(p=>p.owner_id===user.id)?.cleared_seq??'0'),serverNow:String(Date.now())};
   });
  },
  async 'clear-history'(user,body) {
   return pair(user,body.peerId,async({db,link,profiles})=>{
    requireFriend(link,profiles);
    const seq=(await db.query(`SELECT COALESCE(MAX(seq),0)::text AS seq FROM chat_messages WHERE (sender_id=$1 AND recipient_id=$2) OR (sender_id=$2 AND recipient_id=$1)`,[user.id,body.peerId])).rows[0].seq;
    await db.query(`INSERT INTO friend_profiles(owner_id,peer_id,cleared_seq,read_seq) VALUES($1,$2,$3,$3)
      ON CONFLICT(owner_id,peer_id) DO UPDATE SET cleared_seq=GREATEST(friend_profiles.cleared_seq,$3),read_seq=GREATEST(friend_profiles.read_seq,$3)`,[user.id,body.peerId,seq]);
    return {ok:true,clearedThrough:seq};
   });
  }
 };
}
