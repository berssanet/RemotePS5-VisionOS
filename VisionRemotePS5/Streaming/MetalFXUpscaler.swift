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
}

/// HDR configuration for the upscaler
struct MetalFXHDRConfig {
    /// Enable HDR processing with extended range formats
    var hdrEnabled: Bool = false
    
    /// Pixel format for SDR mode
    static let sdrFormat: MTLPixelFormat = .bgra8Unorm
    
    /// Pixel format for HDR (Apple Extended Range - supports values > 1.0)
    static let hdrFormat: MTLPixelFormat = .bgra10_xr
    
    /// Get the appropriate format based on HDR state
    var colorFormat: MTLPixelFormat {
        return hdrEnabled ? Self.hdrFormat : Self.sdrFormat
    }
    
    var outputFormat: MTLPixelFormat {
        return colorFormat
    }
}

// MARK: - HDR Color Metadata

/// Color metadata extracted from CVPixelBuffer for HDR color management.
/// These values describe how to interpret the pixel data.
/// `@unchecked` because CFString is immutable and thread-safe but is not
/// statically marked Sendable by the CoreFoundation overlay.
struct HDRColorMetadata: @unchecked Sendable {
    /// Color primaries (e.g., BT.709, BT.2020, Display P3)
    let colorPrimaries: CFString?
    
    /// Transfer function (e.g., sRGB, PQ, HLG)
    let transferFunction: CFString?
    
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
    
    /// Create empty metadata
    static let unknown = HDRColorMetadata(colorPrimaries: nil, transferFunction: nil)
    
    /// Suggested EDR headroom based on transfer function
    /// PQ: Can represent up to 10,000 nits, but typical content is 1,000-4,000 nits
    /// HLG: Typically 1,000-2,000 nits
    var suggestedEDRHeadroom: Float {
        if isPQ { return 4.0 }  // 4x SDR white for typical HDR10 content
        if isHLG { return 2.0 } // 2x SDR white for HLG
        return 1.0 // SDR
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
    private var textureCache: CVMetalTextureCache?
    
    // MARK: - MetalFX Scaler
    
    private var spatialScaler: MTLFXSpatialScaler?
    
    // MARK: - Output Texture (Private - GPU only, used directly for rendering)
    
    private var outputTexture: MTLTexture?
    
    // MARK: - Mode Selection
    
    /// Current upscaling mode (always .spatial on visionOS)
    private(set) var mode: UpscalingMode = .spatial
    
    // MARK: - HDR Configuration
    
    /// HDR configuration (fixed at initialization)
    let hdrConfig: MetalFXHDRConfig
    
    // MARK: - State
    
    private var frameCount: UInt64 = 0
    
    /// Last extracted color metadata
    private(set) var lastColorMetadata: HDRColorMetadata = .unknown
    
    // MARK: - Initialization
    
    init?(hdrEnabled: Bool = false) {
        self.hdrConfig = MetalFXHDRConfig(hdrEnabled: hdrEnabled)
        
        DebugLog.info("MetalFXUpscaler", "🚀 Starting initialization (HDR: \(hdrEnabled ? "enabled" : "disabled"))...")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            DebugLog.error("MetalFXUpscaler", "No Metal device available")
            return nil
        }
        DebugLog.info("MetalFXUpscaler", "✅ Metal device: \(device.name)")
        

        
        self.device = device
        
        // Create texture cache for CVPixelBuffer conversion
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let textureCache = cache else {
            DebugLog.error("MetalFXUpscaler", "Failed to create texture cache: \(status)")
            return nil
        }
        self.textureCache = textureCache
        DebugLog.info("MetalFXUpscaler", "✅ Texture cache created")
        
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
            DebugLog.error("MetalFXUpscaler", "Failed to create output texture")
            return nil
        }
        self.outputTexture = output
        let formatName = hdrEnabled ? "bgra10_xr (HDR)" : "bgra8Unorm (SDR)"
        DebugLog.info("MetalFXUpscaler", "✅ Output texture: \(Self.outputWidth)x\(Self.outputHeight) [\(formatName)]")
        
        // Initialize Spatial Scaler (only option on visionOS)
        // NOTE: MTLFXTemporalScaler is NOT available on visionOS
        guard initializeSpatialScaler() else {
            return nil
        }
        self.mode = .spatial
        
        let hdrStatus = hdrEnabled ? "HDR (bgra10_xr)" : "SDR (bgra8Unorm)"
        DebugLog.info("MetalFXUpscaler", "✅ Initialized (SPATIAL mode, \(Self.inputWidth)x\(Self.inputHeight) → \(Self.outputWidth)x\(Self.outputHeight), \(hdrStatus))")
    }
    
    // MARK: - Scaler Initialization
    
    private func initializeSpatialScaler() -> Bool {
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            DebugLog.error("MetalFXUpscaler", "MetalFX Spatial Scaler not supported")
            return false
        }
        DebugLog.info("MetalFXUpscaler", "✅ MetalFX Spatial Scaler supported")
        
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
            DebugLog.error("MetalFXUpscaler", "Failed to create Spatial Scaler")
            return false
        }
        self.spatialScaler = scaler
        DebugLog.info("MetalFXUpscaler", "✅ Spatial Scaler created")
        return true
    }
    
    // MARK: - Upscaling
    
    /// Extract color metadata from CVPixelBuffer
    /// Call this before upscaling to capture HDR color properties
    func extractColorMetadata(from pixelBuffer: CVPixelBuffer) -> HDRColorMetadata {
        // Get color attachments from pixel buffer
        let attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate)
        
        var colorPrimaries: CFString?
        var transferFunction: CFString?
        
        if let attachments = attachments as? [CFString: Any] {
            // Conditional casts (via String bridging): attachment values come
            // from the network stream's decoder output — never trust them to
            // be CFString.
            colorPrimaries = (attachments[kCVImageBufferColorPrimariesKey] as? String).map { $0 as CFString }
            transferFunction = (attachments[kCVImageBufferTransferFunctionKey] as? String).map { $0 as CFString }
        }
        
        let metadata = HDRColorMetadata(
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction
        )
        
        // Log first detection of HDR content
        if metadata.isHDR && !lastColorMetadata.isHDR {
            DebugLog.info("MetalFXUpscaler", "🎨 HDR content detected: \(metadata.description)")
        }
        
        lastColorMetadata = metadata
        return metadata
    }
    
    /// Encode before the render pass on the renderer command buffer.
    func encode(_ pixelBuffer: CVPixelBuffer, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let spatialScaler = spatialScaler,
              let textureCache = textureCache,
              let outputTexture = self.outputTexture else {
            DebugLog.warning("MetalFXUpscaler", "upscale: missing resources")
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
            DebugLog.info("MetalFXUpscaler", "📹 First frame: \(width)x\(height), format=\(formatName(format)), \(zeroCopyStatus)")
            DebugLog.info("MetalFXUpscaler", "🎨 Color: \(lastColorMetadata.description)")
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
                DebugLog.error("MetalFXUpscaler", "Failed to create texture from CVPixelBuffer: \(status)")
            }
            return nil
        }
        
        // Create command buffer
        
        // Apply Spatial Scaler
        spatialScaler.colorTexture = inputTexture
        spatialScaler.outputTexture = outputTexture
        spatialScaler.encode(commandBuffer: commandBuffer)
        
        let frameNum = frameCount
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime((pixelBuffer, cvTexture)) {}
        }
        
        DebugLog.every(frameNum, interval: 60, "MetalFXUpscaler", "📊 Frame \(frameNum) processed (SPATIAL)")
        
        return outputTexture
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
}
