# 2026-10-12 应用内更新

新增 Mac / Windows / Android 的更新检查、更新说明、签名校验、下载与安装入口。版本记录保存在服务端 PostgreSQL，管理 API 和独立发布脚本可供未来管理后台复用，客户端没有发布管理界面。

当前客户端版本为 `0.2.0`，统一 buildCode `2026101201`。普通更新可稍后处理；强制更新没有关闭入口，已确认的要求会在本机保存。版本撤回或安装完成后解除提示。Android 分 ABI 构建不再隐式偏移版本编号，避免实际 APK 版本与发布记录不一致。

安装前结束当前通话、投屏和传输。Android 由系统确认安装，取消后不丢失设备待命能力。Mac 校验并替换 app，保留旧版备份；Windows 启动 NSIS 更新安装。

详细管理 API、密钥配置、发布步骤和平台限制见 [应用更新与版本管理](../app-updates.md)。

## 已完成验证

- 服务端隔离数据库 HTTP 检查：管理鉴权、上传校验、元数据验签、版本持久化、强制版本链、发布/撤回、分页、HEAD 与 Range。
- Flutter 14 项相关回归通过（其中更新模块 6 项），覆盖签名篡改、错误目标/下载地址、离线强制缓存、撤回、普通/强制交互及已有首页/通话行为。
- 新增 Flutter 模块静态检查无问题；现有主入口的 LiveKit experimental 警告保留。
- Rust 更新模块 2 项测试通过：签名/有效期与安装前文件校验。
- 桌面浏览器交互检查通过：Escape/遮罩不能关闭强制提示、取消系统安装后保留要求、普通稍后及手动检查。
- Mac app 测试签名构建通过；ZIP 解压回验通过，签名、可执行权限与内嵌版本正确。
- Android release APK 构建通过，实际版本 0.2.0 / 2026101201，含安装权限，签名与原有安装包一致。
- Windows Actions [38196655498](https://github.com/GMCXUE/RempteScreen/actions/runs/38196655498) 构建成功；源码提交 `fbb95d7a4965f22f5db0983cf36287ae7ddbf0c5`，NSIS 安装包已下载并校验。

## 交付状态

安装包及普通更新草稿记录位于 `dist/app-updates-20261012/`。首次构建时未部署；本次首次覆盖结果见下方部署记录。后续下载更新触发的系统安装确认与自动替换仍需随下一版实际更新验收。

Windows 源码通过独立 `codex/windows-client` 分支构建，main 不变；验签公钥可公开，私钥与更新管理令牌始终只存放在忽略的 `.local/` 目录中。


## 部署与首次覆盖（2026-10-12）

用户授权覆盖安装后，更新服务已部署至生产 `121.43.102.154`，备份为 `/opt/remotescreen/backups/app-updates-20261012-105818`。生产使用 `docker-compose.override.yml` 持久启用更新包卷、只读密钥目录和仅本机可访问的管理端口；后续默认 `docker compose up` 会继续保留该配置。部署前后 7 个用户、8 对好友、73 条聊天记录、34 条通话记录一致，新增更新相关表，已有业务表保留。

- Mac `/Applications/RemoteScreen.app` 已覆盖并启动，版本 0.2.0，buildCode 2026101201，本地测试签名。原 app 备份 `/private/tmp/RemoteScreen-before-app-updates-20261012-105818.app`。实际界面保留登录和聊天状态，设置入口显示 0.2.0，手动检查返回“已是最新版本”。
- Android `com.remotescreen.remotescreen` 无线覆盖返回 Success，实际版本 0.2.0 / 2026101201，安装后的 base.apk 摘要与新包一致，MessagingService 和 RequestWatchService 正常运行。覆盖使用 `pm install -r`，原 APK 已备份并核对签名。
- 用户明确表示 Windows 先不安装；已保留 NSIS 安装包，未覆盖 Windows。
- 三端安装包及更新说明已保存为 draft，forceUpdate=false。公网检查接口签名与客户端固定公钥一致，草稿不会返回给客户端，草稿下载地址不可公开访问，匿名管理请求为 403。

自动审批拒绝将 0.2.0 向所有用户公开发布，理由是本次授权为覆盖安装而未授权面向所有用户发布。已采用保存草稿的替代方案，没有公开发布任何更新，也没有启用强制更新。将来的全体用户分发需另行明确授权。
