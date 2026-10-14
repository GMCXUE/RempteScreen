// Video bytes travel as a bounded binary stream, never a giant JSON/base64 body.
import {mkdtemp,readFile,stat,rm,open} from 'node:fs/promises';
import {createWriteStream} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pipeline} from 'node:stream/promises';
import {Transform} from 'node:stream';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash,randomUUID} from 'node:crypto';
import {query as sqlQuery} from './db.mjs';
import {resolveSession} from './users.mjs';
const run=promisify(execFile);
export const chatVideoMaxBytes=50*1024*1024;
let processors=0;
const fail=(status,message)=>{throw Object.assign(new Error(message),{statusCode:status});};
const errors=error=>({status:error.statusCode??500,body:{error:{code:'chat_video',message:error.statusCode?error.message:'视频处理失败，请重试'}}});
async function mediaCommand(command,args,options){
 try{return await run(command,args,options);}catch(error){
  if(['ENOENT','EACCES'].includes(error.code)){
   console.warn('[chat_video] media executable unavailable');
   fail(503,'视频服务暂不可用，请稍后重试');
  }
  throw error;
 }
}
async function userFor(request){const s=await resolveSession(/^Bearer\s+(.+)$/i.exec(request.headers.authorization??'')?.[1]);if(!s)fail(401,'请先登录');return s.user;}
async function probe(path){try{return JSON.parse((await mediaCommand(process.env.CHAT_FFPROBE??'ffprobe',['-v','error','-protocol_whitelist','file,pipe','-show_format','-show_streams','-of','json',path],{timeout:20000,maxBuffer:1024*1024})).stdout);}catch(error){if(error.statusCode===503)throw error;fail(400,'无法读取视频，请选择其他 MP4 或 MOV 视频');}}
export async function normalizeChatVideo(input,dir){
 const info=await probe(input),stream=info.streams?.find(s=>s.codec_type==='video'),duration=Number(info.format?.duration);
 if(!stream||!String(info.format?.format_name).split(',').includes('mov'))fail(400,'请选择 MP4 或 MOV 视频');
 if(!Number.isFinite(duration)||duration<=0)fail(400,'无法读取视频时长，请选择其他视频');
 if(duration>300)fail(400,'视频过长，请选择 5 分钟以内的视频');
 if(!Number.isSafeInteger(stream.width)||!Number.isSafeInteger(stream.height)||stream.width<=0||stream.height<=0||stream.width*stream.height>33000000)fail(400,'视频分辨率过大，请选择其他视频');
 const output=join(dir,'video.mp4');
 try{
  await mediaCommand(process.env.CHAT_FFMPEG??'ffmpeg',['-nostdin','-v','error','-protocol_whitelist','file,pipe','-i',input,'-map','0:v:0','-map','0:a:0?','-map_metadata','-1','-vf',"scale=w='min(1280,iw)':h='min(1280,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2",'-r','30','-c:v','libx264','-preset','veryfast','-crf','23','-pix_fmt','yuv420p','-c:a','aac','-b:a','96k','-movflags','+faststart','-threads','2',output],{timeout:180000,maxBuffer:1024*1024});
 }catch(error){if(error.statusCode===503)throw error;fail(400,'无法处理视频，请选择其他 MP4 或 MOV 视频');}
 if((await stat(output)).size>chatVideoMaxBytes)fail(400,'视频过大，请选择 50 MB 以内的视频');
 const normalized=await probe(output),v=normalized.streams.find(s=>s.codec_type==='video');
 const thumb=(await mediaCommand(process.env.CHAT_FFMPEG??'ffmpeg',['-nostdin','-v','error','-protocol_whitelist','file,pipe','-i',output,'-frames:v','1','-vf','scale=320:320:force_original_aspect_ratio=decrease','-f','image2pipe','-c:v','mjpeg','pipe:1'],{timeout:20000,maxBuffer:512*1024,encoding:'buffer'})).stdout;
 const data=await readFile(output);
 return {data,metadata:{width:v.width,height:v.height,duration:Math.round(Number(normalized.format.duration)*1000),bytes:data.length,mime:'video/mp4',sha256:createHash('sha256').update(data).digest('hex'),thumbnail:'data:image/jpeg;base64,'+thumb.toString('base64')}};
}
export function chatVideoHandlers({pair,requireFriend,messageColumns,clientIdValid,budget}){
 const existing=async(user,peer,clientId,hash)=>pair(user,peer,async({db,link,profiles})=>{
  requireFriend(link,profiles);const row=(await db.query(`SELECT ${messageColumns},recipient_id,payload_hash FROM chat_messages WHERE sender_id=$1 AND client_id=$2`,[user.id,clientId])).rows[0];
  if(row&&(row.recipient_id!==peer||row.payload_hash!==hash))fail(409,'消息标识已经用于其他消息');
  if(row){delete row.recipient_id;delete row.payload_hash;}return row;
 });
 const info=async(user,peer,messageId,archive=false)=>pair(user,peer,async({db,link,profiles})=>{
  if(!archive)requireFriend(link,profiles);const row=(await db.query(`SELECT ${messageColumns} FROM chat_messages WHERE id=$1 AND ((sender_id=$2 AND recipient_id=$3) OR (sender_id=$3 AND recipient_id=$2)) AND seq>COALESCE((SELECT cleared_seq FROM friend_profiles WHERE owner_id=$2 AND peer_id=$3),0)`,[messageId,user.id,peer])).rows[0];
  if(!row)fail(404,'消息不存在');if(row.kind==='recalled')fail(410,'视频已撤回');if(row.kind!=='video')fail(404,'视频不存在');return row;
 });
 return {
  async upload({request,params,query}){
   let dir,processing=false;
   try{
    const user=await userFor(request),peer=query.get('peerId'),clientId=params.clientId;
    if(!clientIdValid(clientId))fail(400,'消息标识不正确');
    if((await sqlQuery('SELECT 1 FROM chat_delivery_dedup WHERE sender_id=$1 AND client_id=$2',[user.id,clientId])).length)fail(409,'消息已投递并超过服务器暂存期限，请查看本地记录');budget(user.id,'send-video');
    await pair(user,peer,async({link,profiles})=>requireFriend(link,profiles));
    if(processors>=2)fail(429,'视频正在处理中，请稍后重试');processors++;processing=true;
    const declared=Number(request.headers['content-length']);if(Number.isFinite(declared)&&declared>chatVideoMaxBytes)fail(413,'视频过大，请选择 50 MB 以内的视频');
    dir=await mkdtemp(join(process.env.CHAT_MEDIA_TEMP_DIR??tmpdir(),'rs-chat-video-'));const input=join(dir,'input.mp4');let size=0;const hash=createHash('sha256');
    await pipeline(request,new Transform({transform(chunk,_,done){size+=chunk.length;if(size>chatVideoMaxBytes)return done(Object.assign(new Error('视频过大，请选择 50 MB 以内的视频'),{statusCode:413}));hash.update(chunk);done(null,chunk);}}),createWriteStream(input,{mode:0o600}),{signal:AbortSignal.timeout(240000)});
    if(size<16)fail(400,'请选择 MP4 或 MOV 视频');
    const file=await open(input);const head=Buffer.alloc(16);try{await file.read(head,0,16,0);}finally{await file.close();}
    if(head.toString('ascii',4,8)!=='ftyp')fail(400,'请选择 MP4 或 MOV 视频');
    const payloadHash='video:'+hash.digest('hex'),old=await existing(user,peer,clientId,payloadHash);if(old)return {status:200,body:{message:old}};
    const video=await normalizeChatVideo(input,dir);
    const message=await pair(user,peer,async({db,link,profiles,low,high})=>{
     requireFriend(link,profiles);
     if((await db.query('SELECT 1 FROM chat_delivery_dedup WHERE sender_id=$1 AND client_id=$2',[user.id,clientId])).rows.length)fail(409,'消息已投递并超过服务器暂存期限，请查看本地记录');
     const duplicate=(await db.query(`SELECT ${messageColumns},recipient_id,payload_hash FROM chat_messages WHERE sender_id=$1 AND client_id=$2`,[user.id,clientId])).rows[0];
     if(duplicate){if(duplicate.recipient_id!==peer||duplicate.payload_hash!==payloadHash)fail(409,'消息标识已经用于其他消息');delete duplicate.recipient_id;delete duplicate.payload_hash;return duplicate;}
     const row=(await db.query(`INSERT INTO chat_messages(id,sender_id,recipient_id,client_id,text,created_at,kind,metadata,payload_hash) VALUES($1,$2,$3,$4,'[视频]',$5,'video',$6,$7) RETURNING ${messageColumns}`,[randomUUID(),user.id,peer,clientId,Date.now(),video.metadata,payloadHash])).rows[0];
     await db.query('INSERT INTO chat_videos(message_id,data) VALUES($1,$2)',[row.id,video.data]);await db.query('UPDATE friend_links SET updated_at=$3 WHERE low_id=$1 AND high_id=$2',[low,high,Date.now()]);return row;
    });return {status:200,body:{message}};
   }catch(error){return errors(error);}finally{if(processing)processors--;if(dir)await rm(dir,{recursive:true,force:true});}
  },
  async metadata(user,body){return {message:await info(user,body.peerId,body.messageId)};},
  async archiveMetadata(user,body){return {message:await info(user,body.peerId,body.messageId,true)};},
  async download({request,response,params,query}){
   let knownSize=0;
   try{
    const user=await userFor(request),peer=query.get('peerId'),row=await info(user,peer,params.messageId,query.get('archive')==='1'),size=Number(row.video.bytes);knownSize=size;
    let start=0,end=size-1,status=200;
    if(request.headers.range){const match=/^bytes=(\d*)-(\d*)$/.exec(request.headers.range);if(!match||(!match[1]&&!match[2]))fail(416,'视频范围无效');if(!match[1])start=Math.max(0,size-Number(match[2]));else{start=Number(match[1]);if(match[2])end=Math.min(end,Number(match[2]));}if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start>end||start>=size)fail(416,'视频范围无效');status=206;}
    const data=await pair(user,peer,async({db,link,profiles})=>{if(query.get('archive')!=='1')requireFriend(link,profiles);return (await db.query("SELECT substring(v.data FROM $2::int FOR $3::int) AS data FROM chat_videos v JOIN chat_messages m ON m.id=v.message_id WHERE v.message_id=$1 AND m.kind='video' AND m.seq>COALESCE((SELECT cleared_seq FROM friend_profiles WHERE owner_id=$4 AND peer_id=$5),0)",[row.id,start+1,request.method==='HEAD'?0:end-start+1,user.id,peer])).rows[0]?.data;});
    if(!data)fail(410,'视频已撤回');response.writeHead(status,{'Content-Type':'video/mp4','Content-Length':end-start+1,'Accept-Ranges':'bytes',...(status===206?{'Content-Range':`bytes ${start}-${end}/${size}`}:{})});response.end(request.method==='HEAD'?undefined:data);return {__sse:true};
   }catch(error){if(error.statusCode===416)response.setHeader('Content-Range',`bytes */${knownSize}`);return errors(error);}
  }
 };
}
