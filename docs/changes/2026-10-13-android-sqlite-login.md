# Android 本地聊天数据库初始化修复

Android 0.2.14 在登录、注册和恢复账号时会打开本地聊天数据库。初始化使用 execute 执行 PRAGMA journal_mode=WAL，但该语句会返回结果行，Android 的 SQLiteDatabase.execSQL 拒绝执行，因此出现 “Queries can be performed using SQLiteDatabase query or rawQuery methods only” 并中断登录流程。

将该语句改用 sqflite 的 rawQuery 执行，继续启用 WAL、FULL 同步及外键约束。数据库路径、结构版本和现有记录保持兼容，覆盖安装后可重新初始化上一版失败后留下的空数据库，无需卸载或清除应用数据。

这是 Android 数据库驱动的平台差异：桌面 Rust 使用的 rusqlite execute_batch 明确允许 PRAGMA 返回结果行，不存在此调用限制。本次不改变跨端行为及备份格式，macOS 0.2.9 继续适用；发布 Android 完整 APK 修复包。

回归验证使用真实 sqflite MethodChannel factory，并在真实 SQLite 前施加 Android execSQL 的查询限制，覆盖新库创建与重开、初始化失败后遗留空库恢复、v1 升级到 v2 保留消息，以及 WAL/FULL/外键实际值。修复前这三项测试均复现用户报告的异常。该测试用于补足此前纯 FFI 测试未覆盖的平台调用限制，不代替 Android 实机验证。

验证结果：修复后新增 3 项平台契约回归全部通过，Flutter 完整回归 98 项全部通过，修复与新增测试的定向静态分析无问题。当前没有连接指定的 Android 测试手机，未执行实机登录验证。

完整包已发布：Android 0.2.15，buildCode 2026101304，stable 可选更新，发布记录 rel_75a748d69046086296。APK 共 60,815,802 字节，SHA-256 cdc0282d1b2d8ecf7a52de90a67fbb42d0c34a6f98a9d29887513099fe7ddf22。安装证书与 0.2.14 一致，SQLite 原生插件和 Shorebird 3.47.7 引擎、补丁公开密钥及 auto_update=false 保留；使用 dry-run 本地构建，未上传源码或发布热补丁。公网元数据 Ed25519 验签、完整下载校验及当前版本无重复升级检查均通过。其他平台及所有既有完整包、热更新发布记录未改变。源码修复与测试提交 4f895aa 已推送 codex/server-bandwidth-20261013；安装包、测试及发布验证收据位于 dist/sqlite-login-2026101304。
