import Foundation
import CoreVideo
import CoreImage
@preconcurrency import CoreML
@preconcurrency import Metal
import os

/// An independent, bounded depth lane. Color decoding/rendering never waits for
/// prediction. Call submit/snapshot on the renderer's worker, not the main actor.
final class DepthEstimationService: @unchecked Sendable {
    typealias Prediction = @Sendable (CVPixelBuffer) throws -> CVPixelBuffer
    struct DepthSnapshot: @unchecked Sendable {
        /// Relative inverse depth: near = 1, far = 0; never metric game geometry.
        let texture: MTLTexture
        let frameID: UInt64
        let session: MetricSessionID
        let sourceUptimeNs: UInt64
        let inferenceMilliseconds: Double
        /// Motion/age compatibility of this map with the requested color frame.
        let confidence: Float
    }

    private struct Result: @unchecked Sendable {
        let epoch: UInt64
        let texture: MTLTexture
        let frameID: UInt64
        let session: MetricSessionID
        let sourceUptimeNs: UInt64
        let inferenceMilliseconds: Double
        let signature: [Float]
    }

    private struct State {
        var epoch: UInt64 = 0
        var session: MetricSessionID?
        var enabled = false
        var stopped = false
        var revision: UInt64 = 0
        var busy = false
        var lastAdmission: UInt64 = 0
        var lastFrameID: UInt64?
        var retryAfter: UInt64 = 0
        var latest: Result?
        var message = "3D depth off"
    }

    private struct Work: @unchecked Sendable {
        let frame: VideoFrameMailbox.Frame
        let session: MetricSessionID
        let epoch: UInt64
        let admittedAt: UInt64
    }

    private enum Failure: Error {
        case missingModel, unsupportedModel, allocation, unsupportedPixels, invalidDepth
    }

    private let device: MTLDevice
    private let explicitModelURL: URL?
    private let injectedPrediction: Prediction?
    private let queue = DispatchQueue(label: "com.visionremote.depth", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())
    // Everything below belongs exclusively to queue.
    private var model: MLModel?
    private var context: CIContext?
    private var modelWidth = 518
    private var modelHeight = 392
    private var normalizationRange: SIMD2<Float>?
    private var previousSignature: [Float]?
    private var normalizationEpoch: UInt64?

    init(device: MTLDevice, modelURL: URL? = nil, prediction: Prediction? = nil) {
        self.device = device
        explicitModelURL = modelURL
        injectedPrediction = prediction
    }

    /// At most one work item exists, including loading and preprocessing. Busy
    /// arrivals are skipped; there is no pending source-frame queue.
    func submit(frame: VideoFrameMailbox.Frame, enabled: Bool) {
        guard enabled, let session = frame.session else { setEnabled(false); return }
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious, thermal != .critical else {
            deactivate(message: "2D — device cooling down")
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let work: Work? = state.withLock { value in
            guard !value.stopped else { return nil }
            if value.session != session || !value.enabled {
                value.epoch &+= 1
                value.session = session
                value.enabled = true
                value.latest = nil
                value.lastFrameID = nil
                value.lastAdmission = 0
                value.message = "Preparing 3D depth…"
                value.revision &+= 1
            }
            guard !value.busy, value.lastFrameID != frame.id,
                  now >= value.retryAfter,
                  now &- value.lastAdmission >= 125_000_000 else { return nil }
            value.busy = true
            value.lastAdmission = now
            value.lastFrameID = frame.id
            return Work(frame: frame, session: session, epoch: value.epoch, admittedAt: now)
        }
        guard let work else { return }
        queue.async { [self] in
            autoreleasepool { predict(work) }
        }
    }

    /// This only reads a tiny luma signature (32 × 18) from the current frame.
    /// Stale or incompatible maps fall back to 2D; frozen same-frame inspection
    /// is allowed to retain its matching map without an artificial age limit.
    func snapshot(for frame: VideoFrameMailbox.Frame, frozen: Bool = false) -> DepthSnapshot? {
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious, thermal != .critical else { return nil }
        guard let result = state.withLock({ value -> Result? in
            guard value.enabled, value.session == frame.session else { return nil }
            return value.latest
        }), result.session == frame.session else { return nil }
        let sameFrame = result.frameID == frame.id
        let now = DispatchTime.now().uptimeNanoseconds
        let age = now >= result.sourceUptimeNs ? Double(now - result.sourceUptimeNs) / 1_000_000 : 0
        guard (frozen && sameFrame) || age < 250 else {
            updateStatus("2D — waiting for fresh depth", session: result.session)
            return nil
        }
        let motionConfidence: Float
        if sameFrame { motionConfidence = 1 }
        else {
            guard let current = Self.signature(frame.pixelBuffer) else { return nil }
            let difference = Self.signatureDifference(current, result.signature)
            motionConfidence = Self.compatibility(forMeanLumaDifference: difference)
        }
        let ageConfidence: Float = frozen && sameFrame ? 1 : Float(min(1, max(0, (250 - age) / 100)))
        let confidence = motionConfidence * ageConfidence
        guard confidence > 0.05 else {
            updateStatus(motionConfidence <= 0.05 ? "2D — scene moving" : "2D — waiting for fresh depth", session: result.session)
            return nil
        }
        guard state.withLock({ $0.enabled && $0.epoch == result.epoch && $0.session == result.session }) else { return nil }
        updateStatus("3D depth active", session: result.session)
        return DepthSnapshot(texture: result.texture, frameID: result.frameID,
                             session: result.session, sourceUptimeNs: result.sourceUptimeNs,
                             inferenceMilliseconds: result.inferenceMilliseconds,
                             confidence: confidence)
    }

    func status() -> String { state.withLock { $0.message } }

    private func updateStatus(_ message: String, session: MetricSessionID) {
        state.withLock { value in
            guard value.enabled, value.session == session else { return }
            value.message = message
        }
    }

    /// Cheap observation for a frozen image's redraw key. No image work occurs.
    var revision: UInt64 { state.withLock { $0.revision } }

    /// Current retained map only; excludes Core ML internals and maps retained
    /// by an already-submitted GPU command after replacement.
    var retainedTextures: (count: Int, bytes: Int) {
        state.withLock { value in
            guard let texture = value.latest?.texture else { return (0, 0) }
            return (1, texture.allocatedSize)
        }
    }

    /// Re-enabling admits only a subsequent source frame; disabling immediately
    /// invalidates current work and releases the latest map.
    func setEnabled(_ enabled: Bool) {
        if !enabled { deactivate(message: "3D depth off") }
    }

    /// Permanent shutdown for a retired renderer; late submits cannot revive it.
    func stop() {
        state.withLock { $0.stopped = true }
        deactivate(message: "3D depth off")
    }

    private func deactivate(message: String) {
        state.withLock { value in
            if value.enabled || value.latest != nil {
                value.epoch &+= 1
                value.revision &+= 1
            }
            value.enabled = false
            value.session = nil
            value.latest = nil
            value.lastFrameID = nil
            value.message = message
            // An in-flight prediction cannot be cancelled synchronously. Keep
            // busy set until it finishes, so restart cannot enqueue more work.
        }
    }

    private func predict(_ work: Work) {
        do {
            guard isCurrent(work) else { finishDiscarded(); return }
            let model = injectedPrediction == nil ? try loadModel() : nil
            if context == nil { context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false]) }
            guard isCurrent(work) else { finishDiscarded(); return }
            guard let signature = Self.signature(work.frame.pixelBuffer) else { throw Failure.unsupportedPixels }
            let input = try resizedInput(work.frame.pixelBuffer)
            let predictionStart = DispatchTime.now().uptimeNanoseconds
            let depth: CVPixelBuffer
            if let injectedPrediction {
                depth = try injectedPrediction(input)
            } else {
                guard let model else { throw Failure.missingModel }
                let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
                let output = try model.prediction(from: features)
                guard let outputDepth = output.featureValue(for: "depth")?.imageBufferValue else { throw Failure.unsupportedModel }
                depth = outputDepth
            }
            let predictionEnd = DispatchTime.now().uptimeNanoseconds
            guard isCurrent(work) else { finishDiscarded(); return }
            if normalizationEpoch != work.epoch {
                normalizationEpoch = work.epoch
                normalizationRange = nil
                previousSignature = nil
            }
            if let previousSignature, Self.signatureDifference(signature, previousSignature) > 0.12 {
                normalizationRange = nil
            }
            previousSignature = signature
            let texture = try normalizedTexture(depth)
            let milliseconds = Double(predictionEnd - predictionStart) / 1_000_000
            let result = Result(epoch: work.epoch, texture: texture, frameID: work.frame.id, session: work.session,
                                sourceUptimeNs: work.admittedAt, inferenceMilliseconds: milliseconds,
                                signature: signature)
            state.withLock { value in
                value.busy = false
                guard value.enabled, value.epoch == work.epoch, value.session == work.session else { return }
                value.latest = result
                value.message = "Checking 3D depth…"
                value.revision &+= 1
            }
        } catch {
            state.withLock { value in
                value.busy = false
                guard value.enabled, value.epoch == work.epoch, value.session == work.session else { return }
                value.latest = nil
                value.retryAfter = DispatchTime.now().uptimeNanoseconds &+ 5_000_000_000
                value.lastFrameID = nil
                value.message = "2D — depth model unavailable"
                value.revision &+= 1
            }
        }
    }

    private func isCurrent(_ work: Work) -> Bool {
        state.withLock { $0.enabled && $0.epoch == work.epoch && $0.session == work.session }
    }

    private func finishDiscarded() { state.withLock { $0.busy = false } }

    private func loadModel() throws -> MLModel {
        if let model { return model }
        guard let url = explicitModelURL ?? Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else {
            throw Failure.missingModel
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        guard let input = loaded.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              loaded.modelDescription.outputDescriptionsByName["depth"]?.type == .image,
              input.pixelsWide > 0, input.pixelsHigh > 0 else { throw Failure.unsupportedModel }
        modelWidth = input.pixelsWide
        modelHeight = input.pixelsHigh
        model = loaded
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        return loaded
    }

    private func resizedInput(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                         kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, modelWidth, modelHeight,
                                  kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer, let context else { throw Failure.allocation }
        let image = CIImage(cvPixelBuffer: source)
        // Stretch the whole frame to the model's fixed input. The resulting map
        // is sampled in normalized source coordinates, preserving all edges.
        let resized = image.transformed(by: CGAffineTransform(scaleX: CGFloat(modelWidth) / image.extent.width,
                                                              y: CGFloat(modelHeight) / image.extent.height))
        context.render(resized, to: buffer, bounds: CGRect(x: 0, y: 0, width: modelWidth, height: modelHeight),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }

    private func normalizedTexture(_ depth: CVPixelBuffer) throws -> MTLTexture {
        let format = CVPixelBufferGetPixelFormatType(depth)
        guard format == kCVPixelFormatType_OneComponent16Half || format == kCVPixelFormatType_OneComponent32Float,
              CVPixelBufferLockBaseAddress(depth, .readOnly) == kCVReturnSuccess else { throw Failure.unsupportedPixels }
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { throw Failure.invalidDepth }
        let sourceWidth = CVPixelBufferGetWidth(depth), sourceHeight = CVPixelBufferGetHeight(depth)
        let width = max(1, sourceWidth / 2), height = max(1, sourceHeight / 2)
        let rowBytes = CVPixelBufferGetBytesPerRow(depth)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: min(sourceHeight - 1, y * 2) * rowBytes)
            for x in 0..<width {
                let sx = min(sourceWidth - 1, x * 2)
                let value = format == kCVPixelFormatType_OneComponent16Half
                    ? Float(Float16(bitPattern: row.assumingMemoryBound(to: UInt16.self)[sx]))
                    : row.assumingMemoryBound(to: Float.self)[sx]
                values[y * width + x] = value
            }
        }
        guard let range = Self.robustRange(values) else { throw Failure.invalidDepth }
        let stabilized = normalizationRange.map { $0 * 0.75 + range * 0.25 } ?? range
        normalizationRange = stabilized
        let span = max(stabilized.y - stabilized.x, 0.0001)
        for index in values.indices {
            values[index] = values[index].isFinite ? min(1, max(0, (values[index] - stabilized.x) / span)) : 0
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
        texture.label = "Normalized relative depth"
        values.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width * MemoryLayout<Float>.stride)
        }
        return texture
    }

    // Pure helpers are shared with host checks for finite maps and motion gating.
    static func robustRange(_ values: [Float]) -> SIMD2<Float>? {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard sorted.count > 1, sorted.count >= Int(ceil(Double(values.count) * 0.99)) else { return nil }
        let lower = sorted[Int(Float(sorted.count - 1) * 0.02)]
        let upper = sorted[Int(Float(sorted.count - 1) * 0.98)]
        guard upper - lower > 0.0001 else { return nil }
        return SIMD2(lower, upper)
    }

    static func compatibility(forMeanLumaDifference difference: Float) -> Float {
        guard difference.isFinite else { return 0 }
        return min(1, max(0, (0.16 - difference) / 0.11))
    }

    private static func signatureDifference(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        return zip(a, b).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(a.count)
    }

    private static func signature(_ buffer: CVPixelBuffer) -> [Float]? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let planar = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard planar || format == kCVPixelFormatType_32BGRA else { return nil }
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        var samples = [Float](); samples.reserveCapacity(32 * 18)
        for y in 0..<18 {
            let sy = min(height - 1, (2 * y + 1) * height / 36)
            let row = base.advanced(by: sy * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<32 {
                let sx = min(width - 1, (2 * x + 1) * width / 64)
                if planar { samples.append(Float(row[sx]) / 255) }
                else {
                    let offset = sx * 4
                    samples.append((Float(row[offset]) * 0.0722 + Float(row[offset + 1]) * 0.7152 + Float(row[offset + 2]) * 0.2126) / 255)
                }
            }
        }
        return samples
    }
}
