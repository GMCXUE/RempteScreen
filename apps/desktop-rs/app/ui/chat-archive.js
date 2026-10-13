(() => {
 const ids=['sync','export','import'];let busy=false;
 const status=document.getElementById('chat-archive-status');
 async function refresh(){try{const v=await window.__TAURI__.core.invoke('chat_archive',{action:'status',password:null});status.textContent=`本机 ${v.messages} 条记录，${v.missing} 项媒体待下载。服务器暂存 7 天。`;}catch(e){status.textContent=String(e);}}
 for(const action of ids){document.getElementById(`chat-archive-${action}`).onclick=async()=>{
  if(busy)return;let password=null;
  if(action!=='sync'){
   password=await window.askDialog({title:action==='export'?'设置备份密码':'输入备份密码',message:'至少 8 个字符。备份只可恢复到同一账号，密码遗失后无法恢复。',defaultValue:'',inputType:'password'});
   if(password===null)return;if([...password].length<8){window.showAppToast('备份密码至少需要 8 个字符');return;}
   if(action==='export'){const again=await window.askDialog({title:'再次输入备份密码',defaultValue:'',inputType:'password'});if(again===null)return;if(again!==password){window.showAppToast('两次输入的密码不一致');return;}}
  }
  busy=true;for(const id of ids)document.getElementById(`chat-archive-${id}`).disabled=true;
  status.textContent=action==='sync'?'正在同步到本机…':action==='export'?'正在备份，请稍候…':'正在恢复，请稍候…';
  try{const v=await window.__TAURI__.core.invoke('chat_archive',{action,password});if(v.message)window.showAppToast(v.message,5000);}
  catch(e){window.showAppToast(String(e),5000);}
  finally{password=null;busy=false;for(const id of ids)document.getElementById(`chat-archive-${id}`).disabled=false;await refresh();}
 };}
 document.querySelector('[data-page="settings"]')?.addEventListener('click',refresh);
})();
