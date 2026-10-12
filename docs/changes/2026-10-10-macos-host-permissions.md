# macOS 主应用权限及签名修复

安装包的签名设置包含 Hardened Runtime，但缺少 camera 和 audio-input entitlement。补充 Entitlements.plist 并交给 Tauri 打包签名；检查主程序和摄像头辅助进程签名中的实际权限声明。

摄像头和麦克风授权改由链接到主应用的 AVFoundation 桥接请求。在非主线程等待，在主线程调用授权 API。摄像头辅助进程只采集帧，不再用辅助进程自身的 authorizationStatus 拦截主应用已获得的授权；麦克风直接使用主应用授权及 cpal 采集。

本次是 macOS 专属打包和系统授权修复。安卓已有应用内权限请求和 microphone/camera 前台服务，无对应辅助进程或 Hardened Runtime 声明。

不会重置、写入 TCC 数据库或修改用户系统授权。摄像头首次授权仍需要用户确认。

构建通过，已核验主应用和摄像头辅助进程的实际签名均包含 camera/audio-input=true，并覆盖安装、启动 Mac 客户端。实际弹窗和采集效果需要用户确认。
