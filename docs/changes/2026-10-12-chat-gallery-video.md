# 聊天图片多选与视频消息

主桌面客户端和 Flutter 移动客户端同步实现。图片入口改为“图片与视频”，图库/文件选择器支持混合多选，一次最多 9 项，发送时立即清空草稿并在聊天中显示排队/发送中；网络失败可单独重试，原 clientId 不变。拍照入口继续拍摄照片。

图片仍限制 8 MB。视频支持 MP4、MOV（包括 MP4 容器的 M4V），每项最多 50 MB、5 分钟。服务端将视频转为兼容两端的 H.264/AAC MP4，最长边最多 1280，生成 JPEG 封面和时长。视频作为二进制流上传，不经过大段 base64 JSON。视频原文件在客户端选择后保留文件引用，未读入整体内存。

聊天和“图片与视频”历史筛选支持视频。点击视频后，桌面打开独立视频窗口，移动端进入全屏视频页面；均提供播放、暂停、进度拖动和声音控制。桌面另有全屏按钮，移动端可点画面隐藏控制栏。

视频沿用两分钟撤回规则；撤回删除存储的视频，已打开的播放器在同步后停止播放。好友权限和本人的清空聊天记录边界适用于元数据及下载接口。客户端缓存仅用于本次播放，在关闭、撤回或退出账号后清理；不会删除用户原文件。队列目前保留在当前应用进程中，离开会话后继续，退出账号取消，不包含进程重启后的恢复。

## 服务端

新增 `chat_videos(message_id,data)` PostgreSQL 表；视频元数据保存到原消息表 metadata。原有消息和图片不迁移、不删除。容器增加 FFmpeg/FFprobe，非容器启动也需要这两个程序位于 PATH，可用 CHAT_FFMPEG、CHAT_FFPROBE 指定可执行文件。临时目录默认系统临时目录，可用 CHAT_MEDIA_TEMP_DIR 调整。

- `PUT /v1/social/videos/:clientId?peerId=...`：登录会话鉴权，原始视频 body，稳定 clientId 重试幂等。
- `POST /v1/social/message-video`：peerId、messageId，返回鉴权后的 message 与封面/时长/大小/SHA256。
- `GET/HEAD /v1/social/videos/:messageId?peerId=...`：鉴权下载，支持 Range。已撤回 410；清空后 404；非好友 403。
- 历史筛选 kind=media 包含图片和视频，原 kind=image 兼容旧客户端。

需要部署服务端并发行新完整安装包（新增原生播放器依赖）。本次不创建热补丁，原热更新能力保持可用。

## 验证命令

- server: `npm run test:chat-video`（独立测试数据库和真实 FFmpeg），以及原 chat-media、chat-history 测试。
- Flutter: chat_media_test、chat_messages_test、chat_viewport_test、chat_send_queue_test、chat_history_test、chat_image_viewer_test，以及静态检查和 Android 完整 APK 构建。
- Desktop: chat-messages-ui、chat-history-ui、chat-video-viewer-ui（VIDEO_FIXTURE 指向真实 H.264/AAC MP4）、chat-outbox 测试和 Rust 编译检查。

## 本次验证结果

2026-10-12：Flutter 25 项测试全部通过，相关 8 个文件静态检查无问题，Android arm64 release APK 编译成功。桌面聊天、历史、发送队列和真实 H.264/AAC 浏览器播放测试通过；Mac release 应用构建成功。服务端真实视频上传/转码/下载/撤回/50 MB 与 5 分钟限制通过；原图片 103 项和历史 51 项 PostgreSQL 测试通过。

本次安装包仅用于编译验证，发行版本号未递增，服务端与新完整安装包尚未发布。常规 Flutter 验证构建不用于发行；正式 Android 发行仍通过 Shorebird release 生成带原热更新引擎的新基础 APK，不创建 patch。Windows 尚未运行本次 Actions 构建。
