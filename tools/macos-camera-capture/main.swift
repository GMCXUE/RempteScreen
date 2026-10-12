// macOS 摄像头采集辅助进程：AVFoundation → 紧凑 NV12 帧 → stdout。
// 每帧格式：[u32 width LE][u32 height LE][u32 payloadLength LE][Y][UV]。

import AVFoundation
import CoreVideo
import Foundation
import AppKit
import Darwin

// Helpers never register as the primary app or create a Dock icon.
NSApplication.shared.setActivationPolicy(.prohibited)
let hostPid = getppid()
let parentWatchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
parentWatchdog.schedule(deadline: .now() + 1, repeating: 1)
parentWatchdog.setEventHandler { if getppid() != hostPid || hostPid == 1 { exit(0) } }
parentWatchdog.resume()

// Privacy permission is requested by the host app before launching this process.

final class CameraOutput: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let output = FileHandle.standardOutput

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return }

        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvHeight = (height + 1) / 2
        let payloadLength = width * height + width * uvHeight
        var frame = Data(capacity: 12 + payloadLength)
        var w = UInt32(width).littleEndian
        var h = UInt32(height).littleEndian
        var length = UInt32(payloadLength).littleEndian
        withUnsafeBytes(of: &w) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }

        for row in 0..<height {
            frame.append(yBase.advanced(by: row * yStride).assumingMemoryBound(to: UInt8.self), count: width)
        }
        for row in 0..<uvHeight {
            frame.append(uvBase.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self), count: width)
        }
        self.output.write(frame)
    }
}

let session = AVCaptureSession()
// Capture once at 1080p / 30 fps. RTP encoding scales the same track in place.
session.sessionPreset = .vga640x480
guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
    FileHandle.standardError.write(Data("没有可用摄像头\n".utf8))
    exit(1)
}

do {
    session.beginConfiguration()
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw NSError(domain: "RemoteScreen", code: 1) }
    session.addInput(input)
    if session.canSetSessionPreset(.hd1920x1080) {
        session.sessionPreset = .hd1920x1080
    } else if session.canSetSessionPreset(.hd1280x720) {
        session.sessionPreset = .hd1280x720
    }
    try device.lockForConfiguration()
    // Presets can change activeFormat asynchronously during startRunning.
    // Select the native format and commit size/fps together, so the first
    // published frame and all following frames advertise the same dimensions.
    let formats = device.formats.filter {
        $0.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
            })
    }
    let formatForSize: (Int32, Int32) -> AVCaptureDevice.Format? = { width, height in
        formats.first {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return size.width == width && size.height == height
        }
    }
    if let format = formatForSize(1920, 1080) ?? formatForSize(1280, 720) {
        device.activeFormat = format
    }
    if device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
        $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
    }) {
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
    }
    device.unlockForConfiguration()
    let videoOutput = AVCaptureVideoDataOutput()
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ]
    let delegate = CameraOutput()
    videoOutput.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "remotescreen.camera"))
    guard session.canAddOutput(videoOutput) else { throw NSError(domain: "RemoteScreen", code: 2) }
    session.addOutput(videoOutput)
    session.commitConfiguration()
    session.startRunning()
    let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    FileHandle.standardError.write(Data("camera-capture: started \(size.width)×\(size.height)\n".utf8))
    withExtendedLifetime(delegate) { dispatchMain() }
} catch {
    FileHandle.standardError.write(Data("摄像头启动失败：\(error)\n".utf8))
    exit(1)
}
