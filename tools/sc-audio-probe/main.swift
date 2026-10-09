// RemoteScreen 采集能力探针
//
// 目的：在不引入 LiveKit、不写 App 的前提下，验证本机能否用 ScreenCaptureKit
// 同时采集「屏幕画面」与「系统音频」。这是整个项目技术风险最高的一环。
//
// 编译：见同目录 build.sh（产出 .app 包，便于系统正确归属屏幕录制权限）
// 运行：open "RemoteScreen 采集探针.app"
//
// 需要 macOS 13.0+（SCStreamConfiguration.capturesAudio 自 13.0 起可用）

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import CoreAudio

let captureSeconds = 6.0
let reportPath = "/tmp/remotescreen-probe-report.txt"

var reportLines: [String] = []

/// 同时输出到终端与报告文件。以 .app 方式启动时终端不可见，报告文件是唯一出口。
func emit(_ line: String = "") {
    print(line)
    reportLines.append(line)
    try? reportLines.joined(separator: "\n")
        .write(toFile: reportPath, atomically: true, encoding: .utf8)
}

// MARK: - 统计

final class Metrics {
    private let lock = NSLock()

    private(set) var videoFrames = 0
    private(set) var audioBuffers = 0
    private(set) var peakLevel: Float = 0
    private(set) var firstVideoSize: CGSize?
    private(set) var firstAudioFormat: String?

    func recordVideo(_ buffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        videoFrames += 1
        if firstVideoSize == nil, let pixels = CMSampleBufferGetImageBuffer(buffer) {
            firstVideoSize = CGSize(width: CVPixelBufferGetWidth(pixels),
                                    height: CVPixelBufferGetHeight(pixels))
        }
    }

    func recordAudio(_ buffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        audioBuffers += 1

        if firstAudioFormat == nil, let desc = CMSampleBufferGetFormatDescription(buffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
            let isFloat = asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
            firstAudioFormat = String(format: "%.0f Hz / %u 声道 / %@",
                                      asbd.pointee.mSampleRate,
                                      asbd.pointee.mChannelsPerFrame,
                                      isFloat ? "Float32" : "整型")
        }

        let level = Metrics.rmsLevel(buffer)
        if level > peakLevel { peakLevel = level }
    }

    /// 计算一块音频缓冲的均方根电平，用于判断「有没有真的有声音」
    private static func rmsLevel(_ buffer: CMSampleBuffer) -> Float {
        let list = AudioBufferList.allocate(maximumBuffers: 8)
        defer { free(list.unsafeMutablePointer) }

        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 8),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlock
        )
        guard status == noErr else { return 0 }

        var sumOfSquares: Double = 0
        var total = 0
        for audioBuffer in list {
            guard let raw = audioBuffer.mData else { continue }
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let samples = raw.assumingMemoryBound(to: Float.self)
            for index in 0..<count {
                let value = Double(samples[index])
                sumOfSquares += value * value
            }
            total += count
        }
        guard total > 0 else { return 0 }
        return Float((sumOfSquares / Double(total)).squareRoot())
    }
}

// MARK: - 输出接收

final class ScreenOutput: NSObject, SCStreamOutput {
    let metrics: Metrics
    init(metrics: Metrics) { self.metrics = metrics }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        // 只有 .complete 状态的帧才是完整画面，其余是内容未变的占位帧
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue else { return }
        metrics.recordVideo(sampleBuffer)
    }
}

final class AudioOutput: NSObject, SCStreamOutput {
    let metrics: Metrics
    init(metrics: Metrics) { self.metrics = metrics }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        metrics.recordAudio(sampleBuffer)
    }
}

final class StreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        emit("⚠️  流被系统中止：\(error.localizedDescription)")
    }
}

// MARK: - 主流程

func fail(_ message: String) -> Never {
    emit("")
    emit("❌ \(message)")
    exit(1)
}

emit("=== RemoteScreen 采集能力探针 ===")
emit("时间：\(ISO8601DateFormatter().string(from: Date()))")
emit("系统版本：\(ProcessInfo.processInfo.operatingSystemVersionString)")

if #available(macOS 13.0, *) {
    emit("capturesAudio 支持：是")
} else {
    fail("需要 macOS 13.0 及以上才能采集系统音频")
}

let hasPermission = CGPreflightScreenCaptureAccess()
emit("屏幕录制权限：\(hasPermission ? "已授予" : "未授予")")

if !hasPermission {
    emit("")
    emit("正在申请屏幕录制权限……")
    _ = CGRequestScreenCaptureAccess()
    emit("")
    emit("申请已提交。请到「系统设置 → 隐私与安全性 → 屏幕录制」")
    emit("勾选「RemoteScreen 采集探针」，然后重新运行本程序。")
    emit("")
    emit("注意：授权后系统可能要求退出并重新打开该应用才会生效。")
    exit(2)
}

// 1. 枚举可共享内容
emit("")
emit("[1/4] 枚举可共享内容")
var sharedContent: SCShareableContent?
var contentError: Error?
let contentSemaphore = DispatchSemaphore(value: 0)
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
    sharedContent = content
    contentError = error
    contentSemaphore.signal()
}
contentSemaphore.wait()

if let contentError {
    fail("无法获取可共享内容：\(contentError.localizedDescription)")
}
guard let content = sharedContent, let display = content.displays.first else {
    fail("没有找到可采集的显示器")
}

let pixelWidth = CGDisplayPixelsWide(display.displayID)
let pixelHeight = CGDisplayPixelsHigh(display.displayID)
emit("      显示器数量：\(content.displays.count)")
emit("      主显示器：\(display.displayID)  逻辑 \(display.width)×\(display.height)  像素 \(pixelWidth)×\(pixelHeight)")
emit("      可采集窗口数：\(content.windows.count)")

// 2. 组装采集配置
emit("")
emit("[2/4] 组装采集配置")
let configuration = SCStreamConfiguration()
configuration.width = pixelWidth
configuration.height = pixelHeight
configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
configuration.pixelFormat = kCVPixelFormatType_32BGRA
configuration.queueDepth = 5
configuration.showsCursor = true

configuration.capturesAudio = true
configuration.sampleRate = 48_000
configuration.channelCount = 2
configuration.excludesCurrentProcessAudio = true

emit("      画面：\(pixelWidth)×\(pixelHeight) @ 30fps BGRA")
emit("      音频：48000 Hz / 2 声道 / capturesAudio 已开启")

let filter = SCContentFilter(display: display, excludingWindows: [])
let metrics = Metrics()
let screenOutput = ScreenOutput(metrics: metrics)
let audioOutput = AudioOutput(metrics: metrics)
let streamDelegate = StreamDelegate()
let stream = SCStream(filter: filter, configuration: configuration, delegate: streamDelegate)

let videoQueue = DispatchQueue(label: "remotescreen.video")
let audioQueue = DispatchQueue(label: "remotescreen.audio")

// 3. 启动采集
emit("")
emit("[3/4] 启动采集")
do {
    try stream.addStreamOutput(screenOutput, type: .screen, sampleHandlerQueue: videoQueue)
    try stream.addStreamOutput(audioOutput, type: .audio, sampleHandlerQueue: audioQueue)
} catch {
    fail("挂载输出失败：\(error.localizedDescription)")
}

var startError: Error?
let startSemaphore = DispatchSemaphore(value: 0)
stream.startCapture { error in
    startError = error
    startSemaphore.signal()
}
startSemaphore.wait()

if let startError {
    fail("启动采集失败：\(startError.localizedDescription)")
}
emit("      采集已启动，采样 \(Int(captureSeconds)) 秒")
emit("      请在这段时间内让电脑播放有声音的内容")

Thread.sleep(forTimeInterval: captureSeconds)

let stopSemaphore = DispatchSemaphore(value: 0)
stream.stopCapture { _ in stopSemaphore.signal() }
stopSemaphore.wait()

// 4. 输出结论
emit("")
emit("[4/4] 采集结果")
emit("      视频帧数：\(metrics.videoFrames)（预期约 \(Int(captureSeconds * 30))）")
if let size = metrics.firstVideoSize {
    emit("      画面尺寸：\(Int(size.width))×\(Int(size.height))")
}
// ScreenCaptureKit 的音频缓冲约 1024 帧 @48kHz ≈ 21ms，即每秒约 47 个
let expectedAudioBuffers = Int(captureSeconds * 46)
emit("      音频缓冲数：\(metrics.audioBuffers)（预期约 \(expectedAudioBuffers)）")
if let format = metrics.firstAudioFormat {
    emit("      音频格式：\(format)")
}

let decibels: Float = metrics.peakLevel > 0 ? 20 * log10(metrics.peakLevel) : -Float.infinity
emit(String(format: "      音频峰值电平：%.1f dBFS", decibels))

emit("")
emit("=== 结论 ===")
let videoOK = metrics.videoFrames > 0
let audioOK = metrics.audioBuffers > 0

emit(videoOK ? "✅ 屏幕画面采集正常" : "❌ 未采到画面帧")

if !audioOK {
    emit("❌ 未采到系统音频流，请确认 macOS ≥ 13 且采样期间确有声音播放")
} else if metrics.peakLevel < 0.0005 {
    emit("⚠️  音频流已建立，但采样期间电平为静音")
    emit("    多数情况是电脑当时没在播放声音。请播放一段音频后重新运行；")
    emit("    若届时电平仍是 -inf，才说明音频通道没接对。")
} else {
    emit(String(format: "✅ 系统音频采集正常，峰值 %.1f dBFS", decibels))
}

emit("")
emit("RESULT=\(videoOK && audioOK ? "PASS" : "FAIL")")

exit(videoOK && audioOK ? 0 : 1)
