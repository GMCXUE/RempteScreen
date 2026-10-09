# RemoteScreen

把一台设备的屏幕实时投送给另一台设备观看：**手机投给电脑看、电脑投给手机看、电脑投给电脑看**。

连接模型对齐 ToDesk：**无账号体系感知，凭「设备 ID + 连接密码」配对**（登录只是为了把设备绑定到你名下，方便免密码连自己的设备）。

当前阶段只做**单向画面投送**，不含远程控制。选型理由见 [docs/architecture.md](docs/architecture.md)，实施顺序见 [docs/roadmap.md](docs/roadmap.md)。

## 三端现状

| 端 | 目录 | 技术栈 | 投送 | 观看 | 状态 |
| --- | --- | --- | --- | --- | --- |
| macOS / Windows 桌面端 | `apps/desktop-rs/` | Tauri 2 + Rust | ✅ 原生采集 60fps、画质可选 | ✅ 独立观看窗口（全屏/沉浸/显示模式） | **主推** |
| 移动端 | `apps/flutter_client/` | Flutter + livekit_client | ✅ MediaProjection（Android） | ✅ | 可用 |
| 桌面端（早期） | `apps/desktop/` | Electron | ✅ 含系统音频采集 | ✅（网页观看） | 保留参考 |
| 原生 Android 原型 | `apps/android/` | Kotlin | — | — | 早期探索 |

**服务端**：`server/`（设备目录服务）+ `deploy/`（LiveKit + PostgreSQL + Caddy 编排）。

## 架构

```
发布端（投送）                          观看端
┌──────────────────┐              ┌──────────────────┐
│ 原生采集          │              │ 订阅 + 解码       │
│ ScreenCaptureKit │              │ I420 → RGB       │
│ MediaProjection  │              │ → JPEG 帧池       │
└────────┬─────────┘              └────────▲─────────┘
         │ H.264 单层发布                    │ 订阅
         ▼                                  │
   ┌──────────────────────────────────────────────┐
   │  自托管 LiveKit（SFU + TURN 一体）             │
   │  房间名 = device-<9 位设备 ID>                │
   │  caster 可发布 / viewer 只订阅（写进令牌）     │
   └──────────────────────────────────────────────┘
         ▲
         │ 注册设备、心跳、签发令牌、校验连接密码
   ┌──────────────────────┐
   │ 设备目录服务 + PostgreSQL │
   └──────────────────────┘
```

几个关键设计：

- **采集端必须原生**：macOS 的系统音频只有 ScreenCaptureKit 能拿到，浏览器方案做不到（这也是桌面临时用 Electron、最终转 Tauri + Rust 的原因）。
- **观看端用 JPEG 帧池**：Rust 订阅解码后编成 JPEG，界面通过自定义协议 `frame://` 拉取。原始帧 1080p 一帧约 8MB，走 IPC 必然压垮通道；JPEG 一帧约 100KB 且编码仅 3ms。
- **画质分档**：流畅（长边 720）/ 高清（1080）/ 原始，帧率 15/30/60 可选，编码上限与码率随档位联动，带宽吃紧时优先保帧率。

## 快速开始

### 1. 服务端

```bash
cd deploy/prod
cp .env.example .env          # 生产环境务必替换密钥
docker compose up -d
```

### 2. 设备目录服务（本地开发）

```bash
cd server
npm install
docker run -d --name rs-test-pg -e POSTGRES_PASSWORD=remotescreen \
  -e POSTGRES_DB=remotescreen_test -p 54329:5432 postgres:17-alpine
node src/index.mjs            # 默认监听 127.0.0.1:8787
npm test                      # 端到端 33 项断言
```

### 3. macOS 桌面端

```bash
cd apps/desktop-rs/app
npx @tauri-apps/cli build     # 产出 .app 与 DMG
```

首次开启投送需在「系统设置 → 隐私与安全性 → 屏幕录制」授权本应用。

### 4. 移动端

```bash
cd apps/flutter_client
flutter build apk --debug --target-platform android-arm64
```

## 环境依赖

| 依赖 | 用途 |
| --- | --- |
| Docker + Compose | 自托管 LiveKit、PostgreSQL |
| Rust（stable） | 桌面端（Tauri） |
| Node 20+ | 服务端、Tauri CLI |
| Flutter SDK | 移动端 |
| Android SDK | 构建 Android 包 |
| Xcode Command Line Tools | 编译 Rust / 签名 |

## 已知约束与坑

- **屏幕录制权限与签名绑定**：用 ad-hoc 签名时每次重新构建都会改变签名，系统视为新应用，**已授权限失效**。务必用固定证书签名（本项目用自签证书 `RemoteScreen Dev`），授权才能跨构建保留。
- 应用必须**至少发起过一次采集请求**，macOS 才会把它登记进「屏幕录制」列表；授权后需**重启应用**才生效。
- 生产环境 LiveKit 必须设 `rtc.use_external_ip: true` 并放通 `7882/udp`，否则 ICE 候选不可达；客户端连接需要 `wss`，因此需要域名 + 证书。
- Android 17 强制要求 `mediaProjection` 前台服务，`apps/flutter_client/third_party/flutter_webrtc` 是为此打的补丁版本（同时实现了采集参数约束，否则分辨率/帧率设置不生效）。
- 系统静音状态下采集到的音频是静音，验证音频前先解除静音。

## 安全说明

仓库内**不包含任何生产密钥**：LiveKit 的 key/secret、数据库密码都通过 `deploy/prod/.env` 在服务器本地注入（`.env` 已被 `.gitignore` 排除）。代码里的 `devsecret_*` 仅为本地开发占位值。
