# 通话权限和后台采集

macOS 通话辅助进程现在嵌入隐私用途 plist；摄像头或麦克风权限已拒绝时打开对应系统隐私设置页面。摄像头启动失败显示辅助进程 stderr 中的具体原因，不再只展示 EOF 帧头读取异常。临时签名的覆盖构建仍可能需要重新授权，应用不会自行修改系统授权。

安卓新增 microphone/camera 类型的 CallMediaService 及对应前台服务权限。显式开启采集后启动带常驻通知的服务，切到其他应用仍保持采集所需的进程状态。多个通话会话按 ID 合并活跃设备；最后一个设备关闭或会话结束时停止服务。服务启动失败会返回错误并撤回新增采集状态。

Android 要求在 Activity 可见时开启这类服务，应用后台时不能任意新开麦克风或摄像头。通知可以返回应用；杀掉进程不自动恢复设备采集。系统或厂商仍可能终止进程，后台服务不是永久存活保证。

参考：https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start

后台连续采集和 macOS 权限跳转的真实设备效果尚未验证。
