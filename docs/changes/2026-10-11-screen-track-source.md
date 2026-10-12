# 已连接但等待投送：屏幕轨来源修复

生产 LiveKit 房间 device-522952991 中，caster 已发布 VIDEO/UNKNOWN 与 AUDIO/SCREEN_SHARE_AUDIO。桌面屏幕视频发布选项遗漏 source，Rust SDK 默认 TrackSource::Unknown；Flutter 观看端和更新后的桌面观看端只识别屏幕共享来源，因而连接成功但没有选出投屏轨道。

桌面发布明确设置 TrackSource::Screenshare。双端观看逻辑一致兼容旧轨道：仅允许 UNKNOWN 且名称恰为 screen 的视频作为旧屏幕共享轨道，保持摄像头与屏幕共享分离；仍只接受目标 caster 身份的轨道。其他未知来源视频不作屏幕显示。

服务器查询已确认旧轨道标签错误。双端重新打包安装后需要重新连接，发布新的屏幕轨；完整实机画面仍需确认。
