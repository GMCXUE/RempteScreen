# 部署到 VPS

生产环境跑三个容器：

| 容器 | 角色 | 对公网暴露 |
| --- | --- | --- |
| `caddy` | TLS 终止、路由 | `80`、`443` |
| `livekit` | SFU 转发 + ICE | `7881`(TCP)、`7882`(UDP) |
| `device-service` | 设备目录与令牌签发 | 不直接暴露，经 Caddy 的 `/v1/*` 进入 |

LiveKit 的 `7880` 只绑定在 `127.0.0.1`，diagnostics 走 SSH 隧道，管理接口 `/twirp/*` 不对公网开放。

---

## 一、部署前需要提供的信息

### 1. SSH 连接方式（三选一）

| 方式 | 需要提供 | 安全性 |
| --- | --- | --- |
| **已有 ssh config 别名** | 只要别名，例如 `my-vps` | ✅ 最推荐 |
| **密钥文件** | `user@host`、端口、私钥**文件路径** | ✅ 可以 |
| **仅密码登录** | — | ⚠️ 请先自行把公钥装上 |

> ⚠️ **不要把密码或私钥的内容贴到对话里。** 私钥的*路径*没问题，内容不行。
> 如果目前只有密码，在服务器上执行 `ssh-copy-id` 装好公钥即可，之后我就能用密钥登录。

需要确认：用户名是 `root` 还是普通用户？后者需要能 `sudo`。

### 2. 服务器基本情况

把 `deploy/preflight.sh` 传到服务器执行，把输出贴回来：

```bash
bash preflight.sh
```

它会报告系统版本、架构、CPU/内存/磁盘、Docker 是否就绪、公网 IP、关键端口占用情况与主机防火墙规则。只读，不改任何东西。

### 3. 域名与证书

- **有没有可用域名？** 是否已解析到这台服务器的公网 IP？
- 是否愿意配 HTTPS？

我的建议是**配**。原生 App 技术上可以走明文 `ws://`，但**连接密码和访问令牌会明文过公网**，这在生产环境不可接受。Caddy 会自动申请并续期 Let's Encrypt 证书，只要域名解析正确、80 和 443 可达，零配置。

如果暂时没有域名，也可以先用 IP 跑通，但需要接受明文传输，或者手动搞自签证书（客户端还得信任它，更麻烦）。

### 4. 服务器在境内还是境外

这决定了合规路径，也影响方案：

- **境内 + 域名 + 443** → 需要 **ICP 备案**，否则 80/443 会被拦
- **境外 / 香港** → 免备案，但到国内延迟较高，且 **UDP 可能被限速**

对 WebRTC 来说 UDP 质量很关键。如果只有境外节点，我们可能需要额外启用 TURN over TLS（走 443）来兜底。

### 5. 安全组 / 防火墙

云控制台的安全组需要放通：

| 端口 | 协议 | 用途 |
| --- | --- | --- |
| 22 | TCP | SSH |
| 80 | TCP | 证书申请与跳转 |
| 443 | TCP | HTTPS / wss |
| 7881 | TCP | ICE over TCP（UDP 不通时的回退） |
| 7882 | **UDP** | ICE over UDP，**最关键的一个，不少云厂商默认封禁 UDP** |

---

## 二、部署步骤

信息齐了之后我会执行，你也可以自己跑：

```bash
# 1. 上传代码到服务器
git clone <仓库> /opt/remotescreen     # 或者 scp 推送

# 2. 填配置
cd /opt/remotescreen/deploy/prod
cp .env.example .env
openssl rand -hex 16   # 生成 LIVEKIT_API_KEY
openssl rand -hex 32   # 生成 LIVEKIT_API_SECRET
vi .env

# 3. 启动
docker compose up -d --build
docker compose ps
docker compose logs -f caddy      # 观察证书签发
```

## 三、验证

```bash
# 证书与路由
curl -I https://你的域名/v1/health
curl https://你的域名/v1/health
# 期望：{"ok":true,...}

# 媒体服务（走本机回环，不经公网）
curl -s http://127.0.0.1:7880/ | head -c 200

# 房间巡检
cd /opt/remotescreen/tools/server-check
LIVEKIT_HTTP=http://127.0.0.1:7880 node inspect.mjs
```

端到端验证：在采集端把 `REMOTESCREEN_SERVER` 指向 `https://你的域名`，手机上输入设备 ID 与密码，确认能看到画面。

## 四、日常运维

```bash
docker compose ps                 # 状态
docker compose logs -f livekit    # 媒体服务日志
docker compose logs -f caddy      # 证书与访问日志
docker compose restart livekit    # 重启单个服务
docker compose up -d --build      # 代码更新后重建
docker compose down               # 停止（证书数据在卷里，不会丢）
```

## 五、常见问题

**能连上但一直黑屏**
十有八九是 `rtc.use_external_ip` 没开，或者 `7882/udp` 被安全组挡了。LiveKit 日志里未必有明显报错，先查这两个。

**证书申请失败**
域名没解析到这台机器，或者 80 端口不通。Caddy 的日志会写清楚原因。Let's Encrypt 有频率限制，反复失败要等一段时间再试。

**`/twirp/*` 返回 404**
这是故意的，管理接口不对公网开放。诊断请走 SSH 隧道：
`ssh -L 7880:127.0.0.1:7880 user@host`，然后本地访问 `http://127.0.0.1:7880`。

**海外节点连接慢**
先看延迟，再看是否被限速。必要时启用 TURN over TLS。

---

## 六、安全设计

- 连接密码与访问令牌只经 TLS 传输，明文 `ws://` 仅用于本地开发
- 管理接口 `/twirp/*` 不暴露公网
- LiveKit 的密钥通过环境变量注入，不写进配置文件，也不进版本库
- 接收端令牌的 `canPublish` 与 `canPublishData` 均为 `false`，无法向房间注入内容
- 设备目录服务只监听容器网络，不直接映射到宿主机

---

## 七、没有域名时先用 IP 跑通

把 `DOMAIN` 设成**带 `http://` 前缀**的 IP，Caddy 就会关掉自动 HTTPS，只监听 80 端口：

```
DOMAIN=http://<公网 IP>
PUBLIC_LIVEKIT_URL=ws://<公网 IP>
```

> ⚠️ **这是明文传输。** 连接密码与访问令牌会以明文经过公网，链路上任何一跳都能看到。
> 只适合功能验证，**不要长期这么用，也不要用于任何真实内容**。

**拿到域名后切到 HTTPS**（约十分钟）：

1. 在域名商后台加一条 A 记录，指向服务器公网 IP
2. 确认解析已生效：`dig +short 你的域名`
3. 改 `.env`：
   ```
   DOMAIN=你的域名
   PUBLIC_LIVEKIT_URL=wss://你的域名
   ```
4. `docker compose up -d --force-recreate caddy` —— Caddy 会自动申请证书
5. 采集端把 `REMOTESCREEN_SERVER` 换成 `https://你的域名`

Caddy 的证书数据存在 `caddy_data` 卷里，重建容器不会丢，也不会重复申请触发 Let's Encrypt 的频率限制。

## 八、首次开机的一个坑

新装的 Ubuntu 会立刻跑 `unattended-upgrades` 做首次安全更新，**期间 dpkg 锁被占用**，
此时任何 `apt` 操作（包括 Docker 官方安装脚本）都会失败并报
`Could not get lock /var/lib/dpkg/lock-frontend`。

正确做法是等它跑完（1 核机器上首次更新含内核，可能十几分钟）。
**不要 kill 它** —— 升级中途被打断会让 dpkg 处于半配置状态，后续修复比等待麻烦得多。

判断是否还在跑：

```bash
ps -eo pid,etime,cmd | grep unattended | grep -v grep
tail -f /var/log/unattended-upgrades/unattended-upgrades.log
```
