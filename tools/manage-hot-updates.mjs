// Run on the production service's loopback network, using its mounted administration token.
import {readFile} from 'node:fs/promises';
const [command,argument]=process.argv.slice(2),base=process.env.UPDATE_ADMIN_BASE??'http://127.0.0.1:8787';
const url=new URL(base);
if(url.protocol!=='https:'&&!['127.0.0.1','localhost'].includes(url.hostname))throw Error('Administration credentials require HTTPS or loopback');
const token=String(await readFile(process.env.UPDATE_ADMIN_TOKEN_FILE)).trim();
let path='/v1/admin/hot-releases',method='GET',body;
if(command==='publish'){method='POST';body=await readFile(argument,'utf8');JSON.parse(body);}
else if(command==='withdraw'){method='DELETE';if(!/^hot_[a-f0-9]{18}$/.test(argument??''))throw Error('Invalid release id');path+='/'+argument;}
else if(command!=='list')throw Error('Usage: manage-hot-updates.mjs list | publish DESCRIPTOR | withdraw ID');
const response=await fetch(base+path,{method,redirect:'error',headers:{authorization:`Bearer ${token}`,...(body?{'content-type':'application/json'}:{})},body});
const value=await response.json();if(!response.ok)throw Error(JSON.stringify(value));console.log(JSON.stringify(value,null,2));
