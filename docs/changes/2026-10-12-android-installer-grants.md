# Android 更新安装器文件授权修复

用户在小米安装器扫描 APK 时遇到 `Permission Denial: opening provider androidx.core.content.FileProvider ... com.miui.packageinstaller ... not exported`。应用下载及校验已完成，但安装器没有得到更新文件的读取权限。旧实现只有 ACTION_VIEW 上的读取标记，未附 ClipData，也未为厂商转发后的扫描进程显式授权。

修复在 Android 原生 AppUpdates.kt：

- 为 APK 的 content URI 附 ClipData，同时保留 FLAG_GRANT_READ_URI_PERMISSION。
- 解析当前设备可处理安装 Intent 的系统 Activity，明确选择系统安装器，避免将 APK 授予浏览器、邮件等其他处理器。
- 对实际系统安装器，以及已安装且具有系统标记的 MIUI/AOSP/Google 扫描包，授予该 APK 的单文件只读权限。已安装的厂商扫描包可以与首次解析出的 Activity 不同。
- Provider 继续 exported=false，更新目录范围和 grantUriPermissions=true 不变；不增加写权限、目录权限或 QUERY_ALL_PACKAGES。启动失败立即撤销授权。
- 声明安装 Intent 和已知系统扫描包的 queries，兼容 Android 包可见性过滤。

设备只读查询确认 `com.miui.packageinstaller/com.miui.packageInstaller.InstallStart` 匹配当前应用使用的 content URI 安装请求。此次没有执行手机安装，实际扫描和后续应用内更新需要用户手动安装修复版后验证。Mac 使用独立的 ZIP 更新流程，不使用 Android FileProvider，不需要这项修复；双端下载校验、版本验证和安装确认的行为保持一致。

依据：[Android FileProvider 文件授权](https://developer.android.com/reference/androidx/core/content/FileProvider)、[包可见性声明](https://developer.android.com/training/package-visibility/declaring)。当前 Flutter 项目没有代码推送/热更新框架，Dart 经平台通道调用 Kotlin 安装模块（[Flutter 架构说明](https://docs.flutter.dev/resources/architectural-overview)）。旧 APK 的原生错误不能靠服务端更新信息修复，因此需要从浏览器/文件管理器或经授权覆盖安装一次新 APK；此次保留用户要求的手动更新安排。

Android 0.2.4 / 2026101205，arm64，原签名，非强制更新。构建完成，证书与手机原有 0.2.2 包一致；两项本地授权政策检查通过（项目当前启用的是 testDebugUnitTest）。APK SHA256：`17afe006cfd036f6bf1d9c24e5cd2aebd5edc80347581ca787c46dc9471b9c24`。包与发行描述在 `dist/android-installer-0.2.4/`。

已发布为 `rel_3b8cb208afe35aac01`，更新说明提示旧版从浏览器先安装一次。公网已验证旧版 0.2.2/0.2.3 均收到正确非强制更新，新版不重复收到；完整 APK 下载摘要及 attachment 响应有效。发布前记录备份位于 `/opt/remotescreen/backups/android-installer-0.2.4/releases-before.json`。没有替换手机或 Mac 安装，也没有改动 Mac 的已发布更新。

[手机浏览器下载修复 APK](http://121.43.102.154/v1/updates/packages/rel_3b8cb208afe35aac01)。这一次完整 APK 覆盖安装用于让手机获得修复后的原生安装逻辑，用户无需卸载应用；之后仍需在手机验证下一次应用内升级。
