# 媒体路由接入与 Mac 验证（第三项）

已经推送的基础检查点：91fbaa4 已发布源码基线、20db7af 静音停止 SFU 音频转发、72b849c 双端直连传输基础。第三项在同一工作树同步实现 Rust / Flutter，完成下述 Mac 验证后推送独立源码检查点，再发布完整安装包。

## 连接和授权

- 继续使用原 LiveKit 房间及其鉴权、轨道出版/订阅和控制信令。直连失败不结束房间、不重新采集、不关闭通话或投屏。
- 只在一对一时尝试。房间出现多个远端参与者，立即恢复 SFU；原发送方继续只推一路服务器媒体。
- 只接受选定对端、当前房间、受限大小、协议 v2、当前 attempt nonce 的信令。只把直连的固定媒体槽位映射到 SFU 已授权/实际存在的对端 publication SID，不接受仅靠 P2P SDP 宣称的未经授权来源。
- 固定来源顺序 microphone / camera / screen / screen_audio，在同一 PeerConnection 中分别创建发送和接收方向，共八个 MID。发起方发送 0–3、接收 4–7；回答方接收 0–3、发送 4–7。SDP 交换须校验类型、数量和方向。Nonce 防止旧 offer/answer/ready 覆盖新尝试；有界超时及低频重试，旧客户端不发送能力声明时保留 SFU。
- 不使用 TURN 创建所谓直连，TURN 仍然消耗中继服务器带宽。STUN 可获取公网候选；无法连接就保留 SFU。

## 保留画质与帧率

- 必须连接就绪后才启动直连发送器；native 实测如果协商期间就编码，会触发长期低分辨率。先配置与现有 SFU 编码相同的 maxBitrate / maxFramerate / scaleResolutionDownBy / degradationPreference，不改变采集轨或业务四档策略。
- 复用现有捕获轨；直连预热期间仍用 SFU 展示和播放。直连视频达到原 SFU 的尺寸（考虑旋转可比较像素面积及短边）、帧率及丢包指标后，双方 ready 才切换接收及暂停 SFU RTP sender。音频预热要禁用直连接收轨播放，避免重叠声音。
- 停止 SFU upstream 时暂停对应 RTP sender 的 encodings.active，并释放其捕获输入绑定，避免旧发送器限制直连的分辨率需求。Flutter 使用 replaceTrack(null)；原生 SDK 的空轨道 getter/setter 会崩溃，使用禁用且不产出帧的独立占位轨，保留原 SDK 轨道供回退。禁止 mute/disable 本地捕获轨，否则同时会把直连及本地预览关掉。SFU 下行使用 publication disabled，保留 SID/订阅。
- 同一摄像头的四档参数同步到直连 sender。质量统计和接收端反馈必须采样当前实际路径；feedback 可增加兼容的 direct 来源字段，避免旧路径的低帧率/丢包反馈误伤新路径。
- 直连质量差、CPU 或可用带宽不足，先请求 SFU 回退，不能为了继续省服务器带宽而降业务质量。恢复 SFU 后继续原有网络自适应四档策略。
- 预热必须有时间/负载限制。尤其 WAN 不得让重复发送长期挤占原来的上行；LAN 流量也要检查编码负载。冻结预热前 SFU 参考值，不能把预热造成的低帧率当成新的可接受基准。
- 稳定直连不要持续经 SFU 发送 ready 心跳，否则可能抵消 DTX 静默语音的带宽节省。依靠 P2P 连接/接收数据健康度，初次 ready/active 确认有限重发即可。

## 生命周期和恢复

- 通过 media_route 中按 SID 的 watch 通知切换 NativeVideoStream/NativeAudioStream，保留 JPEG 帧池、播放缓冲及用户 gain。直连流结束先回 SFU，不能让播放循环把它误当作房间结束。
- 保留原生 PeerConnectionFactory 到最后一个原生流/接收轨/stats 异步引用释放；丢弃原生 observer 后才释放 factory。SDK 新增 local audio/video rtp_sender getter 用于暂停 SFU upstream。
- Rust 音频接收服务要同时考虑直连已接管；否则非零音量会反复重新启用 SFU 音频。Flutter 同样使用实际接收路径，并在直连期间保持对应 SFU publication disabled。
- Flutter 原生直连 RemoteAudioTrack 必须在预热期间 muted；RemoteTrack.start 后才能可靠 enable。无 event.streams 时为远端轨创建媒体流容器；不打开第二次摄像头/麦克风。
- Flutter CallController 的 camera getter、ViewingSession 的 screen getter、quality stats、原生悬浮窗 track ID 均要跟随实际路径。新增路线变化 listener 后，在 close/disconnect 清理。
- Publication 增删、mute、捕获轨替换、房间重连/断开、结束通话、切后台和新观看者都要处理。正常停止必须恢复 SFU sender/publication 的必要状态、清理全局 SID 路由、关闭探测任务和直连 PC。
- 不能让 mobile 切后台因 ready 心跳暂停导致对端关直连，而本地 SFU subscription 仍禁用。验证 foreground service 和 Dart 控制面在后台保持工作，且 fallback 能恢复接收。

## 验证范围与设备回归边界

- Mac 两个真实 LiveKit peer（本地隔离服务）用相同源发送音频和视频，自动建立直连；SFU inbound / upstream 媒体载荷降到接近 0，直连收到同尺寸、约 30fps 的四档相机以及正确音调。
- 切换原 SID/房间状态不变；关闭直连 PC/阻断直连、数据超时、旧信令、低帧率/丢包反馈、多观看端、晚到/替换音轨均恢复 SFU，避免双音频。
- 摄像头四档和屏幕编码独立；静音、相机开关、投屏系统声音分别正确。
- Flutter对应策略测试；尽可能做 Rust / Flutter 原生互通（Android 调试设备当前离线，Mac 原生与 Flutter Web 使用虚拟采集验证）。背景测试须使用独立测试应用，不覆盖用户安装的数据或正式客户端。
- 每项实测通过再推送；全部完成后用完整 macOS / Android 安装包发布，保留热更新 loader 和 Shorebird 能力。

## Mac 实测记录

- 原生 SDK 的 sendrecv SDP 只保留发送与接收能力的交集，导致 H264 软件 packetization-mode=0 消失。实际对照确认，方向分开后保留原有软件编码格式；接收方向使用 receiver capabilities，避免宣告较低的 sender profile level。
- 同一连接内双方实际解码 1920×1080、30fps 摄像头视频；屏幕 640×360、30fps；440Hz 麦克风及左右分别 880/1320Hz 系统声音保持正确。稳定后四条原生发送到 Flutter 的 SFU 媒体上下行增量为 0。反向 Native 接收的原 SFU 媒体增量也为 0。原房间不断开，回退保持 1920×1080、30fps；独立 Mac 原生生命周期验证中，暂停 SFU 的相机取消发布不崩溃，双方房间和麦克风 publication 保留。
- 原生四档与相机输入解绑/恢复已再次通过，四档均约 30fps。协议 v2 下新增第三位观看者会恢复单路 SFU publication，实际恢复载荷 553854 字节/2秒，房间和订阅保留。回退路径需给暂停期间的旧带宽估计短恢复期，但真实低帧率、丢包和 CPU 受限仍立即处理。
- 上述测试覆盖本次源码检查点；安装包的版本、发布状态及验签记录在整包发布文档中单独记录。

最终回归：原生 32 项通过，7 项需独立服务的集成测试默认跳过；Flutter 27 项音频、视频策略、协议和界面测试通过，五文件静态分析无问题。直连预热帧率下降或原有四档策略启动调档期间，参考画质不匹配时，质量保护拒绝切换并保留 SFU；相机关闭独立实测已通过（30fps，SFU 视频双向载荷增量为 0）。Android 调试设备当前未连接，未宣称手机后台实测。

最后独立验证：SDK SignalReconnect 保留实际直连媒体、0 字节 SFU 下行；关闭实际直连 PeerConnection 后恢复 SFU，2 秒收到 244995 字节，双方房间和原订阅保留。新增观看者、相机关闭及四档切换分开运行，避免并行编译干扰帧率测量。直连的网络兼容性、真实手机长时间后台运行仍需设备回归；遇到质量保护拒绝时保留 SFU，不承诺所有网络都能省掉转发。
