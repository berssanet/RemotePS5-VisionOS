import CoreVideo
import Foundation
import Metal

// Synthetic SDR fixtures only. These checks establish rendering correctness,
// not the accuracy of monocular inference or comfort on a headset.
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let processor = StereoVideoProcessor(device: device) else {
    fatalError("Stereo tests require a Metal device and a compiled stereo pipeline")
}
let width = 512
let height = 288
let targetWidth = width * 2
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    precondition(condition(), message)
}

func chartPixel(_ x: Int, _ y: Int) -> SIMD4<UInt8> {
    if x < 32 && y < 32 { return SIMD4(3, 16, 224, 255) }
    if x >= width - 32 && y < 32 { return SIMD4(224, 48, 12, 255) }
    if x < 32 && y >= height - 32 { return SIMD4(16, 208, 56, 255) }
    if x >= width - 32 && y >= height - 32 { return SIMD4(96, 12, 176, 255) }
    return SIMD4(UInt8(x * 255 / (width - 1)), UInt8(y * 255 / (height - 1)),
                 UInt8((x / 8 + y / 8) % 2 == 0 ? 32 : 224), 255)
}

func makeFrame(_ id: UInt64 = 1, pixels: (Int, Int) -> SIMD4<UInt8> = chartPixel) -> VideoFrameMailbox.Frame {
    var pixel: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &pixel) == kCVReturnSuccess)
    let buffer = pixel!
    CVPixelBufferLockBaseAddress(buffer, [])
    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let value = pixels(x, y)
            for c in 0..<4 { bytes[y * rowBytes + x * 4 + c] = value[c] }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return VideoFrameMailbox.Frame(pixelBuffer: buffer, receivedAt: id, id: id, metrics: nil, session: nil)
}

func makeDepth(_ value: Float, format: MTLPixelFormat = .r32Float) -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 4, height: 4, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    let texture = device.makeTexture(descriptor: descriptor)!
    let values = Array(repeating: value, count: 16)
    values.withUnsafeBytes {
        texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: 4 * MemoryLayout<Float>.size)
    }
    return texture
}

func makeTarget(width: Int = targetWidth, format: MTLPixelFormat = .bgra8Unorm_srgb) -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.renderTarget, .shaderRead]
    return device.makeTexture(descriptor: descriptor)!
}

func readback(_ target: MTLTexture, command: MTLCommandBuffer) -> MTLBuffer {
    let buffer = device.makeBuffer(length: target.width * target.height * 4, options: .storageModeShared)!
    let blit = command.makeBlitCommandEncoder()!
    blit.copy(from: target, sourceSlice: 0, sourceLevel: 0,
              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: target.width, height: target.height, depth: 1), to: buffer,
              destinationOffset: 0, destinationBytesPerRow: target.width * 4,
              destinationBytesPerImage: target.width * target.height * 4)
    blit.endEncoding()
    return buffer
}

struct Rendered {
    let bytes: [UInt8]
    func value(_ eye: Int, _ x: Int, _ y: Int, _ channel: Int) -> Int {
        Int(bytes[(y * targetWidth + eye * width + x) * 4 + channel])
    }
}

func render(_ frame: VideoFrameMailbox.Frame, depth: MTLTexture?, strength: Float = 1,
            confidence: Float = 1, protectHUD: Bool = false) -> Rendered {
    autoreleasepool {
        let target = makeTarget()
        let command = queue.makeCommandBuffer()!
        check(processor.encode(frame: frame, depth: depth, strength: strength,
                               confidence: confidence, protectHUD: protectHUD,
                               commandBuffer: command, target: target), "Stereo encode must succeed")
        let buffer = readback(target, command: command)
        command.commit()
        command.waitUntilCompleted() // Host fixture readback only; never in playback.
        check(command.status == .completed, "Stereo GPU command failed: \(String(describing: command.error))")
        return Rendered(bytes: Array(UnsafeBufferPointer(
            start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: buffer.length)))
    }
}

func assertNative(_ image: Rendered, _ label: String) {
    // Every source pixel, both eyes: catches eye-half packing, vertical flips,
    // pixel-center offsets, channel swaps and double sRGB encoding.
    for y in 0..<height {
        for x in 0..<width {
            let expected = chartPixel(x, y)
            for c in 0..<4 {
                check(abs(image.value(0, x, y, c) - Int(expected[c])) <= 1, "\(label): left-eye source fidelity at \(x),\(y),\(c)")
                check(abs(image.value(1, x, y, c) - Int(expected[c])) <= 1, "\(label): right-eye source fidelity at \(x),\(y),\(c)")
                check(image.value(0, x, y, c) == image.value(1, x, y, c), "\(label): flat eyes must match exactly")
            }
        }
    }
}

let chart = makeFrame()
let near = makeDepth(1)
let far = makeDepth(0)
let flat = render(chart, depth: nil)
assertNative(flat, "Missing depth")
for (label, depth, strength, confidence): (String, MTLTexture?, Float, Float) in [
    ("Near plane", near, 1, 1),
    ("Strength zero", far, 0, 1),
    ("Confidence zero", far, 1, 0),
    ("Negative strength", far, -1, 1),
    ("Negative confidence", far, 1, -1),
    ("NaN strength", far, .nan, 1),
    ("Infinite strength", far, .infinity, 1),
    ("NaN confidence", far, 1, .nan),
    ("Infinite confidence", far, 1, .infinity),
    ("Depth above one", makeDepth(2), 1, 1),
    ("NaN depth", makeDepth(.nan), 1, 1),
    ("Infinite depth", makeDepth(.infinity), 1, 1),
    ("Negative infinite depth", makeDepth(-.infinity), 1, 1)
] {
    let result = render(chart, depth: depth, strength: strength, confidence: confidence)
    check(result.bytes == flat.bytes, "\(label) must fall back to matching native eyes")
}
print("PASS: both eyes preserve all \(width * height) synthetic SDR pixels and orientation; missing/near/invalid depth and zero confidence/strength are flat")

let shifted = render(chart, depth: far)
check(render(chart, depth: far, strength: 4, confidence: 8).bytes == shifted.bytes,
      "Strength and confidence above one must clamp to the maximum")
check(render(chart, depth: makeDepth(-2)).bytes == shifted.bytes, "Depth below zero must clamp to far")

// The input stripe is at a known horizontal location and depth zero. Behind
// the physical screen, its left-eye location must move LEFT, right-eye RIGHT.
let stripeX = 204
let stripe = makeFrame(2) { x, _ in
    let value: UInt8 = abs(x - stripeX) <= 2 ? 255 : 0
    return SIMD4(value, value, value, 255)
}
func stripeCentroid(_ image: Rendered, eye: Int, y: Int) -> Double {
    var total: Double = 0
    var weighted: Double = 0
    for x in 0..<width {
        let intensity = Double(image.value(eye, x, y, 0))
        total += intensity
        weighted += Double(x) * intensity
    }
    precondition(total > 0)
    return weighted / total
}
let farStripe = render(stripe, depth: far)
let nearStripe = render(stripe, depth: near)
let halfStripe = render(stripe, depth: far, confidence: 0.5)
let expectedShift = Double(width) * 0.012 / 2
for eye in 0..<2 {
    let direction = eye == 0 ? -1.0 : 1.0
    let expected = Double(stripeX) + direction * expectedShift
    check(abs(stripeCentroid(farStripe, eye: eye, y: height / 3) - expected) < 0.08,
          "Far stripe must move outward by the requested behind-screen disparity")
    check(abs(stripeCentroid(nearStripe, eye: eye, y: height / 3) - Double(stripeX)) < 0.01,
          "Near stripe must converge at the physical screen")
    check(abs(stripeCentroid(halfStripe, eye: eye, y: height / 3)
              - (Double(stripeX) + direction * expectedShift / 2)) < 0.08,
          "Confidence must scale disparity continuously")
}
// Horizontal synthesis cannot change the vertical-gradient channel anywhere
// outside the deliberately colored corner fixtures.
for eye in 0..<2 {
    for y in 32..<(height - 32) {
        for x in stride(from: 0, to: width, by: 5) {
            check(abs(shifted.value(eye, x, y, 1) - flat.value(eye, x, y, 1)) <= 1,
                  "Disparity may only move pixels horizontally")
        }
    }
}
print("PASS: far features move left/right with a \(String(format: "%.3f", expectedShift))-pixel shift per eye; near features converge and confidence scales disparity")

let protected = render(chart, depth: far, protectHUD: true)
let protectedPoints = [(width / 2, height / 2), (width / 2 + 6, height / 2),
                       (5, height / 2), (width - 6, height / 2),
                       (width / 2, 5), (width / 2, height - 6),
                       (width / 4, height / 12), (width / 12, height / 3)]
for (x, y) in protectedPoints {
    for eye in 0..<2 {
        for c in 0..<4 {
            check(protected.value(eye, x, y, c) == flat.value(eye, x, y, c),
                  "Central reticle and screen-edge HUD regions must remain on the screen plane")
        }
    }
}
var unprotectedChanges = 0
for y in (height / 3)..<(height * 2 / 3) {
    for x in (width / 4)..<(width / 3) {
        if protected.value(0, x, y, 2) != protected.value(1, x, y, 2) { unprotectedChanges += 1 }
    }
}
check(unprotectedChanges > 100, "HUD protection must leave depth active in scene regions")
print("PASS: manual center/edge HUD regions remain flat while depth remains active elsewhere")

// Validation failures must not encode an incompatible target or depth map.
for invalidTarget in [makeTarget(width: targetWidth - 1), makeTarget(format: .bgra8Unorm)] {
    let command = queue.makeCommandBuffer()!
    check(!processor.encode(frame: chart, depth: far, strength: 1, confidence: 1, protectHUD: false,
                            commandBuffer: command, target: invalidTarget), "Invalid stereo target must be rejected")
}
let invalidDepth = makeDepth(0, format: .r32Uint)
check(!processor.encode(frame: chart, depth: invalidDepth, strength: 1, confidence: 1,
                        protectHUD: false, commandBuffer: queue.makeCommandBuffer()!, target: makeTarget()),
      "Non-floating depth must be rejected")

// No frame history may accumulate in the processor. Drop caller ownership
// before commit, then verify the real pixel buffers stay alive until completion
// and disappear once each pair of command buffers has been released.
final class WeakResources {
    weak var pixel: CVPixelBuffer?
    weak var depth: (any MTLTexture)?
    init(pixel: CVPixelBuffer, depth: MTLTexture) {
        self.pixel = pixel
        self.depth = depth
    }
}
var observed: [WeakResources] = []
for batch in 0..<12 {
    autoreleasepool {
        var commands: [MTLCommandBuffer] = []
        var buffers: [MTLBuffer] = []
        for slot in 0..<2 {
            autoreleasepool {
                let value = UInt8(24 + batch * 8 + slot)
                let frame = makeFrame(UInt64(batch * 2 + slot + 100)) { _, _ in SIMD4(value, value, value, 255) }
                let depth = makeDepth(0)
                observed.append(WeakResources(pixel: frame.pixelBuffer, depth: depth))
                let target = makeTarget()
                let command = queue.makeCommandBuffer()!
                check(processor.encode(frame: frame, depth: depth, strength: 1, confidence: 1,
                                       protectHUD: false, commandBuffer: command, target: target), "Lifetime encode must succeed")
                buffers.append(readback(target, command: command))
                commands.append(command)
            }
        }
        check(observed.suffix(2).allSatisfy { $0.pixel != nil && $0.depth != nil },
              "Input pixels and map must remain alive after callers release them before commit")
        commands.forEach { $0.commit() }
        for (slot, command) in commands.enumerated() {
            command.waitUntilCompleted()
            check(command.status == .completed, "Lifetime GPU submission must complete")
            let bytes = buffers[slot].contents().assumingMemoryBound(to: UInt8.self)
            let expected = UInt8(24 + batch * 8 + slot)
            check(abs(Int(bytes[0]) - Int(expected)) <= 1,
                  "Two asynchronous submissions must sample their own retained color frame")
        }
        commands.removeAll()
        buffers.removeAll()
    }
    check(observed.allSatisfy { $0.pixel == nil && $0.depth == nil },
          "Completed submissions must release their source pixel buffers/maps without accumulating history")
}
print("PASS: 24 asynchronous source frames and depth maps retained through GPU work and released after completion, two submissions at a time")
print("PASS: stereo GPU host suite completed \(assertions) assertions; no headset quality or presentation timing inferred")
