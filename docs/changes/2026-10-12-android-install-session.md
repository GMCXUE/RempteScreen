# Android 安装会话修复

手机实际版本 0.2.4 / 2026101205，系统 Android 17 / API 37。只读设备检查显示 com.miui.packageinstaller UID10137 已持有更新 APK 的单文件读权限，安装 Intent 有读取标记和 ClipData，但 ContentProviderHelper 仍拒绝其打开 UID10434 的非导出 FileProvider；因此不是旧版本尚未更新，也不是 APK 签名/哈希损坏。此前仅补显式 URI 授权没有解决这台系统的兼容问题。

AppUpdates 原生安装改为 PackageInstaller.Session：完整安装会话绑定 RemoteScreen 包名、设置大小，并在 API31+明确要求用户确认。工作线程将校验过的 APK 写入系统 session，写入时再次校验大小及 SHA256，fsync 后 commit。拷贝/提交失败废弃会话，重试仅清理本应用以前的安装会话。系统安装器无需再访问本应用 FileProvider，不导出 Provider，不绕过用户确认，不使用静默安装。

结果回调用显式目标、按会话编号隔离的可变 PendingIntent（API35+要求回调可变），接收器 exported=false，验证回调 session ID 与本地记录、Intent data 匹配。STATUS_PENDING_USER_ACTION 展示系统提供的确认 Intent；应用已退后台时保留确认，回到前台再展示。取消和失败只读结果进入原有更新界面，允许重试；失败不改变应用版本。

Dart 更新控制器兼容旧基线：没有新增原生结果方法时忽略该读取；整包优先、强制升级门禁、手动下载 Shorebird 补丁保持原流程。本次是 Android 安装 API 的平台差异，Mac ZIP/Windows EXE 更新流程不涉及 FileProvider，不修改；桌面侧栏未随本次发布。

依据：[Android PackageInstaller.Session](https://developer.android.com/reference/android/content/pm/PackageInstaller.Session)、[用户确认要求](https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams#setRequireUserAction(int))。

验证：Android debug 原生编译和两项 APK 数据流测试（跨缓冲区复制、截断/扩展/修改拒绝）；Flutter 更新测试包含签名、强制门禁、热补丁、取消结果只消费一次及可重试。Shorebird 基础版本需要新完整 APK，无法热更新已安装的 Kotlin 安装模块。仍需在这台手机安装修复版后，观察下一次真实应用内整包更新。

用户随后明确要求通过无线调试安装：adb install -r 成功，设备实测版本 0.2.6 / 2026101207，主界面已启动到前台，保留应用数据。APK 仍使用原签名，Shorebird 同版本基础发行已激活；未发布本服务器新的整包记录、未更新 Mac/Windows/桌面侧栏。安装记录在 dist/android-session-0.2.6/installation.json。新会话路径仍待下一次应用内升级确认实际系统交互。
