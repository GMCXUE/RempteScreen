import sharp from 'sharp';
import {createHash} from 'node:crypto';
export const avatarIds = Object.freeze(['cat', 'dog', 'fox', 'rabbit', 'bear', 'panda', 'penguin', 'owl']);
export const defaultAvatarId = 'cat';
export const normalizeAvatarId = id => id === 'custom' || avatarIds.includes(id) ? id : defaultAvatarId;
export const avatarFields = user => ({avatarId:normalizeAvatarId(user.avatar_id ?? user.avatarId),avatarRevision:user.avatar_revision ?? user.avatarRevision ?? ''});
export async function normalizeAvatarImage(value) {
 const fail=()=>{throw Object.assign(new Error('请选择有效的图片并裁剪后重试'),{statusCode:400});};
 if(typeof value!=='string' || value.length>410000 || !/^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$/.test(value))fail();
 const bytes=Buffer.from(value.slice(value.indexOf(',')+1),'base64');
 if(bytes.length>300000)fail();
 try{
  const image=sharp(bytes,{limitInputPixels:1048576,failOn:'warning'});
  const info=await image.metadata();
  if(!['png','jpeg','webp'].includes(info.format) || (info.pages??1)>1)fail();
  const png=await image.rotate().resize(256,256,{fit:'cover'}).png({compressionLevel:9}).toBuffer();
  return {png,revision:createHash('sha256').update(png).digest('hex')};
 }catch{fail();}
}
