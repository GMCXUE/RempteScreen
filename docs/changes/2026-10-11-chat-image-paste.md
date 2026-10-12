# 聊天图片粘贴

此前图片复制已写入系统剪贴板，但聊天输入框仅支持文字粘贴，图片发送只能通过文件选择器。

- Mac / Windows：聊天输入框支持 Cmd+V / Ctrl+V。优先处理 WebView 提供的图片文件；系统原生图片通过剪贴板接口读取。对只包含原生像素、未触发网页 paste 事件的情况提供快捷键兜底，避免同一次粘贴重复打开预览。
- 安卓：输入框长按菜单增加“粘贴图片”；图片按钮提供“从相册选择”和“粘贴图片”。支持输入法通过 Android 富内容接口插入 JPEG、PNG、WebP 图片，包括仅返回 content URI 的输入法。
- 双端共用原有图片预览和发送流程，粘贴后需确认发送；取消、发送失败和重试均保留文字草稿。重试沿用同一个 clientId，账号或会话变化后不使用过期读取结果。
- 普通文字粘贴保留原有系统行为。仅在用户主动粘贴时读取剪贴板，不轮询剪贴板；空剪贴板、读取失败和图片过大不会发送消息。

平台差异：安卓的 Flutter 文本剪贴板接口不提供图片字节，因此提供明确的“粘贴图片”菜单和输入法图片插入接口；桌面支持键盘快捷键及输入框的系统粘贴操作。桌面快捷键保留空或文字剪贴板的默认行为；安卓专用“粘贴图片”入口在没有图片时显示轻提示。安卓只读取获得授权的本地 content URI，不读取外部 URL。

图片仍走现有 send-image 协议和服务端压缩、鉴权与静态格式检查，无需修改服务端。编码图片上限为 8 MB；原生剪贴板读取与服务端限制 2400 万像素。桌面原生 RGBA 图片在本地合成白色底并编码为 JPEG，避免透明区域变黑。

验证覆盖图片粘贴预览、取消、发送重试、草稿保留、文字粘贴、空剪贴板、读取失败、大小限制、输入法字节和 URI 插入、桌面快捷键兜底，以及原有图片复制与撤回流程。

验证结果：桌面聊天 UI 回归通过，Flutter 聊天测试 8 项通过且静态检查无问题，Rust cargo check 通过，安卓 arm64 Release APK 打包成功。

## 覆盖安装（2026-10-11）

- Mac 使用 ad hoc 测试签名完成构建及完整签名验证，已覆盖 `/Applications/RemoteScreen.app` 并启动，进程路径与安装二进制核对通过。新程序 SHA-256：`a8b6083b937a05d263cb81a51b344f670221a3cc6687c5f4d872aceec3fb511d`；旧版备份 `/private/tmp/RemoteScreen-before-paste-20261011-1835.app`。
- 安卓通过原配对无线调试 `adb install -r --no-streaming` 覆盖成功，新旧证书一致，设备实际 APK SHA-256：`3fcc7ec54518e270a356d47b952e8f48a6f18872b56085f21b2646712a6f6ea9`，更新时间 18:37:12，首次安装时间仍为 2026-10-08。应用已启动，MessagingService、RequestWatchService 均以前台服务运行。旧包备份 `/private/tmp/RemoteScreen-before-paste-20261011-1835.apk`。
- Windows 本次桌面源码上传 `codex/windows-client`，提交 `7f9d0552df1810a504bc6c688808dd96c55adc4b`，只包含图片粘贴修改。[Actions 38132499181](https://github.com/GMCXUE/RempteScreen/actions/runs/38132499181) 已成功，产物 ID `11699623929`。旧版备份 `C:\Users\ZHY.04\RemoteScreenBackups\before-paste-20261011-1835`。
- Windows 产物 ZIP SHA-256 与 GitHub 返回摘要一致：`f86ea834a06287fde8332adee051d3e03597aa8ebc20d1e52e0e495f332e41ae`；安装器 SHA-256：`087225840e49973683ffb1835d7f3d352c9377a2613cc1b3e856d7d6fad2e0cb`，传输后再次核对通过。
- Windows 已覆盖原目录 `E:\新建文件夹 (2)\RemoteScreen`，安装器退出码 0，安装后程序 SHA-256：`0ca9b27cbee7680469df3351c1389af13ae4f8d8a5bff4e7f4a9e245f856561d`，与旧版不同。
- Windows 新程序已在用户交互桌面会话（Session 1，PID 28524）启动，实际进程路径与原安装目录一致；临时启动任务已删除。三端覆盖安装、安装文件和启动核对已完成。
- 本次没有服务端修改，线上服务和账号、好友、聊天数据沿用已部署版本。本地 main 和暂存区未改动。
