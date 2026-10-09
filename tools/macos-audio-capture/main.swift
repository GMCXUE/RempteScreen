// macOS 系统音频采集器（RemoteScreen 专用子进程）。
//
// 用 ScreenCaptureKit 抓取**系统音频**（不占麦克风），以交织 Int16 PCM 输出到 stdout：
//   · 采样率 48000Hz · 双声道 · 交给父进程（Rust）喂给 LiveKit 的音频轨
// 为什么用子进程：SCStream 的音频回调代码用 Swift 写最省事，且子进程由应用拉起时
// 会继承应用的「屏幕录制」授权（TCC 归属到父应用），无需单独授权。
//
// 用法：macos-audio-capture（无参数，常驻直到被父进程杀掉）
// 依赖：需要「屏幕录制」权限（由父应用 RemoteScreen 持有）

import CoreMedia
import Foundation
import ScreenCaptureKit

/// 全局保活：SCStream/delegate 是局部变量的话，Task 结束就会被释放，
/// 流随之销毁、音频回调停摆 —— 之前「采集器活着但没有数据」就是这个原因。
enum StreamHolder {
    static var stream: SCStream?
    static let tap = AudioTap()
    static let queue = DispatchQueue(label: "remotescreen.audio-capture")
}

final class AudioTap: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    let stdoutHandle = FileHandle.standardOutput
    var callbackCount: Int64 = 0
    var audioCallbackCount: Int64 = 0

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("流异常终止：\(error)\n".data(using: .utf8)!)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        callbackCount += 1
        if callbackCount % 60 == 1 {
            FileHandle.standardError.write("回调统计：共 \(callbackCount) 次（音频 \(audioCallbackCount) 次）\n".data(using: .utf8)!)
        }
        guard type == .audio else { return }
        audioCallbackCount += 1
        guard sampleBuffer.isValid else { return }

        var blockBuffer: CMBlockBuffer?
        // SCStream 输出的是非交错（non-interleaved）Float32 立体声：
        // AudioBufferList 里 mBuffers[0] = 左声道，mBuffers[1] = 右声道。
        // AudioBufferList 内联只带 1 个 AudioBuffer，手动扩到 2 个。
        let listSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let list = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        memset(list, 0, listSize)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer = blockBuffer else { return }

        // UnsafeMutableAudioBufferListPointer 正确处理可变长度的 mBuffers 数组
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        guard buffers.count == 2 else { return }

        let left = buffers[0].mData?.assumingMemoryBound(to: Float32.self)
        let right = buffers[1].mData?.assumingMemoryBound(to: Float32.self)
        let frameCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Float32>.size
        guard frameCount > 0, let left = left, let right = right else { return }

        // Float32 非交错 → Int16 交错
        // 注意：必须用 Data(count:)（真实长度）而不是 Data(capacity:)（只分配、长度为 0），
        // 否则写入的数据不算在 Data 里，stdout 永远是 0 字节。
        var pcm = Data(count: frameCount * 4)
        pcm.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                let l = max(-1.0, min(1.0, left[i]))
                let r = max(-1.0, min(1.0, right[i]))
                out[i * 2] = Int16(l * 32767.0)
                out[i * 2 + 1] = Int16(r * 32767.0)
            }
        }
        stdoutHandle.write(pcm)
    }
}

let semaphore = DispatchSemaphore(value: 0)

// 先报告（并在需要时请求）麦克风权限：webrtc 的音频数据泵由麦克风设备时钟驱动，
// 没有麦克风授权时泵不转，推送的系统音频帧永远发不出去（表现为观看端只有静音）。
import AVFoundation
let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
FileHandle.standardError.write("mic 授权状态: \(micStatus.rawValue)（3=已授权，0=未询问，2=已拒绝）\n".data(using: .utf8)!)
if micStatus != .authorized {
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        FileHandle.standardError.write("mic 授权结果: \(granted)\n".data(using: .utf8)!)
        if !granted { exit(2) }
    }
}

Task {
    do {
        // 音频采集仍需要一个内容过滤器（拿到主显示器即可，视频我们不用）
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            FileHandle.standardError.write("没有可用的显示器\n".data(using: .utf8)!)
            exit(1)
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // 排除自己的声音（避免回环啸叫）
        config.excludesCurrentProcessAudio = true
        // 视频部分压到最小（本进程只用音频）
        config.width = 320
        config.height = 180
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3

        let queue = StreamHolder.queue
        let tap = StreamHolder.tap
        let stream = SCStream(filter: filter, configuration: config, delegate: tap)
        StreamHolder.stream = stream
        do {
            try stream.addStreamOutput(tap, type: .audio, sampleHandlerQueue: queue)
            // 视频输出也注册（回调里忽略视频帧）：部分系统版本要求视频路径运行才有音频
            try stream.addStreamOutput(tap, type: .screen, sampleHandlerQueue: queue)
        } catch {
            FileHandle.standardError.write("添加输出失败：\(error)\n".data(using: .utf8)!)
            exit(1)
        }
        try await stream.startCapture()
        FileHandle.standardError.write("audio-capture: started\n".data(using: .utf8)!)
        // 常驻由主线程的 dispatchMain() 负责（Task 到此结束）；
        // dispatchMain 只能在主线程调用，在这里调会直接 abort —— 之前就是这个问题
    } catch {
        FileHandle.standardError.write("audio-capture 初始化失败：\(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

semaphore.wait()
dispatchMain()
