import Foundation
import Metal
import CoreVideo

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let metalFX = MetalFXUpscaler()!
let enhanced = EnhancedUpscaler()!
let metrics = StreamingMetricsRecorder()
let session = metrics.beginSession()
for mode in ["MetalFX", "Enhanced"] {
    var submissions: [(MTLCommandBuffer, MTLBuffer, UInt8, VideoFrameMetrics)] = []
    // Reuse each upscaler's output across command buffers, as in the renderer.
    // Each readback must contain its own input, never the following frame.
    for value: UInt8 in [32, 128, 224] {
        let timing = VideoFrameMetrics(recorder: metrics, session: session, receivedAt: StreamingMetricsClock.now())!
        var pixel: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixel) == kCVReturnSuccess)
        let buffer = pixel!
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<1080 {
            for x in 0..<1920 {
                let i = y * stride + x * 4
                bytes[i] = value; bytes[i+1] = value; bytes[i+2] = value; bytes[i+3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let command = queue.makeCommandBuffer()!
        let texture = (mode == "MetalFX" ? metalFX.encode(buffer, commandBuffer: command) : enhanced.encode(buffer, commandBuffer: command))!
        let readback = device.makeBuffer(length: 3840 * 2160 * 4, options: .storageModeShared)!
        let blit = command.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 3840, height: 2160, depth: 1), to: readback,
            destinationOffset: 0, destinationBytesPerRow: 3840 * 4, destinationBytesPerImage: 3840 * 2160 * 4)
        blit.endEncoding()
        command.commit()
        submissions.append((command, readback, value, timing))
    }
    for (command, readback, expected, timing) in submissions {
        command.waitUntilCompleted() // Test-only CPU readback, never in app playback.
        precondition(command.status == .completed, "GPU error: \(String(describing: command.error))")
        precondition(timing.gpuCompleted(success: command.status == .completed,
            startSeconds: command.gpuStartTime, endSeconds: command.gpuEndTime) != nil,
            "GPU host timestamps must yield a valid correlated interval")
        let bytes = readback.contents().assumingMemoryBound(to: UInt8.self)
        for (x, y) in [(0,0), (1920,1080), (3839,2159)] {
            let actual = Int(bytes[(y * 3840 + x) * 4])
            precondition(abs(actual - Int(expected)) <= 3, "\(mode) frame/border corruption: \(actual) != \(expected)")
        }
    }
    print("PASS: \(mode) asynchronous encode, shared-queue texture reuse, center and border pixels")
}
let samples = metrics.snapshot()!.samples
precondition(samples.count == 12)
precondition(Set(samples.compactMap(\.frame)).count == 6)
precondition(!samples.contains { $0.interval.metric == .receiveToPresentation })
print("PASS: actual Metal GPU timestamps correlated to six frames; no presentation inferred")
