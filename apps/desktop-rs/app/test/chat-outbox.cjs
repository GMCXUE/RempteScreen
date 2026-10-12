const assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const window={};vm.runInNewContext(fs.readFileSync(path.resolve(__dirname,'../ui/chat-outbox.js'),'utf8'),{window,Date,Promise});
const tick=()=>new Promise(resolve=>setImmediate(resolve));
(async()=>{
 let release,attempts=[], fail=true;
 const queue=new window.ChatSendQueue({accountId:'me',peerId:'peer',sender:async(op,body)=>{
  attempts.push({...body});if(body.clientId==='image'&&fail){await new Promise(r=>release=r);fail=false;throw '网络不可用';}
  return {message:{id:`server_${body.clientId}`,senderId:'me',clientId:body.clientId,kind:op==='send'?'text':'image'}};
 }});
 queue.enqueue([{id:'image',kind:'image',image:'data:image/png;base64,AAAA'},{id:'text',kind:'text',text:'继续输入'}]);await tick();
 assert.equal(queue.records().length,2);assert.equal(queue.items[0].status,'sending');assert.equal(attempts.length,1);
 release();await tick();assert.equal(attempts.length,2);assert.equal(queue.items[0].status,'failed');assert.equal(queue.confirmed[0].id,'server_text');
 queue.retry('image');queue.retry('image');await tick();assert.equal(attempts.length,3);assert.equal(attempts[2].clientId,'image');assert.equal(queue.items.length,0);
 let reject;
 const late=new window.ChatSendQueue({accountId:'me',peerId:'peer',sender:async()=>new Promise((_,r)=>reject=r)});
 late.enqueue([{id:'lost',kind:'text',text:'已送达但回执丢失'}]);await tick();
 late.reconcile([{id:'other',clientId:'lost',senderId:'other',kind:'text'}]);assert.equal(late.items.length,1);
 late.reconcile([{id:'received',clientId:'lost',senderId:'me',kind:'text'}]);reject('回执丢失');await tick();assert.equal(late.items.length,0);assert.equal(late.confirmed.length,1);
 let resolve;
 const cancelled=new window.ChatSendQueue({accountId:'me',peerId:'peer',sender:async()=>new Promise(r=>resolve=r)});
 cancelled.enqueue([{id:'late',kind:'text',text:'退出账号'}]);await tick();cancelled.cancel();resolve({message:{id:'late',senderId:'me'}});await tick();assert.equal(cancelled.confirmed.length,0);assert.throws(()=>cancelled.enqueue([]));
 console.log('Desktop chat send queue: PASS');
})().catch(e=>{console.error(e);process.exitCode=1;});
