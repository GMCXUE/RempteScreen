# 通话修复覆盖记录

## 最新覆盖：peer-background-20261012-012324

Mac 和安卓已覆盖安装。当前安卓 versionCode `4010`，安装包 SHA-256 `79183f0725ac046fd9cfd046889a4817c3be1dfa7a989cd9e9f6caeb772ce9b1`；Mac 二进制 SHA-256 `a051aaa474961e695e432b2825df844877560e3186d0e6b884e9312c8c0d95be`。两端启动、安装哈希和签名均已核对，账号及聊天数据保留。

本次补齐接收端的摄像头显示方向，使默认前置或桌面自拍摄像头在双方的大画面、小窗口和悬浮窗保持一致。屏幕共享不翻转，视频采集及发布轨不改动。语音通话也提供独立悬浮入口、点击返回、贴边收起及安卓授权引导。安卓改为先启动正确类型的前台服务再采集，接通期间保留媒体接收保护，原生线程为当前账号的媒体客户端续期。详见 [变更说明](2026-10-12-peer-video-background.md)。

Flutter 检查 16 项、7 个 Dart 文件静态检查、桌面完整及悬浮窗浏览器检查、安卓原生位置 2 项及账号归属 1 项、Rust 多屏位置 1 项通过；Mac 和安卓发布构建通过。覆盖后请用户重新发起视频通话、切后台约 30 秒，检查对方画面方向、连续通话、小窗返回及语音悬浮入口；用户反馈“可以了”。

回退包为 `/private/tmp/RemoteScreen-before-peer-background-20261012-012324.app` 与 `/private/tmp/RemoteScreen-before-peer-background-20261012-012324.apk`；安卓新包 `/private/tmp/RemoteScreen-peer-background-20261012-012324.apk`。

Windows 提交 `8bba1528c4e09bc9d9d013293632ffbd8ad87d50` 已上传独立 `codex/windows-client` 分支，[本次构建](https://github.com/GMCXUE/RempteScreen/actions/runs/38159461167) 已成功；main 未改变。按用户安排，Windows 稍后安装，本次没有执行 Windows 安装。

Windows 安装包已下载并核对 GitHub 制品摘要，位置 `/private/tmp/RemoteScreen-video-call-release-38159461167/RemoteScreen_0.1.0_x64-setup.exe`，SHA-256 `95d0a20f149960e59fe1a57c66329cbf55b7a811164765277e27d579f84b7474`。

## 前一次覆盖：self-preview-20261012-010132

发布标识：self-preview-20261012-010132。本次将完整视频通话、摄像头 NV12 兼容修复、来电卡片、大小窗切换、悬浮窗授权和贴边收起，以及自拍预览动作同向调整一起覆盖到 Mac 和安卓。服务端协议未改变。

## 已安装

- Mac：`/Applications/RemoteScreen.app`，测试用 ad hoc 签名。已核对签名、摄像头/麦克风用途声明、安装后的二进制哈希和启动进程。二进制 SHA-256：`cf9d2d8b981e1c3159c365c5dd52a718b5e70e15849a5c59bda05b342859c602`。
- 安卓：`com.remotescreen.remotescreen`，versionCode `4009`。覆盖安装成功，已核对安装包哈希和版本；`MessagingService` 与 `RequestWatchService` 在运行。APK SHA-256：`b289515cc725d409690f1ad234b7fa5e6be398a57dea466945b70a45395688db`。
- 账号和聊天数据保留。回退包：Mac `/private/tmp/RemoteScreen-before-self-preview-20261012-010132.app`；安卓 `/private/tmp/RemoteScreen-before-self-preview-20261012-010132.apk`。安卓修复包 `/private/tmp/RemoteScreen-self-preview-20261012-010132.apk`。

## Windows

桌面源码已同步至独立 `codex/windows-client` 分支，提交 `3fbf340e5afff0851b974f60ca96e97f90befd05`；main 未改变。[最终构建](https://github.com/GMCXUE/RempteScreen/actions/runs/38157950517) 正在运行，尚未确认完成。用户已明确安排 Windows 稍后安装，本次未执行 Windows 远程安装。

## 验证与预览规则

Flutter 通话及交互检查 15 项通过，Dart 静态检查通过；桌面浏览器预览及通话交互检查通过。此前 Mac 实际 NV12 路径的三项合成帧检查、桌面多显示器位置检查一项、安卓原生贴边位置检查两项通过。

移动端自己的前置预览跟动作同方向，后置与远端视频不翻转。桌面默认摄像头作为自拍摄像头，在本地预览显示层水平翻转。双方画面交换后沿用同一规则，标题、头像、字幕不翻转。采集帧、发布轨和对方收到的画面没有修改。悬浮小窗展示远端画面，沿用正常方向。

安卓缺少悬浮窗权限时，收起和返回键会引导去系统设置授权；取消或未授权时保留完整通话页。授权后再次收起即可显示系统小窗。小窗点击返回通话，拖到左右边缘后收成标识，点击标识展开，再点击小窗返回。

验证包括真实 SDK 渲染组件与模拟输入，安装验证不等同于真实设备动作方向的人工确认。覆盖后需重新发起通话观察自拍预览。
