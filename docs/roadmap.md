# 实施路线

按「先打通最难的一环」排序，而不是按功能列表排序。系统音频采集与端到端链路是整个项目最大的不确定性，先验证它们。

## M0 · 地基（已完成）

- [x] 目录结构与架构文档
- [x] 自托管 LiveKit 部署配置，本机启动验证通过（v1.13.9，HTTP 200）
- [x] 设备目录与令牌签发服务，端到端测试 27 / 27 通过
- [x] 屏幕与系统音频采集能力探针（画面已验证；音频通道已建立，静音前提下未出电平）
- [x] 房间巡检工具（从媒体服务侧核查参与者与轨道，是验证推流的权威视角）

## M0.5 · Electron 采集端（已完成，已在 macOS 上验证）

不是原计划的第一顺位，但它是本机唯一能真正跑起来的客户端，所以提前做掉，
用来把「设备注册 → LiveKit 推流」整条链路先验证掉，避免后面写 Swift 时同时面对多个未知数。

- [x] 主进程：采集源枚举、屏幕捕获授权、凭据持久化、心跳
- [x] 渲染进程：界面、`getDisplayMedia` 采集、LiveKit 推流
- [x] 接入设备目录服务（注册 / 心跳 / 刷新密码 / 下线）
- [x] 发布 `screen` 轨道，**已由媒体服务侧确认**：`caster-<设备ID>` 在线且持有 `SCREEN_SHARE` 视频轨
- [x] 自检模式（`npm run selftest`，无人值守跑完整流程并返回退出码）
- [ ] 托盘常驻、断线重连、推流质量档位
- [ ] Windows 上实机验证系统音频（macOS 无从验证，属平台限制）

## M0.6 · 接收端（已完成，已上生产）

原文里接收端要等 M1 的 iOS 原生客户端，但 iOS 需要 Xcode 而当前不具备。
先把渲染层写成**不依赖 Electron 的通用网页**，同一份代码三种用法，解开了这个死结。

- [x] Electron 桌面客户端（设备 ID + 密码 → 订阅播放）
- [x] 渲染层可作为纯静态页面托管，已部署到 `/viewer/`，**手机零安装可用**
- [x] `--self-test` 自动化验证，用 `requestVideoFrameCallback` 统计**真实解码帧数**
- [x] 端到端验证通过：采集端 → 公网 → 远程 SFU → 接收端，3024×1964，8 秒解码 94 帧
- [ ] 远程控制（ToDesk 式操作能力，架构已预留）
- [ ] 画质自适应、剪贴板同步、文件传输
- [ ] iOS / Android 原生接收端（等 Xcode 与 Android SDK）

### 已合并为单一桌面应用

投送端与观看端原先分在两个目录，现合并为 `apps/desktop`，一个应用两种角色（默认投送，`--viewer` 切观看）。
投送界面右上角可直接打开观看窗口。合并后两个角色都做过端到端验证。

服务器上的网页观看端**保留**，作为手机 / 平板在原生客户端完成前的过渡通道；原生端做完后可以关掉。

### 客户端技术路线：Flutter 全平台（2026-10-08 拍板）

用户明确要求 APK 必须**真写出来**（不能是 WebView 引用网页），同时要 exe 与浏览器版。
对比了 Flutter / Compose Multiplatform / React Native / 各端原生 / Tauri 后选 Flutter：

| 能力 | Flutter 方案 |
| --- | --- |
| 屏幕投送 | `room.localParticipant.setScreenShareEnabled(true)` —— Android 上触发 MediaProjection |
| 观看 | `RemoteVideoTrack` + `RTCVideoRenderer` |
| 账号 / 设备绑定 | 直接调现有服务端接口 |
| 打包 | `flutter build apk` / `flutter build macos` / `flutter build web` |

**服务端完全不用动** —— 这是这次选型最重要的结论。

工程位置：`apps/flutter_client`，已含完整 Dart 实现（api / 登录 / 主页 / 观看）。
待完成：Android APK 构建验证、iOS 端（需要 Xcode）、屏幕采集在各平台的原生通道补齐。

## M1 · macOS 采集端 → iOS 接收端，端到端打通

这是技术风险最高的一段，也是第一个能「真的看到画面」的里程碑。
服务端在 M0 已经就绪，本阶段只做两个客户端。

**采集端**
- [ ] Xcode 工程（macOS App，SwiftUI）
- [ ] `SCStream` 采集整屏画面 + `capturesAudio = true` 采集系统音频
- [ ] 接入 LiveKit Swift SDK，以 `caster` 身份发布两路轨道
- [ ] 首次运行引导用户开启「屏幕录制」权限
- [ ] 主界面展示设备 ID 与连接密码，支持一键刷新密码
- [ ] 本地持久化设备 ID 与 sessionToken（凭据每次注册都会轮换，必须覆盖写入）
- [ ] 定时心跳，断线自动重连与重新注册
- [ ] 托盘常驻与推流状态指示

**接收端**
- [ ] Xcode 工程（iOS App，SwiftUI）
- [ ] 输入「设备 ID + 连接密码」发起连接，以 `viewer` 身份订阅
- [ ] 错误提示区分：设备离线 / 密码错误（带剩余次数）/ 尝试过于频繁（带倒计时）
- [ ] 播放画面 + 声音，支持全屏与横竖屏
- [ ] 后台与锁屏的音频会话配置

**验收**：Mac 上放一段有声音的视频，iPhone 输入设备 ID 与密码后能同时看到画面、听到声音，延迟可接受。

## M2 · Android 接收端

LiveKit Android SDK 使用方式与 Swift 版接近，M1 的房间模型与令牌服务可直接复用，这一阶段主要工作量在播放器 UI。

- [ ] 房间码输入与进房
- [ ] 画面播放与全屏切换
- [ ] 音频焦点与后台播放

## M3 · Windows 采集端

- [ ] Electron 壳 + `livekit-client` 推流
- [ ] `getDisplayMedia({ audio: true })` 采集系统声音
- [ ] 多显示器选择与推流质量档位

## M4 · 体验与健壮性

- [ ] 扫码进房（采集端显示二维码）
- [ ] 断线自动重连与会话恢复
- [ ] 码率自适应，弱网下降分辨率
- [ ] 一键停止推流与参会者管理
- [ ] 长时间推流的资源占用优化

## 环境前置条件

M1 开始前需要：

1. 安装 Xcode（App Store 或 developer.apple.com，约 7 GB 以上）
2. 一个 Apple Developer 账号，用于真机调试与后续签名分发
3. 一台公网服务器 + 已备案域名 + TLS 证书，用于生产环境 `wss` 接入

本机当前状态：Xcode 未安装、Android SDK 未安装，这两项会阻塞 M1 与 M2 的构建。
