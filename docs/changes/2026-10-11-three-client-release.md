# 三端部署与覆盖安装（2026-10-11）

本次包含聊天图片发送、消息复制与两分钟内撤回、移动端首页优化，以及桌面连接区域和观看控制栏更新。保留已确认正常的 Windows 音频播放修复。安装保持应用数据，未清空账号、好友或聊天记录。

## 服务端

- 更新生产 `/opt/remotescreen` 的服务源码并重建 `device-service`，数据库、LiveKit、Caddy 未重启。
- 源码、数据库和旧镜像备份：`/opt/remotescreen/backups/three-clients-20261011-1745`，旧镜像标签 `remotescreen-device-service:before-three-clients-20261011-1745`。
- 部署前后均为 7 个账号、7 条好友关系、44 条消息、16 条通话。新 `chat_images` 表与撤回/同步所需 3 个字段存在。
- 健康接口 200。生产镜像 sharp 图片归一化通过；登录态消息同步返回更新游标和服务端时间。非法图片、不存在图片及无权撤回分别返回 400、404、403。检查未写入测试消息。

## Mac

- 使用 ad hoc 测试签名构建 Release app，完整签名验证通过，摄像头和麦克风用途声明保留。
- 已覆盖 `/Applications/RemoteScreen.app` 并启动，进程路径和安装二进制核对通过。
- 安装二进制 SHA-256：`f8402431d840b10455f9cc4eebbf6cbb61976be48ebb4117475891ce8dda5697`。
- 旧版备份：`/private/tmp/RemoteScreen-before-three-clients-20261011-1745.app`。

## Android

- arm64 Release APK 构建、签名检查通过。新包 SHA-256：`df3186cd84d366cdf610df06c7c4a75861b922727167b167fe7f0da381ce7f58`。
- 原无线地址失效后重新启动本机 ADB，通过原配对的 mDNS 服务自动恢复连接；无需重新配对。
- `adb install -r --no-streaming` 覆盖返回 Success，保留应用数据。旧包已备份 `/private/tmp/RemoteScreen-before-three-clients-20261011-1745.apk`，新旧证书一致。设备实际 APK 哈希与新包一致，进程已启动；首次安装时间仍为 2026-10-08，更新至 2026-10-11 17:50:41，后台 MessagingService 与 RequestWatchService 均为前台服务运行状态。

## Windows

- 已把桌面客户端源码快照上传独立 `codex/windows-client` 分支，本地 main 和暂存区未改动；未上传账号数据或凭据。
- 首次源码提交：`d711e38f4d61047cc23c5b6a0d073ae62f6f9d2e`；图片复制补充提交：`75c14f75ab0a13813228c521d78a74248d35c999`。
- [Actions 构建 38129461096](https://github.com/GMCXUE/RempteScreen/actions/runs/38129461096) 已成功；随后因用户补充图片复制需求，最终版另行构建并覆盖，结果见下文。

## 安装过程中补充：图片复制及复制提示

- 用户补充要求后，两端图片菜单和大图预览新增“复制图片”，通过原有鉴权接口取完整图片；远端撤回或下载失败时不会复制缩略图或文本路径。
- Mac/Windows 使用原生 RGBA 图像剪贴板；安卓使用仅暴露 `chat-clipboard` 缓存目录的 FileProvider URI，支持跨应用图片粘贴，目标应用需支持图片剪贴板。
- 移动端不再显示默认全宽复制 Snackbar。Android 13 及以上成功复制只保留系统提示，避免重复；较旧系统显示顶部紧凑提示，成功 1.2 秒、失败 2.2 秒，重复提示替换而不排队，离开聊天页面时清除。
- [Android 复制反馈及避免重复提示说明](https://developer.android.com/develop/ui/views/touch-and-input/copy-paste#duplicate-notifications)。
- 桌面聊天媒体交互检查通过；Flutter 5 项检查通过（含完整图复制、失败不写剪贴板、系统提示不重复、提示大小/位置/自动消失）；静态检查无问题，原生 Cargo check 和双端 Release 构建通过。
- 最终 Mac 二进制 SHA-256：`2c73658738dc9e59c26a595cac08ac66f43d9c43cd9b74b1e39cc7e284ba1172`。安装前备份 `/private/tmp/RemoteScreen-before-clipboard-20261011-1804.app`。
- 最终 Android APK SHA-256：`762f7d598e3c657fa0956cb79c87d77d3fb3aa867e555670bd907fbc638fba07`。
- 最终 Mac、Android 已覆盖并启动，实际安装文件与以上哈希一致；安卓消息及观看请求后台服务正常。Windows 最终版 [Actions 38130512042](https://github.com/GMCXUE/RempteScreen/actions/runs/38130512042) 成功并已覆盖，已在交互桌面会话启动；服务端无需因本次补充再次变更。

## Windows 最终安装

- Actions 38130512042 成功，源代码提交 `75c14f75ab0a13813228c521d78a74248d35c999`，安装包 Artifact ID `11698959987`。
- Artifact ZIP SHA-256 已与 GitHub 返回摘要核对：`0bdbd9836171bd0ed0acf77253c993cc15a4cfd48b802f412bf30d4d4c93f01f`。
- NSIS 安装包 SHA-256：`9ec429a816d9e0c6cbc3e74d521cd27d5f1ebd38d1c10f4d0655bd8484247940`；Windows 收到的安装包与本地摘要一致。
- Windows 原客户端备份：`C:\Users\ZHY.04\RemoteScreenBackups\before-three-clients-20261011-1808`。
- 已覆盖原安装目录 `E:\新建文件夹 (2)\RemoteScreen`，安装器退出码 0，旧音频修复保持。实际新程序 SHA-256：`94fb79e8a794c4853f096e20f97bd97f9c99da40b64fadd68a894a6afedcfa85`，确认新图片剪贴板命令存在。
- 新 Windows 程序已在用户交互会话（Session 1）启动，进程路径与安装目录一致；临时计划任务已移除。
- 最终 Android 包已于 2026-10-11 18:10:23 覆盖，设备实际文件哈希与最终包一致，进程启动，首次安装时间仍为 2026-10-08。
- 三端构建、安装文件、启动及服务端部署检查完成；未代替用户发送线上测试消息、发起通话或执行跨应用粘贴。
