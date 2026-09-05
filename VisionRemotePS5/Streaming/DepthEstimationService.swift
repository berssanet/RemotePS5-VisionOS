//
//  DepthEstimationService.swift
//  VisionRemotePS5
//
//  AI depth estimation on the Apple Neural Engine (Depth Anything V2 Small).
//  Restored and reworked from the removed 2026-02-05 attempt (commit f3b3b73):
//  the model is now loaded dynamically from the app bundle, so the project
//  builds and runs with or without the .mlmodelc resource present.
//
//  Drop-frame strategy: if an inference is already running, estimate(from:)
//  returns nil immediately — the video pipeline is never blocked.
//
//  Model: DepthAnythingV2SmallF16.mlmodelc (input 518x392 color image,
//  output 518x392 Grayscale16Half relative inverse depth — brighter = nearer).
//  Source: https://huggingface.co/apple/coreml-depth-anything-v2-small
//

import Accelerate
import CoreML
import Vision
import CoreVideo
import QuartzCore  // CACurrentMediaTime monotonic clock

/// One estimated depth map plus its value range.
/// Depth Anything outputs unbounded relative inverse depth; the shader needs
/// min/max to normalize into 0...1. Range is computed here, off the main
/// thread, with Accelerate.
struct DepthFrame {
    let pixelBuffer: CVPixelBuffer
    let minValue: Float
    let maxValue: Float
}

/// Asynchronous monocular depth estimation on the Neural Engine.
/// The Neural Engine is otherwise idle during streaming, so inference does
/// not compete with the GPU (MetalFX upscale) or the media engine (decode).
actor DepthEstimationService {

    static let shared = DepthEstimationService()

    // MARK: - State

    private var model: VNCoreMLModel?
    private var isBusy: Bool = false
    private var loadAttempted: Bool = false

    // Performance tracking (monotonic clock)
    private var frameCount: UInt64 = 0
    private var totalInferenceTime: Double = 0

    // MARK: - Model loading

    /// Loads the Core ML model from the bundle on first use.
    /// Missing model is a soft failure: spatial 3D stays disabled.
    private func loadModelIfNeeded() {
        guard !loadAttempted else { return }
        loadAttempted = true

        guard let url = Bundle.main.url(forResource: "DepthAnythingV2SmallF16",
                                        withExtension: "mlmodelc") else {
            DebugLog.warning("DepthEstimation", "DepthAnythingV2SmallF16.mlmodelc not in bundle — spatial 3D unavailable")
            return
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all  // prefer the Neural Engine
            let coreModel = try MLModel(contentsOf: url, configuration: config)
            model = try VNCoreMLModel(for: coreModel)
            DebugLog.info("DepthEstimation", "✅ Depth Anything V2 Small loaded (Neural Engine)")
        } catch {
            DebugLog.error("DepthEstimation", "Model load failed: \(error)")
        }
    }

    // MARK: - Inference

    // Scratch buffer for Float16 → Float32 range computation (reused).
    private var rangeScratch: [Float] = []

    /// Estimate relative depth for a video frame.
    /// Returns nil immediately when busy (drop-frame) or when the model is
    /// unavailable. Output is a 518x392 OneComponent16Half CVPixelBuffer,
    /// brighter = nearer (relative inverse depth, NOT normalized to 0...1).
    func estimate(from buffer: CVPixelBuffer) async -> DepthFrame? {
        loadModelIfNeeded()
        guard let model, !isBusy else { return nil }

        isBusy = true
        defer { isBusy = false }

        let startTime = CACurrentMediaTime()

        let depthMap = await withCheckedContinuation { (continuation: CheckedContinuation<CVPixelBuffer?, Never>) in
            let request = VNCoreMLRequest(model: model) { request, error in
                if let error {
                    DebugLog.error("DepthEstimation", "Inference error: \(error)")
                    continuation.resume(returning: nil)
                    return
                }
                let depth = (request.results as? [VNPixelBufferObservation])?.first?.pixelBuffer
                continuation.resume(returning: depth)
            }
            request.imageCropAndScaleOption = .scaleFill  // Vision resizes to 518x392

            do {
                try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
            } catch {
                DebugLog.error("DepthEstimation", "Vision request failed: \(error)")
                continuation.resume(returning: nil)
            }
        }

        let elapsed = (CACurrentMediaTime() - startTime) * 1000
        totalInferenceTime += elapsed
        frameCount += 1
        if frameCount % 120 == 0 {
            let avg = totalInferenceTime / Double(frameCount)
            DebugLog.info("DepthEstimation", "📊 \(frameCount) depth frames, avg \(String(format: "%.1f", avg))ms, last \(String(format: "%.1f", elapsed))ms")
        }

        guard let depthMap, let range = computeRange(of: depthMap) else { return nil }

        // Range hysteresis: EMA-smooth min/max so hard scene cuts don't make
        // the displaced screen "breathe" (Phase 7 backlog item). ~0.15 at
        // 30Hz depth ≈ 200ms adaptation — fast enough for scene changes,
        // slow enough to kill per-frame flicker.
        if let smoothedMin, let smoothedMax {
            let alpha: Float = 0.15
            self.smoothedMin = smoothedMin + (range.min - smoothedMin) * alpha
            self.smoothedMax = smoothedMax + (range.max - smoothedMax) * alpha
        } else {
            smoothedMin = range.min
            smoothedMax = range.max
        }
        return DepthFrame(pixelBuffer: depthMap,
                          minValue: smoothedMin ?? range.min,
                          maxValue: smoothedMax ?? range.max)
    }

    // Smoothed normalization range (see estimate).
    private var smoothedMin: Float?
    private var smoothedMax: Float?

    /// Drop the smoothed range so a NEW streaming session doesn't inherit the
    /// previous game's depth statistics (stale prior warps the first frames).
    func resetRange() {
        smoothedMin = nil
        smoothedMax = nil
    }

    // MARK: - Depth range (normalization support)

    /// Min/max of a one-component Float16 or Float32 depth buffer via vImage/vDSP.
    /// ~200k values per frame; SIMD passes keep this well under a millisecond.
    private func computeRange(of buffer: CVPixelBuffer) -> (min: Float, max: Float)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let count = width * height

        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half:
            if rangeScratch.count < count {
                rangeScratch = [Float](repeating: 0, count: count)
            }
            var src = vImage_Buffer(data: base, height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: rowBytes)
            let converted: Bool = rangeScratch.withUnsafeMutableBufferPointer { dstPtr in
                var dst = vImage_Buffer(data: dstPtr.baseAddress, height: vImagePixelCount(height),
                                        width: vImagePixelCount(width),
                                        rowBytes: width * MemoryLayout<Float>.stride)
                return vImageConvert_Planar16FtoPlanarF(&src, &dst, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
            guard converted else { return nil }
            var minV: Float = 0
            var maxV: Float = 0
            vDSP_minv(rangeScratch, 1, &minV, vDSP_Length(count))
            vDSP_maxv(rangeScratch, 1, &maxV, vDSP_Length(count))
            return (minV, maxV)

        case kCVPixelFormatType_OneComponent32Float:
            guard rowBytes == width * MemoryLayout<Float>.stride else { return nil }
            let floats = base.assumingMemoryBound(to: Float.self)
            var minV: Float = 0
            var maxV: Float = 0
            vDSP_minv(floats, 1, &minV, vDSP_Length(count))
            vDSP_maxv(floats, 1, &maxV, vDSP_Length(count))
            return (minV, maxV)

        default:
            DebugLog.warning("DepthEstimation", "Unexpected depth pixel format: \(CVPixelBufferGetPixelFormatType(buffer))")
            return nil
        }
    }
}
