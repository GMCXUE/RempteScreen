const {test}=require('node:test'),assert=require('node:assert/strict');
const vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const scope={window:{},document:{addEventListener(){}},crypto:{randomUUID:()=> 'image-test'}};
vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../ui/chat-messages.js'),'utf8'),scope);
function composer(){return new scope.window.ChatMessages({context:()=>({accountId:'me',peerId:'peer',generation:1}),onDraftChanged(){}});}
test('8 MB image enters draft without overflowing; invalid large data rejected',async()=>{
 const bytes=Buffer.alloc(8*1024*1024);bytes[0]=255;bytes[1]=216;bytes[bytes.length-1]=123;
 const source='data:image/jpeg;base64,'+bytes.toString('base64'),chat=composer();
 await chat.prepareImage(async()=>source);
 assert.equal(chat.draftImages.length,1);assert.equal(chat.draftImages[0].image,source);
 await assert.rejects(chat.prepareImage(async()=>source+'!'));assert.equal(chat.draftImages.length,1);
});
test('desktop accepts same image headers/padding and rejects oversized or malformed payloads',async()=>{
 for(const mime of ['jpeg','png','webp'])for(const payload of ['YQ==','YWFh']){
  const chat=composer();await chat.prepareImage(async()=>`data:image/${mime};base64,${payload}`);assert.equal(chat.draftImages.length,1);
 }
 for(const source of ['https://example.test/image.png','data:image/svg+xml;base64,YQ==',
  ...['','Y','YQ','YQ=','YQ===','Y=Q=','YQ==\n','Y%51==','A'.repeat(Math.ceil(8*1024*1024/3)*4+4)].map(s=>'data:image/png;base64,'+s)]){
  const chat=composer();await assert.rejects(chat.prepareImage(async()=>source));assert.equal(chat.draftImages.length,0);
 }
});
