import Foundation
import CoreVideo
import Metal
import os

func eventually(_ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        precondition(Date() < deadline, message)
        Thread.sleep(forTimeInterval: 0.01)
    }
}

func pixels(_ value: UInt8, patterned: Bool = false) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &buffer) == kCVReturnSuccess)
    let result = buffer!
    CVPixelBufferLockBaseAddress(result, [])
    let bytes = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(result)
    for y in 0..<360 {
        for x in 0..<640 {
            let offset = y * rowBytes + x * 4
            let shade = patterned ? UInt8((x / 32 + y / 32) % 2 == 0 ? 48 : 224) : value
            bytes[offset] = shade; bytes[offset + 1] = shade; bytes[offset + 2] = shade; bytes[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(result, [])
    return result
}

func syntheticDepth() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, 518, 392, kCVPixelFormatType_OneComponent16Half, nil, &buffer) == kCVReturnSuccess)
    let result = buffer!
    CVPixelBufferLockBaseAddress(result, [])
    let base = CVPixelBufferGetBaseAddress(result)!
    for y in 0..<392 {
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(result)).assumingMemoryBound(to: UInt16.self)
        for x in 0..<518 { row[x] = Float16(Float(x) / 518 + 0.001 * Float(y)).bitPattern }
    }
    CVPixelBufferUnlockBaseAddress(result, [])
    return result
}

let device = MTLCreateSystemDefaultDevice()!
let recorder = StreamingMetricsRecorder()
let session1 = recorder.beginSession()
let session2 = recorder.beginSession()
let dark = pixels(20)
let light = pixels(240)
func frame(_ id: UInt64, session: MetricSessionID, buffer: CVPixelBuffer = dark) -> VideoFrameMailbox.Frame {
    VideoFrameMailbox.Frame(pixelBuffer: buffer, receivedAt: 0, id: id, metrics: nil, session: session)
}
precondition(DepthEstimationService.robustRange([Float.nan, .infinity]) == nil)
precondition(DepthEstimationService.robustRange([1, 1, 1]) == nil)
precondition(DepthEstimationService.robustRange([Float.nan] + Array(0..<20).map(Float.init)) == nil)
precondition(DepthEstimationService.robustRange(Array(0..<100).map(Float.init)) == SIMD2<Float>(1, 97))
precondition(DepthEstimationService.compatibility(forMeanLumaDifference: .nan) == 0)
precondition(DepthEstimationService.compatibility(forMeanLumaDifference: 0) == 1)
precondition(DepthEstimationService.compatibility(forMeanLumaDifference: 0.2) == 0)

let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
let calls = OSAllocatedUnfairLock(initialState: 0)
let service = DepthEstimationService(device: device, prediction: { input in
    precondition(CVPixelBufferGetWidth(input) == 518 && CVPixelBufferGetHeight(input) == 392)
    let number = calls.withLock { $0 += 1; return $0 }
    if number == 1 { entered.signal(); release.wait() }
    return syntheticDepth()
})
service.submit(frame: frame(1, session: session1), enabled: true)
precondition(entered.wait(timeout: .now() + 5) == .success)
for id in 2...101 { service.submit(frame: frame(UInt64(id), session: session1), enabled: true) }
precondition(calls.withLock { $0 } == 1, "Busy submissions must never queue predictions")
service.setEnabled(false)
release.signal()
eventually("Old prediction must finish without publishing") { calls.withLock { $0 } == 1 && service.snapshot(for: frame(1, session: session1), frozen: true) == nil }
let fresh = frame(102, session: session2)
eventually("New session must obtain its own map") {
    service.submit(frame: fresh, enabled: true)
    return service.snapshot(for: fresh, frozen: true) != nil
}
precondition(calls.withLock { $0 } == 2, "Only one old and one new prediction are permitted")
let map = service.snapshot(for: fresh, frozen: true)!
precondition(map.session == session2 && map.frameID == 102 && map.confidence == 1)
precondition(map.texture.width == 259 && map.texture.height == 196 && map.texture.pixelFormat == .r32Float)
var values = [Float](repeating: 0, count: 259 * 196)
values.withUnsafeMutableBytes { bytes in
    map.texture.getBytes(bytes.baseAddress!, bytesPerRow: 259 * MemoryLayout<Float>.stride,
                         from: MTLRegionMake2D(0, 0, 259, 196), mipmapLevel: 0)
}
precondition(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
precondition(values.max()! - values.min()! > 0.9, "Depth must contain usable relative disparity")
precondition(service.snapshot(for: frame(103, session: session2, buffer: light)) == nil,
             "Scene changes must reject an incompatible map")
precondition(service.snapshot(for: frame(102, session: session1), frozen: true) == nil)
Thread.sleep(forTimeInterval: 0.27)
precondition(service.snapshot(for: fresh) == nil, "Live maps older than 250 ms must fall back")
precondition(service.snapshot(for: fresh, frozen: true) != nil, "The identical frozen image may keep its map")
let revision = service.revision
service.stop()
precondition(service.revision > revision)
service.submit(frame: frame(104, session: session2), enabled: true)
Thread.sleep(forTimeInterval: 0.15)
precondition(calls.withLock { $0 } == 2 && service.snapshot(for: fresh, frozen: true) == nil)
print("Depth service: finite normalization, one-work bound, generation revocation, motion/age gating and stop passed")

// Run the real bundled model as well: this validates the shipped schema, pixel
// formats, model loading and normalization instead of only a test substitute.
let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
let real = DepthEstimationService(device: device, modelURL: modelURL)
let actualFrame = frame(200, session: session2, buffer: pixels(0, patterned: true))
real.submit(frame: actualFrame, enabled: true)
eventually("Bundled Core ML model must produce a normalized map: \(real.status())", timeout: 60) {
    real.snapshot(for: actualFrame, frozen: true) != nil
}
let actual = real.snapshot(for: actualFrame, frozen: true)!
precondition(actual.texture.width == 259 && actual.texture.height == 196)
print("Bundled model: 518×392 BGRA → Float16 depth → 259×196 r32Float; host inference \(Int(actual.inferenceMilliseconds.rounded())) ms")
for id: UInt64 in [201, 202, 203] {
    let warmFrame = frame(id, session: session2, buffer: actualFrame.pixelBuffer)
    eventually("Warm model prediction must produce its own source frame", timeout: 60) {
        real.submit(frame: warmFrame, enabled: true)
        return real.snapshot(for: warmFrame, frozen: true)?.frameID == id
    }
    let warmed = real.snapshot(for: warmFrame, frozen: true)!
    print("Bundled model warm inference: \(Int(warmed.inferenceMilliseconds.rounded())) ms; live map usable: \(real.snapshot(for: warmFrame) != nil)")
}
real.stop()
