import {execFileSync} from 'node:child_process';

// Make an image with missing media dependencies fail at build/verification time.
for (const [name,command] of [['ffmpeg',process.env.CHAT_FFMPEG??'ffmpeg'],['ffprobe',process.env.CHAT_FFPROBE??'ffprobe']]) {
  try {execFileSync(command,['-version'],{stdio:'pipe',timeout:10000});}
  catch {console.error(`视频运行依赖检查失败：${name} 不可用`);process.exit(1);}
}
const encoders=execFileSync(process.env.CHAT_FFMPEG??'ffmpeg',['-hide_banner','-encoders'],{encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:10000});
for(const codec of ['libx264','aac','mjpeg']) {
  if(!new RegExp(`\\s${codec}\\s`).test(encoders)) {console.error(`视频运行依赖检查失败：缺少 ${codec} 编码器`);process.exit(1);}
}
console.log('视频运行依赖检查通过：FFmpeg、FFprobe、H.264、AAC 和 JPEG');
