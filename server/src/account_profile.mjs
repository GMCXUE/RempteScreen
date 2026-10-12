import {config} from './config.mjs';
const fail=message=>{throw Object.assign(new Error(message),{statusCode:400});};
function field(value,max,label){if(typeof value!=='string'||value.trim().length>max)fail(`${label}格式不正确或过长`);return value.trim();}
export function validateAccountProfile(body){
 const name=field(body.name,config.auth.nameMaxLength,'昵称');if(!name)fail('请填写昵称');
 const bio=field(body.bio??'',160,'个人简介'),region=field(body.region??'',32,'地区');
 const gender=body.gender??'';if(!['','male','female'].includes(gender))fail('请选择有效的性别');
 const birthday=body.birthday??'';if(typeof birthday!=='string')fail('请选择有效的生日');
 if(birthday){
  if(!/^\d{4}-\d{2}-\d{2}$/.test(birthday))fail('请选择有效的生日');
  const date=new Date(`${birthday}T00:00:00Z`);
  if(!Number.isFinite(date.getTime())||date.toISOString().slice(0,10)!==birthday||birthday<'1900-01-01'||birthday>new Date(Date.now()+14*60*60*1000).toISOString().slice(0,10))fail('请选择有效的生日');
 }
 return {name,bio,region,gender,birthday};
}
export const profileFields = user => ({bio:user.bio??'',region:user.region??'',gender:user.gender??'',birthday:user.birthday??''});
