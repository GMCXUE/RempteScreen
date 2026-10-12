# 通知、来电铃声与振动修复

真机排查：Android POST_NOTIFICATION 已允许，各通知通道未被关闭，手机处于 VIBRATE 模式且勿扰关闭；铃声流因此被系统静音。检查时安卓应用进程及消息服务均未运行，不能将其等同于用户之前前台测试的状态。Mac 应用仍运行，保存的账号凭据与消息状态接口有效。之前只确认服务启动、编译和隔离界面，未确认真实系统通知授权及物理声音/振动效果。

双端修正：前台非当前会话也发送系统通知；此前仅应用内轻提示。通知按本设备的收到消息游标判断新到达，初始化后不再依赖共享未读数，避免另一端更快标记已读导致漏提醒。首次同步没有未读的历史消息不补发。当前正在查看的会话、已拉黑好友和免打扰仍不额外提醒。Mac 后台窗口不再自动标记聊天已读。

Mac 改用链接在主应用内的 UserNotifications 桥接：明确申请 alert/sound/badge 授权，支持前台横幅、默认通知声音、来电接听/拒绝动作、通知点击；来电结束可撤销原生通知。铃声仍由独立原生线程播放并按截止时间停止。授权、提醒投递结果及消息轮询错误保存在应用数据目录的 notification-diagnostics.json，不含令牌或聊天正文。通知插件继续保留作其他桌面平台的兼容路径。

安卓来电振动改为 RINGTONE 用途的 VibrationAttributes/AudioAttributes，避免无用途振动被当作触摸反馈或背景振动抑制。消息通道明确配置默认通知声音和振动；静音通道不响不振。消息音与系统通知合并触发，避免前台手动声音和通知声音重复。保留系统振动/静音/勿扰行为，不擅自改手机设置。Home 在恢复前台和前台每 15 秒检查消息服务，未运行时重新启动；启动错误不再被吞掉，同一错误不重复刷提示，原生轮询记录最后成功时间和错误类别。

双端“消息与来电提醒”增加通知状态诊断、测试消息通知、测试来电铃声；安卓显示通知权限、后台服务、静音/振动/声音模式。测试只在本设备生成提醒，不发送好友消息，不建立真实通话，测试铃声 6 秒自动停止。

验证：4 项独立 Rust 通知策略测试、5 项 Android JUnit 策略测试、8 项 Flutter 回归测试；Dart 修改文件分析无问题。桌面隔离界面验证测试入口、提醒设置、未读和通知点击。Mac 原生桥接已编译通过。真实系统授权状态、铃声和振动效果需以安装后原生返回和本机测试为准。

参考：[Apple 通知委托](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate)、[Android Vibrator 用途](https://developer.android.com/reference/android/os/Vibrator)。

已覆盖两端修复版。Mac 旧应用备份：`/private/tmp/RemoteScreen-before-notification-fix-20261011-114743.app`。真实原生状态返回 authorization=1（拒绝）和 `Notifications are not allowed for this application`，消息接口轮询成功；已打开系统通知设置供用户允许 RemoteScreen。Mac 输出音量 38、未静音。安卓安装 Success，消息前台服务运行；新 rs_messages_v2 通道 importance=4、默认通知声音、振动已启用。APK 内容确认包含新的通道、诊断与测试入口。物理来电响铃/振动仍应在本机测试入口确认，手机保持振动模式时不会播放铃声。
