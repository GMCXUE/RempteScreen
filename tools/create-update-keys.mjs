// Run once; the private key remains local/secret, only the verification key is shipped.
import {generateKeyPairSync, createPrivateKey, createPublicKey, createHash, randomBytes} from 'node:crypto';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
const root=resolve(import.meta.dirname,'..');
await mkdir(resolve(root,'.local'),{recursive:true,mode:0o700});
await mkdir(resolve(root,'config'),{recursive:true});
const path=resolve(root,'.local/update-signing-private.pem');
let key;
try {key=createPrivateKey(await readFile(path));}
catch(error) {
 if(error.code!=='ENOENT')throw error;
 key=generateKeyPairSync('ed25519').privateKey;
 await writeFile(path,key.export({type:'pkcs8',format:'pem'}),{flag:'wx',mode:0o600});
}
const publicKey=createPublicKey(key).export({type:'spki',format:'der'}).subarray(-32);
const data={algorithm:'ed25519',keyId:createHash('sha256').update(publicKey).digest('hex').slice(0,16),publicKey:publicKey.toString('base64')};
const destination=resolve(root,'config/update-public-key.json');
try {const existing=JSON.parse(await readFile(destination));if(existing.publicKey!==data.publicKey)throw Error('Existing verification key differs; do not rotate installed clients implicitly');}
catch(error) {if(error.code!=='ENOENT')throw error;await writeFile(destination,JSON.stringify(data,null,2)+'\n',{flag:'wx'});}
try {await writeFile(resolve(root,'.local/update-admin-token'),randomBytes(32).toString('hex')+'\n',{flag:'wx',mode:0o600});}
catch(error){if(error.code!=='EEXIST')throw error;}
console.log('Update verification key ready:',data.keyId,'(private key and management token remain in .local)');
