# 后台通知与任务划掉

范围：用户确认先修好普通后台接收，尚未申请小米推送，不接入进程终止后的厂商推送。本次未覆盖安装，没有发送真实好友消息/来电。

现场读取：小米手机，API 37。消息前台服务运行中，应用通知允许；来电 `rs_calls_v2` 频道 importance=4，但 sound=null、振动关闭，而旧代码通过 Ringtone 播放声音。没有当前来电样本，不能断言这是全部原因。

修正：
- 使用新来电频道 `rs_calls_v3`，系统铃声、振动、CallStyle 来电通知统一交给 NotificationManager。移除独立 Ringtone 循环，不再出现应用自行响铃、通知提交失败却继续响铃的路径。设置中关闭声音或好友免打扰时使用独立静音来电频道。保留旧频道的低重要性/关闭状态，避免绕过用户设置。
- 来电通过 FLAG_INSISTENT 响铃，45 秒服务端时限内保持通知；接通、拒绝、结束、退出时取消通知同时停止响铃。没有配置 ONLY_ALERT_ONCE，它会终止正在进行的提醒。来电本机测试也用系统通知，6 秒自动停止。
- 普通后台来电关联 full-screen intent，仅有权限且未在应用前台时启用；没有权限则仍提交普通 CallStyle 通知。仅来电入口临时允许锁屏展示，处理通话后恢复。
- 消息通知不因其他设备已读（共享 unread=0）立即撤掉，与桌面保留行为一致。本机实际看到会话或拉黑时清理。通知权限/频道关闭或提交失败时不消耗消息通知序号，允许恢复权限后重试。
- 消息服务明确 stopWithTask=false；onTaskRemoved 清理“前台”标记，继续原生轮询；START_STICKY 保留。系统重启与应用替换可恢复已有登录会话的 remoteMessaging 服务，退出登录后不恢复。
- dataSync 待命服务超时时主动结束自己，避免 Android 超时引发进程错误影响独立消息服务。
- 两端提醒设置提供系统通知设置入口。Android 另有来电弹出、自启动、电池限制入口和频道/后台诊断。小米手机还需用户允许自启动，并在系统中取消后台电池限制；不会自动修改用户权限。

边界：轮询约 4 秒一次，网络失败会重试。START_STICKY/启动广播不能保证系统强制停止、厂商清理进程、Doze 或网络隔离时实时接收；完整进程外投递需要已配置的厂商推送。本次不宣称已解决这种情况。

参考：
- https://developer.android.com/reference/android/app/Notification#FLAG_INSISTENT
- https://developer.android.com/develop/ui/compose/notifications/create-notification#urgent-message
- https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1544

验证：Android 原生代码编译及提醒策略单元测试；Flutter 提醒设置静态检查和现有通话/消息界面测试；桌面原生桥接编译、浮层显示策略以及按钮动作路由检查。尚未在新安装版本上验证小米后台横幅的实际展示。
