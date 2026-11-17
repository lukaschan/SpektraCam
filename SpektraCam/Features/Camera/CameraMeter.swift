@preconcurrency import AVFoundation
import Foundation
import OSLog

nonisolated struct CameraReadings: Sendable {
    var histogram = Array(repeating: Double(0), count: 64)
    var seconds = Double(0)
    var aperture = Float(0)
    var iso = Float(0)
    /// The device's own exposure bias, so the slider follows Camera Control.
    var bias = Float(0)
}

nonisolated struct CameraLens: Identifiable, Equatable, Sendable {
    let id: String
    let millimeters: Int
    let front: Bool
    let macro: Bool
    let primary: Bool
    var title: String {
        front ? String(localized: "camera.front", defaultValue: "Front") : String(millimeters)
    }
}

/// Preview-sized luma samples, at most five updates per second. This is not a RAW histogram.
nonisolated final class CameraMeter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let device: AVCaptureDevice
    private let publish: @Sendable (CameraReadings) -> Void
    private var lastUpdate = -Double.infinity
    private let started = ProcessInfo.processInfo.systemUptime
    init(device: AVCaptureDevice, publish: @escaping @Sendable (CameraReadings) -> Void) {
        self.device = device
        self.publish = publish
    }
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        if lastUpdate == -.infinity {
            Log.camera.debug("First preview frame: \(now - self.started) s")
        }
        guard now - lastUpdate >= 0.2, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            CVPixelBufferGetPlaneCount(buffer) >= 1
        else { return }
        lastUpdate = now
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let fullRange =
            CVPixelBufferGetPixelFormatType(buffer)
            == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        var bins = Array(repeating: Double(0), count: 64)
        for y in stride(from: 0, to: height, by: max(1, height / 64)) {
            for x in stride(from: 0, to: width, by: max(1, width / 64)) {
                let value = Int(pixels[y * rowBytes + x])
                let code = fullRange ? value : max(0, min(255, (value - 16) * 255 / 219))
                bins[code / 4] += 1
            }
        }
        let peak = max(1, bins.max() ?? 1)
        publish(
            CameraReadings(
                histogram: bins.map { $0 / peak }, seconds: device.exposureDuration.seconds,
                aperture: device.lensAperture, iso: device.iso,
                bias: device.exposureTargetBias))
    }
}
