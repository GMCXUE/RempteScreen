# 客户端热更新

桌面采用签名的 HTML/CSS/JS 资源覆盖，安卓采用 Shorebird Flutter 引擎。两个平台独立发布，补丁只匹配平台、架构、通道及准确的基础 buildCode。Rust/Kotlin、权限、原生插件、安装器和新增 Flutter assets 仍需整包更新。旧版本没有加载器，必须先更新一次基础应用。

## 桌面

资源从现有 Tauri 本地源加载，保持原 IPC、媒体协议和子窗口；不修改已签名的应用包。校验 Ed25519 签名、单个文件 SHA-256、数量/体积限制及路径。用户确认后暂存，在重新启动时加载；当前通话、投屏、文件传输和来电状态阻止即时重启。首次启动没有收到主界面就绪确认时，下次启动退回上个可用资源，故障补丁不再重复提示。缓存修改也需重新验证签名和哈希。服务端撤回或替换已暂存的补丁时，在线检查会取消旧暂存选择。离线时仍可使用已验证缓存。

## 安卓

Shorebird SDK 2.0.7，Flutter 3.47.7，应用 ID 见 shorebird.yaml。auto_update: false：由应用内现有更新对话框控制用户选择。整包升级优先；没有整包升级时获取本服务签名的更新内容，再检查 Shorebird。下载补丁不会打断媒体连接，生效需真正的进程冷启动，单纯切到后台或 Activity 重建不会生效。开启自有 RSA 补丁签名：公钥 config/shorebird-public.pem；私钥只存本地忽略目录，不提交或上传。

## 发布与管理入口

GET /v1/hot-updates/check?platform=macos&arch=arm64&channel=stable&nativeBuild=2026101206

POST /v1/admin/hot-releases：platform、arch、channel、nativeBuild、revision、notes、resource。桌面 resource.files 是完整资源包（path/base64/sha256），安卓 resource.patchNumber 是 Shorebird 的补丁编号。GET /v1/admin/hot-releases 列出记录，DELETE /v1/admin/hot-releases/:id 撤回。使用现有服务器管理凭据和 Ed25519 密钥，管理入口不进入客户端界面。

桌面打包：node tools/package-desktop-ui.mjs macos arm64 REVISION NOTES_FILE OUTPUT；服务端容器回环地址内运行 tools/manage-hot-updates.mjs publish OUTPUT。安卓用 shorebird patch android --release-version 0.2.5+2026101206 --public-key-path ../../config/shorebird-public.pem --private-key-path ../../.local/shorebird-signing-private.pem（命令工作目录为 apps/flutter_client）；先 beta 验证，再将对应说明和编号发布并把补丁提升到 stable。撤回安卓必须同时在 Shorebird 撤回对应补丁，单独撤回本站说明不会删除厂商服务已暂存的 Dart 补丁。

热更新记录当前为可选补丁；强制升级继续使用原有整包更新 forceUpdate 门禁。本次保留 Android 原有四个底部标签，隐藏重复顶部栏只适用于桌面。

## 验证

隔离 PostgreSQL HTTP 测试：管理鉴权、签名、基础版本及平台隔离、资源路径/哈希、撤回与重启持久化。Rust 3 项测试：签名/过期/版本、路径/哈希及资源覆盖、启动失败回退。Flutter 8 项测试：原有强制整包门禁与新增补丁签名、用户决定下载、整包优先。桌面浏览器测试：选择/稍后、暂存不自动重启、媒体会话及来电阻止重启。

## 本次发布结果

Mac 0.2.3 / Android 0.2.5，buildCode 2026101206，stable、可选更新。Mac 发布记录 rel_e779a8f9a236e3b9f2，Android rel_00238dee61063deda0；公网签名、下载哈希已验证，Android 包名/版本/旧证书一致，APK 内 auto_update: false 与 RSA 公钥存在。Shorebird 0.2.5+2026101206 已激活。服务部署备份 /opt/remotescreen/backups/hot-updates-20261012，用户/好友/聊天/通话数量未下降。未覆盖任何设备，Windows 继续暂缓安装。

本次发布基础版本，没有另发内容相同的资源/Dart 补丁；后续修改可单独发布补丁。桌面资源描述示例在 dist/hot-updates-20261012/hot.macos-arm64.json，目前未发布。旧版本需先完成一次整包更新，已通过自动测试和包结构验证；尚未在真机执行一次真实补丁切换。发布校验记录见 dist/hot-updates-20261012/publication.json。
