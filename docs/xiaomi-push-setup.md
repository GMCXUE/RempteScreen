# RemoteScreen 小米推送接入准备

状态：2026-10-14 用户确认尚未申请。本文是申请资料和后续接入要求，当前客户端与服务端尚未接入 MiPush。

Android 0.2.28 已覆盖安装成功，但用户锁屏实测仍未通过。真机已读到厂商 UID 冻结，后续又发生最近任务清理。需要系统通知投递通道，不能继续以应用内四秒轮询和唤醒锁代表后台可靠投递。

## 申请填写

先完成[小米开发者账号注册认证](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1145)，再进入[小米推送运营平台](https://admin.xmpush.xiaomi.com/)创建手机/平板应用并启用推送。具体步骤以[官方启用指南](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1542)为准。

| 字段 | 本项目内容 |
| --- | --- |
| 操作系统 | Android |
| 应用名称 | RemoteScreen |
| 包名 | `com.remotescreen.remotescreen` |
| 当前安装包 | Android 0.2.28，构建 2026101409 |
| 当前安装证书 SHA-256（页面需要时） | `5a7e6892914c8004fc0d24b22dbb7c2b99eda465ba4b8f8866d7e139a7c3165d` |
| 通知用途 | 已建立好友关系的用户之间的聊天消息和音视频通话邀请 |

应用说明可使用：RemoteScreen 提供设备间投屏、好友聊天、音视频通话及文件传输。消息提醒用于用户之间主动发起的好友聊天和来电邀请。

申请私信通知类别时，聊天选择“聊天消息 → 好友聊天”；来电选择“聊天消息 → 音视频通话”。两类用途与[小米 2026 年分类说明](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=2321)一致。按平台要求提供现有聊天/来电功能的真实材料，不能把消息类别审核通过前的配置当作可用通道。

启用后保存 AppId、AppKey、AppSecret，以及审核通过的通知类别 ID。AppId/AppKey 用于客户端 SDK；AppSecret 仅用于服务器，详见官方启用指南。凭据在本机 `.local/` 或服务端密钥配置中交接，禁止提交 Git、写入公开构建日志或发送到聊天。AppSecret 不进入 APK。

## 后续实现和验收

1. 集成官方大陆版 Android AAR，注册设备 regId，并与当前登录账号绑定；换号、退出和撤销设备时解除旧关联。
2. 服务端使用正式通知通道投递聊天和来电事件，提供重试及去重。轮询继续用于会话同步和兜底；桌面保留本机通知入口，两端继续对齐账号、已读、免打扰和错误处理。厂商 SDK 是 Android 平台差异。
3. 与现有通知去重、隐私预览、撤回和本机已读清理一起设计，不因引入系统推送重复响铃或泄露隐藏的消息内容。2026 年好友聊天分类对发送人及实际聊天内容有要求，隐藏预览模式需要与厂商规则一并验证，不能先提交模糊占位消息后宣称兼容。
4. 用真实配置验证后台、锁屏、熄屏、最近任务清理、换号及点击跳转，再发布完整安装包。应用被系统强制停止、通知权限或勿扰策略等仍需分别验证，不能承诺任何系统状态均实时展示。

申请期间可手动检查自启动及后台电池策略，并暂时关闭勿扰进行对照测试。这些设置不代表正式推送已接入，也不等同于锁屏可靠性验收。

参考：[Android SDK 接入指南](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1544)、[Android 勿扰显示策略](https://developer.android.com/reference/android/app/NotificationManager.Policy)。
