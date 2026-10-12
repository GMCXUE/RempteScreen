# 降低服务器媒体带宽：逐项验证记录

## 第一项：关闭接收声音时暂停 SFU 音频转发

桌面 Rust 和 Flutter 同步修改：扬声器关闭或观看音量为 0 时，通过 LiveKit publication 的接收设置暂停对应音频的服务器转发；保留订阅、音轨 SID 和房间连接。麦克风和投屏声音分别控制，对选定通话对象之外的参与者不作调整。新音轨到达时重新应用开关状态。声音重新开启时在原订阅上恢复转发。

桌面 SDK 原本在信令恢复的 SyncState 中发送空的 track_sids_disabled，现在携带仍被禁用的订阅，与 Flutter SDK 的行为一致。没有修改视频分辨率、帧率、音频采样率、编码码率、DTX、RED 或发送端音频内容。

### Mac 实测

在独立的本地 LiveKit dev 实例中持续发送 440 Hz 麦克风、880 Hz 投屏声音和 640×360 / 30fps 摄像头视频。测量均为接收端 RTP 载荷字节，2 秒统计窗口；静音后先等待 2 秒，避开 LiveKit 清空播放缓冲的约 1 秒静音帧。

| 状态 | 麦克风字节 | 投屏声音字节 | 视频实测 fps |
| --- | ---: | ---: | ---: |
| 先关闭扬声器，再发布音轨 | 0 | 24700 | 30.0 |
| 两条声音都开启 | 24700 | 24700 | 30.0 |
| 只关闭投屏声音 | 24700 | 0 | 30.5 |
| 快速连续开关后恢复 | 24700 | 24700 | 30.0 |
| 信令重连后保持投屏声音关闭 | 24700 | 0 | 30.0 |

开关操作未触发音轨取消订阅或房间重连，发送方始终只有原来的 3 条媒体轨道。额外主动制造一次信令重连后，静音仍然生效。

验证命令：在 apps/desktop-rs/app/src-tauri 中运行 RS_AUDIO_RECEPTION_TEST_URL=ws://127.0.0.1:19080 cargo test muted_audio_stops_server_forwarding -- --ignored --nocapture（需要独立 devkey/secret 本地测试服务）。

Flutter 在 Mac 上通过 18 项声音控制、迟到音轨、快速操作、好友通话界面和四档视频回归测试；修改文件静态分析无问题。该检查不替代 Android 设备实测。

静音可节省该接收方的音频下行媒体流量；发送端上行、仍有其他接收方的流量、协议心跳及转发中的视频不会因此消失。

协议依据：[LiveKit UpdateTrackSettings](https://github.com/livekit/protocol/blob/main/protobufs/livekit_rtc.proto)，服务端静音缓冲行为：[DownTrack](https://github.com/livekit/livekit/blob/master/pkg/sfu/downtrack.go)。

## 第二项：两端直连传输基础与独立验证

新增 Rust / Flutter 对应的 DirectTransport：固定 microphone、camera、screen、screen_audio 四个 Unified Plan 槽位，摄像头优先 H264 constrained baseline、屏幕采用 VP8；同一发送器复制现有码率、帧率及缩放参数，保留 active、RID 和事务标识。协商有大小和超时限制；STUN 参数只允许 stun:，不配置 TURN 媒体中继。原生侧收集 ICE 候选后组成 SDP，避免 SDK 的 current_local_description 在 offer 待确认期间为空。

所有媒体发送器在协商期间保持 inactive，只有 PeerConnection 已连接才允许 activate。独立测试发现，如果协商完成之前就启动编码器，会在等待连接期间触发带宽降级，导致连上后仍长时间保持低分辨率；连接就绪后再启动解决了该问题。媒体工厂保留到链路销毁，避免测试采集轨的工厂过早释放。

Mac 原生两个端点直接连接，解码 440 Hz 连续测试声音正确；1080p、720p、360p、180p、再次 1080p 均收到目标尺寸，同一个连接的短窗口帧率约 30fps（最近一次分别为 30.0、30.5、30.3、31.0、30.5，窗口边界会有少量计数误差）。没有 TURN 候选。同机现有 LiveKit SFU 对照测试仍通过全部四档及接收端反馈自动升降档检查。

Flutter 3 项协议/参数/配置回归测试通过，相关文件静态分析无问题。此项是接入前的传输基础检查点；尚未接入正式通话或投屏，不代表当前应用已自动切换直连或已节省这部分带宽。下一项将接入媒体接收、发送暂停和 SFU 回退后，再验证流量及切换行为。
