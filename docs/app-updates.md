# 应用更新与版本管理

## 用户流程

桌面端（Mac、Windows）和 Android 每次启动、从后台返回时检查更新。同一次检查/下载不重复请求。检查在登录前进行，设置/我的 → 关于中另有“检查更新”。

发布策略：按用户2026-10-12的要求，后续默认仅发布完整安装包，不发布新的热更新补丁；保留桌面资源加载器、安卓Shorebird及相关管理接口，只有用户明确要求热更新时才启用补丁发布。各平台版本独立，整包更新仍由用户确认下载安装。

- 有新版本时展示版本号、完整更新说明及“下载更新”。普通更新允许“稍后”，下次进入再检查。
- `forceUpdate: true` 不展示取消入口，返回/Escape/点遮罩不能关闭更新提示。已验证的强制要求会保存在本机；断网重启不会跳过。
- 下载显示进度，失败可重试或重新检查。SHA-256 校验通过后才允许安装。
- 安装按钮明确标为“结束会话并安装更新”；此时结束通话、投屏与传输。
- Android 首次安装引导用户允许“安装未知应用”，随后由系统确认安装。系统安装被取消时，应用内要求仍保留。此功能面向当前直接分发的 APK；上架应用商店时需按商店更新规则另行适配。
- Windows 打开当前用户的 NSIS 安装程序并退出旧进程；用户取消系统安装后，下次启动旧版仍受强制要求约束。
- Mac 将验证后的 `.app.zip` 解压到安装目录旁，验证 app 标识、内嵌版本与 codesign，再退出替换并重新启动；旧 app 保留为 `.before-update` 备份。目录不可写时先报错，不退出应用。支持目前的本地测试签名。
- 操作系统允许用户退出应用、取消系统安装或清除应用数据；“强制”指旧版应用内不能跳过提示继续操作，不会强制绕过系统安装确认。
- iOS 当前没有分发/安装链路；未来需接 App Store/TestFlight，不能直接使用 APK 安装。

只有带此功能的新客户端安装一次后，后续才可应用内更新。旧客户端仍需首次覆盖安装。

## 数据与接口

`app_releases` 持久保存平台、架构、通道、版本名称/编号、更新说明、包摘要、强制标记、发布状态、时间和修订号；`update_packages` 保存包信息。安装包在持久卷中保存。撤回是软操作，不删除历史版本记录。

管理入口只有后端 API 和独立命令行工具，没有在桌面端/手机端放置发布管理入口，未来管理后台直接调用这些接口。

| 方法 / 地址 | 用途 |
| --- | --- |
| `GET /v1/updates/check?platform=android&arch=arm64&channel=stable&buildCode=2026101201` | 未登录可检查；返回 Ed25519 签名的更新信息或无更新 |
| `GET/HEAD /v1/updates/packages/:releaseId` | 下载已发布安装包，支持单段 Range |
| `PUT /v1/admin/update-packages/:sha256?platform=android&arch=arm64` | `application/octet-stream` 上传，最多 512 MB |
| `POST /v1/admin/releases` | 新增版本（默认 draft） |
| `GET /v1/admin/releases?limit=50` | 查询记录；响应 next 可带 before/beforeId 继续翻页 |
| `GET /v1/admin/releases/:id` | 读取记录 |
| `PATCH /v1/admin/releases/:id` | 修改 notes、forceUpdate、status（其余字段不可改） |
| `DELETE /v1/admin/releases/:id` | 撤回，保留记录 |

管理接口使用独立 `Authorization: Bearer <更新管理令牌>`，普通登录令牌没有发布权限。未配置管理密钥时返回 503，默认不对外启用管理能力。生产管理端应在自身后端持有此令牌，不放入浏览器静态包。

发布平台为 `android / macos / windows`；架构 `arm64 / x64 / armv7`。接口预留 `stable / beta` 通道，当前客户端固定使用 stable。客户端按自己的平台、架构、通道选择最高的已发布 buildCode。若任一比当前版本更新的已发布记录是强制更新，返回的最新版本也会要求强制更新；这样旧用户不会因之后发布普通版本而绕过要求。撤回相关强制版本后，在线检查会解除要求。

## 密钥与部署

`node tools/create-update-keys.mjs` 创建本机 `.local/update-signing-private.pem`、`.local/update-admin-token`；已存在则复用，拒绝无意旋转公钥。`.local/` 已排除 Git，不能上传到仓库、安装包、聊天或构建日志。请备份私钥、管理令牌和当前 Android 签名 keystore；丢失私钥会令已分发客户端无法验证后续版本。

`config/update-public-key.json` 是客户端固定的公开验签密钥，可以进入 Git；Flutter 的同名 asset 由同步工具复制。当前服务器使用 HTTP 时，签名元数据和安装包哈希用于防止内容被替换；发布管理必须使用 HTTPS 或 SSH 隧道。

部署配置是额外的 `deploy/prod/docker-compose.updates.yml`，不影响尚未配置更新的环境：

```sh
# UPDATE_SECRETS_DIR 指向服务器上含两个密钥文件的目录，权限仅允许服务读取。
export UPDATE_SECRETS_DIR=/opt/remotescreen/update-secrets
cd deploy/prod
docker compose -f docker-compose.yml -f docker-compose.updates.yml up -d --build device-service
```

本机管理端口仅绑定 `127.0.0.1:8787`。远程操作可通过 SSH 隧道，例如 `ssh -N -L 18787:127.0.0.1:8787 user@server`，然后令 `UPDATE_ADMIN_URL=http://127.0.0.1:18787`。

目录包含 `update-signing-private.pem` 与 `update-admin-token`。数据库和 `update_packages` Docker 卷必须一起备份；重建服务不得删除卷。更新服务只读取签名密钥，不生成/覆盖它。

## 发布操作

1. 修改 `config/client-version.json`：根字段控制桌面版本，可选 `android` 对象独立控制安卓的 versionName、buildCode、channel（没有该对象时跟随桌面）。递增对应平台的 buildCode（正整数，不超过 2147483647），更新三段 versionName；运行 `node tools/sync-client-version.mjs`。Android 分 ABI 构建不再隐式增加版本号，安装包实际编号必须和记录一致。更新 Cargo.lock 后再执行 Windows `--locked` 构建。
2. 构建三个安装包。Android 保持当前签名；Mac 继续本地测试签名；Windows 使用 NSIS `.exe`。
3. Mac 包用 `python3 tools/package-macos-update.py /path/RemoteScreen.app /path/RemoteScreen-0.2.0-arm64.zip` 创建（只有 app 的标准 ZIP，保留可执行权限）。
4. 管理工具连接 HTTPS 管理地址，或通过 SSH 隧道暴露的本机端口。工具拒绝向公网 HTTP 发送管理令牌。

```sh
export UPDATE_ADMIN_URL=http://127.0.0.1:8787
export UPDATE_ADMIN_TOKEN_FILE=/secure/path/update-admin-token
node tools/manage-updates.mjs upload /path/app-arm64-v8a-release.apk android arm64
# 将输出 sha256 写入下面的 release.json，再创建草稿：
node tools/manage-updates.mjs create /path/release.json
node tools/manage-updates.mjs list
# 准备 JSON {"status":"published"} 后发布：
node tools/manage-updates.mjs edit rel_记录编号 /path/publish.json
# 紧急停止分发：
node tools/manage-updates.mjs withdraw rel_记录编号
```

示例 release.json（先填入真实安装包摘要）：

```json
{
  "platform": "android",
  "arch": "arm64",
  "channel": "stable",
  "versionName": "0.2.1",
  "buildCode": 2026101202,
  "notes": "修复通话连接问题\n优化消息与界面体验",
  "sha256": "填写上传返回的64位摘要",
  "forceUpdate": false,
  "status": "draft"
}
```

首次部署不自动发布任何更新，更不会自动开启强制更新。应先用普通更新验证实际覆盖安装与数据保留，再按需要将版本标为强制。

## 验证

- `cd server && node test/updates.mjs`：仅用本机临时数据库，验证鉴权、签名、持久化、发布/撤回、强制链、文件哈希与 Range。
- `cd apps/flutter_client && flutter test test/app_updates_test.dart`：元数据防篡改、离线强制缓存、撤回、普通/强制弹窗。
- `cd apps/desktop-rs/app/src-tauri && cargo test updates::tests`（需在此目录运行以加载 macOS 链接配置）：验签、过期、离线验证、安装前重新验证哈希。
- `apps/desktop-rs/app/test/updates-ui.cjs`：模拟 API 的浏览器检查，覆盖 Escape/遮罩、普通推迟和安装取消。

这些检查不会发布真实更新或覆盖已安装客户端。首次实际安装仍需验证系统安装确认、签名延续、账号数据保留及 Mac 权限状态。


## 热更新

2026-10-12 新增桌面签名资源补丁与 Android Shorebird 手动补丁。原有平台独立的整包升级和强制升级机制继续保留。旧客户端需先安装包含加载器/引擎的基础版本。管理接口与发布命令详见 [热更新说明](changes/2026-10-12-hot-updates.md)。此管理入口不放入用户端界面。
