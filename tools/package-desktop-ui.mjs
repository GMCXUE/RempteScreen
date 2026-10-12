// Create a reviewable resource release descriptor; it contains no native binary or account data.
import {readFile,writeFile,readdir,lstat} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolve,join} from 'node:path';
const [platform,arch,revision,notesFile,output]=process.argv.slice(2);
if(!['macos','windows'].includes(platform)||!['arm64','x64'].includes(arch)||!/^\d+$/.test(revision??'')||Number(revision)<1||!notesFile||!output)throw Error('Usage: node tools/package-desktop-ui.mjs macos arm64 REVISION NOTES_FILE OUTPUT');
const root=new URL('../',import.meta.url),ui=new URL('apps/desktop-rs/app/ui/',root);
const version=JSON.parse(await readFile(new URL('config/client-version.json',root)));
const files=[];
async function visit(dir,prefix=''){
 for(const name of (await readdir(dir)).sort()){
  const path=join(dir,name),info=await lstat(path),relative=prefix+name;
  if(info.isSymbolicLink())throw Error('Resource symlinks are not supported');
  if(info.isDirectory())await visit(path,relative+'/');
  else {const bytes=await readFile(path);files.push({path:relative,base64:bytes.toString('base64'),sha256:createHash('sha256').update(bytes).digest('hex')});}
 }
}
await visit(ui.pathname);
const body={platform,arch,channel:version.channel,nativeBuild:version.buildCode,revision:Number(revision),notes:String(await readFile(notesFile)).trim(),resource:{files}};
// Reuse server validation so an unsupported asset fails packaging, not a customer startup.
const {validateResource}=await import('../server/src/hot_updates.mjs');validateResource(body.resource,platform);
await writeFile(resolve(output),JSON.stringify(body),{flag:'wx'});
console.log(JSON.stringify({file:resolve(output),nativeBuild:body.nativeBuild,revision:body.revision,files:files.length,bytes:JSON.stringify(body).length}));
