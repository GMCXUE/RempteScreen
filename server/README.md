# 设备目录与令牌签发服务

账号体系 + 设备目录 + 令牌签发，一个进程搞定。

好友私聊已支持图片发送、鉴权读取和两分钟内撤回，数据库新增图片表与消息修改游标；服务端与主桌面、移动客户端同步升级。接口和限制见 [聊天改动说明](../docs/changes/2026-10-11-chat-images-copy-recall.md)。本地隔离数据库检查运行 `npm run test:chat-media`，使用 `TEST_DATABASE_URL` 指定测试数据库的 PostgreSQL 连接。

服务使用 PostgreSQL、sharp 和 FFmpeg，启动前运行 `npm install` 并配置 `DATABASE_URL`。聊天支持图片/视频混合多选；视频接口、限制与测试见 [图片与视频说明](../docs/changes/2026-10-12-chat-gallery-video.md)。容器已安装 FFmpeg，非容器运行需要安装 FFmpeg/FFprobe。

## 启动

```bash
cd server
node src/index.mjs
```

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` / `HOST` | `8787` / `127.0.0.1` | 监听地址，线上改 `0.0.0.0` |
| `DATABASE_URL` | `postgres://remotescreen:remotescreen@127.0.0.1:5432/remotescreen` | PostgreSQL 连接，容器通过环境变量注入 |
| `LIVEKIT_URL` | `ws://127.0.0.1:7880` | 下发给客户端，线上必须是 `wss://` |
| `LIVEKIT_API_KEY` / `_SECRET` | `devkey` / `devsecret_…` | 必须与 `livekit.yaml` 一致 |
| `SESSION_TTL_SEC` | `2592000`（30 天） | 账号会话有效期 |
| `HEARTBEAT_INTERVAL_SEC` / `_TIMEOUT_SEC` | `15` / `45` | 设备心跳间隔与离线判定 |
| `RATE_LIMIT_MAX_FAILURES` / `_COOLDOWN_SEC` | `5` / `60` | 设备密码尝试的限流 |
| `LOGIN_MAX_FAILURES` / `_COOLDOWN_SEC` | `10` / `300` | 登录尝试的限流 |

## 两种鉴权，不要混淆

| | 谁用 | 怎么带 |
| --- | --- | --- |
| **用户会话** | 人：管理账号与设备 | `Authorization: Bearer <token>` |
| **设备凭据** | 设备自己：心跳、刷新密码、解绑 | 请求体里的 `sessionToken` |

两者不能互换。用账号令牌调设备心跳会被拒，反之亦然。

## 数据模型

```
users     id / email(唯一，小写) / name / password_salt / password_hash
sessions  token_hash / user_id / expires_at          ← 只存令牌哈希
devices   device_id(9 位) / user_id / name / platform
          password_salt / password_hash               ← 连接密码，scrypt
          session_token_hash                          ← 设备自身凭据
          registered_at / last_heartbeat_at
```

设备**不会因为离线被删除**，只是状态变为离线 —— 有了账号体系后，「我的设备」需要长期存在。

## 接口

### 账号

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| POST | `/v1/auth/register` | — | `{ email, password, name }` → `{ user, token, expiresAt }` |
| POST | `/v1/auth/login` | — | `{ email, password }` → 同上 |
| POST | `/v1/auth/logout` | 会话 | 立即吊销当前令牌 |
| GET | `/v1/me` | 会话 | 当前用户 |

约束：邮箱需合法、密码至少 8 位、昵称不超过 32 字符。邮箱统一转小写，`Alice@x.com` 与 `alice@x.com` 是同一个账号。

### 设备

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| GET | `/v1/devices` | 会话 | **我名下的**设备列表，含在线状态 |
| POST | `/v1/devices/register` | 会话 | 注册/重新注册，绑定到当前用户 |
| PATCH | `/v1/devices/:id` | 会话 | 重命名自己名下的设备 |
| POST | `/v1/devices/:id/heartbeat` | 设备凭据 | 保活 |
| POST | `/v1/devices/:id/password` | 设备凭据 | 刷新连接密码 |
| DELETE | `/v1/devices/:id` | 设备凭据 | 解绑 |
| GET | `/v1/devices/:id/status` | — | 只返回在线与否，不泄漏设备名 |

`register` 的响应含 `deviceId`、`password`、`sessionToken`、`token`（推流令牌）等。
客户端**必须**把 `deviceId` 与 `sessionToken` 覆盖写入本地 —— 设备凭据每次注册都会轮换。

### 连接

`POST /v1/connect`，两条路径：

| 场景 | 请求 | 效果 |
| --- | --- | --- |
| 连自己的设备 | 带会话令牌，`{ deviceId }` | 免密码，响应 `via: "owner"` |
| 连别人的设备 | `{ deviceId, password }` | ToDesk 式的对外分享，响应 `via: "password"` |

响应含 `token` 与 `livekitUrl`。观看令牌仅允许发布摄像头、麦克风通话轨，并允许通过可靠数据通道发送文件；屏幕共享发布权限仍关闭。

### 健康检查

`GET /v1/health` → `{ ok, service, version, stats: { users, devices, online } }`

## 错误码

| HTTP | `error.code` | 含义 |
| --- | --- | --- |
| 400 | `invalid_email` / `weak_password` / `invalid_name` | 注册参数不合法 |
| 400 | `invalid_device_id` / `invalid_request` | 参数不合法 |
| 401 | `invalid_credentials` | 邮箱或密码错误 |
| 401 | `unauthorized` | 会话或设备凭据无效/过期 |
| 404 | `device_offline` | 设备不在线 |
| 404 | `device_unknown` | 设备不存在或已解绑 |
| 404 | `not_found` | 资源不存在或不属于你 |
| 409 | `email_taken` | 邮箱已注册 |
| 429 | `rate_limited` | 尝试过于频繁，带 `retryAfterSec` |

## 安全设计

**校验顺序是「限流 → 在线 → 密码」**。若先算密码再限流，攻击者能用无效设备 ID 反复触发 scrypt 把 CPU 打满。

**用户不存在时也跑一次 scrypt**（用固定盐），避免通过响应耗时探测某个邮箱是否已注册。

**密码与设备连接密码都不存明文**，用 scrypt 派生 + 常量时间比较。

**会话只存令牌哈希**，数据库泄露也无法直接冒用登录态。

**跨账号越权全部封死**：无法用别人的设备 ID 抢占设备（会被分到新 ID）、无法读取或重命名别人的设备、无法用别人的设备凭据刷新密码。这些都有对应的端到端断言。

观看端令牌只允许发布 `CAMERA` 与 `MICROPHONE` 通话轨，不能发布屏幕共享轨。`canPublishData`
仅用于文件传输；客户端只处理 `rs-file-ctl` 与 `rs-file-bin` 两个文件协议主题，其他数据消息不会触发本机操作。

## 已知取舍

- **限流状态在内存里**，服务重启后清零。对暴力破解而言只是要求攻击者放慢一点，真正的防线是 scrypt 的耗时。要更严可以把它挪进数据库。
- **`node:sqlite` 被 Node 标记为实验特性**。用到的 API 非常基础且稳定，镜像固定为 `node:22-alpine`，Dockerfile 里用 `--disable-warning=ExperimentalWarning` 关掉噪音。
- **没有邮件验证与找回密码**。当前阶段不做，需要时再加。

## 测试

```bash
node test/e2e.mjs
```

会真实拉起服务进程 + 独立的一次性数据库，覆盖账号、会话、设备绑定、连接、越权路径与登出，共 33 项断言。

### 独立文件会话协议

注册设备响应增加 `fileToken`：房间为 `files-{deviceId}`、身份为 `file-host-{deviceId}`，仅允许数据收发，禁止媒体发布与订阅。
`POST /v1/connect` 与 `POST /v1/connect-requests` 接受 `purpose: "screen" | "files"`（默认 screen）。审批列表保留 purpose；files 请求签发独立数据房间令牌，也不会触发 viewer-connected 自动投屏事件。

客户端文件协议为 `meta → ready → chunks → end → saved`。服务端不处理文件内容、保存回执或本地任务记录。更新顺序为服务端 → 双端客户端 → 重新注册设备；详情见 [本次修整说明](../docs/changes/2026-10-10-session-reliability.md)。

## 好友与私聊（第一阶段）

单聊历史现支持全文关键词、消息类型、日期及分页查找，目标上下文定位、账号级置顶和个人清空边界；主桌面和移动端同步实现。协议、清空范围及验证见 [聊天历史说明](../docs/changes/2026-10-12-chat-history.md)。运行 `npm run test:chat-history` 在独立临时 PostgreSQL 数据库验证，不修改已有账号或聊天数据。

新增账号级好友申请、好友备注与黑名单以及持久化文字私聊，双端使用 `/v1/social/*` 接口。接口契约、迁移和测试见 [变更说明](../docs/changes/2026-10-11-friends-and-private-chat.md)。语音视频通话迁移和聊天文件仍属后续阶段。测试命令 `npm run test:social` 使用独立临时 PostgreSQL 数据库，不清空已有数据。

好友通话第二阶段：新增 `friend_calls` 表和 POST `/v1/social/call-start`、`call-state`、`call-decision`、`call-end`，使用账号 Bearer 及每安装实例固定的 clientId。语音/视频房间与投屏房间隔离，同账号多设备接听由数据库事务仲裁；响铃 45 秒、客户端租约 35 秒，好友删除/拉黑后自动结束。`npm run test:calls` 使用隔离临时数据库验证信令与授权。详细协议与客户端平台差异见 `docs/changes/2026-10-11-friend-calls.md`。

## 应用版本管理

更新检查、签名安装包、强制更新规则及独立管理 API 见 [应用更新与版本管理](../docs/app-updates.md)。管理接口默认不启用，需要独立发布令牌和签名私钥；普通账号没有发布权限。

### 文件传输元数据历史

`POST /v1/file-transfers` 需要账号 Bearer、files 连接下发的签名 `grant`、`senderDeviceId`、幂等 `clientId`、`name`、`size`。只存元数据（50 MB = 52,428,800 bytes），不接收文件内容。
`GET /v1/file-transfers?before=<id>` 只返回当前账号参与的记录，每页最多 50 条，返回 `items` 和 `next`；按数值主键倒序。记录没有自动过期。
`PATCH /v1/file-transfers/:id` 由发送方确认 `status: completed|failed|cancelled`，终态不可改写。十分钟未确认的记录在列表中显示 `unconfirmed`，不等同于实际传输失败。账号与设备名称记录的是发送时快照。
