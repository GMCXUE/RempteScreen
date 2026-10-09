# 设备目录与令牌签发服务

账号体系 + 设备目录 + 令牌签发，一个进程搞定。

**零第三方依赖** —— 连持久化都用 Node 内置的 `node:sqlite`。部署就是把 `server/` 拷到服务器，
`node src/index.mjs` 跑起来，不需要 `npm install`。

## 启动

```bash
cd server
node src/index.mjs
```

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` / `HOST` | `8787` / `127.0.0.1` | 监听地址，线上改 `0.0.0.0` |
| `DATABASE_FILE` | `./data/remotescreen.db` | SQLite 文件位置，容器里挂到卷上 |
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

响应含 `token`（观看令牌，`canPublish=false`、`canPublishData=false`）与 `livekitUrl`。

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

**接收端令牌的 `canPublish` 与 `canPublishData` 均为 false**，单向投送由架构保证而非界面限制。

## 已知取舍

- **限流状态在内存里**，服务重启后清零。对暴力破解而言只是要求攻击者放慢一点，真正的防线是 scrypt 的耗时。要更严可以把它挪进数据库。
- **`node:sqlite` 被 Node 标记为实验特性**。用到的 API 非常基础且稳定，镜像固定为 `node:22-alpine`，Dockerfile 里用 `--disable-warning=ExperimentalWarning` 关掉噪音。
- **没有邮件验证与找回密码**。当前阶段不做，需要时再加。

## 测试

```bash
node test/e2e.mjs
```

会真实拉起服务进程 + 独立的一次性数据库，覆盖账号、会话、设备绑定、连接、越权路径与登出，共 33 项断言。
