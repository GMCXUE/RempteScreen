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
session.sessionPreset = .vga640x480
guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
    FileHandle.standardError.write(Data("没有可用摄像头\n".utf8))
    exit(1)
}

do {
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw NSError(domain: "RemoteScreen", code: 1) }
    session.addInput(input)
    let videoOutput = AVCaptureVideoDataOutput()
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ]
    let delegate = CameraOutput()
    videoOutput.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "remotescreen.camera"))
    guard session.canAddOutput(videoOutput) else { throw NSError(domain: "RemoteScreen", code: 2) }
    session.addOutput(videoOutput)
    session.startRunning()
    FileHandle.standardError.write(Data("camera-capture: started\n".utf8))
    withExtendedLifetime(delegate) { dispatchMain() }
} catch {
    FileHandle.standardError.write(Data("摄像头启动失败：\(error)\n".utf8))
    exit(1)
}
