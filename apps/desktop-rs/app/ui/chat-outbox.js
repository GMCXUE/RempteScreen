// A local enqueue is not a delivery receipt. Only a server acknowledgement replaces it.
(() => {
 class ChatSendQueue {
  constructor({accountId,peerId,sender,onChange,releaseMedia}){this.accountId=accountId;this.peerId=peerId;this.sender=Promise.resolve(sender).catch(error=>()=>Promise.reject(error));this.onChange=onChange;this.releaseMedia=releaseMedia;this.items=[];this.confirmed=[];this.running=false;this.cancelled=false;}
  enqueue(batch){
   if(this.cancelled)throw '账号已变化，请重新打开聊天';
   const all=[...this.items,...batch],bytes=all.reduce((n,m)=>n+(m.image?Math.floor(m.image.length*3/4):0),0);
   if(all.length>40||bytes>80*1024*1024||all.reduce((n,m)=>n+(m.video?.bytes||0),0)>512*1024*1024)throw '发送队列较满，请等当前图片或视频发送完成后再试';
   this.items.push(...batch.map(m=>({...m,status:'queued',error:'',createdAt:String(Date.now())})));this.onChange?.();this.drain();
  }
  drop(predicate){this.items=this.items.filter(m=>{if(!predicate(m))return true;this.releaseMedia?.(m);return false;});}
  retry(id){const m=this.items.find(m=>m.id===id&&m.status==='failed');if(!m)return;m.status='queued';m.error='';this.onChange?.();this.drain();}
  confirm(row){const i=this.confirmed.findIndex(m=>m.id===row.id);if(i<0)this.confirmed.push(row);else if(this.confirmed[i].kind!=='recalled'||row.kind==='recalled')this.confirmed[i]=row;if(this.confirmed.length>50)this.confirmed.shift();}
  reconcile(rows){let changed=false;for(const row of rows){if(row.senderId!==this.accountId||!row.clientId)continue;if(this.items.some(m=>m.id===row.clientId)){this.drop(m=>m.id===row.clientId);this.confirm(row);changed=true;}}if(changed)this.onChange?.();}
  records(){return this.items.map(m=>({id:`local_${m.id}`,clientId:m.id,senderId:this.accountId,kind:m.kind,text:m.kind==='image'?'[图片]':m.kind==='video'?'[视频]':m.text,createdAt:m.createdAt,localStatus:m.status,localError:m.error,...(m.video?{video:m.video}:{}),...(m.image?{image:{width:240,height:240,thumbnail:m.image}}:{})}));}
  async drain(){if(this.running||this.cancelled)return;this.running=true;
   try{while(!this.cancelled){const item=this.items.find(m=>m.status==='queued');if(!item)break;item.status='sending';this.onChange?.();
    try{const send=await this.sender;if(this.cancelled||!this.items.includes(item))continue;const result=await send(item.kind==='image'?'send-image':item.kind==='video'?'send-video':'send',{peerId:this.peerId,clientId:item.id,...(item.kind==='image'?{image:item.image}:item.kind==='video'?{video:item.video}:{text:item.text})});if(this.cancelled)return;this.confirm({...result.message,clientId:result.message.clientId||item.id});this.drop(m=>m===item);}
    catch(error){if(this.cancelled)return;if(this.items.includes(item)){item.status='failed';item.error=String(error);}}
    this.onChange?.();
   }}finally{this.running=false;if(!this.cancelled)this.onChange?.();}
  }
  discardFailures(){this.drop(m=>m.status==='failed');this.confirmed=[];this.onChange?.();}
  cancel(){this.cancelled=true;this.drop(()=>true);this.confirmed=[];this.onChange?.();}
 }
 window.ChatSendQueue=ChatSendQueue;
})();
