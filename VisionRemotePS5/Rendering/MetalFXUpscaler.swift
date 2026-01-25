//
//  MetalFXUpscaler.swift
//  VisionRemotePS5
//
//  MetalFX Spatial Scaler for GPU-only upscaling from 1080p to 4K.
//  Uses Apple's MetalFX framework for high-quality, low-latency upscaling.
//

import Foundation
import Metal
import MetalFX
import CoreVideo

/// High-performance GPU upscaler using MetalFX Spatial Scaler.
/// Upscales 1080p video to 4K (3840x2160) with minimal latency.
@MainActor
final class MetalFXUpscaler {
    
    // MARK: - Properties
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var spatialScaler: MTLFXSpatialScaler?
    private var textureCache: CVMetalTextureCache?
    
    // YUV to RGB conversion
    private var yuvToRGBPipeline: MTLComputePipelineState?
    private var rgbTexture: MTLTexture?
    
    // Output texture (4K)
    private var outputTexture: MTLTexture?
    
    // Current dimensions
    private var inputWidth: Int = 0
    private var inputHeight: Int = 0
    private let outputWidth: Int = 3840
    private let outputHeight: Int = 2160
    
    /// Whether the upscaler is ready for use
    var isReady: Bool { spatialScaler != nil && yuvToRGBPipeline != nil }
    
    // MARK: - Initialization
    
    init?() {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            print("[MetalFXUpscaler] ❌ No Metal device available")
            return nil
        }
        
        guard let queue = metalDevice.makeCommandQueue() else {
            print("[MetalFXUpscaler] ❌ Failed to create command queue")
            return nil
        }
        
        self.device = metalDevice
        self.commandQueue = queue
        
        // Create texture cache for zero-copy CVPixelBuffer access
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &cache)
        guard status == kCVReturnSuccess, let textureCache = cache else {
            print("[MetalFXUpscaler] ❌ Failed to create texture cache: \(status)")
            return nil
        }
        self.textureCache = textureCache
        
        // Load YUV to RGB shader
        guard loadShaders() else {
            print("[MetalFXUpscaler] ❌ Failed to load shaders")
            return nil
        }
        
        print("[MetalFXUpscaler] ✅ Initialized with device: \(metalDevice.name)")
    }
    
    // MARK: - Shader Loading
    
    private func loadShaders() -> Bool {
        guard let library = device.makeDefaultLibrary() else {
            print("[MetalFXUpscaler] ❌ Failed to load default library")
            return false
        }
        
        // Try to load existing YUV to RGB shader, or create inline
        if let function = library.makeFunction(name: "yuvToRGBConvert") {
            do {
                yuvToRGBPipeline = try device.makeComputePipelineState(function: function)
                return true
            } catch {
                print("[MetalFXUpscaler] ⚠️ Failed to create yuvToRGBConvert pipeline: \(error)")
            }
        }
        
        // Create inline shader if not found
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        kernel void yuvToRGBUpscaler(texture2d<float, access::read> yTexture [[texture(0)]],
                                     texture2d<float, access::read> uvTexture [[texture(1)]],
                                     texture2d<float, access::write> outTexture [[texture(2)]],
                                     uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
            
            float y = yTexture.read(gid).r;
            float2 uv = uvTexture.read(gid / 2).rg;
            
            // BT.709 YUV to RGB conversion
            float u = uv.x - 0.5;
            float v = uv.y - 0.5;
            
            float r = y + 1.5748 * v;
            float g = y - 0.1873 * u - 0.4681 * v;
            float b = y + 1.8556 * u;
            
            outTexture.write(float4(r, g, b, 1.0), gid);
        }
        """
        
        do {
            let inlineLibrary = try device.makeLibrary(source: shaderSource, options: nil)
            if let function = inlineLibrary.makeFunction(name: "yuvToRGBUpscaler") {
                yuvToRGBPipeline = try device.makeComputePipelineState(function: function)
                return true
            }
        } catch {
            print("[MetalFXUpscaler] ❌ Failed to compile inline shader: \(error)")
        }
        
        return false
    }
    
    // MARK: - Spatial Scaler Setup
    
    private func setupSpatialScaler(inputWidth: Int, inputHeight: Int) -> Bool {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual
        
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            print("[MetalFXUpscaler] ❌ Failed to create spatial scaler")
            return false
        }
        
        self.spatialScaler = scaler
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        
        // Create RGB intermediate texture
        let rgbDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: inputWidth,
            height: inputHeight,
            mipmapped: false
        )
        rgbDescriptor.usage = [.shaderRead, .shaderWrite]
        rgbDescriptor.storageMode = .private
        self.rgbTexture = device.makeTexture(descriptor: rgbDescriptor)
        
        // Create output 4K texture
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        outputDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        outputDescriptor.storageMode = .private
        self.outputTexture = device.makeTexture(descriptor: outputDescriptor)
        
        print("[MetalFXUpscaler] ✅ Spatial scaler configured: \(inputWidth)x\(inputHeight) → \(outputWidth)x\(outputHeight)")
        return true
    }
    
    // MARK: - Upscale Frame
    
    /// Upscale a CVPixelBuffer from 1080p to 4K using MetalFX.
    /// - Parameter pixelBuffer: Input frame (typically 1920x1080 NV12 or BGRA)
    /// - Returns: 4K MTLTexture or nil on failure
    func upscale(_ pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Setup scaler if dimensions changed
        if width != inputWidth || height != inputHeight || spatialScaler == nil {
            guard setupSpatialScaler(inputWidth: width, inputHeight: height) else {
                return nil
            }
        }
        
        guard let scaler = spatialScaler,
              let rgbTex = rgbTexture,
              let outputTex = outputTexture,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }
        
        // Convert input to RGB texture
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        if pixelFormat == kCVPixelFormatType_32BGRA {
            // Direct BGRA - create texture from pixel buffer
            guard let inputTexture = createBGRATexture(from: pixelBuffer) else {
                return nil
            }
            
            // Copy to private storage for MetalFX
            if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                blitEncoder.copy(from: inputTexture,
                                sourceSlice: 0,
                                sourceLevel: 0,
                                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                                sourceSize: MTLSize(width: width, height: height, depth: 1),
                                to: rgbTex,
                                destinationSlice: 0,
                                destinationLevel: 0,
                                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blitEncoder.endEncoding()
            }
        } else {
            // NV12 YUV - convert to RGB
            guard let yuvTextures = createYUVTextures(from: pixelBuffer),
                  let pipeline = yuvToRGBPipeline,
                  let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                return nil
            }
            
            computeEncoder.setComputePipelineState(pipeline)
            computeEncoder.setTexture(yuvTextures.y, index: 0)
            computeEncoder.setTexture(yuvTextures.uv, index: 1)
            computeEncoder.setTexture(rgbTex, index: 2)
            
            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(
                width: (width + 15) / 16,
                height: (height + 15) / 16,
                depth: 1
            )
            computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.endEncoding()
        }
        
        // Apply MetalFX upscaling
        scaler.colorTexture = rgbTex
        scaler.outputTexture = outputTex
        scaler.encode(commandBuffer: commandBuffer)
        
        // Execute GPU work
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        return outputTex
    }
    
    // MARK: - Texture Creation Helpers
    
    private func createBGRATexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        
        guard status == kCVReturnSuccess, let cvTex = cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }
    
    private func createYUVTextures(from pixelBuffer: CVPixelBuffer) -> (y: MTLTexture, uv: MTLTexture)? {
        guard let cache = textureCache else { return nil }
        
        // Y plane
        let yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        
        var yTexture: CVMetalTexture?
        var status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .r8Unorm, yWidth, yHeight, 0, &yTexture
        )
        guard status == kCVReturnSuccess, let yTex = yTexture,
              let yMTL = CVMetalTextureGetTexture(yTex) else { return nil }
        
        // UV plane
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        
        var uvTexture: CVMetalTexture?
        status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .rg8Unorm, uvWidth, uvHeight, 1, &uvTexture
        )
        guard status == kCVReturnSuccess, let uvTex = uvTexture,
              let uvMTL = CVMetalTextureGetTexture(uvTex) else { return nil }
        
        return (yMTL, uvMTL)
    }
    
    // MARK: - Cleanup
    
    func flush() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}
