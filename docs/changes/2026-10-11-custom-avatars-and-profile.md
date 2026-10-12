# 自定义头像和个人资料

在已有默认头像功能上同步扩展 Rust 桌面端和 Flutter/Android 移动端；不修改旧 Electron 客户端或 Android 原型。

账号菜单、消息页的“我的账号”和移动端“我的 → 个人资料”提供编辑入口。昵称、个人简介、性别、生日、地区可以编辑，账号 ID、邮箱只读。生日、性别、地区和简介可留空。好友管理菜单新增“好友资料”，展示头像、昵称、账号 ID 和已填写的资料，不展示邮箱。账号搜索与未确认的申请只展示昵称、账号 ID、头像，其他资料仅随已确认的好友关系下发。

头像支持从系统图片选择器选择图片，拖动位置、缩放裁剪后保存。仅发送裁剪后的 256×256 PNG，不上传原图。客户端限制选图 8 MB、裁剪解码 2400 万像素，移动端预览解码最长边限制为 1024 像素。桌面支持 JPG、PNG、WebP，移动端使用系统图库中可解码的图片。取消选图或裁剪不更改头像；保存失败保留选择和错误信息，可以重试。头像保存独立于资料保存，已保存头像不会因取消资料编辑被撤销。

默认头像仍使用稳定的八个 ID，重绘为柔和配色的动物头像，去掉身体和文字名称。选图界面只展示图片和选中勾标，保留不显示在界面上的无障碍标签。SVG 原稿在 `assets/default-avatars/`；同一份 PNG 同步到桌面 UI、Flutter assets 和 Android 通知 drawable。

## 服务和数据

- `POST /v1/social/avatar`：内置头像 `{avatarId}`；自定义头像 `{avatarId:"custom",image:"data:image/png;base64,..."}`。头像端点单独允许 512 KB JSON，其余接口保持原有请求体限制。
- 服务端接收最多 300 KB 图片数据，限定 PNG/JPEG/WebP、最多 104 万像素、单帧。sharp 重新解码、去除元数据并生成 256×256 PNG；图片 SHA-256 作为版本标识。
- `POST /v1/social/avatar-image`：`{peerId,revision}` 返回当前版本 PNG 数据 URL。需登录；过期版本返回 404。头像属于公开账号资料，登录用户可以查看，不需要对象存储或公开文件目录。
- `POST /v1/social/account-profile`：`{name,bio,gender,birthday,region}`，仅更新当前登录账号。昵称最多 32 字符且非空，简介最多 160、地区最多 32，性别为 `""/male/female`，生日需合法且不早于 1900 年、不能超过当前各时区的今天。
- PostgreSQL `users` 添加 `avatar_revision`、`avatar_image` BYTEA、`bio`、`gender`、`birthday`、`region`；旧账号使用空资料及现有默认头像。切回内置头像清除旧图片。
- 账号、好友、搜索、申请 DTO 返回头像版本；通话返回 `peerAvatarRevision`。客户端按账号及版本缓存图片，登录退出清理头像状态。头像下载失败使用默认图，不影响消息和来电接收。Mac 原生来电面板和 Android 系统消息、来电通知同步自定义头像。
- 昵称更新同时刷新桌面保存的账号名称及移动端个人资料显示；不自动修改设备名称。

## 验证

- PostgreSQL 好友/头像/资料集成检查 133 项通过，含图片重编码、格式拒绝、版本匹配、越权字段忽略、生日校验、资料和头像重启持久化、切回默认头像清理。
- 通话信令 57 项通过，含自定义头像版本下发和已有通话权限/租约检查。
- `node server/test/profile_http.mjs` 验证真实 HTTP 上传超过 16 KB 的头像、读取、资料保存及无效图片处理，通过；使用临时数据库和隔离服务。
- Flutter 原有 11 项测试及新增 2 项资料/裁剪检查通过，包含失败保留草稿、重试提交、可编辑字段限制、裁剪输出尺寸和退出动画图片生命周期。静态分析无问题。
- 桌面实际 HTML/CSS/JS 的隔离浏览器检查通过，含无名称选择、选图裁剪拖动/缩放、保存失败重试、聊天头像同步、资料编辑、好友资料和小窗口中保存按钮可见。
- Rust `cargo check --offline` 通过（保留已有采集/观看模块警告）。Android `:app:compileDebugKotlin` 通过；新增 image_picker 所需依赖已下载。

开发阶段检查未进行真实跨设备头像修改或来电联调。部署需要同时更新服务端 package.json/package-lock.json（sharp）及新增 account_profile.mjs，先部署服务迁移，再更新双端应用。

预览：[头像选择](../design/avatar-picker-preview.png)、[个人资料](../design/account-profile-preview.png)。

## 部署与覆盖安装（2026-10-11 13:00）

用户授权后已部署并覆盖两端。服务端代码、package.json/package-lock.json 和 Dockerfile 同步，sharp 在 Linux/Alpine 镜像中的图片处理确认可运行，再重建 device-service；PostgreSQL 和 LiveKit 保持运行。公网健康检查 HTTP 200，新增资料字段、资料校验、鉴权和头像图片路由检查通过，临时验证会话已撤销。现有数据仍为 7 个账号、6 对好友、27 条消息、15 条通话。

- 服务端代码、数据库和旧镜像备份：`/opt/remotescreen/backups/custom-profile-20261011-130005`；旧镜像标签 `remotescreen-device-service:before-custom-profile-20261011-130005`。
- Mac 旧应用备份：`/private/tmp/RemoteScreen-before-custom-profile-20261011-130005.app`。新应用使用 ad hoc 测试签名，已覆盖 `/Applications/RemoteScreen.app` 并启动；签名校验通过、安装二进制与构建产物哈希一致，账号消息同步没有报错。SHA-256：`ed6c555c9f710dcfa75f83618abbf3744bf175c75af9f4eac25aae59646eab9b`。
- 安卓无线覆盖安装返回 Success，手机实际 base.apk 与构建的 APK 哈希一致：`c7f29e166920aa3d6245f5ab21b49ae3033c30711c7c57da2619494896402a99`；新包包含 8 个新头像资源，应用已启动，原有登录和数据保留。

未替用户修改实际头像或个人资料，也未发起好友消息或真实来电。
