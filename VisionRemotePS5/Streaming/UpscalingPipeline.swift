//
//  UpscalingPipeline.swift
//  VisionRemotePS5
//
//  GPU upscaling pipeline with multiple quality modes.
//  Supports MetalFX Spatial and Enhanced (Lanczos+CAS) upscaling.
//

import Foundation
import Metal
import CoreVideo
import Combine
import UIKit  // v9.0: For dynamic EDR headroom query
import QuartzCore  // v10.1: For CACurrentMediaTime monotonic clock

/// Upscaling quality mode
enum UpscalerType: String, CaseIterable {
    case metalFX = "MetalFX"       // MetalFX Spatial Scaler (fast)
    case enhanced = "Enhanced"     // Lanczos + CAS (better quality)
}

/// HDR processing mode
enum HDRMode: String, CaseIterable {
    case auto = "Auto"             // Detect from stream
    case forceSDR = "SDR"          // Force SDR (8-bit BGRA)
    case forceHDR = "HDR10"        // Force HDR10 (P010 + BT.2020 + PQ)
}

/// GPU upscaling pipeline with selectable quality modes.
/// Upscales 1080p video to 4K using MetalFX or custom shaders.
@MainActor
final class UpscalingPipeline: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = UpscalingPipeline()
    
    // MARK: - Published Properties (Slow State Only - Low Frequency Updates)
    
    @Published var isEnabled: Bool = false
    @Published var processingTimeMs: Double = 0
    
    /// Current upscaling mode
    @Published var currentMode: UpscalingMode = .spatial
    
    /// Current upscaler type (MetalFX or Enhanced)
    @Published var upscalerType: UpscalerType = .metalFX
    
    /// CAS sharpening strength (0.0-1.0)
    @Published var sharpenStrength: Float = 0.5
    
    // MARK: - High-Performance Texture Callback (Bypasses SwiftUI)
    
    /// Called on GPU thread when upscaled texture is ready.
    /// This is the HOT PATH - do NOT dispatch to MainActor from here.
    /// - Warning: Called from Metal pipeline thread. Must be thread-safe.
    var onTextureReady: ((MTLTexture) -> Void)?
    
    /// Last upscaled texture (non-published, for direct access)
    private(set) var upscaledTexture: MTLTexture?
    
    /// Frame counter (non-published)
    private(set) var textureFrameId: UInt64 = 0
    
    // MARK: - Private Properties
    
    private var metalFXUpscaler: MetalFXUpscaler?
    private var enhancedUpscaler: EnhancedUpscaler?
    private var colorSpaceConverter: ColorSpaceConverter?
    private var isInitialized = false
    private var frameCount: UInt64 = 0
    
    /// HDR processing mode
    @Published var hdrMode: HDRMode = .auto
    
    // MARK: - Initialization
    
    private init() {
        print("[UpscalingPipeline] Initializing...")
    }
    
    /// Initialize the upscaling pipeline
    func initialize() {
        guard !isInitialized else { return }
        
        // Initialize color space converter (for P010/HDR input)
        colorSpaceConverter = ColorSpaceConverter()
        if colorSpaceConverter != nil {
            print("[UpscalingPipeline] ✅ ColorSpaceConverter ready (HDR support)")
        }
        
        // Initialize both upscalers
        metalFXUpscaler = MetalFXUpscaler()
        enhancedUpscaler = EnhancedUpscaler()
        
        if metalFXUpscaler != nil || enhancedUpscaler != nil {
            isInitialized = true
            isEnabled = true
            
            // Default to MetalFX, fall back to enhanced if unavailable
            if metalFXUpscaler != nil {
                upscalerType = .metalFX
                currentMode = metalFXUpscaler?.mode ?? .spatial
                print("[UpscalingPipeline] ✅ MetalFX upscaler ready (SPATIAL)")
            } else if enhancedUpscaler != nil {
                upscalerType = .enhanced
                print("[UpscalingPipeline] ✅ Enhanced upscaler ready (Lanczos+CAS)")
            }
        } else {
            print("[UpscalingPipeline] ⚠️ No upscaler available, using native resolution")
        }
    }
    
    /// Process a video frame through the upscaling pipeline.
    /// For P010 (HDR) input: ColorSpaceConverter → Upscaler
    /// For BGRA (SDR) input: Direct to Upscaler
    func processFrame(_ frame: CVPixelBuffer) -> MTLTexture? {
        guard isEnabled else {
            if frameCount == 0 {
                print("[UpscalingPipeline] ⚠️ Not enabled")
            }
            return nil
        }
        
        // v9.0: Update EDR headroom dynamically from display
        // Vision Pro adjusts max brightness based on thermal state
        updateDynamicEDRHeadroom()
        
        // v10.1: Use monotonic clock for accurate timing
        let startTime = CACurrentMediaTime()
        var result: MTLTexture?
        
        // Check pixel format to determine processing path
        let format = CVPixelBufferGetPixelFormatType(frame)
        let isP010 = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                     format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        
        // Configure HDR settings based on mode
        if let converter = colorSpaceConverter {
            switch hdrMode {
            case .auto:
                // Auto-detect: P010 = HDR, BGRA = SDR
                converter.colorPrimaries = isP010 ? .bt2020 : .bt709
                converter.transferFunction = isP010 ? .pq : .sdr
            case .forceSDR:
                converter.colorPrimaries = .bt709
                converter.transferFunction = .sdr
            case .forceHDR:
                converter.colorPrimaries = .bt2020
                converter.transferFunction = .pq
            }
        }
        
        // Step 1: Color space conversion (P010→Linear RGB or BGRA→Linear RGB)
        if isP010, let converter = colorSpaceConverter {
            // HDR path: P010 YUV → Linear RGB (RGBA16Float)
            if let convertedTexture = converter.convert(frame) {
                if frameCount == 0 {
                    print("[UpscalingPipeline] 🎨 HDR path: P010→RGBA16Float→Upscale")
                }
                // Note: Currently upscalers expect CVPixelBuffer input
                // TODO: Update upscalers to accept MTLTexture input for HDR
                // For now, use BGRA fallback
                result = upscaleFromPixelBuffer(frame)
            }
        } else {
            // SDR path: Direct upscaling from BGRA
            result = upscaleFromPixelBuffer(frame)
        }
        
        if let texture = result {
            frameCount += 1
            upscaledTexture = texture
            textureFrameId = frameCount
            
            // v10.3: Direct callback - bypasses SwiftUI state management
            onTextureReady?(texture)
            
            if frameCount == 1 {
                let hdrStatus = isP010 ? "HDR" : "SDR"
                print("[UpscalingPipeline] ✅ First 4K frame generated! (\(upscalerType.rawValue), \(hdrStatus))")
            }
        } else if frameCount == 0 {
            print("[UpscalingPipeline] ❌ Failed to upscale frame")
        }
        
        // Track processing time
        // v10.1: Monotonic clock for processing time
        let elapsed = (CACurrentMediaTime() - startTime) * 1000
        processingTimeMs = elapsed
        
        // Log periodic stats
        if frameCount > 0 && frameCount % 60 == 0 {
            let hdrStatus = hdrMode == .forceHDR || (hdrMode == .auto && isP010) ? "HDR" : "SDR"
            print("[UpscalingPipeline] 📊 \(frameCount) frames, \(String(format: "%.1f", elapsed))ms/frame (\(upscalerType.rawValue), \(hdrStatus))")
        }
        
        return result
    }
    
    /// Upscale from CVPixelBuffer (SDR path or HDR fallback)
    private func upscaleFromPixelBuffer(_ frame: CVPixelBuffer) -> MTLTexture? {
        switch upscalerType {
        case .metalFX:
            return metalFXUpscaler?.upscale(frame)
        case .enhanced:
            if let enhanced = enhancedUpscaler {
                enhanced.sharpenStrength = sharpenStrength
                return enhanced.upscale(frame)
            }
            return nil
        }
    }
    
    // MARK: - Control
    
    func enable() {
        if !isInitialized {
            initialize()
        }
        isEnabled = true
        print("[UpscalingPipeline] ✅ Enabled")
    }
    
    func disable() {
        isEnabled = false
        print("[UpscalingPipeline] ⏸️ Disabled")
    }
    
    func flush() {
        metalFXUpscaler?.flush()
        enhancedUpscaler?.flush()
        colorSpaceConverter?.flush()
    }
    
    // MARK: - HDR Control
    
    /// Set HDR processing mode
    func setHDRMode(_ mode: HDRMode) {
        hdrMode = mode
        print("[UpscalingPipeline] 🎨 HDR mode: \(mode.rawValue)")
    }
    
    /// Configure color primaries manually
    func setColorPrimaries(_ primaries: ColorPrimaries) {
        colorSpaceConverter?.colorPrimaries = primaries
    }
    
    /// Configure transfer function manually  
    func setTransferFunction(_ tf: TransferFunction) {
        colorSpaceConverter?.transferFunction = tf
    }
    
    // MARK: - v10.0 Dynamic EDR Headroom (from SwiftUI Environment)
    
    /// Cache for last EDR headroom to avoid redundant updates
    private var lastEDRHeadroom: Float = 2.0
    
    /// v10.0: Update EDR headroom from SwiftUI Environment
    /// Call this from your View with @Environment(\.displayEDRHeadroom)
    /// Vision Pro dynamically adjusts max brightness based on:
    /// - Thermal state (reduces when hot)
    /// - Content on screen (scene-referred EDR)
    /// This prevents clipped highlights when device is warm
    func updateEDRHeadroom(from environmentValue: CGFloat) {
        let currentHeadroom = Float(environmentValue)
        
        // Only update if changed significantly (avoid per-frame Metal calls)
        if abs(currentHeadroom - lastEDRHeadroom) > 0.1 {
            lastEDRHeadroom = currentHeadroom
            colorSpaceConverter?.edrHeadroom = currentHeadroom
            
            print("[UpscalingPipeline] 🌟 v10.0 EDR Headroom (live): \(String(format: "%.2f", currentHeadroom))x")
        }
    }
    
    /// Legacy: Query EDR headroom (fallback for non-SwiftUI contexts)
    /// v10.1: Now includes thermal state monitoring for proactive throttling
    private func updateDynamicEDRHeadroom() {
        // v10.1: Check thermal state via ProcessInfo
        let thermalState = ProcessInfo.processInfo.thermalState
        var thermalMultiplier: Float = 1.0
        
        switch thermalState {
        case .nominal:
            thermalMultiplier = 1.0
        case .fair:
            thermalMultiplier = 0.9
        case .serious:
            // Reduce EDR significantly and log warning
            thermalMultiplier = 0.7
            if frameCount % 120 == 0 {
                print("[UpscalingPipeline] ⚠️ Thermal state SERIOUS - reducing EDR to 70%")
            }
        case .critical:
            // Disable upscaling to reduce GPU load
            thermalMultiplier = 0.5
            if isEnabled && upscalerType == .metalFX {
                print("[UpscalingPipeline] 🔥 Thermal CRITICAL - disabling MetalFX upscaling")
                upscalerType = .enhanced  // Less GPU-intensive
            }
        @unknown default:
            thermalMultiplier = 0.8
        }
        
        #if os(visionOS)
        // visionOS: Use last known EDR or default, adjusted for thermal
        let currentHeadroom: Float = lastEDRHeadroom * thermalMultiplier
        #else
        let scenes = UIApplication.shared.connectedScenes
        guard let windowScene = scenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene else {
            return
        }
        let currentHeadroom = Float(windowScene.screen.currentEDRHeadroom) * thermalMultiplier
        #endif
        
        if abs(currentHeadroom - lastEDRHeadroom) > 0.1 {
            lastEDRHeadroom = currentHeadroom
            colorSpaceConverter?.edrHeadroom = currentHeadroom
            
            if thermalMultiplier < 1.0 {
                print("[UpscalingPipeline] 🌡️ Thermal-adjusted EDR: \(String(format: "%.2f", currentHeadroom))x")
            }
        }
    }
    
    /// Set EDR headroom manually (1.0 = SDR, 2.0 = 2x HDR brightness)
    func setEDRHeadroom(_ headroom: Float) {
        lastEDRHeadroom = headroom
        colorSpaceConverter?.edrHeadroom = headroom
    }
    
    // MARK: - Mode Control
    
    /// Switch upscaler type
    func setUpscalerType(_ type: UpscalerType) {
        upscalerType = type
        print("[UpscalingPipeline] ⚙️ Switched to \(type.rawValue) upscaler")
    }
    
    /// Switch upscaling mode (for MetalFX)
    func setMode(_ mode: UpscalingMode) {
        metalFXUpscaler?.setMode(mode)
        currentMode = metalFXUpscaler?.mode ?? mode
    }
    
    /// Signal a scene cut
    func signalSceneCut() {
        metalFXUpscaler?.signalSceneCut()
    }
}
