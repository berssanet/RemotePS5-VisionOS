//
//  DepthService.swift
//  VisionRemotePS5
//
//  AI-powered depth estimation service using CoreML/Vision.
//  Runs on the Neural Engine with "Drop Frame" strategy: if busy, skip the frame
//  to prevent blocking the video rendering pipeline.
//
//  Requires: DepthAnythingV2Small.mlpackage (Float16) in the Xcode project.
//

import CoreML
import Vision
import CoreVideo
import QuartzCore

/// Asynchronous depth estimation service using Apple Neural Engine.
/// Implements a non-blocking "Drop Frame" strategy for real-time performance.
actor DepthService {
    
    // MARK: - Properties
    
    private var model: VNCoreMLModel?
    private var isBusy = false
    private var isInitialized = false
    private var frameCount: UInt64 = 0
    
    // Performance tracking
    private var lastInferenceTime: Double = 0
    private var totalInferenceTime: Double = 0
    
    // MARK: - Initialization
    
    init() {
        Task(priority: .userInitiated) {
            await initializeModel()
        }
    }
    
    /// Initialize the CoreML model for depth estimation.
    private func initializeModel() async {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all // Force Neural Engine usage
            
            // Try to load the DepthAnything V2 Small model
            // NOTE: This model must be added to the Xcode project manually
            #if canImport(DepthAnythingV2Small)
            let coreModel = try DepthAnythingV2Small(configuration: config)
            self.model = try VNCoreMLModel(for: coreModel.model)
            self.isInitialized = true
            print("[DepthService] ✅ Model loaded successfully (Neural Engine)")
            #else
            // Model not available - log warning but don't crash
            print("[DepthService] ⚠️ DepthAnythingV2Small not found. Add the .mlpackage to your project.")
            self.isInitialized = false
            #endif
        } catch {
            print("[DepthService] 💀 Critical failure loading model: \(error)")
            self.isInitialized = false
        }
    }
    
    // MARK: - Public API
    
    /// Check if the depth service is ready for inference.
    var isReady: Bool {
        return isInitialized && model != nil
    }
    
    /// Estimate depth from a video frame.
    /// Returns nil immediately if the service is busy (Drop Frame strategy).
    /// - Parameter buffer: Input CVPixelBuffer (typically 1920x1080)
    /// - Returns: Depth map as CVPixelBuffer, or nil if busy/failed
    func estimate(from buffer: CVPixelBuffer) async -> CVPixelBuffer? {
        // Non-blocking: return nil if already processing
        guard let model = model, !isBusy else {
            return nil
        }
        
        isBusy = true
        defer { isBusy = false }
        
        let startTime = CACurrentMediaTime()
        
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<CVPixelBuffer?, Never>) in
            let request = VNCoreMLRequest(model: model) { request, error in
                if let error = error {
                    print("[DepthService] ❌ Inference error: \(error)")
                    continuation.resume(returning: nil)
                    return
                }
                
                if let results = request.results as? [VNPixelBufferObservation],
                   let depthMap = results.first?.pixelBuffer {
                    continuation.resume(returning: depthMap)
                } else {
                    continuation.resume(returning: nil)
                }
            }
            
            // Vision automatically resizes to model input (518x518)
            request.imageCropAndScaleOption = .scaleFill
            
            do {
                try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
                    .perform([request])
            } catch {
                print("[DepthService] ❌ Vision request failed: \(error)")
                continuation.resume(returning: nil)
            }
        }
        
        // Track performance
        let elapsed = (CACurrentMediaTime() - startTime) * 1000
        lastInferenceTime = elapsed
        totalInferenceTime += elapsed
        frameCount += 1
        
        // Log periodic stats
        if frameCount % 60 == 0 {
            let avgTime = totalInferenceTime / Double(frameCount)
            print("[DepthService] 📊 \(frameCount) frames, avg \(String(format: "%.1f", avgTime))ms/frame, last \(String(format: "%.1f", elapsed))ms")
        }
        
        return result
    }
    
    /// Get the last inference time in milliseconds.
    func getLastInferenceTime() -> Double {
        return lastInferenceTime
    }
    
    /// Get average inference time in milliseconds.
    func getAverageInferenceTime() -> Double {
        guard frameCount > 0 else { return 0 }
        return totalInferenceTime / Double(frameCount)
    }
    
    /// Reset performance counters.
    func resetStats() {
        frameCount = 0
        totalInferenceTime = 0
        lastInferenceTime = 0
    }
}
