import sharp from 'sharp';
import {createHash} from 'node:crypto';

export const chatImageMaxBytes = 8 * 1024 * 1024;
export async function normalizeChatImage(value) {
 const fail = message => {throw Object.assign(new Error(message), {statusCode:400});};
 if (typeof value !== 'string' || value.length > Math.ceil(chatImageMaxBytes / 3) * 4 + 64
     || !/^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$/.test(value)) fail('请选择 JPG、PNG 或 WebP 图片');
 const bytes = Buffer.from(value.slice(value.indexOf(',') + 1), 'base64');
 if (bytes.length > chatImageMaxBytes) fail('图片过大，请选择 8 MB 以内的图片');
 try {
  const source = sharp(bytes, {limitInputPixels:24000000, failOn:'warning'});
  const info = await source.metadata();
  if (!['jpeg','png','webp'].includes(info.format) || (info.pages ?? 1) > 1) fail('请选择静态 JPG、PNG 或 WebP 图片');
  const {data, info:output} = await source.rotate().resize({width:2048,height:2048,fit:'inside',withoutEnlargement:true})
   .flatten({background:'#ffffff'}).jpeg({quality:88}).toBuffer({resolveWithObject:true});
  const thumbnail = await sharp(data).resize({width:320,height:320,fit:'inside',withoutEnlargement:true}).jpeg({quality:72}).toBuffer();
  return {data, hash:createHash('sha256').update(bytes).digest('hex'),
   metadata:{sha256:createHash('sha256').update(data).digest('hex'),width:output.width,height:output.height,bytes:data.length,mime:'image/jpeg',thumbnail:'data:image/jpeg;base64,'+thumbnail.toString('base64')}};
 } catch(error) {
  if (error.statusCode) throw error;
  fail('无法读取图片，请选择其他图片');
 }
}
