#if DEBUG
import Foundation
import CoreVideo
@preconcurrency import Metal
import os

/// Explicit developer launch only. Exercises the shipped model with generated
/// pixels; it never reads a console, account, screenshot, or streaming mailbox.
enum DepthModelSmokeTest {
    private static let didRun = OSAllocatedUnfairLock(initialState: false)

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--depth-model-smoke-test"),
              didRun.withLock({ value in
                  guard !value else { return false }
                  value = true
                  return true
              }) else { return }
        await Task.detached(priority: .utility) { await run() }.value
    }

    private static func run() async {
        guard let device = MTLCreateSystemDefaultDevice(), let input = makeInput() else {
            DebugLog.print("[DepthSmoke] failed: device or synthetic input unavailable")
            return
        }
        let service = DepthEstimationService(device: device)
        defer { service.stop() }
        let recorder = StreamingMetricsRecorder(capacity: 8)
        let session = recorder.beginSession()
        defer { recorder.endSession(session) }
        DebugLog.print("[DepthSmoke] started: synthetic 1920x1080; CPU+GPU; one cold and three warm predictions")
        for index in 0..<4 {
            let frame = VideoFrameMailbox.Frame(pixelBuffer: input, receivedAt: 0,
                                                 id: UInt64(index + 1), metrics: nil, session: session)
            let started = DispatchTime.now().uptimeNanoseconds
            let budget: UInt64 = index == 0 ? 15_000_000_000 : 2_000_000_000
            var map: DepthEstimationService.DepthSnapshot?
            while !Task.isCancelled, DispatchTime.now().uptimeNanoseconds - started < budget {
                service.submit(frame: frame, enabled: true)
                if let candidate = service.snapshot(for: frame, frozen: true), candidate.frameID == frame.id {
                    map = candidate
                    break
                }
                if service.status() == "2D — depth model unavailable" { break }
                do { try await Task.sleep(nanoseconds: 20_000_000) }
                catch { return }
            }
            guard let map else {
                DebugLog.print("[DepthSmoke] failed: sample=\(index) state=\(service.status())")
                return
            }
            let width = map.texture.width, height = map.texture.height
            var values = [Float](repeating: 0, count: width * height)
            values.withUnsafeMutableBytes { bytes in
                map.texture.getBytes(bytes.baseAddress!, bytesPerRow: width * MemoryLayout<Float>.stride,
                                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            let finite = values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
            let live = service.snapshot(for: frame) != nil
            let totalMS = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            DebugLog.print("[DepthSmoke] sample=\(index) shape=\(width)x\(height) r32Float finite=\(finite) inferenceMs=\(Int(map.inferenceMilliseconds.rounded())) totalMs=\(Int(totalMS.rounded())) mapLiveUsable=\(live)")
            guard finite, width == 259, height == 196 else {
                DebugLog.print("[DepthSmoke] failed: invalid model output")
                return
            }
        }
        DebugLog.print("[DepthSmoke] completed: model output valid; visual quality requires headset evaluation")
    }

    private static func makeInput() -> CVPixelBuffer? {
        let width = 1920, height = 1080
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferMetalCompatibilityKey: true,
                                   kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                let foreground = x > 700 && x < 1220 && y > 280 && y < 920
                let checker = ((x / 120) + (y / 120)) % 2 == 0
                if foreground {
                    row[offset] = 36
                    row[offset + 1] = UInt8(110 + (x - 700) / 8)
                    row[offset + 2] = 220
                } else {
                    let shade = min(230, 40 + y * 130 / height + (checker ? 35 : 0))
                    row[offset] = UInt8(min(255, shade + 30))
                    row[offset + 1] = UInt8(shade)
                    row[offset + 2] = UInt8(shade)
                }
                row[offset + 3] = 255
            }
        }
        return buffer
    }
}
#endif
