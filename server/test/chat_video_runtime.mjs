import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,chmod,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {normalizeChatVideo} from '../src/chat_video.mjs';

async function fixture(run){
 const dir=await mkdtemp(join(tmpdir(),'rs-media-runtime-test-'));
 const old={probe:process.env.CHAT_FFPROBE,ffmpeg:process.env.CHAT_FFMPEG};
 try{await run(dir);}finally{
  for(const [name,value] of [['CHAT_FFPROBE',old.probe],['CHAT_FFMPEG',old.ffmpeg]]){
   if(value===undefined)delete process.env[name];else process.env[name]=value;
  }
  await rm(dir,{recursive:true,force:true});
 }
}
test('missing probe is a service failure, not an invalid user video',()=>fixture(async dir=>{
 process.env.CHAT_FFPROBE=join(dir,'absent-probe');
 await assert.rejects(normalizeChatVideo(join(dir,'input.mp4'),dir),e=>e.statusCode===503&&e.message==='视频服务暂不可用，请稍后重试');
}));
test('missing encoder is reported as a service failure after a valid probe',()=>fixture(async dir=>{
 const probe=join(dir,'probe');
 await writeFile(probe,'#!/usr/bin/env node\nconsole.log(JSON.stringify({streams:[{codec_type:"video",width:64,height:48}],format:{format_name:"mov,mp4",duration:"1"}}));\n');await chmod(probe,0o700);
 process.env.CHAT_FFPROBE=probe;process.env.CHAT_FFMPEG=join(dir,'absent-encoder');
 await assert.rejects(normalizeChatVideo(join(dir,'input.mp4'),dir),e=>e.statusCode===503&&e.message==='视频服务暂不可用，请稍后重试');
}));
test('a readable probe rejecting bad input still returns a format error',()=>fixture(async dir=>{
 const probe=join(dir,'probe');await writeFile(probe,'#!/usr/bin/env node\nprocess.exit(1);\n');await chmod(probe,0o700);process.env.CHAT_FFPROBE=probe;
 await assert.rejects(normalizeChatVideo(join(dir,'input.mp4'),dir),e=>e.statusCode===400&&e.message.includes('无法读取视频'));
}));
test('deployment dependency verification rejects an incomplete runtime',()=>fixture(async dir=>{
 const result=spawnSync(process.execPath,['scripts/check-video-runtime.mjs'],{cwd:new URL('../',import.meta.url),env:{...process.env,CHAT_FFPROBE:join(dir,'absent'),CHAT_FFMPEG:join(dir,'absent')},encoding:'utf8'});
 assert.equal(result.status,1);assert.match(result.stderr,/视频运行依赖检查失败/);
}));
