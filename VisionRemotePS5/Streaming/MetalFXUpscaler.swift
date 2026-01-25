//
//  MetalFXUpscaler.swift
//  VisionRemotePS5
//
//  GPU upscaling from 1080p to 4K using MetalFX Spatial Scaler.
//  NOTE: MTLFXTemporalScaler is NOT available on visionOS, only Spatial Scaler is supported.
//  Uses perceptual color processing for high-quality upscaling.
//  Supports HDR with .bgra10_xr (Extended Range) pixel format.
//  Zero-copy: output texture is private (GPU-only) for maximum performance.
//

import Foundation
import Metal
import MetalFX
import CoreVideo

/// Upscaling mode selection
/// NOTE: Only .spatial is available on visionOS
enum UpscalingMode {
    case spatial   // MetalFX Spatial Scaler (visionOS supported)
    case temporal  // Not available on visionOS
}

/// HDR configuration for the upscaler
struct MetalFXHDRConfig {
    /// HDR precision mode
    enum HDRPrecision: String {
        case standard   // bgra10_xr - Good for most HDR content (2.0 EDR headroom)
        case high       // rgba16Float - Maximum precision for extreme HDR (8.0+ EDR headroom)
    }
    
    /// Enable HDR processing with extended range formats
    var hdrEnabled: Bool = false
    
    /// HDR precision level (affects format choice)
    var precision: HDRPrecision = .standard
    
    /// Maximum EDR headroom for HDR content (1.0 = SDR, 2.0+ = HDR)
    /// Vision Pro Micro-OLED typically supports 2.0-4.0 EDR
    var maxEDRHeadroom: Float = 2.0
    
    /// Pixel format for SDR mode
    static let sdrFormat: MTLPixelFormat = .bgra8Unorm
    
    /// Pixel format for standard HDR (Apple Extended Range - supports values > 1.0)
    static let hdrFormat: MTLPixelFormat = .bgra10_xr
    
    /// Pixel format for high-precision HDR (full 16-bit float for PQ/HLG)
    static let hdrHighPrecisionFormat: MTLPixelFormat = .rgba16Float
    
    /// Get the appropriate format based on HDR state and precision
    var colorFormat: MTLPixelFormat {
        guard hdrEnabled else { return Self.sdrFormat }
        switch precision {
        case .standard: return Self.hdrFormat
        case .high: return Self.hdrHighPrecisionFormat
        }
    }
    
    var outputFormat: MTLPixelFormat {
        return colorFormat
    }
    
    /// Description for logging
    var description: String {
        if !hdrEnabled { return "SDR (bgra8Unorm)" }
        switch precision {
        case .standard: return "HDR (bgra10_xr, EDR: \(maxEDRHeadroom))"
        case .high: return "HDR High (rgba16Float, EDR: \(maxEDRHeadroom))"
        }
    }
}

// MARK: - HDR Color Metadata

/// Color metadata extracted from CVPixelBuffer for HDR color management.
/// These values describe how to interpret the pixel data.
struct HDRColorMetadata: Sendable {
    /// Color primaries (e.g., BT.709, BT.2020, Display P3)
    let colorPrimaries: CFString?
    
    /// Transfer function (e.g., sRGB, PQ, HLG)
    let transferFunction: CFString?
    
    /// YCbCr matrix (for YUV content)
    let ycbcrMatrix: CFString?
    
    /// Whether content is HDR (PQ or HLG transfer function)
    var isHDR: Bool {
        guard let tf = transferFunction else { return false }
        return CFEqual(tf, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
               CFEqual(tf, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
    }
    
    /// Whether content uses PQ (Perceptual Quantizer) EOTF
    var isPQ: Bool {
        guard let tf = transferFunction else { return false }
        return CFEqual(tf, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
    }
    
    /// Whether content uses HLG (Hybrid Log-Gamma)
    var isHLG: Bool {
        guard let tf = transferFunction else { return false }
        return CFEqual(tf, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
    }
    
    /// Whether content uses wide color gamut (BT.2020 or Display P3)
    var isWideGamut: Bool {
        guard let cp = colorPrimaries else { return false }
        return CFEqual(cp, kCVImageBufferColorPrimaries_ITU_R_2020) ||
               CFEqual(cp, kCVImageBufferColorPrimaries_P3_D65)
    }
    
    /// Whether content uses BT.2020 color primaries
    var isBT2020: Bool {
        guard let cp = colorPrimaries else { return false }
        return CFEqual(cp, kCVImageBufferColorPrimaries_ITU_R_2020)
    }
    
    /// Create empty metadata
    static let unknown = HDRColorMetadata(colorPrimaries: nil, transferFunction: nil, ycbcrMatrix: nil)
    
    /// Create BT.2020 + PQ (standard HDR10)
    static let hdr10 = HDRColorMetadata(
        colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
        transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
        ycbcrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020
    )
    
    /// Suggested EDR headroom based on transfer function
    /// PQ: Can represent up to 10,000 nits, but typical content is 1,000-4,000 nits
    /// HLG: Typically 1,000-2,000 nits
    var suggestedEDRHeadroom: Float {
        if isPQ { return 4.0 }  // 4x SDR white for typical HDR10 content
        if isHLG { return 2.0 } // 2x SDR white for HLG
        return 1.0 // SDR
    }
    
    /// Get CGColorSpace for this content (visionOS 2.0+)
    @available(visionOS 2.0, *)
    var cgColorSpace: CGColorSpace? {
        if isPQ && isBT2020 {
            // BT.2020 + PQ = HDR10
            return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        } else if isHLG && isBT2020 {
            // BT.2020 + HLG
            return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        } else if isBT2020 {
            // BT.2020 without HDR transfer function
            return CGColorSpace(name: CGColorSpace.itur_2020)
        } else if let cp = colorPrimaries, CFEqual(cp, kCVImageBufferColorPrimaries_P3_D65) {
            // Display P3
            return CGColorSpace(name: CGColorSpace.displayP3)
        }
        // Default: sRGB
        return CGColorSpace(name: CGColorSpace.sRGB)
    }
    
    /// Debug description
    var description: String {
        let cp = colorPrimaries.map { String(describing: $0) } ?? "unknown"
        let tf = transferFunction.map { String(describing: $0) } ?? "unknown"
        return "ColorMetadata(primaries: \(cp), transfer: \(tf), HDR: \(isHDR), EDR: \(suggestedEDRHeadroom))"
    }
}

/// MetalFX-based upscaler for PS5 Remote Play video stream.
/// Upscales 1080p BGRA frames to 4K resolution with optional HDR support.
final class MetalFXUpscaler {
    
    // MARK: - Constants
    
    static let inputWidth = 1920
    static let inputHeight = 1080
    static let outputWidth = 3840
    static let outputHeight = 2160
    
    // MARK: - Metal Resources
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    
    // MARK: - MetalFX Scaler
    
    private var spatialScaler: MTLFXSpatialScaler?
    
    // MARK: - Output Texture (Private - GPU only, used directly for rendering)
    
    private var outputTexture: MTLTexture?
    
    // MARK: - Mode Selection
    
    /// Current upscaling mode (always .spatial on visionOS)
    private(set) var mode: UpscalingMode = .spatial
    
    // MARK: - HDR Configuration
    
    /// HDR configuration (can be changed at runtime)
    private(set) var hdrConfig: MetalFXHDRConfig
    
    /// Current pixel format based on HDR state
    var currentPixelFormat: MTLPixelFormat {
        return hdrConfig.colorFormat
    }
    
    // MARK: - State
    
    private var frameCount: UInt64 = 0
    
    /// Triple buffer pool for non-blocking GPU sync
    private var tripleBuffer: TripleBufferPool?
    
    // MARK: - MTLEvent Synchronization
    
    /// Shared event for GPU-GPU synchronization (avoids CPU waits)
    private var syncEvent: MTLSharedEvent?
    
    /// Event counter for frame synchronization
    private var eventCounter: UInt64 = 0
    
    /// Last extracted color metadata
    private(set) var lastColorMetadata: HDRColorMetadata = .unknown
    
    /// Callback invoked when upscaling completes (non-blocking)
    var onUpscaleComplete: ((MTLTexture) -> Void)?
    
    // MARK: - Initialization
    
    init?(hdrEnabled: Bool = false) {
        self.hdrConfig = MetalFXHDRConfig(hdrEnabled: hdrEnabled)
        
        print("[MetalFXUpscaler] 🚀 Starting initialization (HDR: \(hdrEnabled ? "enabled" : "disabled"))...")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[MetalFXUpscaler] ❌ No Metal device available")
            return nil
        }
        print("[MetalFXUpscaler] ✅ Metal device: \(device.name)")
        
        guard let commandQueue = device.makeCommandQueue() else {
            print("[MetalFXUpscaler] ❌ Failed to create command queue")
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        
        // Create texture cache for CVPixelBuffer conversion
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let textureCache = cache else {
            print("[MetalFXUpscaler] ❌ Failed to create texture cache: \(status)")
            return nil
        }
        self.textureCache = textureCache
        print("[MetalFXUpscaler] ✅ Texture cache created")
        
        // Create output texture - private storage for MetalFX (required)
        // Use HDR format (.bgra10_xr) if HDR enabled, otherwise SDR (.bgra8Unorm)
        let outputPixelFormat = hdrConfig.outputFormat
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: outputPixelFormat,
            width: Self.outputWidth,
            height: Self.outputHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        
        guard let output = device.makeTexture(descriptor: descriptor) else {
            print("[MetalFXUpscaler] ❌ Failed to create output texture")
            return nil
        }
        self.outputTexture = output
        let formatName = hdrEnabled ? "bgra10_xr (HDR)" : "bgra8Unorm (SDR)"
        print("[MetalFXUpscaler] ✅ Output texture created: \(Self.outputWidth)x\(Self.outputHeight) [\(formatName)]")
        
        // Initialize Spatial Scaler (only option on visionOS)
        // NOTE: MTLFXTemporalScaler is NOT available on visionOS
        guard initializeSpatialScaler() else {
            return nil
        }
        self.mode = .spatial
        
        // Create triple buffer pool with matching format
        self.tripleBuffer = TripleBufferPool(
            device: device,
            width: Self.outputWidth,
            height: Self.outputHeight,
            pixelFormat: hdrConfig.outputFormat
        )
        
        // Create MTLSharedEvent for GPU-GPU synchronization
        self.syncEvent = device.makeSharedEvent()
        if syncEvent != nil {
            print("[MetalFXUpscaler] ✅ MTLSharedEvent created for GPU sync")
        }
        
        let hdrStatus = hdrEnabled ? "HDR (bgra10_xr)" : "SDR (bgra8Unorm)"
        print("[MetalFXUpscaler] ✅ Initialized (SPATIAL mode - visionOS)")
        print("[MetalFXUpscaler]   Input: \(Self.inputWidth)x\(Self.inputHeight)")
        print("[MetalFXUpscaler]   Output: \(Self.outputWidth)x\(Self.outputHeight)")
        print("[MetalFXUpscaler]   Format: \(hdrStatus)")
        print("[MetalFXUpscaler]   ⚠️ Temporal Scaler not available on visionOS")
    }
    
    // MARK: - Scaler Initialization
    
    private func initializeSpatialScaler() -> Bool {
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            print("[MetalFXUpscaler] ❌ MetalFX Spatial Scaler not supported")
            return false
        }
        print("[MetalFXUpscaler] ✅ MetalFX Spatial Scaler supported")
        
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = Self.inputWidth
        descriptor.inputHeight = Self.inputHeight
        descriptor.outputWidth = Self.outputWidth
        descriptor.outputHeight = Self.outputHeight
        
        // Use HDR-capable format when HDR is enabled
        // .bgra10_xr supports Extended Range (values > 1.0) for HDR content
        descriptor.colorTextureFormat = hdrConfig.colorFormat
        descriptor.outputTextureFormat = hdrConfig.outputFormat
        descriptor.colorProcessingMode = .perceptual
        
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            print("[MetalFXUpscaler] ❌ Failed to create Spatial Scaler")
            return false
        }
        self.spatialScaler = scaler
        print("[MetalFXUpscaler] ✅ Spatial Scaler created")
        return true
    }
    
    // MARK: - Mode Control
    
    /// Switch upscaling mode
    /// NOTE: On visionOS, only .spatial is supported
    func setMode(_ newMode: UpscalingMode) {
        if newMode == .temporal {
            print("[MetalFXUpscaler] ⚠️ Temporal mode not available on visionOS, using Spatial")
        }
        // Always use spatial on visionOS
        mode = .spatial
    }
    
    // MARK: - Upscaling
    
    /// Extract color metadata from CVPixelBuffer
    /// Call this before upscaling to capture HDR color properties
    func extractColorMetadata(from pixelBuffer: CVPixelBuffer) -> HDRColorMetadata {
        // Get color attachments from pixel buffer
        let attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate)
        
        var colorPrimaries: CFString?
        var transferFunction: CFString?
        var ycbcrMatrix: CFString?
        
        if let attachments = attachments as? [CFString: Any] {
            // CFString values - use direct access and cast
            if let cp = attachments[kCVImageBufferColorPrimariesKey] {
                colorPrimaries = (cp as! CFString)
            }
            if let tf = attachments[kCVImageBufferTransferFunctionKey] {
                transferFunction = (tf as! CFString)
            }
            if let mat = attachments[kCVImageBufferYCbCrMatrixKey] {
                ycbcrMatrix = (mat as! CFString)
            }
        }
        
        let metadata = HDRColorMetadata(
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            ycbcrMatrix: ycbcrMatrix
        )
        
        // Log first detection of HDR content
        if metadata.isHDR && !lastColorMetadata.isHDR {
            print("[MetalFXUpscaler] 🎨 HDR content detected: \(metadata.description)")
        }
        
        lastColorMetadata = metadata
        return metadata
    }
    
    /// Upscale a CVPixelBuffer from 1080p to 4K (synchronous)
    func upscale(_ pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let spatialScaler = spatialScaler,
              let textureCache = textureCache,
              let outputTexture = self.outputTexture else {
            print("[MetalFXUpscaler] ⚠️ upscale: missing resources")
            return nil
        }
        
        frameCount += 1
        
        // Extract color metadata for HDR handling
        _ = extractColorMetadata(from: pixelBuffer)
        
        // Get pixel buffer info
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        // Log first frame details
        if frameCount == 1 {
            let ioSurface = CVPixelBufferGetIOSurface(pixelBuffer)
            let zeroCopyStatus = ioSurface != nil ? "✅ Zero-copy" : "⚠️ No IOSurface"
            print("[MetalFXUpscaler] 📹 First frame: \(width)x\(height), format=\(formatName(format)), \(zeroCopyStatus)")
            print("[MetalFXUpscaler] 🎨 Color: \(lastColorMetadata.description)")
        }
        
        // Create Metal texture from CVPixelBuffer
        var cvTexture: CVMetalTexture?
        let inputFormat = hdrConfig.colorFormat
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            inputFormat, width, height, 0, &cvTexture
        )
        
        guard status == kCVReturnSuccess, let cvTexture = cvTexture,
              let inputTexture = CVMetalTextureGetTexture(cvTexture) else {
            if frameCount <= 5 {
                print("[MetalFXUpscaler] ❌ Failed to create texture from CVPixelBuffer: \(status)")
            }
            return nil
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }
        
        // Apply Spatial Scaler
        spatialScaler.colorTexture = inputTexture
        spatialScaler.outputTexture = outputTexture
        spatialScaler.encode(commandBuffer: commandBuffer)
        
        let frameNum = frameCount
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if frameNum % 60 == 0 {
            print("[MetalFXUpscaler] 📊 Frame \(frameNum) processed (SPATIAL)")
        }
        
        return outputTexture
    }
    
    /// Upscale with MTLEvent synchronization (non-blocking, GPU-GPU sync)
    /// Returns the output texture and event counter for downstream synchronization
    func upscaleAsync(_ pixelBuffer: CVPixelBuffer) -> (texture: MTLTexture, eventValue: UInt64)? {
        guard let spatialScaler = spatialScaler,
              let textureCache = textureCache,
              let outputTexture = self.outputTexture,
              let syncEvent = self.syncEvent else {
            return nil
        }
        
        frameCount += 1
        eventCounter += 1
        
        // Extract color metadata
        _ = extractColorMetadata(from: pixelBuffer)
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Create input texture
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            hdrConfig.colorFormat, width, height, 0, &cvTexture
        )
        
        guard status == kCVReturnSuccess, let cvTexture = cvTexture,
              let inputTexture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }
        
        // Encode upscaling
        spatialScaler.colorTexture = inputTexture
        spatialScaler.outputTexture = outputTexture
        spatialScaler.encode(commandBuffer: commandBuffer)
        
        // Signal event when GPU work completes (no CPU wait needed)
        let currentEventValue = eventCounter
        commandBuffer.encodeSignalEvent(syncEvent, value: currentEventValue)
        
        commandBuffer.commit()
        // NO waitUntilCompleted() - caller uses MTLEvent to sync
        
        return (outputTexture, currentEventValue)
    }
    
    /// Get the shared event for downstream GPU synchronization
    var sharedEvent: MTLSharedEvent? {
        return syncEvent
    }
    
    // MARK: - Scene Cut (no-op for Spatial Scaler)
    
    /// Signal a scene cut - no effect for Spatial Scaler (no temporal history)
    func signalSceneCut() {
        // Spatial Scaler has no temporal history, nothing to reset
    }
    
    // MARK: - HDR Control
    
    /// Enable or disable HDR mode
    /// Note: Requires reinitializing textures and scaler for format change
    func setHDREnabled(_ enabled: Bool) {
        guard enabled != hdrConfig.hdrEnabled else { return }
        
        hdrConfig.hdrEnabled = enabled
        
        // Reinitialize scaler with new format
        if !initializeSpatialScaler() {
            print("[MetalFXUpscaler] ❌ Failed to reinitialize scaler for HDR change")
        }
        
        // Recreate output texture with new format
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: hdrConfig.outputFormat,
            width: Self.outputWidth,
            height: Self.outputHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        
        if let newOutput = device.makeTexture(descriptor: descriptor) {
            outputTexture = newOutput
            let formatName = enabled ? "bgra10_xr (HDR)" : "bgra8Unorm (SDR)"
            print("[MetalFXUpscaler] ✅ HDR mode changed, new format: \(formatName)")
        }
    }
    
    /// Check if HDR is currently enabled
    var isHDREnabled: Bool {
        return hdrConfig.hdrEnabled
    }
    
    // MARK: - Utilities
    
    private func formatName(_ format: OSType) -> String {
        switch format {
        case kCVPixelFormatType_32BGRA:
            return "BGRA"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return "YUV420 (Video Range)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return "YUV420 (Full Range)"
        default:
            return "Unknown(\(format))"
        }
    }
    
    func flush() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}
