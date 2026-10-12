# macOS 辅助进程的 Dock 身份修复

用户看到两个 RemoteScreen Dock 图标，其中一个持续跳动，窗口无法打开。进程检查只有一个主客户端，但音频辅助进程的 NSRunningApplication.activationPolicy 为 0（regular，前台应用），与主客户端相同；另有 5 个父进程为 launchd 的旧摄像头辅助进程残留。前一次窗口恢复修改未解决这个独立问题。

此前辅助进程嵌入的 Info.plist 只有摄像头、麦克风权限说明，没有独立后台身份。现在按辅助进程生成独立 BundleIdentifier、Name、Executable，并设置 LSUIElement；两个 Swift 采集器显式使用 prohibited 激活策略，不创建 Dock 图标或抢前台焦点。增加父进程监测，父进程退出后辅助进程自行退出，避免强制结束主客户端后持续采集。

已编译并签名验证。部署时清理旧 RemoteScreen 辅助进程，刷新当前安装路径的 Launch Services 注册。该修复限 macOS 应用和辅助进程启动机制；安卓原生采集在现有应用及服务中运行，没有 macOS Dock 身份问题。
