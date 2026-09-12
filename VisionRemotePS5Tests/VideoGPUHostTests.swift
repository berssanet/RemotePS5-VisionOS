import Foundation
import Metal
import MetalFX
import CoreVideo

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let metalFX = MetalFXUpscaler()!
let enhanced = EnhancedUpscaler()!
let metrics = StreamingMetricsRecorder()
let session = metrics.beginSession()
for mode in ["MetalFX", "Enhanced"] {
    var submissions: [(MTLCommandBuffer, MTLBuffer, UInt8, VideoFrameMetrics)] = []
    let expectedOwnedCount = mode == "MetalFX" ? 1 : 2
    let initialOwnedBytes = mode == "MetalFX" ? metalFX.ownedTextureBytes : enhanced.ownedTextureBytes
    precondition(initialOwnedBytes > 0, "\(mode) must report allocated persistent texture bytes")
    var firstOutput: ObjectIdentifier?
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
        let outputIdentity = ObjectIdentifier(texture)
        if let firstOutput {
            precondition(outputIdentity == firstOutput, "\(mode) must reuse its persistent output texture")
        } else {
            firstOutput = outputIdentity
        }
        let ownedCount = mode == "MetalFX" ? metalFX.ownedTextureCount : enhanced.ownedTextureCount
        let ownedBytes = mode == "MetalFX" ? metalFX.ownedTextureBytes : enhanced.ownedTextureBytes
        precondition(ownedCount == expectedOwnedCount, "\(mode) persistent texture count must remain bounded")
        precondition(ownedBytes == initialOwnedBytes, "\(mode) persistent texture bytes must remain stable")
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
    let completedOwnedCount = mode == "MetalFX" ? metalFX.ownedTextureCount : enhanced.ownedTextureCount
    let completedOwnedBytes = mode == "MetalFX" ? metalFX.ownedTextureBytes : enhanced.ownedTextureBytes
    precondition(completedOwnedCount == expectedOwnedCount && completedOwnedBytes == initialOwnedBytes,
        "\(mode) persistent texture accounting must remain stable after GPU completion")
    print("PASS: \(mode) asynchronous encode, shared-queue texture reuse, center and border pixels")
    print("PASS: \(mode) output identity reused, ownedTextures=\(completedOwnedCount), stableOwnedBytes=\(completedOwnedBytes)")
}
let samples = metrics.snapshot()!.samples
precondition(samples.count == 12)
precondition(Set(samples.compactMap(\.frame)).count == 6)
precondition(!samples.contains { $0.interval.metric == .receiveToPresentation })
print("PASS: actual Metal GPU timestamps correlated to six frames; no presentation inferred")

// Synthetic chart only: fine detail, gradients, and different colored corners
// catch a stale frame, a mirrored UV, and double sRGB encoding independently.
func chartPixel(_ x: Int, _ y: Int) -> [UInt8] {
    if x < 80 && y < 80 { return [16, 80, 224, 255] }
    if x >= 1840 && y < 80 { return [224, 40, 16, 255] }
    if x < 80 && y >= 1000 { return [24, 208, 48, 255] }
    let detail = ((x + y) % 2) * 40
    return [UInt8(48 + y % 128), UInt8(32 + x % 96), UInt8(32 + (x / 8 + y / 8) % 160 + detail), 255]
}

var chartPixelBuffer: CVPixelBuffer?
precondition(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
    [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
    &chartPixelBuffer) == kCVReturnSuccess)
let chart = chartPixelBuffer!
CVPixelBufferLockBaseAddress(chart, [])
let chartBytes = CVPixelBufferGetBaseAddress(chart)!.assumingMemoryBound(to: UInt8.self)
let chartStride = CVPixelBufferGetBytesPerRow(chart)
for y in 0..<1080 {
    for x in 0..<1920 {
        let pixel = chartPixel(x, y)
        for c in 0..<4 { chartBytes[y * chartStride + x * 4 + c] = pixel[c] }
    }
}
CVPixelBufferUnlockBaseAddress(chart, [])
let chartFrame = VideoFrameMailbox.Frame(pixelBuffer: chart, receivedAt: 1, id: 100,
                                         metrics: nil, session: session)

struct ProcessorReadback {
    let buffer: MTLBuffer
    let width: Int
    let height: Int
    let result: VideoProcessingResult
    func byte(_ x: Int, _ y: Int, _ c: Int) -> Int {
        Int(buffer.contents().assumingMemoryBound(to: UInt8.self)[(y * width + x) * 4 + c])
    }
}

func renderChart(_ processor: VideoFrameProcessor, state: VideoFrameMailbox.State,
                 format: MTLPixelFormat = .bgra8Unorm,
                 width: Int = 3840, height: Int = 2160) -> ProcessorReadback {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
        width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    let target = device.makeTexture(descriptor: descriptor)!
    let command = queue.makeCommandBuffer()!
    let result = processor.encode(frame: state.frame ?? chartFrame, state: state,
                                   commandBuffer: command, target: target)!
    let readback = device.makeBuffer(length: width * height * 4, options: .storageModeShared)!
    let blit = command.makeBlitCommandEncoder()!
    blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback,
        destinationOffset: 0, destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted() // Synthetic fixture readback only.
    precondition(command.status == .completed, "Processor command must complete")
    return ProcessorReadback(buffer: readback, width: width, height: height, result: result)
}

let nativeProcessor = VideoFrameProcessor(device: device, thermalState: { .nominal })!
var nativeState = VideoFrameMailbox.State()
nativeState.enabled = true
nativeState.comparisonEnabled = true // Remembered preference must not divide Native mode.
let nativeIdentity = renderChart(nativeProcessor, state: nativeState, width: 1920, height: 1080)
let nativeSRGB = renderChart(nativeProcessor, state: nativeState, format: .bgra8Unorm_srgb,
                             width: 1920, height: 1080)
precondition(nativeIdentity.result.appliedMode == .native && nativeIdentity.result.ownedTextureCount == 0)
precondition(!nativeIdentity.result.status.contains("Same frame"))
var identityPoints = 0
for y in stride(from: 0, to: 1080, by: 17) {
    for x in stride(from: 0, to: 1920, by: 13) {
        let expected = chartPixel(x, y)
        for c in 0..<4 {
            precondition(abs(nativeIdentity.byte(x, y, c) - Int(expected[c])) <= 1,
                         "Native 1:1 rendering must preserve source channels and orientation")
            precondition(abs(nativeSRGB.byte(x, y, c) - nativeIdentity.byte(x, y, c)) <= 1,
                         "sRGB target must preserve encoded SDR bytes, without double gamma")
        }
        identityPoints += 1
    }
}
print("PASS: Native source fidelity and sRGB/plain target byte parity at \(identityPoints) chart locations")
let native4K = renderChart(nativeProcessor, state: nativeState)

for mode: UpscalerType in [.metalFX, .enhanced] {
    autoreleasepool {
        let processor = VideoFrameProcessor(device: device, thermalState: { .nominal })!
        var selectedState = VideoFrameMailbox.State()
        selectedState.enabled = true
        selectedState.mode = mode
        selectedState.sharpness = mode == .metalFX ? 0 : 0.5
        let selected = renderChart(processor, state: selectedState)
        precondition(selected.result.appliedMode == mode, "Host GPU must apply the requested test mode")
        var splitState = selectedState
        splitState.comparisonEnabled = true
        splitState.comparisonPosition = 0.37
        let split = renderChart(processor, state: splitState)
        let splitSRGB = renderChart(processor, state: splitState, format: .bgra8Unorm_srgb)
        precondition(split.result.reusedOutput && split.result.ownedTextureCount == (mode == .metalFX ? 1 : 2))
        precondition(split.result.ownedTextureBytes == selected.result.ownedTextureBytes)
        precondition(split.result.status.contains("Same frame") && split.result.status.contains("Display target 3840×2160"))
        var checked = 0
        var changed = 0
        let dividerX = Float(split.width) * splitState.comparisonPosition
        for y in stride(from: 0, to: split.height, by: 17) {
            for x in stride(from: 0, to: split.width, by: 13) {
                guard abs(Float(x) + 0.5 - dividerX) > 2 else { continue }
                let expected = Float(x) + 0.5 < dividerX ? native4K : selected
                var differs = false
                for c in 0..<4 {
                    precondition(abs(split.byte(x, y, c) - expected.byte(x, y, c)) <= 1,
                                 "Split must use the matching Native/processed reference of the same frame")
                    precondition(abs(splitSRGB.byte(x, y, c) - split.byte(x, y, c)) <= 1,
                                 "Cinema sRGB split must preserve window split colors")
                    differs = differs || abs(selected.byte(x, y, c) - native4K.byte(x, y, c)) > 1
                }
                if differs { changed += 1 }
                checked += 1
            }
        }
        precondition(changed > 100, "Detail chart must expose real processing differences")
        // Endpoint positions are full-frame references, without a divider.
        for endpoint: Float in [0, 1] {
            splitState.comparisonPosition = endpoint
            let entireSide = renderChart(processor, state: splitState)
            let expected = endpoint == 0 ? selected : native4K
            for (x, y) in [(0, 0), (1, 1079), (1919, 1080), (3838, 2158), (3839, 2159)] {
                for c in 0..<4 {
                    precondition(abs(entireSide.byte(x, y, c) - expected.byte(x, y, c)) <= 1,
                                 "Split endpoints must expose the entire requested side")
                }
            }
        }
        for zoom: Float in [2, 4] {
            autoreleasepool {
                selectedState.inspectionZoom = zoom
                selectedState.inspectionCenter = SIMD2<Float>(0.75, 0.25)
                let zoomedSelected = renderChart(processor, state: selectedState)
                var zoomedNativeState = selectedState
                zoomedNativeState.mode = .native
                let zoomedNative = renderChart(nativeProcessor, state: zoomedNativeState)
                splitState = selectedState
                splitState.comparisonEnabled = true
                splitState.comparisonPosition = 0.37
                let zoomedSplit = renderChart(processor, state: splitState)
                let zoomedSRGB = renderChart(processor, state: splitState, format: .bgra8Unorm_srgb)
                var cropPoints = 0
                for y in stride(from: 0, to: zoomedSplit.height, by: 43) {
                    for x in stride(from: 0, to: zoomedSplit.width, by: 47) {
                        guard abs(Float(x) + 0.5 - dividerX) > 2 else { continue }
                        let expected = Float(x) + 0.5 < dividerX ? zoomedNative : zoomedSelected
                        // Independent bilinear source reference verifies the
                        // requested crop, beyond comparing two shader outputs.
                        let u = (Float(x) + 0.5) / Float(zoomedNative.width)
                        let v = (Float(y) + 0.5) / Float(zoomedNative.height)
                        let sx = ((u - 0.5) / zoom + 0.75) * 1920 - 0.5
                        let sy = ((v - 0.5) / zoom + 0.25) * 1080 - 0.5
                        let x0 = Int(floor(sx)), y0 = Int(floor(sy))
                        let fx = sx - Float(x0), fy = sy - Float(y0)
                        func source(_ dx: Int, _ dy: Int, _ channel: Int) -> Float {
                            Float(chartPixel(min(max(x0 + dx, 0), 1919), min(max(y0 + dy, 0), 1079))[channel])
                        }
                        for c in 0..<4 {
                            precondition(abs(zoomedSplit.byte(x, y, c) - expected.byte(x, y, c)) <= 1,
                                         "Native and processed halves must use exactly the same inspection crop")
                            precondition(abs(zoomedSRGB.byte(x, y, c) - zoomedSplit.byte(x, y, c)) <= 1,
                                         "Inspection crop must preserve sRGB/window byte parity")
                            let top = source(0, 0, c) * (1 - fx) + source(1, 0, c) * fx
                            let bottom = source(0, 1, c) * (1 - fx) + source(1, 1, c) * fx
                            let expectedNative = Int((top * (1 - fy) + bottom * fy).rounded())
                            precondition(abs(zoomedNative.byte(x, y, c) - expectedNative) <= 1,
                                         "Zoom/center must match the independently calculated source crop")
                        }
                        cropPoints += 1
                    }
                }
                print("PASS: \(mode.rawValue) \(Int(zoom))x common crop, \(cropPoints) independent source/split/sRGB locations")
            }
        }
        print("PASS: \(mode.rawValue) same-frame split, \(checked) reference locations, \(changed) detail differences, endpoint fidelity and sRGB parity")
    }
}

let hotProcessor = VideoFrameProcessor(device: device, thermalState: { .serious })!
var hotState = nativeState
hotState.mode = .enhanced
let protected = renderChart(hotProcessor, state: hotState, width: 1920, height: 1080)
precondition(protected.result.appliedMode == .native && protected.result.ownedTextureCount == 0)
precondition(protected.result.status.contains("Temperature protection") && protected.result.status.contains("Native | Native"))
for (x, y) in [(0, 0), (100, 500), (1919, 1079)] {
    for c in 0..<4 { precondition(abs(protected.byte(x, y, c) - nativeIdentity.byte(x, y, c)) <= 1) }
}
print("PASS: injected thermal pressure selects Native without allocating upscaler textures")

#if VIDEO_GPU_TESTING
for failedPass in [1, 2] {
    let failing = EnhancedUpscaler(device: device)!
    var encoderCalls = 0
    failing.makeEncoderForTesting = { command in
        encoderCalls += 1
        return encoderCalls == failedPass ? nil : command.makeComputeCommandEncoder()
    }
    let command = queue.makeCommandBuffer()!
    precondition(failing.encode(chart, commandBuffer: command) == nil,
                 "A missing encoder must never return a stale output as successful")
    precondition(encoderCalls == failedPass)
    command.commit()
    command.waitUntilCompleted()
    precondition(command.status == .completed,
                 "Work encoded before the failed second pass remains valid and retains its input")
}
print("PASS: Enhanced first/second encoder failure returns nil with valid partial-command lifetime")
#endif

let gatedMailbox = VideoFrameMailbox()
gatedMailbox.configure(enabled: true, mode: .enhanced, sharpness: 0.5,
                       comparisonEnabled: true, comparisonPosition: 0.37)
gatedMailbox.beginSession(session)
gatedMailbox.submit(chart, timestamp: 1, session: session)
let retainedID = gatedMailbox.snapshot().frame!.id
let windowConsumer = UUID(), cinemaConsumer = UUID()
gatedMailbox.selectConsumer(windowConsumer)
precondition(gatedMailbox.isSelectedConsumer(windowConsumer))
precondition(!gatedMailbox.isSelectedConsumer(nil) && !gatedMailbox.isSelectedConsumer(cinemaConsumer))
precondition(!gatedMailbox.acquireForRendering().enabled)
precondition(gatedMailbox.acquireForRendering(consumerID: cinemaConsumer).frame == nil)
precondition(gatedMailbox.diagnostics.acquiredFrames == 0, "Denied consumers cannot mark acquisition")
precondition(gatedMailbox.acquireForRendering(consumerID: windowConsumer).frame?.id == retainedID)
gatedMailbox.selectConsumer(cinemaConsumer)
precondition(gatedMailbox.acquireForRendering(consumerID: windowConsumer).frame == nil)
precondition(gatedMailbox.acquireForRendering(consumerID: cinemaConsumer).frame?.id == retainedID)
precondition(gatedMailbox.diagnostics.acquiredFrames == 1, "Handoff reuses the same retained frame")
precondition(gatedMailbox.snapshot().comparisonEnabled && gatedMailbox.snapshot().comparisonPosition == 0.37)
gatedMailbox.selectConsumer(nil)
precondition(!gatedMailbox.isSelectedConsumer(nil) && !gatedMailbox.isSelectedConsumer(cinemaConsumer))
precondition(gatedMailbox.snapshot().frame?.id == retainedID, "Revoking rendering preserves the latest decoded frame")
gatedMailbox.beginSession(StreamingMetricsRecorder().beginSession())
precondition(!gatedMailbox.isSelectedConsumer(nil), "Session reset cannot reopen the legacy bypass")
for position: Float in [-1, 2, .nan, .infinity] {
    gatedMailbox.configure(enabled: true, mode: .enhanced, sharpness: 0.5,
                           comparisonEnabled: true, comparisonPosition: position)
    let clamped = gatedMailbox.snapshot().comparisonPosition
    precondition(clamped.isFinite && (0...1).contains(clamped))
}
print("PASS: exclusive consumer gate, nil revocation, same-frame handoff and bounded comparison controls")

var nonfiniteInspection = nativeState
nonfiniteInspection.inspectionZoom = .nan
nonfiniteInspection.inspectionCenter = SIMD2<Float>(.nan, .infinity)
let defaultInspection = renderChart(nativeProcessor, state: nonfiniteInspection, width: 1920, height: 1080)
var edgeInspection = nativeState
edgeInspection.inspectionZoom = 4
edgeInspection.inspectionCenter = SIMD2<Float>(-100, 100)
let edgeCrop = renderChart(nativeProcessor, state: edgeInspection, width: 1920, height: 1080)
for (x, y) in [(0, 0), (80, 100), (959, 539), (1919, 1079)] {
    for c in 0..<4 {
        precondition(abs(defaultInspection.byte(x, y, c) - nativeIdentity.byte(x, y, c)) <= 1,
                     "Invalid inspection controls render the centered 1x image")
    }
}
precondition(edgeCrop.result.status.contains("Detail 4×"))
// Both lower-left source/output corners are solid green in this chart. A
// clamped crop must reach that source corner, without wrap or an empty border.
for c in 0..<4 {
    precondition(abs(edgeCrop.byte(0, 1079, c) - Int(chartPixel(0, 1079)[c])) <= 1)
}

let freezeMailbox = VideoFrameMailbox()
freezeMailbox.beginSession(session)
freezeMailbox.configure(enabled: true, mode: .enhanced, sharpness: 0.5,
    comparisonEnabled: true, comparisonPosition: 0.37, inspectionZoom: 4,
    inspectionCenter: SIMD2<Float>(0.75, 0.25))
freezeMailbox.submit(chart, timestamp: 1, session: session)
precondition(freezeMailbox.setInspectionFrozen(true))
let frozenFrameID = freezeMailbox.snapshotForRendering().frame!.id
let frozenProcessor = VideoFrameProcessor(device: device, thermalState: { .nominal })!
let frozenBefore = renderChart(frozenProcessor, state: freezeMailbox.acquireForRendering())
var differentPixelBuffer: CVPixelBuffer?
precondition(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA,
    [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
    &differentPixelBuffer) == kCVReturnSuccess)
let different = differentPixelBuffer!
CVPixelBufferLockBaseAddress(different, [])
memset(CVPixelBufferGetBaseAddress(different)!, 255, CVPixelBufferGetDataSize(different))
CVPixelBufferUnlockBaseAddress(different, [])
for index in 2...101 { freezeMailbox.submit(different, timestamp: UInt64(index), session: session) }
let frozenAfterState = freezeMailbox.acquireForRendering()
precondition(frozenAfterState.frame?.id == frozenFrameID && frozenAfterState.frame?.metrics == nil)
let frozenAfter = renderChart(frozenProcessor, state: frozenAfterState, format: .bgra8Unorm_srgb)
precondition(frozenAfter.result.status.contains("Frozen image") && frozenAfter.result.status.contains("Detail 4×"))
for y in stride(from: 0, to: 2160, by: 43) {
    for x in stride(from: 0, to: 3840, by: 47) {
        for c in 0..<4 {
            precondition(abs(frozenAfter.byte(x, y, c) - frozenBefore.byte(x, y, c)) <= 1,
                         "A hundred new frames cannot change the frozen inspection pixels")
        }
    }
}
precondition(freezeMailbox.diagnostics.inspectionFrameCount == 1)
precondition(freezeMailbox.diagnostics.acquiredFrames == 1)
freezeMailbox.setInspectionFrozen(false)
let resumed = freezeMailbox.acquireForRendering()
precondition(resumed.frame?.id != frozenFrameID && !resumed.isInspectionFrozen)
let resumedImage = renderChart(nativeProcessor, state: resumed, width: 1920, height: 1080)
precondition(resumedImage.byte(100, 100, 0) == 255 && freezeMailbox.diagnostics.inspectionFrameCount == 0)
print("PASS: frozen GPU pixels stay fixed across 100 live frames; resume releases the additional image and renders latest")

// Real low-resolution decoder dimensions, not a reduced crop of a 1080p frame.
// Spatial output is at least 2x the source and grows to match a larger drawable.
func lowResolutionPixel(_ x: Int, _ y: Int, width: Int, height: Int) -> SIMD4<UInt8> {
    if x < 24 && y < 24 { return SIMD4(12, 72, 220, 255) }
    if x >= width - 24 && y < 24 { return SIMD4(216, 44, 12, 255) }
    if x < 24 && y >= height - 24 { return SIMD4(20, 204, 48, 255) }
    if x >= width - 24 && y >= height - 24 { return SIMD4(128, 24, 180, 255) }
    return SIMD4(UInt8(32 + y % 160), UInt8(32 + x % 160),
                 UInt8((x / 3 + y / 3) % 2 == 0 ? 32 : 224), 255)
}

func lowResolutionFrame(width: Int, height: Int, value: UInt8? = nil) -> VideoFrameMailbox.Frame {
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &buffer) == kCVReturnSuccess)
    let pixel = buffer!
    CVPixelBufferLockBaseAddress(pixel, [])
    let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
    for y in 0..<height {
        for x in 0..<width {
            let source = value.map { SIMD4<UInt8>($0, $0, $0, 255) }
                ?? lowResolutionPixel(x, y, width: width, height: height)
            for c in 0..<4 { bytes[y * rowBytes + x * 4 + c] = source[c] }
        }
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    return VideoFrameMailbox.Frame(pixelBuffer: pixel, receivedAt: 1, id: UInt64(width), metrics: nil, session: nil)
}

for (width, height) in [(640, 360), (960, 540), (1280, 720)] {
    autoreleasepool {
        let processor = VideoFrameProcessor(device: device, thermalState: { .nominal })!
        var state = VideoFrameMailbox.State()
        state.enabled = true
        state.mode = .native
        state.frame = lowResolutionFrame(width: width, height: height)
        let outputWidth = width * 2, outputHeight = height * 2
        let original = renderChart(processor, state: state, width: outputWidth, height: outputHeight)
        state.mode = .metalFX
        state.sharpness = 0 // Preserve the pure MetalFX reference for this test.
        let upscaled = renderChart(processor, state: state, width: outputWidth, height: outputHeight)
        precondition(upscaled.result.appliedMode == .metalFX && !upscaled.result.reusedOutput)
        precondition(upscaled.result.ownedTextureCount == 1 && upscaled.result.ownedTextureBytes > 0)
        precondition(upscaled.result.status.contains("Source \(width)×\(height) → Output texture \(outputWidth)×\(outputHeight)"),
                     "MetalFX must report actual decoded dimensions and 2x processing dimensions")
        state.comparisonEnabled = true
        state.comparisonPosition = 0.37
        let split = renderChart(processor, state: state, width: outputWidth, height: outputHeight)
        let splitSRGB = renderChart(processor, state: state, format: .bgra8Unorm_srgb,
                                    width: outputWidth, height: outputHeight)
        precondition(split.result.reusedOutput && splitSRGB.result.reusedOutput)
        precondition(split.result.ownedTextureBytes == upscaled.result.ownedTextureBytes)
        var referencePoints = 0
        var changed = 0
        for y in stride(from: 0, to: outputHeight, by: 17) {
            for x in stride(from: 0, to: outputWidth, by: 13) {
                guard abs(Float(x) + 0.5 - Float(outputWidth) * state.comparisonPosition) > 2 else { continue }
                let sourceX = (Double(x) + 0.5) / 2 - 0.5
                let sourceY = (Double(y) + 0.5) / 2 - 0.5
                let baseX = Int(floor(sourceX)), baseY = Int(floor(sourceY))
                let fractionX = sourceX - floor(sourceX), fractionY = sourceY - floor(sourceY)
                func channel(_ dx: Int, _ dy: Int, _ c: Int) -> Double {
                    Double(lowResolutionPixel(min(max(baseX + dx, 0), width - 1),
                                              min(max(baseY + dy, 0), height - 1),
                                              width: width, height: height)[c])
                }
                let reference = Float(x) + 0.5 < Float(outputWidth) * state.comparisonPosition ? original : upscaled
                var differs = false
                for c in 0..<4 {
                    let top = channel(0, 0, c) * (1 - fractionX) + channel(1, 0, c) * fractionX
                    let bottom = channel(0, 1, c) * (1 - fractionX) + channel(1, 1, c) * fractionX
                    let expected = Int((top * (1 - fractionY) + bottom * fractionY).rounded())
                    precondition(abs(original.byte(x, y, c) - expected) <= 1,
                                 "Original must match an independent bilinear reference of the low-resolution source")
                    precondition(abs(split.byte(x, y, c) - reference.byte(x, y, c)) <= 1,
                                 "Low-resolution split must use the same original/upscaled frame")
                    precondition(abs(splitSRGB.byte(x, y, c) - split.byte(x, y, c)) <= 1,
                                 "Low-resolution cinema sRGB and window SDR must match")
                    differs = differs || abs(upscaled.byte(x, y, c) - original.byte(x, y, c)) > 1
                }
                if differs { changed += 1 }
                referencePoints += 1
            }
        }
        precondition(changed > 100, "Low-resolution synthetic detail must expose MetalFX processing")
        for (x, y) in [(0, 0), (outputWidth - 1, 0), (0, outputHeight - 1), (outputWidth - 1, outputHeight - 1)] {
            let expected = lowResolutionPixel(x / 2, y / 2, width: width, height: height)
            for c in 0..<4 {
                precondition(abs(upscaled.byte(x, y, c) - Int(expected[c])) <= 3,
                             "Low-resolution output must preserve nonempty colored corners and orientation")
            }
        }
        // Drawables below the 2x minimum share the same effective output size.
        let resized = renderChart(processor, state: state, width: 960, height: 540)
        precondition(resized.result.reusedOutput && resized.result.ownedTextureBytes == upscaled.result.ownedTextureBytes)
        precondition(resized.result.status.contains("Output texture \(outputWidth)×\(outputHeight) · Display target 960×540"))
        state.mode = .enhanced
        let unavailableEnhanced = renderChart(processor, state: state, width: outputWidth, height: outputHeight)
        precondition(unavailableEnhanced.result.appliedMode == .native)
        precondition(unavailableEnhanced.result.status.contains("Enhanced requires a 1080p source; showing Original"))
        precondition(unavailableEnhanced.result.ownedTextureCount == 1,
                     "Selecting unsupported Enhanced must not allocate its 4K textures")
        for (x, y) in [(0, 0), (outputWidth / 2, outputHeight / 2), (outputWidth - 1, outputHeight - 1)] {
            for c in 0..<4 {
                precondition(abs(unavailableEnhanced.byte(x, y, c) - original.byte(x, y, c)) <= 1,
                             "Unsupported Enhanced must display current Original pixels on both sides")
            }
        }
        print("PASS: \(width)×\(height)→\(outputWidth)×\(outputHeight) MetalFX, \(referencePoints) independent bilinear/split/sRGB locations, \(changed) detail differences, stable drawable-resize resources and explicit Enhanced fallback")
    }
}

// An independent MetalFX API reference bypasses both production wrappers and
// the final VideoFrameProcessor shader. It proves which pixels reach the target,
// not whether a processed image is subjectively better than its source.
func directMetalFXReference(_ frame: VideoFrameMailbox.Frame, width: Int, height: Int) -> MTLBuffer {
    let descriptor = MTLFXSpatialScalerDescriptor()
    descriptor.inputWidth = CVPixelBufferGetWidth(frame.pixelBuffer)
    descriptor.inputHeight = CVPixelBufferGetHeight(frame.pixelBuffer)
    descriptor.outputWidth = width
    descriptor.outputHeight = height
    descriptor.colorTextureFormat = .bgra8Unorm
    descriptor.outputTextureFormat = .bgra8Unorm
    descriptor.colorProcessingMode = .perceptual
    let scaler = descriptor.makeSpatialScaler(device: device)!
    var cache: CVMetalTextureCache?
    precondition(CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess)
    var wrapper: CVMetalTexture?
    precondition(CVMetalTextureCacheCreateTextureFromImage(nil, cache!, frame.pixelBuffer,
        [kCVMetalTextureUsage: scaler.colorTextureUsage.rawValue] as CFDictionary,
        .bgra8Unorm, descriptor.inputWidth, descriptor.inputHeight, 0, &wrapper) == kCVReturnSuccess)
    let input = CVMetalTextureGetTexture(wrapper!)!
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: width, height: height, mipmapped: false)
    textureDescriptor.storageMode = .private
    textureDescriptor.usage = scaler.outputTextureUsage.union(.shaderRead)
    let output = device.makeTexture(descriptor: textureDescriptor)!
    scaler.colorTexture = input
    scaler.inputContentWidth = descriptor.inputWidth
    scaler.inputContentHeight = descriptor.inputHeight
    scaler.outputTexture = output
    let command = queue.makeCommandBuffer()!
    scaler.encode(commandBuffer: command)
    let bytes = device.makeBuffer(length: width * height * 4, options: .storageModeShared)!
    let blit = command.makeBlitCommandEncoder()!
    blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
              sourceSize: .init(width: width, height: height, depth: 1), to: bytes,
              destinationOffset: 0, destinationBytesPerRow: width * 4,
              destinationBytesPerImage: width * height * 4)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted() // Test-only; retain every API resource through completion.
    withExtendedLifetime((scaler, cache, wrapper, input, output, frame.pixelBuffer)) {}
    precondition(command.status == .completed, "Independent direct MetalFX reference must complete")
    return bytes
}

func bufferByte(_ buffer: MTLBuffer, width: Int, x: Int, y: Int, channel: Int) -> Int {
    Int(buffer.contents().assumingMemoryBound(to: UInt8.self)[(y * width + x) * 4 + channel])
}

func bilinearReference(sourceWidth: Int, sourceHeight: Int, targetWidth: Int, targetHeight: Int,
                       x: Int, y: Int, channel: Int, source: (Int, Int, Int) -> Int) -> Int {
    let sx = (Double(x) + 0.5) * Double(sourceWidth) / Double(targetWidth) - 0.5
    let sy = (Double(y) + 0.5) * Double(sourceHeight) / Double(targetHeight) - 0.5
    let x0 = Int(floor(sx)), y0 = Int(floor(sy))
    let fx = sx - floor(sx), fy = sy - floor(sy)
    func value(_ dx: Int, _ dy: Int) -> Double {
        Double(source(min(max(x0 + dx, 0), sourceWidth - 1),
                      min(max(y0 + dy, 0), sourceHeight - 1), channel))
    }
    let top = value(0, 0) * (1 - fx) + value(1, 0) * fx
    let bottom = value(0, 1) * (1 - fx) + value(1, 1) * fx
    return Int((top * (1 - fy) + bottom * fy).rounded())
}

autoreleasepool {
    let processor = VideoFrameProcessor(device: device, thermalState: { .nominal })!
    var state = VideoFrameMailbox.State()
    state.enabled = true
    state.frame = lowResolutionFrame(width: 640, height: 360)
    let original = renderChart(processor, state: state, width: 2560, height: 1440)
    state.mode = .metalFX
    state.sharpness = 0 // Preserve the pure MetalFX reference for this test.
    let full = renderChart(processor, state: state, width: 2560, height: 1440)
    let srgb = renderChart(processor, state: state, format: .bgra8Unorm_srgb, width: 2560, height: 1440)
    let direct = directMetalFXReference(state.frame!, width: 2560, height: 1440)
    let intermediate720 = directMetalFXReference(state.frame!, width: 1280, height: 720)
    precondition(full.result.appliedMode == .metalFX && !full.result.reusedOutput && srgb.result.reusedOutput)
    precondition(full.result.status.contains("Output texture 2560×1440 · Display target 2560×1440"))
    state.comparisonEnabled = true
    state.comparisonPosition = 0.37
    let split = renderChart(processor, state: state, width: 2560, height: 1440)
    let splitSRGB = renderChart(processor, state: state, format: .bgra8Unorm_srgb, width: 2560, height: 1440)
    var locations = 0, differsFromOriginal = 0, differsFromIntermediate = 0
    for y in stride(from: 0, to: 1440, by: 17) {
        for x in stride(from: 0, to: 2560, by: 13) {
            guard abs(Float(x) + 0.5 - 2560 * state.comparisonPosition) > 2 else { continue }
            var originalDifference = false, intermediateDifference = false
            for c in 0..<4 {
                let directByte = bufferByte(direct, width: 2560, x: x, y: y, channel: c)
                let expectedOriginal = bilinearReference(sourceWidth: 640, sourceHeight: 360,
                    targetWidth: 2560, targetHeight: 1440, x: x, y: y, channel: c) {
                        Int(lowResolutionPixel($0, $1, width: 640, height: 360)[$2])
                    }
                let legacyByte = bilinearReference(sourceWidth: 1280, sourceHeight: 720,
                    targetWidth: 2560, targetHeight: 1440, x: x, y: y, channel: c) {
                        bufferByte(intermediate720, width: 1280, x: $0, y: $1, channel: $2)
                    }
                precondition(abs(original.byte(x, y, c) - expectedOriginal) <= 1,
                             "640→2560 Original must match independent bilinear source sampling")
                precondition(abs(full.byte(x, y, c) - directByte) <= 1,
                             "Final pixels must be direct 640→2560 MetalFX, not 640→1280 then bilinear")
                precondition(abs(srgb.byte(x, y, c) - directByte) <= 1,
                             "Direct-size MetalFX must preserve encoded SDR colors on an sRGB target")
                let expectedSplit = Float(x) + 0.5 < 2560 * state.comparisonPosition ? expectedOriginal : directByte
                precondition(abs(split.byte(x, y, c) - expectedSplit) <= 1,
                             "The split must choose independent original/direct-MetalFX references of one frame")
                precondition(abs(splitSRGB.byte(x, y, c) - expectedSplit) <= 1,
                             "The same-frame split must preserve both independent references in sRGB")
                originalDifference = originalDifference || abs(directByte - expectedOriginal) > 2
                intermediateDifference = intermediateDifference || abs(directByte - legacyByte) > 2
            }
            if originalDifference { differsFromOriginal += 1 }
            if intermediateDifference { differsFromIntermediate += 1 }
            locations += 1
        }
    }
    precondition(differsFromOriginal > 100 && differsFromIntermediate > 100,
                 "The synthetic chart must distinguish direct MetalFX from Original and the former two-stage path")
    for (x, y) in [(0, 0), (2559, 0), (0, 1439), (2559, 1439)] {
        for c in 0..<4 {
            precondition(abs(full.byte(x, y, c) - bufferByte(direct, width: 2560, x: x, y: y, channel: c)) <= 1,
                         "Direct-size processing must also preserve the reference at all four borders")
        }
    }
    print("PASS: 640×360→2560×1440 final pixels match independent direct MetalFX at \(locations) locations; Original/split/sRGB verified; differences validate the fixture, not visual quality")
}

// Explicit policy examples cover rounding, aspect preservation and a bounded
// allocation even for hostile target dimensions; they don't allocate textures.
for (sourceW, sourceH, targetW, targetH, expectedW, expectedH) in [
    (640, 360, 2560, 1440, 2560, 1440),
    (640, 360, 2561, 1440, 2576, 1449),
    (640, 360, 1000, 1000, 1792, 1008),
    (640, 360, 5000, 2800, 3840, 2160),
    (640, 360, Int.max, Int.max, 3840, 2160),
    (640, 480, 2560, 1440, 2560, 1920),
    (1920, 1080, 1920, 1080, 3840, 2160)
] {
    let dimensions = MetalFXUpscaler.outputDimensions(inputWidth: sourceW, inputHeight: sourceH,
                                                      targetWidth: targetW, targetHeight: targetH)
    precondition(dimensions?.width == expectedW && dimensions?.height == expectedH,
                 "Output must cover the target at a minimum 2x source, preserve aspect, and remain within 4K")
}
for (sourceW, sourceH, targetW, targetH) in [
    (0, 360, 1280, 720), (-1, 360, 1280, 720), (Int.max, 360, 1280, 720),
    (640, 360, 0, 720), (640, 360, 1280, -1), (2048, 1152, 1280, 720)
] {
    precondition(MetalFXUpscaler.outputDimensions(inputWidth: sourceW, inputHeight: sourceH,
        targetWidth: targetW, targetHeight: targetH) == nil,
        "Invalid dimensions or a 2x minimum outside the allocation ceiling must not create a scaler")
}

// Invalid dimensions must fail before multiplying or allocating a texture.
for (inputWidth, inputHeight, outputWidth, outputHeight) in [
    (0, 360, 1280, 720), (-1, 360, 1280, 720), (Int.max, 360, 1280, 720),
    (640, 360, Int.max, 720), (640, 360, 1280, Int.max),
    (640, 360, 320, 180), (640, 360, 1280, 1080), (2048, 1152, 4096, 2304)
] {
    precondition(MetalFXUpscaler(inputWidth: inputWidth, inputHeight: inputHeight,
                                outputWidth: outputWidth, outputHeight: outputHeight, device: device) == nil,
                 "Malformed, stretched, downscaled or over-budget dimensions must be rejected")
}
autoreleasepool {
    let scaler = MetalFXUpscaler(inputWidth: 640, inputHeight: 360, device: device)!
    precondition(scaler.inputWidth == 640 && scaler.inputHeight == 360 && scaler.outputWidth == 1280 && scaler.outputHeight == 720)
    let wrongSize = lowResolutionFrame(width: 960, height: 540)
    let command = queue.makeCommandBuffer()!
    precondition(scaler.encode(wrongSize.pixelBuffer, commandBuffer: command) == nil,
                 "An immutable scaler must reject a mismatched decoder buffer before encoding")
    var wrongFormat: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32ARGB,
        [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &wrongFormat) == kCVReturnSuccess)
    precondition(scaler.encode(wrongFormat!, commandBuffer: command) == nil,
                 "SDR MetalFX must reject a different channel layout rather than reinterpret it as BGRA")
    command.commit()
    command.waitUntilCompleted()
    precondition(command.status == .completed)
}

#if VIDEO_GPU_TESTING
struct ScalerRequest: Equatable {
    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int
}
autoreleasepool {
    let processor = VideoFrameProcessor(device: device, thermalState: { .nominal })!
    var requests: [ScalerRequest] = []
    processor.makeMetalFXForTesting = { width, height, outputWidth, outputHeight in
        requests.append(ScalerRequest(inputWidth: width, inputHeight: height,
                                      outputWidth: outputWidth, outputHeight: outputHeight))
        return MetalFXUpscaler(inputWidth: width, inputHeight: height,
            outputWidth: outputWidth, outputHeight: outputHeight, device: device)
    }
    var state = VideoFrameMailbox.State()
    state.enabled = true
    state.mode = .metalFX
    state.sharpness = 0 // Preserve the pure MetalFX reference for this test.
    state.frame = lowResolutionFrame(width: 640, height: 360, value: 96)
    let small = renderChart(processor, state: state, width: 1280, height: 720)
    let smallAgain = renderChart(processor, state: state, width: 960, height: 540)
    precondition(requests.count == 1 && smallAgain.result.reusedOutput,
                 "A target below the minimum must reuse the effective 1280×720 output")
    let large = renderChart(processor, state: state, width: 2560, height: 1440)
    precondition(requests.count == 2 && !large.result.reusedOutput,
                 "A growing target must replace the former 720p processing output")
    precondition(large.result.ownedTextureCount == 1 && large.result.ownedTextureBytes > small.result.ownedTextureBytes,
                 "Only the larger persistent output remains owned by the processor")
    let sameEffective = renderChart(processor, state: state, width: 2559, height: 1439)
    precondition(requests.count == 2 && sameEffective.result.reusedOutput,
                 "Drawable jitter yielding the same aspect-rounded output must not recreate the scaler")
    precondition(sameEffective.result.ownedTextureBytes == large.result.ownedTextureBytes)
    let rounded = renderChart(processor, state: state, width: 2561, height: 1440)
    precondition(requests.count == 3 && !rounded.result.reusedOutput,
                 "Crossing the aspect-rounded size boundary requires a new scaler")
    let smaller = renderChart(processor, state: state, width: 1920, height: 1080)
    precondition(requests.count == 4 && !smaller.result.reusedOutput)
    let smallerAgain = renderChart(processor, state: state, format: .bgra8Unorm_srgb, width: 1920, height: 1080)
    precondition(requests.count == 4 && smallerAgain.result.reusedOutput,
                 "Changing the final target's sRGB format alone must not invalidate the SDR scaler")
    precondition(requests == [
        ScalerRequest(inputWidth: 640, inputHeight: 360, outputWidth: 1280, outputHeight: 720),
        ScalerRequest(inputWidth: 640, inputHeight: 360, outputWidth: 2560, outputHeight: 1440),
        ScalerRequest(inputWidth: 640, inputHeight: 360, outputWidth: 2576, outputHeight: 1449),
        ScalerRequest(inputWidth: 640, inputHeight: 360, outputWidth: 1920, outputHeight: 1080)
    ], "The factory must receive both source and effective output dimensions")
    for image in [small, smallAgain, large, sameEffective, rounded, smaller, smallerAgain] {
        for (x, y) in [(0, 0), (image.width / 2, image.height / 2), (image.width - 1, image.height - 1)] {
            for c in 0..<3 {
                precondition(abs(image.byte(x, y, c) - 96) <= 3,
                             "Every resize must preserve its source pixels, including target edges")
            }
        }
    }
}
autoreleasepool {
    let processor = VideoFrameProcessor(device: device, thermalState: { .nominal })!
    var requests: [ScalerRequest] = []
    processor.makeMetalFXForTesting = { width, height, outputWidth, outputHeight in
        requests.append(ScalerRequest(inputWidth: width, inputHeight: height,
                                      outputWidth: outputWidth, outputHeight: outputHeight))
        // The first effective configuration fails, the next one can succeed.
        guard outputWidth >= 1920 else { return nil }
        return MetalFXUpscaler(inputWidth: width, inputHeight: height,
            outputWidth: outputWidth, outputHeight: outputHeight, device: device)
    }
    var state = VideoFrameMailbox.State()
    state.enabled = true
    state.mode = .metalFX
    state.sharpness = 0 // Preserve the pure MetalFX reference for this test.
    state.frame = lowResolutionFrame(width: 640, height: 360, value: 48)
    for target in [(1280, 720), (960, 540), (1280, 720)] {
        let failed = renderChart(processor, state: state, width: target.0, height: target.1)
        precondition(requests.count == 1 && failed.result.appliedMode == .native && failed.result.ownedTextureCount == 0,
                     "Failed creation must remain cached while the effective input/output configuration is unchanged")
    }
    let recovered = renderChart(processor, state: state, width: 2560, height: 1440)
    precondition(requests.count == 2 && recovered.result.appliedMode == .metalFX && !recovered.result.reusedOutput,
                 "A changed effective output permits a fresh attempt and recovery")
    state.frame = lowResolutionFrame(width: 640, height: 360, value: 192)
    for target in [(1280, 720), (960, 540)] {
        let failedAgain = renderChart(processor, state: state, width: target.0, height: target.1)
        precondition(requests.count == 3 && failedAgain.result.appliedMode == .native && failedAgain.result.ownedTextureCount == 0,
                     "Returning to a different failed configuration drops the old successful output and retries only once")
        for (x, y) in [(0, 0), (target.0 / 2, target.1 / 2), (target.0 - 1, target.1 - 1)] {
            for c in 0..<3 {
                precondition(abs(failedAgain.byte(x, y, c) - 192) <= 1,
                             "Output-size failure must show the new source, never stale pixels from the successful larger target")
            }
        }
    }
}
print("PASS: effective input/output factory identity, growth/shrink, rounded-size reuse, sRGB reuse and bounded creation-failure recovery")

autoreleasepool {
    let processor = VideoFrameProcessor(device: device, thermalState: { .nominal })!
    var attempts = 0
    processor.makeMetalFXForTesting = { _, _, _, _ in attempts += 1; return nil }
    var state = VideoFrameMailbox.State()
    state.enabled = true
    state.mode = .metalFX
    state.sharpness = 0 // Preserve the pure MetalFX reference for this test.
    state.frame = lowResolutionFrame(width: 640, height: 360)
    for attempt in 0..<3 {
        let result = renderChart(processor, state: state, width: attempt == 0 ? 1280 : 960, height: attempt == 0 ? 720 : 540)
        precondition(result.result.appliedMode == .native && result.result.ownedTextureCount == 0)
        precondition(result.result.status.contains("MetalFX unavailable for 640×360; showing Original"))
        precondition(attempts == 1, "Failed scaler creation must not retry for every frame or drawable resize")
    }
    state.frame = lowResolutionFrame(width: 960, height: 540)
    let nextSize = renderChart(processor, state: state, width: 1920, height: 1080)
    precondition(attempts == 2 && nextSize.result.appliedMode == .native,
                 "A new decoded size permits one fresh scaler creation attempt")
}
autoreleasepool {
    let processor = VideoFrameProcessor(device: device, thermalState: { .nominal })!
    var attempts = 0
    processor.makeMetalFXForTesting = { width, height, outputWidth, outputHeight in
        attempts += 1
        return width == 640 ? MetalFXUpscaler(inputWidth: width, inputHeight: height,
            outputWidth: outputWidth, outputHeight: outputHeight, device: device) : nil
    }
    var state = VideoFrameMailbox.State()
    state.enabled = true
    state.mode = .metalFX
    state.sharpness = 0 // Preserve the pure MetalFX reference for this test.
    state.frame = lowResolutionFrame(width: 640, height: 360, value: 48)
    let initial = renderChart(processor, state: state, width: 1280, height: 720)
    precondition(initial.result.appliedMode == .metalFX && attempts == 1)
    state.frame = lowResolutionFrame(width: 960, height: 540, value: 192)
    for _ in 0..<3 {
        let fallback = renderChart(processor, state: state, width: 1920, height: 1080)
        precondition(fallback.result.appliedMode == .native && fallback.result.ownedTextureCount == 0 && attempts == 2)
        for (x, y) in [(0, 0), (959, 539), (1919, 1079)] {
            for c in 0..<3 {
                precondition(abs(fallback.byte(x, y, c) - 192) <= 1,
                             "A failed replacement must show the new source, never the last successful scaler output")
            }
        }
    }
}
print("PASS: rejected dimensions, mismatched input and creation failure fall back safely without per-frame retry")
#endif

final class WeakLowResolutionInput {
    weak var buffer: CVPixelBuffer?
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}
var retiredInputs: [WeakLowResolutionInput] = []
for changes: [(Int, Int, Int, Int, UInt8)] in [
    [(640, 360, 1280, 720, 48), (640, 360, 2560, 1440, 192)],
    [(640, 360, 2560, 1440, 48), (960, 540, 1920, 1080, 192)],
    [(640, 360, 2560, 1440, 48), (640, 360, 1280, 720, 192)]
] {
  autoreleasepool {
    var processor: VideoFrameProcessor? = VideoFrameProcessor(device: device, thermalState: { .nominal })!
    var pending: [(MTLCommandBuffer, MTLBuffer, Int, Int, UInt8)] = []
    for (width, height, outputWidth, outputHeight, value) in changes {
        autoreleasepool {
            var state = VideoFrameMailbox.State()
            state.enabled = true
            state.mode = .metalFX
            state.sharpness = 0 // Preserve the pure MetalFX reference for this test.
            let frame = lowResolutionFrame(width: width, height: height, value: value)
            retiredInputs.append(WeakLowResolutionInput(frame.pixelBuffer))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: outputWidth, height: outputHeight, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            let target = device.makeTexture(descriptor: descriptor)!
            let command = queue.makeCommandBuffer()!
            let result = processor!.encode(frame: frame, state: state, commandBuffer: command, target: target)!
            precondition(result.appliedMode == .metalFX && result.ownedTextureCount == 1 && !result.reusedOutput,
                         "Source/output-size change must replace the persistent scaler exactly once")
            let buffer = device.makeBuffer(length: outputWidth * outputHeight * 4, options: .storageModeShared)!
            let blit = command.makeBlitCommandEncoder()!
            blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1), to: buffer,
                      destinationOffset: 0, destinationBytesPerRow: outputWidth * 4,
                      destinationBytesPerImage: outputWidth * outputHeight * 4)
            blit.endEncoding()
            pending.append((command, buffer, outputWidth, outputHeight, value))
        }
    }
    // Retire the renderer-side owner too, before either command is submitted.
    // Completion handlers and encoded work must retain both generations.
    processor = nil
    precondition(retiredInputs.suffix(2).allSatisfy { $0.buffer != nil })
    precondition(pending.count == 2, "Each resize burst stays within the renderer's two-command admission bound")
    pending.forEach { $0.0.commit() }
    for (command, buffer, width, height, value) in pending {
        command.waitUntilCompleted()
        precondition(command.status == .completed, "Source/output resize cannot invalidate in-flight MetalFX work")
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        for (x, y) in [(0, 0), (width / 2, height / 2), (width - 1, height - 1)] {
            for c in 0..<3 {
                precondition(abs(Int(bytes[(y * width + x) * 4 + c]) - Int(value)) <= 3,
                             "Old/new scaler commands must retain their own source and output after source resize")
            }
        }
    }
    pending.removeAll()
  }
}
precondition(retiredInputs.allSatisfy { $0.buffer == nil },
             "Retired source buffers must be released after GPU completion")
print("PASS: source/output growth and shrink plus processor retirement preserve two in-flight generations; retired source buffers release after GPU completion")
