# Windows 客户端与 Actions 构建修复

## 已确认的失败原因

GitHub Actions 运行 `38019214587`（提交 `58b0959`）在 `webrtc-sys` 编译时报 C1083：找不到 `absl/strings/internal/str_format/constexpr_parser.h`。
官方 `webrtc-89d790b/webrtc-win-x64-release.zip` 内存在该文件，旧 CI 的完整文件路径长达 263 字符。仅换 `windows-2022` 无法修复 MSVC 的路径限制。

## 本次修改

- SDK 解压到 `C:\lk`，通过 LiveKit 官方支持的 `LK_CUSTOM_WEBRTC` 指向短路径，校验完整 ZIP 的 SHA256、锁定 SDK 标签和必需文件。
- Cargo 构建目录改为 `C:\rs-target`；锁定 Tauri CLI 2.12.1，保留 Rust `Cargo.lock`，明确使用 Windows MSVC x64 目标。
- 原生 CI 运行 `38117915549` 编译通过后，在链接阶段发现静态 WebRTC `/MT` 与默认 `/MD` 的运行库冲突（LNK2038/LNK2005）。根据 LiveKit 官方 Cargo 配置，为 Windows MSVC x64 增加 `+crt-static`，统一原生桥接与 Rust 的运行库。
- Windows 发布版使用 GUI 子系统，启动时不额外打开命令行窗口；构建缓存保留在独立工作目录以缩短后续验证。
- Windows 目标检查另外发现 `scap 0.0.8` 与解析出的 `windows-capture 1.5` 构造器接口不兼容，锁定兼容的 `windows-capture 1.4.2`。
- 新增 `tauri.windows.conf.json`，生成当前用户安装的 NSIS `*-setup.exe`，支持中文和英文，缺少 WebView2 时安装引导程序。
- 原生 CI 首次验证发现 npm 的 PowerShell 启动脚本吞掉 `--` 分隔符，改为直接通过 Node 运行 Tauri CLI，确保 `--locked` 传给 Cargo。
- 构建命令保留真实退出码；成功必须存在安装包；安装包与日志上传到 Actions Artifacts。
- 移除旧工作流向 `dist` 分支强制推送整个源代码的行为。诊断日志在 `build-logs/windows` 独立分支正常追加提交，不覆盖源码历史。
- Windows 使用 Graphics Capture 的 BGRA 帧，队列容量为 1，控制采集帧率，支持 720p/1080p 缩放，帧等待最长 300ms，可在静态屏幕下停止会话。
- 保留并发送首帧；Windows 静态屏幕每 300ms 重发最近画面，避免首次订阅或后来加入的观看端只得到黑帧。
- Mac 的 NV12 与 Windows 的 BGRA 共用有边界检查的 I420 转换，包含行填充、奇数尺寸和截断帧回归检查。
- Windows 摄像头使用 Media Foundation；JPEG 摄像头帧使用现有 Rust 解码器，避免重复引入原生 libjpeg；麦克风继续使用现有 CPAL。
- Windows 系统声音使用 WASAPI，发布为 ScreenshareAudio，和通话麦克风分开。支持时排除 RemoteScreen 自身进程的播放，避免将通话声音再次投送。
- Windows 来电铃声使用系统音频资源，并隐藏播放进程控制台；通知设置按钮打开 Windows 通知设置。
- 观看、摄像头和好友通话图片通过 Tauri `convertFileSrc` 生成自定义协议地址，兼容 Windows WebView2 的 localhost 映射与 Mac 原有协议。
- Windows 设备登记使用 `windows` 平台标识，与移动端现有设备显示兼容。

## 双端与平台差异

此次为桌面 Windows 平台适配，不新增跨端协议或业务入口。Flutter 端已支持屏幕轨、系统声音轨、麦克风轨和摄像头轨；继续使用同一协议与界面文案。Mac、安卓安装及服务端数据不变。

Windows 进程排除回环需要系统 build 20348 及以上；旧系统退回默认输出设备回环，可能包含本机通话播放声音。Windows 权限设置界面、铃声资源和通知外观由系统提供，与 Mac 平台实现不同。

## 验证与发布范围

- 已验证旧失败日志与官方 ZIP 内容、SHA256。
- Mac `cargo check` 通过；帧转换回归检查通过（Windows 实机行为尚需验证）。
- Windows 新增采集、摄像头、WASAPI、通话模块的 MSVC 目标 Rust 类型检查通过。使用临时检查工程跳过 C++ 静态库链接，不修改正式依赖源码；不等同于完整 Windows 构建或硬件实测。
- Windows 摄像头、WASAPI、采集线程及 NSIS 需要原生 Windows CI 构建和后续实机检查。本机为 Mac，不能把交叉类型检查当成完整 Windows 构建。
- 验证分支拟为 `codex/windows-client`，包含当前 `apps/desktop-rs/app/` 完整源码、两个 Mac 采集辅助程序源码、本次 Windows 构建脚本和此说明；当前桌面端已有功能仍有未提交文件，需要纳入才能构建最新客户端。
- 不上传账号数据、登录凭据、服务器数据库、安卓构建目录、已安装应用或本机日志。不得覆盖 `main`、旧 `dist` 或用户已有提交。
- 用户已明确批准以上源码上传范围，将推送到独立验证分支并运行 CI；尚未生成 Windows 安装包。

## Windows 安装与检查

1. 打开验证分支的成功 Actions 运行，在 Artifacts 下载 `RemoteScreen-Windows-x64` 并解压。
2. 在 Windows 电脑运行 `RemoteScreen_*_x64-setup.exe`；本测试版本尚未做商业代码签名。
3. 安装后登录现有账号，检查消息、文件传输、双向投屏、麦克风与摄像头。安卓端无需更换协议。
4. 摄像头或麦克风无法启动时，在 Windows「设置 → 隐私和安全性」检查相应设备访问权限，同时确认没有被其他应用占用。

构建验证运行：https://github.com/GMCXUE/RempteScreen/actions/runs/38117493413 。本机未执行 Windows 硬件测试。
