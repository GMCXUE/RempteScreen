# 好友与私聊：第一阶段

## 已实现

账号级好友搜索（完整账号 ID 或邮箱）、申请说明、同意/拒绝、等待确认、备注、删除、拉黑/解除拉黑。双端统一“消息”入口。移动导航为首页、消息、投屏、我的，设备入口保留在首页。个人账号 ID 可复制。

好友文字私聊使用 PostgreSQL 持久化，支持最近记录、历史分页、断线积压增量补齐、服务端未读游标、多端同步和发送重试去重。消息最长 2000 字，备注 32 字，申请说明 160 字。应用内定时同步（3–4 秒），目前没有系统推送、群聊或聊天附件。

授权、好友变更、消息发送在同一数据库事务内通过好友对的 advisory lock 串行化。只有申请接收方能决策；非好友、删除或拉黑后不能发送或读取私聊。消息按数值序号排序，已读序号不能引用其他会话；客户端渲染文本不执行 HTML。消息内容没有端到端加密，服务端持久化保存。

## 接口

账号 Bearer 令牌鉴权。GET `/v1/social/state` 返回当前账号、好友、申请、黑名单、未读与最近消息。
POST `/v1/social/search` `{query}` 精确搜索。
POST `/v1/social/request` `{peerId,note}` 发申请。
POST `/v1/social/decision` `{peerId,accept}` 决策。
POST `/v1/social/profile` `{peerId,action,remark?,blocked?}`，action 为 remark/remove/block。
POST `/v1/social/messages` `{peerId,before?,after?}`，历史或增量每页 50 条，两个游标不能同时传。
POST `/v1/social/send` `{peerId,text,clientId}`，clientId 是账号范围内的发送幂等标识。
POST `/v1/social/read` `{peerId,seq}` 标记已读。

服务启动时幂等创建 friend_links、friend_profiles、chat_messages 表及索引，不清空已有账号或设备。

## 后续阶段

文字消息基础先落地。聊天文件、独立呼叫/接听/拒绝/挂断、多端来电抢答和麦克风统一管理尚未实现。语音、视频通话尚未迁移，现有投屏语音继续保留，现有摄像头通话入口也暂时保留，待独立聊天通话稳定后迁移。投屏与聊天房间需要隔离，以免挂断聊天结束投屏。

## 验证与部署

本机隔离 PostgreSQL 集成检查覆盖好友权限、并发去重、拉黑/删除、分页、断线增量和重连持久化，86 项通过。测试会创建并删除独立临时数据库，不清空现有库；运行 `npm run test:social`，可指定 TEST_DATABASE_URL 连接本地测试 PostgreSQL（账户需要创建数据库权限）。桌面 cargo check 通过，JavaScript 语法检查通过；Flutter 静态检查只有既有实验性音频 API 警告，Android release 构建通过。

尚未部署服务端或覆盖安装。新版客户端需要对应服务端升级后才能使用好友与私聊接口；还未进行两台真实设备的互发测试。

## 第一阶段覆盖安装（2026-10-11）

用户要求覆盖供测试，已更新生产 device-service 的 db/index/social/social_schema 文件并重建服务镜像，仅更新该容器；数据库和旧服务源码备份位于服务器 `/opt/remotescreen/backups/friends-20261011-011934`，保留回滚镜像标签 `remotescreen-device-service:before-friends-20261011-011934`。

Mac 使用临时测试签名覆盖 `/Applications/RemoteScreen.app`，安卓无线安装成功，双端已启动。公开健康检查 200、未认证好友状态 401、当前账号的只读好友状态 200 且返回字段正确。没有代用户发好友申请或聊天消息；两账号互加、双端互聊等待用户实测。
