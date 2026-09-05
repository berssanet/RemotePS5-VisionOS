//
//  MetalTextureView.swift
//  VisionRemotePS5
//
//  Direct GPU texture rendering using MTKView.
//  Optimized for displaying upscaled 4K content from MetalFX.
//

import GameController
import SwiftUI
import MetalKit
import CoreGraphics

/// A SwiftUI view that renders an MTLTexture directly on GPU.
/// Optimized for high-resolution content with minimal CPU overhead.
struct MetalTextureView: UIViewRepresentable {
    let texture: MTLTexture?
    let frameId: UInt64  // Forces SwiftUI to update when frame changes
    
    init(texture: MTLTexture?, frameId: UInt64 = 0) {
        self.texture = texture
        self.frameId = frameId
    }
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = texture?.device ?? MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.framebufferOnly = true
        
        // SDR Mode: Use standard BGRA8 format for SDR content
        // NOTE: bgra10_xr (EDR) expects linear/HDR values - using it with SDR content
        // (which has gamma encoding) causes washed-out colors
        // TODO: Switch to bgra10_xr when PS5 actually sends HDR (P010) content
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        DebugLog.print("[MetalTextureView] Using SDR pixel format: bgra8Unorm")
        
        // Use continuous rendering at 60fps for smooth video playback
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.autoResizeDrawable = true
        
        // High resolution for visionOS
        mtkView.contentScaleFactor = 2.0
        
        // visionOS turns gamepad presses into gaze + pinch events unless the view
        // hosting the CAMetalLayer declares that it handles them itself. Without
        // this interaction GCExtendedGamepad values never change while streaming.
        let gamepadInteraction = GCEventInteraction()
        gamepadInteraction.handledEventTypes = .gamepad
        mtkView.addInteraction(gamepadInteraction)
        
        // Initialize render pipeline
        if let device = mtkView.device {
            context.coordinator.setupPipeline(device: device, pixelFormat: mtkView.colorPixelFormat)
        }
        
        return mtkView
    }
    
    func updateUIView(_ mtkView: MTKView, context: Context) {
        context.coordinator.texture = texture
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(texture: texture)
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        var texture: MTLTexture?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var sampler: MTLSamplerState?
        private var vertexBuffer: MTLBuffer?
        private var isSetup = false
        
        init(texture: MTLTexture?) {
            self.texture = texture
            super.init()
        }
        
        func setupPipeline(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra10_xr) {
            guard !isSetup else { return }
            
            commandQueue = device.makeCommandQueue()
            
            // Create shader library from source
            // HDR-aware shader: handles both SDR and EDR textures
            let shaderSource = """
            #include <metal_stdlib>
            using namespace metal;
            
            struct VertexOut {
                float4 position [[position]];
                float2 texCoord;
            };
            
            vertex VertexOut textureVertex(uint vertexID [[vertex_id]],
                                           constant float4 *vertices [[buffer(0)]]) {
                float4 vertexData = vertices[vertexID];
                VertexOut out;
                out.position = float4(vertexData.xy, 0.0, 1.0);
                out.texCoord = vertexData.zw;
                return out;
            }
            
            // HDR-aware fragment shader
            // Supports both BGRA8 (SDR) and RGBA16Float/BGRA10_XR (HDR) textures
            // Output values >1.0 enable Extended Dynamic Range on Vision Pro
            fragment float4 textureFragment(VertexOut in [[stage_in]],
                                           texture2d<float> tex [[texture(0)]],
                                           sampler samp [[sampler(0)]]) {
                float4 color = tex.sample(samp, in.texCoord);
                // Pass through - EDR values >1.0 are preserved for HDR display
                return color;
            }
            """
            
            do {
                let library = try device.makeLibrary(source: shaderSource, options: nil)
                let vertexFunc = library.makeFunction(name: "textureVertex")
                let fragmentFunc = library.makeFunction(name: "textureFragment")
                
                let pipelineDesc = MTLRenderPipelineDescriptor()
                pipelineDesc.vertexFunction = vertexFunc
                pipelineDesc.fragmentFunction = fragmentFunc
                // Use HDR-capable pixel format
                pipelineDesc.colorAttachments[0].pixelFormat = pixelFormat
                
                pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
                DebugLog.print("[MetalTextureView] ✅ Pipeline created (format: \(pixelFormat.rawValue))")
            } catch {
                DebugLog.print("[MetalTextureView] ❌ Failed to create pipeline: \(error)")
                return
            }
            
            // Create sampler with linear filtering for smooth scaling
            let samplerDesc = MTLSamplerDescriptor()
            samplerDesc.magFilter = .linear
            samplerDesc.minFilter = .linear
            samplerDesc.mipFilter = .notMipmapped
            samplerDesc.sAddressMode = .clampToEdge
            samplerDesc.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: samplerDesc)
            
            // Create fullscreen quad vertices: (x, y, u, v)
            let vertices: [Float] = [
                -1.0, -1.0, 0.0, 1.0,  // Bottom-left
                 1.0, -1.0, 1.0, 1.0,  // Bottom-right
                -1.0,  1.0, 0.0, 0.0,  // Top-left
                 1.0,  1.0, 1.0, 0.0,  // Top-right
            ]
            vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.size, options: .storageModeShared)
            
            isSetup = true
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle resize if needed
        }
        
        func draw(in view: MTKView) {
            // Skip if no texture
            guard let texture = texture else {
                // Present empty frame to avoid hang
                guard let drawable = view.currentDrawable,
                      let commandBuffer = commandQueue?.makeCommandBuffer(),
                      let renderPassDesc = view.currentRenderPassDescriptor else { return }
                
                if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) {
                    encoder.endEncoding()
                }
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }
            
            guard let pipelineState = pipelineState,
                  let sampler = sampler,
                  let vertexBuffer = vertexBuffer,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let renderPassDesc = view.currentRenderPassDescriptor else { return }
            
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return }
            
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

#Preview {
    MetalTextureView(texture: nil, frameId: 0)
        .frame(width: 400, height: 225)
}
