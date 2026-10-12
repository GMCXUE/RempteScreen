# 聊天图片进入输入区

此前图片粘贴和选图都会打开“发送图片”弹窗，打断了继续输入文字的流程。本次同时修改主桌面客户端（Mac、Windows 共用）和 Flutter 移动端。

- 粘贴、相册/文件选图和安卓输入法插图均进入输入框内的缩略图区域，不自动弹出发送对话框，也不自动发送。
- 图片与文字使用同一个输入框边框和“发送”按钮。支持连续添加、横向浏览和逐张移除；移除图片保留文字，单次最多保留 9 张图片。
- 保留原有系统文字粘贴行为。查看已发送图片的完整预览不受影响。
- 图片沿用 `send-image`，文字沿用 `send`。一次点击先按草稿顺序发送图片，再发送文字，服务端仍分别保存为独立消息。
- 每项草稿使用固定的 `clientId`，确认成功后才移除。部分失败时保留剩余图片和文字，重试不会重新提交已确认的图片；发送过程阻止再次点击和修改当前草稿。
- 切换桌面会话/账号或离开移动端聊天后，不使用迟到的图片读取结果。

安卓继续通过长按菜单“粘贴图片”和输入法富内容接口插入图片；桌面支持 Cmd+V / Ctrl+V 和系统粘贴入口。格式、大小限制和错误文案沿用现有实现。

验证结果：桌面聊天 UI 回归通过；Flutter 聊天组件测试 10 项通过；本次 Flutter 源码与测试静态检查无问题。覆盖输入区位置、保留文字、移除图片、部分发送失败、固定编号重试、9 张限制、迟到回调，以及原有图片复制与撤回。

首次实现时仅修改源码。用户随后授权覆盖安装；服务端协议无需变更。

## 覆盖安装（2026-10-11）

- Mac ad hoc 测试签名构建及完整签名验证通过，已覆盖 `/Applications/RemoteScreen.app` 并启动，PID 84212。安装二进制与构建产物 SHA-256 一致：`ac32c579c79f1b224049705542b60e85e14b57872d4baaae3f1071c35683740b`。旧版备份 `/private/tmp/RemoteScreen-before-inline-images-20261011-1920.app`。
- 安卓 arm64 release 构建通过，新旧 APK 签名证书一致。通过原配对无线调试 `adb install -r --no-streaming` 覆盖成功并启动，PID 17516。设备实际 APK SHA-256 与新包一致：`1c1dd38d2855902899d16776769bbb330447fcfee7ca937d793cff63b722a8d8`；更新时间 19:22:25，首次安装时间仍为 2026-10-08。旧包备份 `/private/tmp/RemoteScreen-before-inline-images-20261011.apk`。
- 安卓覆盖启动后，MessagingService、RequestWatchService 均仍以前台服务运行。
- Windows 仅上传本次 5 个桌面 UI/测试文件至用户已授权的 `codex/windows-client` 分支，提交 `99d02f5290af537842336c386d10b7e49b4dedc8`，本地 main 暂存区保持不变。[Actions 38135189205](https://github.com/GMCXUE/RempteScreen/actions/runs/38135189205) 构建成功，产物 ID `11700544152`，产物关联提交已核对。
- Windows 产物 ZIP SHA-256 与 GitHub 摘要一致：`3abbcc10d3571b45846696ac5d8cfbba134413dd5722f04d56d29a230cc72216`；安装器 SHA-256：`fa5273e7550522bb4ffc419f68e6b13364a11a232dbae527a7f67f9d44ca9df4`。安装器位于 `/private/tmp/RemoteScreen-inline-release-38135189205/RemoteScreen_0.1.0_x64-setup.exe`。
- 用户开机并启动 SSH 后，Windows 连接恢复，主机身份与原固定 SSH 主机密钥核对通过。安装器传输后哈希再次核对一致，旧版已备份至 `C:\Users\ZHY.04\RemoteScreenBackups\before-inline-images-20261011-1920`。
- Windows 已覆盖原目录 `E:\新建文件夹 (2)\RemoteScreen`，安装器退出码 0。原程序 SHA-256：`0ca9b27cbee7680469df3351c1389af13ae4f8d8a5bff4e7f4a9e245f856561d`；新程序 SHA-256：`4360395aeb741948b8951603e566876583f7fbe3daa39a86e6d0017c72643709`。
- Windows 新版已在当前用户交互桌面会话启动（Session 1，PID 22344），实际程序路径与原安装目录一致。临时启动任务已删除。Mac、安卓、Windows 三端覆盖安装和启动核对均已完成。
