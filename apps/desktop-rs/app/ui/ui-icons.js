// Fixed SVG artwork; user-provided file names never become markup.
(() => {
 const paths={
  message:['M3 3h18v14H9l-6 4z'],
  file:['M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z','M14 2v6h6'],
  text:['M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z','M14 2v6h6','M8 13h8M8 17h6'],
  image:['M4 3h16a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z','m3 17 6-6 4 4 4-6 4 8','M8 7h.01'],
  video:['M4 5h11a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z','m17 9 5-3v12l-5-3'],
  videoOff:['m17 9 5-3v12l-5-3','M10 5h5a2 2 0 0 1 2 2v6M17 17a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V7a2 2 0 0 1 1-1','M2 2l20 20'],
  audio:['M9 18V5l12-2v13','M9 5l12-2','M9 18a3 3 0 1 1-3-3c1.7 0 3 1.3 3 3z','M21 16a3 3 0 1 1-3-3c1.7 0 3 1.3 3 3z'],
  archive:['M5 3h14v18H5z','M11 3v3h2v3h-2v3h2v3h-2v3h2'],
  folder:['M3 6a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v2','M3 8v12h16l3-10H6z'],
  copy:['M9 9h12v12H9z','M15 9V3H3v12h6'],
  undo:['M9 4 4 9l5 5','M4 9h9a7 7 0 0 1 7 7v3'],
  call:['M22 16.9v3a2 2 0 0 1-2.2 2A19.8 19.8 0 0 1 3.1 5.2 2 2 0 0 1 5.1 3h3a2 2 0 0 1 2 1.7l.5 2.8a2 2 0 0 1-.6 1.9L8.4 11a16 16 0 0 0 4.6 4.6l1.6-1.6a2 2 0 0 1 1.9-.6l2.8.5a2 2 0 0 1 1.7 2z'],
  hangup:['M3 16v-4c5-5 13-5 18 0v4h-5v-4M8 12v4H3'],
  mic:['M9 5a3 3 0 0 1 6 0v7a3 3 0 0 1-6 0z','M5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8'],
  micOff:['M9 5a3 3 0 0 1 6 0v6M9 9v3a3 3 0 0 0 5 2','M5 10v2a7 7 0 0 0 12 5M19 10v2M12 19v3M8 22h8','M2 2l20 20'],
  speaker:['M11 5 6 9H3v6h3l5 4z','M15 8a6 6 0 0 1 0 8M18 5a10 10 0 0 1 0 14'],
  speakerOff:['M11 5 6 9H3v6h3l5 4z','m16 9 6 6m0-6-6 6'],
  expand:['M8 3H3v5M16 3h5v5M21 16v5h-5M3 16v5h5'],
  down:['m6 9 6 6 6-6'],
  return:['M7 17 17 7M7 7h10v10'],
 };
 function create(name){
  const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');
  for(const [key,value] of Object.entries({viewBox:'0 0 24 24',fill:'none',stroke:'currentColor','stroke-width':'1.7','stroke-linecap':'round','stroke-linejoin':'round','aria-hidden':'true',focusable:'false'}))svg.setAttribute(key,value);
  for(const d of paths[name]||paths.file){const path=document.createElementNS(svg.namespaceURI,'path');path.setAttribute('d',d);svg.append(path);}return svg;
 }
 function button(element,icon,label){element.replaceChildren(create(icon));const text=document.createElement('span');text.className='control-label';text.textContent=label;element.append(text);element.setAttribute('aria-label',label);element.title=label;}
 function fileKind(name){
  const extension=String(name||'').split('.').at(-1).toLowerCase();
  for(const [types,icon,tone] of [[['jpg','jpeg','png','gif','webp','heic','bmp'],'image','blue'],[['mp4','mov','mkv','avi','webm'],'video','purple'],[['mp3','wav','aac','flac','m4a','ogg'],'audio','green'],[['zip','rar','7z','tar','gz'],'archive','amber'],[['pdf'],'text','red'],[['doc','docx','txt','md','xls','xlsx','ppt','pptx'],'text','blue']])if(types.includes(extension))return {icon,tone};
  return {icon:'file',tone:'gray'};
 }
 function bytes(value){let size=Math.max(0,Number(value)||0),unit=0;const units=['B','KB','MB','GB','TB'];while(size>=1024&&unit<units.length-1){size/=1024;++unit;}return `${unit?Number(size.toFixed(1)):Math.round(size)} ${units[unit]}`;}
 window.uiIcons={create,button,fileKind,bytes};
})();
