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
import QuartzCore

/// A SwiftUI view that renders an MTLTexture directly on GPU.
/// Optimized for high-resolution content with minimal CPU overhead.
struct MetalTextureView: UIViewRepresentable {
    let frames: VideoFrameMailbox
    var onFirstFrame: () -> Void = {}
    var onProcessingStatus: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.framebufferOnly = true
        
        // SDR Mode: Use standard BGRA8 format for SDR content
        // NOTE: bgra10_xr (EDR) expects linear/HDR values - using it with SDR content
        // (which has gamma encoding) causes washed-out colors
        // TODO: Switch to bgra10_xr when PS5 actually sends HDR (P010) content
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        DebugLog.print("[MetalTextureView] Using SDR pixel format: bgra8Unorm")
        
        // Request the display cadence; submit GPU work only for a new decoded frame.
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 120
        if let layer = mtkView.layer as? CAMetalLayer {
            layer.maximumDrawableCount = 3
            layer.allowsNextDrawableTimeout = true
        }
        mtkView.autoResizeDrawable = true
        
        // High resolution for visionOS
        mtkView.contentScaleFactor = 2.0
        
        // visionOS turns gamepad presses into gaze + pinch events unless the view
        // hosting the CAMetalLayer declares that it handles them itself. Without
        // this interaction GCExtendedGamepad values never change while streaming.
        let gamepadInteraction = GCEventInteraction()
        gamepadInteraction.handledEventTypes = .gamepad
        mtkView.addInteraction(gamepadInteraction)
        
        return mtkView
    }
    
    func updateUIView(_ mtkView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(frames: frames, onFirstFrame: onFirstFrame, onProcessingStatus: onProcessingStatus)
    }

    class Coordinator: NSObject, MTKViewDelegate, @unchecked Sendable {
        private let frames: VideoFrameMailbox
        private let onFirstFrame: () -> Void
        private let onProcessingStatus: (String) -> Void
        private var lastProcessingStatus: String?
        private var lastMode: UpscalerType?
        private var lastSharpness: Float?
        private let renderQueue = DispatchQueue(label: "video.render", qos: .userInteractive)
        // Never wait on main for GPU capacity. At most two command buffers in flight.
        private let capacity = DispatchSemaphore(value: 2)
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var sampler: MTLSamplerState?
        private var vertexBuffer: MTLBuffer?
        private var textureCache: CVMetalTextureCache?
        private var metalFX: MetalFXUpscaler?
        private var enhanced: EnhancedUpscaler?
        private var attemptedMetalFX = false
        private var attemptedEnhanced = false
        private var isSetup = false
        private var lastFrameID: UInt64 = 0
        private var lastTimingReport: Double = 0
        private var lastDrawableWarning: Double = 0
        private var announcedFirstFrame = false

        init(frames: VideoFrameMailbox, onFirstFrame: @escaping () -> Void, onProcessingStatus: @escaping (String) -> Void) {
            self.frames = frames
            self.onFirstFrame = onFirstFrame
            self.onProcessingStatus = onProcessingStatus
            super.init()
        }

        func setupPipeline(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra10_xr) {
            guard !isSetup else { return }
            
            commandQueue = device.makeCommandQueue()
            CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
            
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
            guard capacity.wait(timeout: .now()) == .success else { return }
            guard let device = view.device,
                  let layer = view.layer as? CAMetalLayer else {
                capacity.signal()
                return
            }
            renderQueue.async { [self] in
                autoreleasepool {
                    setupPipeline(device: device, pixelFormat: .bgra8Unorm)
                    let state = frames.snapshot()
                    guard state.enabled, let frame = state.frame,
                          (frame.id != lastFrameID || state.mode != lastMode || state.sharpness != lastSharpness),
                          let pipelineState, let sampler, let vertexBuffer,
                          let commandBuffer = commandQueue?.makeCommandBuffer() else {
                        capacity.signal()
                        return
                    }
                    // Drawable acquisition may block; it belongs on the renderer queue too.
                    guard let drawable = layer.nextDrawable() else {
                        let now = CACurrentMediaTime()
                        if now - lastDrawableWarning >= 2 {
                            lastDrawableWarning = now
                            DebugLog.print("[Video] No drawable available; latest decoded frame=\(frame.id)")
                        }
                        capacity.signal(); return
                    }
                    let reportTiming = CACurrentMediaTime() - lastTimingReport >= 2
                    if reportTiming { lastTimingReport = CACurrentMediaTime() }
                    let renderPass = MTLRenderPassDescriptor()
                    renderPass.colorAttachments[0].texture = drawable.texture
                    renderPass.colorAttachments[0].loadAction = .clear
                    renderPass.colorAttachments[0].storeAction = .store
                    renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                    let buffer = frame.pixelBuffer
                    var cvTexture: CVMetalTexture?
                    guard let textureCache,
                          CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil,
                            .bgra8Unorm, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                            0, &cvTexture) == kCVReturnSuccess,
                          let cvTexture, let native = CVMetalTextureGetTexture(cvTexture) else {
                        capacity.signal()
                        return
                    }
                    var texture = native
                    var appliedMode: UpscalerType = .native
                    var fallbackReason: String?
                    // Thermal pressure always falls back to native, never to the heavier Lanczos pass.
                    let thermal = ProcessInfo.processInfo.thermalState
                    let mode = thermal == .serious || thermal == .critical ? .native : state.mode
                    if mode == .metalFX && CVPixelBufferGetWidth(buffer) == 1920 && CVPixelBufferGetHeight(buffer) == 1080 {
                        if !attemptedMetalFX { attemptedMetalFX = true; metalFX = MetalFXUpscaler() }
                        if let output = metalFX?.encode(buffer, commandBuffer: commandBuffer) {
                            texture = output
                            appliedMode = .metalFX
                        } else {
                            fallbackReason = "MetalFX unavailable"
                        }
                    } else if mode == .enhanced {
                        if !attemptedEnhanced { attemptedEnhanced = true; enhanced = EnhancedUpscaler() }
                        enhanced?.sharpenStrength = state.sharpness
                        if let output = enhanced?.encode(buffer, commandBuffer: commandBuffer) {
                            texture = output
                            appliedMode = .enhanced
                        } else {
                            fallbackReason = "Enhanced unavailable"
                        }
                    }
                    if mode != state.mode {
                        fallbackReason = "Temperature protection"
                    } else if mode == .metalFX && appliedMode == .native && fallbackReason == nil {
                        fallbackReason = "MetalFX requires a 1080p stream"
                    }
                    let name = appliedMode == .native ? "Native" : appliedMode.rawValue
                    var processingStatus = "\(name) · \(native.width)×\(native.height) → \(texture.width)×\(texture.height)"
                    if let fallbackReason { processingStatus += " · \(fallbackReason)" }
                    let status = processingStatus
                    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
                        capacity.signal()
                        return
                    }
                    encoder.setRenderPipelineState(pipelineState)
                    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.setFragmentSamplerState(sampler, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    encoder.endEncoding()
                    let capacity = self.capacity
                    commandBuffer.addCompletedHandler { completed in
                        // Retain the decoder's IOSurface until the GPU has stopped reading it.
                        withExtendedLifetime((buffer, cvTexture)) {}
                        capacity.signal()
                        if completed.status == .completed {
                            self.renderQueue.async {
                                if self.lastProcessingStatus != status {
                                    self.lastProcessingStatus = status
                                    DebugLog.print("[Video] Processing: \(status)")
                                    DispatchQueue.main.async { self.onProcessingStatus(status) }
                                }
                                if !self.announcedFirstFrame {
                                    self.announcedFirstFrame = true
                                    DispatchQueue.main.async(execute: self.onFirstFrame)
                                }
                            }
                            if reportTiming {
                                let age = CACurrentMediaTime() * 1000 - Double(frame.receivedAt) / 1000
                                let gpu = (completed.gpuEndTime - completed.gpuStartTime) * 1000
                                DebugLog.print("[Video] receive-to-GPU=\(String(format: "%.1f", age))ms GPU=\(String(format: "%.1f", gpu))ms")
                            }
                        } else {
                            self.renderQueue.async {
                                if self.lastFrameID == frame.id { self.lastFrameID = 0 }
                            }
                            DebugLog.print("[Video] GPU command failed: \(String(describing: completed.error))")
                        }
                    }
                    lastFrameID = frame.id
                    lastMode = state.mode
                    lastSharpness = state.sharpness
                    if reportTiming {
                        drawable.addPresentedHandler { presented in
                            let time = presented.presentedTime
                            let received = Double(frame.receivedAt) / 1_000_000
                            guard time > 0, time >= received else {
                                DebugLog.print("[Video] Presentation timestamp unavailable; no latency sample")
                                return
                            }
                            DebugLog.print("[Video] receive-to-present=\(String(format: "%.1f", (time - received) * 1000))ms (local pipeline only)")
                        }
                    }
                    commandBuffer.present(drawable)
                    commandBuffer.commit()
                }
            }
        }
    }
}
