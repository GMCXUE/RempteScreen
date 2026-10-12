# 观看页直播式布局

## 移动端

- 移除固定 AppBar，画面铺满观看区域并保持完整比例，不裁掉远端屏幕内容。
- 顶部使用渐变背景、设备名和观看状态，返回与断开分别提供入口；断开需确认，返回页面保留会话。
- 底部改为紧凑半透明悬浮栏：投屏声音、麦克风、通话声音、全屏、收起。正常观看 4 秒无操作自动收起；连接、重连和设备操作中保持可见。
- 轻点画面可以切换控制栏；收起后右下角保留全屏及展开入口。仅隐藏界面，不切断会话或关闭音视频轨。
- 对方摄像头小窗保持显示，圆角裁剪；控制栏收起时移动到右上角，不附加黑色背景或关闭按钮。
- 横向画面进入全屏时请求横屏，纵向画面保持系统旋转策略；返回键先退出全屏，再返回会话列表。退出页面或对端结束时恢复系统栏并解除方向限制。
- 安卓通过原生 WindowInsetsController 隐藏/恢复系统栏，支持边缘滑动临时显示系统栏，避免仅依赖 Flutter 的 SystemUiMode。参考 [Flutter 系统 UI 模式说明](https://api.flutter.dev/flutter/services/SystemChrome/setEnabledSystemUIMode.html) 和 [Android 沉浸显示 API](https://developer.android.com/develop/ui/views/layout/immersive)。Android 16 的大屏设备可能由系统控制方向，见 [方向限制](https://api.flutter.dev/flutter/services/SystemChrome/setPreferredOrientations.html)。

## 桌面端同步

- 使用顶部设备信息浮层及底部悬浮控制栏，4 秒无操作自动收起。主动收起后鼠标移动不强行展开；轻点画面或右下角展开按钮可以恢复。
- 收起后保留快捷全屏入口；Esc 退出全屏或取消关闭确认；键盘 Tab 可恢复控制栏，避免隐藏按钮仍可被误聚焦。
- 全屏调用失败时保留原状态并提示“无法切换全屏，请重试”；等待画面或处理麦克风时不自动隐藏控制栏。
- 主动断开与关闭窗口共用确认，不改变音频、视频及断开协议。

## 验证

- 移动端观看流程 6 项检查通过：320px 窄屏及横屏布局、自动收起和唤回、不改变音频/连接、全屏返回、对端结束自动退出及系统栏恢复、横屏请求/解除限制、全屏请求尚未完成时退出以及迟到回调保护、收起后摄像头保留。
- 桌面浏览器检查通过：自动收起、主动收起、快捷按钮点击、全屏/Esc/失败提示、取消断开、横竖窗口边界及无 JavaScript 错误。
- Flutter 相关文件分析通过；安卓 `:app:compileDebugKotlin --offline` 编译通过。
- 源码验证阶段未上传新界面到 GitHub、部署服务端或覆盖安装客户端；原生设备的旋转动画与系统栏表现仍需实机确认。后续覆盖安装结果见下文。

## 覆盖安装

按用户后续要求，2026-10-11 16:20 已覆盖 Mac 和无线连接的安卓设备，保留账号及应用数据。服务端无需修改，观看界面源码未上传 GitHub。

- Mac Release app 构建成功，使用 ad hoc 测试签名；摄像头、麦克风用途声明及签名权限保留，完整签名检查通过。已替换 `/Applications/RemoteScreen.app` 并启动，安装二进制与构建产物一致：`46e6a492243fe5f301f545f49213c4ae6f736c8715acdaac770827e5043a57a5`。
- Android arm64 Release APK 构建成功，证书与旧版相同；无线 `adb install -r` 返回 Success，新版已启动。设备实际 APK 与构建产物一致：`56b8c2b94f7d77608ea77d0597eb9c2b6f57584b97b97b3290921c4d6750fcc5`。
- 旧版备份：`/private/tmp/RemoteScreen-before-viewer-layout-20261011-161807.app` 和 `/private/tmp/RemoteScreen-before-viewer-layout-20261011-161807.apk`。
- 本次安装确认构建、签名、文件一致和启动；未代替用户发起实际投屏或通话，旋转动画及全屏操作可在已安装版本上实机体验。
