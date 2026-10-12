(() => {
 const $=id=>document.getElementById(id),invoke=(command,args)=>window.__TAURI__.core.invoke(command,args),player=$('video'),status=$('status');let generation=0,closed=false,unavailable=false;
 window.uiIcons.button($('fullscreen'),'expand','全屏');window.uiIcons.button($('close'),'close','关闭');
 const windowHandle=window.__TAURI__.window.getCurrentWindow();
 $('close').onclick=()=>windowHandle.close();$('fullscreen').onclick=async()=>windowHandle.setFullscreen(!(await windowHandle.isFullscreen()));
 function fail(error){player.pause();player.hidden=true;status.hidden=false;status.firstChild.textContent=String(error);$('retry').hidden=false;}
 async function load(){if(unavailable)return;const v=++generation;$('retry').hidden=true;status.hidden=false;status.firstChild.textContent='正在加载视频…';try{const data=await invoke('get_chat_video');if(v!==generation||closed)return;player.src=window.__TAURI__.core.convertFileSrc(data.path);player.hidden=false;status.hidden=true;player.play().catch(()=>{});}catch(error){if(v===generation&&!closed)fail(error);}}
 player.onerror=()=>{if(!unavailable)fail('视频无法播放，请重试');};$('retry').onclick=load;
 const timer=setInterval(()=>invoke('check_chat_video').catch(error=>{if(/已撤回|消息不存在|账号已变化|请先登录|好友关系/.test(String(error))){unavailable=true;++generation;player.pause();player.removeAttribute('src');player.load();fail(error);$('retry').hidden=true;clearInterval(timer);}}),3000);
 window.addEventListener('beforeunload',()=>{closed=true;++generation;clearInterval(timer);player.pause();});document.addEventListener('keydown',async e=>{if(e.key==='Escape'){if(await windowHandle.isFullscreen())await windowHandle.setFullscreen(false);else await windowHandle.close();}});load();
})();
