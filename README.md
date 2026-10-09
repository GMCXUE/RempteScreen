# RemoteScreen

把电脑上的内容（画面 + 系统声音）实时投送到手机、平板观看。

## 目标形态

连接模型对齐 ToDesk：**无账号体系，凭「设备 ID + 连接密码」配对**。

| 角色 | 平台 | 形态 |
| --- | --- | --- |
| 采集端 | macOS / Windows | 原生 App，采集屏幕与系统音频并推流；界面展示自己的设备 ID 与连接密码 |
| 接收端 | iOS / Android | 原生 App，输入设备 ID 与连接密码后拉流播放 |
| 控制面 | 服务器 | 自建设备目录服务：ID 分配、密码校验、令牌签发 |
| 媒体面 | 服务器 | 自托管 LiveKit（SFU + TURN 一体） |

当前阶段只做**单向画面投送**，不含远程控制。选型理由见 [docs/architecture.md](docs/architecture.md)，实施顺序见 [docs/roadmap.md](docs/roadmap.md)。

## 目录结构

```
server/                 设备目录与令牌签发服务（Node，零第三方依赖）
deploy/prod/            生产部署：LiveKit + 设备服务 + Caddy 三容器编排
deploy/livekit/         本地开发用的单容器配置
apps/desktop/           桌面端：一个应用、一个窗口，左栏投送、右栏观看
apps/flutter_client/    Flutter 全平台客户端（Android / iOS / 桌面 / Web）
tools/sc-audio-probe/   屏幕与系统音频采集能力探针（Swift，无依赖）
tools/server-check/     媒体服务鉴权与房间巡检（Node，零第三方依赖）
```

macOS / iOS / Android 原生客户端尚未开始，等 Xcode 与 Android SDK 就绪后再建目录 —— 现在留空目录只会造成困惑。

## 怎么用

```bash
cd apps/desktop
npm install && npm run vendor
npm run start:remote
```

一个窗口两栏：

1. **先登录**（右上角）：注册一个账号，设备会绑定到它
2. **左栏「本机」**：显示设备 ID 与连接密码，选好内容后点「开始投送」
3. **右栏「我的设备」**：列出你名下所有设备，点一下即可**免密码**连接自己的另一台设备
4. **右栏「连接其他设备」**：输入对方的设备 ID 与密码 —— 对方**不需要注册**

**手机 / 平板**打开 `http://91.208.104.182/viewer/` —— 同一份页面，检测到是浏览器加载时会自动只显示连接相关的部分。

细节见 [apps/desktop/README.md](apps/desktop/README.md)。

## 快速开始

**一、启动媒体服务**

```bash
cd deploy/livekit
cp .env.example .env      # 生产环境务必替换密钥
docker compose up -d
curl -i http://127.0.0.1:7880/     # 期望 HTTP 200
```

监听：`7880`（信令）、`7881`（TCP ICE）、`7882/udp`（UDP ICE）。

**二、启动设备目录服务**

```bash
cd server
node src/index.mjs        # 默认监听 127.0.0.1:8787
```

**三、自检**

```bash
node server/test/e2e.mjs        # 配对链路 27 项断言
node tools/server-check/check.mjs   # 媒体服务鉴权 5 项断言
```

## 环境依赖

| 依赖 | 用途 | 状态 |
| --- | --- | --- |
| Docker + Compose | 自托管媒体服务 | 已就绪 |
| Xcode | 构建 macOS / iOS 端 | **未安装，阻塞** |
| Android SDK + Android Studio | 构建 Android 端 | **未安装，阻塞** |
| Apple Developer 账号 | macOS / iOS 签名分发 | 需确认 |
| 带证书的公网域名 | 生产环境 wss 接入 | 需确认 |

## 已知约束

- macOS 系统音频必须走 ScreenCaptureKit，浏览器方案拿不到，这是采集端必须原生的根本原因。
- 生产环境 LiveKit 必须设置 `rtc.use_external_ip: true` 并放通 `7882/udp`，否则 ICE 候选不可达。
- 屏幕录制权限属于系统级授权，首次使用需引导用户前往「系统设置 → 隐私与安全性 → 屏幕录制」开启。
- ⚠️ **开发期摩擦**：用临时签名（`codesign --sign -`）时，每次重新构建都会改变签名值，系统会视为另一个 App，**已授予的屏幕录制权限随之失效，必须重新授权**。装好 Xcode 并登录 Apple ID 后会生成免费的 Apple Development 证书，改用它签名即可让授权跨构建保留。
- 系统处于静音状态（输出音量为 0 或 muted）时，采集到的音频是静音，验证音频前需先解除静音。
