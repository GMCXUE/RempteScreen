// Metadata only: no file bodies, hashes, local paths or download endpoints.
import {query as sql} from './db.mjs';
import {resolveSession} from './users.mjs';
import {verifyFileTransferGrant} from './token.mjs';
const fail=(status,message)=>{throw Object.assign(new Error(message),{statusCode:status});};
async function userFor(request) {
 const session=await resolveSession(/^Bearer\s+(.+)$/i.exec(request.headers.authorization??'')?.[1]);
 if(!session)fail(401,'请先登录');return session.user;
}
const fields=`id::text,sender_id AS "senderId",recipient_id AS "recipientId",
 sender_name AS "senderName",recipient_name AS "recipientName",
 sender_device_id AS "senderDeviceId",sender_device_name AS "senderDeviceName",
 recipient_device_id AS "recipientDeviceId",recipient_device_name AS "recipientDeviceName",
 file_name AS name,size_bytes::float8 AS size,created_at::float8 AS "createdAt",
 finished_at::float8 AS "finishedAt",status`;
export async function create({request,body}) {
 const user=await userFor(request),grant=verifyFileTransferGrant(body.grant,user.id);
 if(!grant)fail(403,'文件连接授权已失效，请重新连接设备');
 if(!/^[a-zA-Z0-9_-]{8,100}$/.test(body.clientId??''))fail(400,'传输标识无效');
 if(typeof body.name!=='string'||!body.name.trim()||Buffer.byteLength(body.name)>1024||/[\\/\x00-\x1f]/.test(body.name))fail(400,'文件名无效');
 if(!Number.isSafeInteger(body.size)||body.size<0)fail(400,'文件大小无效');
 if(body.size>50*1024*1024)fail(413,'单个文件不能超过 50 MB');
 const [source]=await sql('SELECT device_id,name FROM devices WHERE device_id=$1 AND user_id=$2',[body.senderDeviceId,user.id]);
 const [target]=await sql('SELECT d.device_id,d.name,u.id AS owner_id,u.name AS owner_name FROM devices d JOIN users u ON u.id=d.user_id WHERE d.device_id=$1 AND d.user_id=$2',[grant.deviceId,grant.recipientId]);
 if(!source||!target)fail(403,'设备信息已变化，请重新登录并连接设备');
 const args=[user.id,target.owner_id,body.clientId,user.name,target.owner_name,source.device_id,source.name,target.device_id,target.name,body.name,body.size,Date.now()];
 const inserted=await sql(`INSERT INTO file_transfers(sender_id,recipient_id,client_id,sender_name,recipient_name,sender_device_id,sender_device_name,recipient_device_id,recipient_device_name,file_name,size_bytes,created_at,status)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,'sending') ON CONFLICT(sender_id,client_id) DO NOTHING RETURNING ${fields}`,args);
 const row=inserted[0]??(await sql(`SELECT ${fields} FROM file_transfers WHERE sender_id=$1 AND client_id=$2`,[user.id,body.clientId]))[0];
 if(row.recipientId!==target.owner_id||row.senderDeviceId!==source.device_id||row.recipientDeviceId!==target.device_id||row.name!==body.name||row.size!==body.size)fail(409,'传输标识已用于其他文件');
 return {status:200,body:{transfer:row}};
}
export async function finish({request,params,body}) {
 const user=await userFor(request);
 if(!['completed','failed','cancelled'].includes(body.status)||!/^\d{1,18}$/.test(params.id))fail(400,'传输状态无效');
 const rows=await sql(`UPDATE file_transfers SET status=$3,finished_at=$4 WHERE id=$1 AND sender_id=$2 AND status='sending' RETURNING ${fields}`,[params.id,user.id,body.status,Date.now()]);
 const row=rows[0]??(await sql(`SELECT ${fields} FROM file_transfers WHERE id=$1 AND sender_id=$2`,[params.id,user.id]))[0];
 if(!row)fail(404,'传输记录不存在');
 if(row.status!==body.status)fail(409,'传输结果已经确认');
 return {status:200,body:{transfer:row}};
}
export async function list({request,query}) {
 const user=await userFor(request),before=query.get('before')??'9223372036854775807';
 if(!/^\d{1,19}$/.test(before)||BigInt(before)>9223372036854775807n)fail(400,'历史游标无效');
 const rows=await sql(`SELECT ${fields} FROM file_transfers WHERE (sender_id=$1 OR recipient_id=$1) AND id<$2 ORDER BY file_transfers.id DESC LIMIT 51`,[user.id,before]);
 const items=rows.slice(0,50).map(row=>({...row,status:row.status==='sending'&&Date.now()-row.createdAt>600000?'unconfirmed':row.status}));
 return {status:200,body:{items,next:rows.length>50?items.at(-1).id:null}};
}
