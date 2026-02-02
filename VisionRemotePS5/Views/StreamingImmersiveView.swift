//
//  StreamingImmersiveView.swift
//  VisionRemotePS5
//
//  Immersive view for streaming in VR space
//  Uses same coordinator pattern as RealityKitVideoView to avoid duplicate entities
//

import SwiftUI
import RealityKit
import CoreVideo
import Metal

// MARK: - Immersive Texture Coordinator

/// Separate coordinator for immersive mode (doesn't conflict with windowed mode)
@available(visionOS 2.0, *)
@MainActor
final class ImmersiveTextureCoordinator {
    static let shared = ImmersiveTextureCoordinator()
    
    private var lowLevelTexture: LowLevelTexture?
    private var textureResource: TextureResource?
    private var commandQueue: MTLCommandQueue?
    private var textureSize: (Int, Int) = (0, 0)
    private var isInitialized = false
    private var isInitializing = false
    
    private(set) var videoEntity: ModelEntity?
    private(set) var hasValidTexture = false
    
    private init() {}
    
    func getOrCreateEntity(width: Float, height: Float, distance: Float, elevation: Float) -> ModelEntity {
        if let existing = videoEntity {
            return existing
        }
        
        let mesh = MeshResource.generatePlane(width: width, height: height)
        let entity = ModelEntity(mesh: mesh)
        
        var material = UnlitMaterial()
        material.color = .init(tint: .clear)
        entity.model?.materials = [material]
        entity.position = [0, elevation, -distance]
        entity.name = "ImmersiveVideoPlane"
        
        videoEntity = entity
        
        print("[ImmersiveCoordinator] ✅ Entity created: \(width)x\(height)")
        
        return entity
    }
    
    func updateTexture(from sourceTexture: MTLTexture) {
        let newSize = (sourceTexture.width, sourceTexture.height)
        
        if isInitialized && textureSize == newSize {
            copyTextureContent(from: sourceTexture)
            return
        }
        
        guard !isInitializing else { return }
        isInitializing = true
        
        Task { @MainActor in
            await initializeTexture(from: sourceTexture)
        }
    }
    
    private func initializeTexture(from sourceTexture: MTLTexture) async {
        do {
            if commandQueue == nil {
                commandQueue = sourceTexture.device.makeCommandQueue()
            }
            
            let descriptor = LowLevelTexture.Descriptor(
                pixelFormat: .bgra8Unorm,
                width: sourceTexture.width,
                height: sourceTexture.height,
                depth: 1,
                mipmapLevelCount: 1,
                textureUsage: [.shaderRead, .shaderWrite]
            )
            
            let llTexture = try LowLevelTexture(descriptor: descriptor)
            let resource = try await TextureResource(from: llTexture)
            
            lowLevelTexture = llTexture
            textureResource = resource
            textureSize = (sourceTexture.width, sourceTexture.height)
            isInitialized = true
            isInitializing = false
            hasValidTexture = true
            
            print("[ImmersiveCoordinator] ✅ Texture: \(sourceTexture.width)x\(sourceTexture.height)")
            
            applyToEntity()
            copyTextureContent(from: sourceTexture)
            
        } catch {
            isInitializing = false
            print("[ImmersiveCoordinator] ❌ Failed: \(error)")
        }
    }
    
    func applyToEntity() {
        guard let entity = videoEntity, let resource = textureResource else { return }
        
        var material = UnlitMaterial()
        material.color = .init(texture: .init(resource))
        entity.model?.materials = [material]
    }
    
    private func copyTextureContent(from sourceTexture: MTLTexture) {
        guard let llTexture = lowLevelTexture,
              let queue = commandQueue,
              isInitialized else { return }
        
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        
        let destTexture = llTexture.replace(using: commandBuffer)
        
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        
        let copyWidth = min(sourceTexture.width, destTexture.width)
        let copyHeight = min(sourceTexture.height, destTexture.height)
        
        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
            to: destTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        
        blitEncoder.endEncoding()
        commandBuffer.commit()
    }
    
    func reset() {
        lowLevelTexture = nil
        textureResource = nil
        commandQueue = nil
        textureSize = (0, 0)
        isInitialized = false
        isInitializing = false
        videoEntity = nil
        hasValidTexture = false
        print("[ImmersiveCoordinator] 🔄 Reset")
    }
}

// MARK: - Streaming Immersive View

struct StreamingImmersiveView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var upscalingPipeline = UpscalingPipeline.shared
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    
    // v10.0: Dynamic EDR headroom (monitored via scene/device state)
    // visionOS doesn't expose displayEDRHeadroom directly via Environment
    // We use scene updates to estimate current headroom capability
    @State private var currentEDRHeadroom: CGFloat = 2.0
    
    @State private var showControls = false
    @State private var controlHideTimer: Timer?
    @State private var currentFrame: CVPixelBuffer?
    
    // v10.6: Virtual steering wheel hand tracking
    @StateObject private var steeringService = VirtualSteeringWheelService()
    @State private var steeringInputTimer: Timer?
    
    // v10.7: User-adjustable wheel position
    @State private var wheelPosition: SIMD3<Float> = [0, 0.6, -0.7]  // 70cm in front, 60cm height
    @State private var wheelDragOffset: SIMD3<Float> = .zero
    
    var body: some View {
        ZStack {
            // Main streaming surface
            if upscalingPipeline.isEnabled,
               let texture4K = upscalingPipeline.upscaledTexture {
                if #available(visionOS 2.0, *) {
                    Immersive4KSurface(
                        texture: texture4K,
                        frameId: upscalingPipeline.textureFrameId
                    )
                } else if let frame = currentFrame {
                    StreamingSurface(pixelBuffer: frame)
                }
            } else if let frame = currentFrame {
                StreamingSurface(pixelBuffer: frame)
            } else {
                // Loading state
                RealityView { content in
                    let mesh = MeshResource.generatePlane(width: 6.0, height: 3.375)
                    let material = UnlitMaterial(color: .init(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0))
                    let entity = ModelEntity(mesh: mesh, materials: [material])
                    entity.position = [0, 1.8, -4.0]
                    content.add(entity)
                }
            }
            
            // Floating control panel (separate from video surface)
            if showControls {
                // Floating glass panel below the video screen
                RealityView { content, attachments in
                    // Create anchor for floating panel
                    let anchor = AnchorEntity(world: [0, 0.3, -2.5])  // In front and below video
                    
                    if let panelAttachment = attachments.entity(for: "controlPanel") {
                        panelAttachment.position = [0, 0, 0]
                        anchor.addChild(panelAttachment)
                    }
                    
                    content.add(anchor)
                } attachments: {
                    Attachment(id: "controlPanel") {
                        FloatingControlPanel(
                            isUpscalingEnabled: upscalingPipeline.isEnabled,
                            onExitVR: { Task { await exitImmersive() } },
                            onToggleUpscaling: { upscalingPipeline.isEnabled.toggle() }
                        )
                    }
                }
                .transition(.opacity)
            }
            
            // v10.6: 3D F1 Steering Wheel (when in F1 cockpit or virtualWheel mode)
            if appState.controllerMode == .f1Cockpit || appState.controllerMode == .virtualWheel {
                // 3D wheel entity in RealityKit - user can drag to reposition
                RealityView { content in
                    print("[StreamingImmersive] 🎡 Creating F1 Steering Wheel 3D model...")
                    let wheelModel = F1SteeringWheel3DModel()
                    let wheelEntity = wheelModel.createWheelEntity()
                    
                    // Initial position - farther from user for comfort
                    wheelEntity.position = wheelPosition
                    wheelEntity.scale = [1.5, 1.5, 1.5]    // 1.5x scale for better visibility
                    wheelEntity.name = "F1WheelRoot"
                    
                    // Enable input for dragging
                    wheelEntity.components.set(InputTargetComponent())
                    wheelEntity.generateCollisionShapes(recursive: true)
                    
                    print("[StreamingImmersive] ✅ Wheel entity created - drag to reposition")
                    content.add(wheelEntity)
                } update: { content in
                    // Update wheel rotation and position
                    if let wheelEntity = content.entities.first(where: { $0.name == "F1WheelRoot" }) {
                        // Apply user-adjusted position + any active drag offset
                        wheelEntity.position = wheelPosition + wheelDragOffset
                        
                        // Rotate wheel around Z axis based on steering (INVERTED for visual)
                        let steeringAngle = Float(-steeringService.steeringValue) * (.pi / 2)  // ±90°
                        wheelEntity.orientation = simd_quatf(angle: steeringAngle, axis: [0, 0, 1])
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .targetedToAnyEntity()
                        .onChanged { value in
                            // Convert 2D drag to 3D offset
                            // NOTE: Y axis is INVERTED in visionOS drag gestures
                            let translation = value.translation3D
                            wheelDragOffset = SIMD3<Float>(
                                Float(translation.x) * 0.001,
                                Float(-translation.y) * 0.001,  // INVERTED: negative Y to fix up/down
                                Float(translation.z) * 0.001
                            )
                        }
                        .onEnded { value in
                            // Commit the position change
                            wheelPosition += wheelDragOffset
                            wheelDragOffset = .zero
                            print("[StreamingImmersive] 🎡 Wheel repositioned to \(wheelPosition)")
                        }
                )
                
                // HUD overlay with trigger values
                VStack {
                    Spacer()
                    
                    // Minimal HUD at bottom
                    HStack(spacing: 40) {
                        // Left trigger (brake)
                        VStack(spacing: 4) {
                            Text("L2 BRAKE")
                                .font(.caption2)
                                .foregroundColor(.red)
                            ProgressView(value: Double(steeringService.leftTrigger))
                                .tint(.red)
                                .frame(width: 80)
                        }
                        
                        // Steering indicator
                        VStack(spacing: 4) {
                            Text("STEERING")
                                .font(.caption2)
                                .foregroundColor(.white)
                            Text(String(format: "%+.0f%%", steeringService.steeringValue * 100))
                                .font(.headline)
                                .monospacedDigit()
                                .foregroundColor(steeringService.isTracking ? .green : .gray)
                        }
                        
                        // Right trigger (accelerator)
                        VStack(spacing: 4) {
                            Text("R2 ACCEL")
                                .font(.caption2)
                                .foregroundColor(.green)
                            ProgressView(value: Double(steeringService.rightTrigger))
                                .tint(.green)
                                .frame(width: 80)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    .padding(.bottom, 40)
                }
            }
        }
        .onTapGesture {
            toggleControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoFrameReceived)) { notification in
            guard let object = notification.object else { return }
            let frame = object as! CVPixelBuffer
            currentFrame = frame
            
            if upscalingPipeline.isEnabled {
                // v10.0: Update EDR headroom from monitored scene value
                // On visionOS, we estimate based on device thermal state
                // TODO: Implement thermal state monitoring via ProcessInfo
                upscalingPipeline.updateEDRHeadroom(from: currentEDRHeadroom)
                
                let result = upscalingPipeline.processFrame(frame)
                if result == nil && upscalingPipeline.textureFrameId < 5 {
                    print("[StreamingImmersiveView] ⚠️ processFrame returned nil")
                }
                
                // v10.5.1: Direct update to ImmersiveTextureCoordinator
                // RealityView.update doesn't trigger reliably, so we update directly
                if #available(visionOS 2.0, *) {
                    if let upscaledTexture = upscalingPipeline.upscaledTexture {
                        ImmersiveTextureCoordinator.shared.updateTexture(from: upscaledTexture)
                    }
                }
            }
        }
        .onAppear {
            upscalingPipeline.initialize()
            
            // v10.6: Start hand tracking if F1 cockpit or virtual wheel mode
            print("[StreamingImmersive] 🎮 Controller mode: \(appState.controllerMode)")
            let isSteeringMode = appState.controllerMode == .f1Cockpit || appState.controllerMode == .virtualWheel
            if isSteeringMode {
                print("[StreamingImmersive] 🎯 F1/Virtual Wheel mode ACTIVE - starting hand tracking...")
                Task {
                    do {
                        try await steeringService.startTracking()
                        print("[StreamingImmersive] ✅ Hand tracking started successfully")
                    } catch {
                        print("[StreamingImmersive] ❌ Hand tracking failed: \(error)")
                    }
                }
                // Start input loop at 120Hz for lower latency
                steeringInputTimer = Timer.scheduledTimer(withTimeInterval: 1.0/120.0, repeats: true) { _ in
                    Task { @MainActor in
                        guard steeringService.isTracking else { return }
                        
                        // Get steering and trigger values
                        let steering = steeringService.steeringValue
                        let leftTrig = steeringService.leftTrigger   // L2 = brake
                        let rightTrig = steeringService.rightTrigger // R2 = accelerator
                        
                        // Send directly to ChiakiFullSession with L2/R2 triggers!
                        ChiakiFullSession.shared.setControllerState(
                            buttons: 0,  // No buttons pressed
                            leftX: Int16(steering * 32767),  // Steering on left stick X
                            leftY: 0,
                            rightX: 0,
                            rightY: 0,
                            l2: UInt8(leftTrig * 255),   // L2 trigger = brake
                            r2: UInt8(rightTrig * 255)   // R2 trigger = accelerator
                        )
                    }
                }
                print("[StreamingImmersive] ⏱️ Input timer started at 120Hz (~8ms latency)")
            } else {
                print("[StreamingImmersive] ℹ️ Not in steering wheel mode, skipping hand tracking")
            }
        }
        .onDisappear {
            controlHideTimer?.invalidate()
            controlHideTimer = nil
            // Reset immersive coordinator
            if #available(visionOS 2.0, *) {
                ImmersiveTextureCoordinator.shared.reset()
            }
            // v10.6: Stop hand tracking and input timer
            steeringInputTimer?.invalidate()
            steeringInputTimer = nil
            steeringService.stopTracking()
        }
    }
    
    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.3)) {
            showControls.toggle()
        }
        
        controlHideTimer?.invalidate()
        if showControls {
            controlHideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
                withAnimation {
                    showControls = false
                }
            }
        }
    }
    
    private func exitImmersive() async {
        await dismissImmersiveSpace()
    }
    
    // v10.6: Send steering wheel input to PS5
    private func sendSteeringInput() {
        guard steeringService.isTracking else { return }
        
        // Steering goes to left stick X
        let steering = CGFloat(steeringService.steeringValue)
        
        // Triggers: R2 (throttle) - L2 (brake) = right stick Y
        let throttleBrake = CGFloat(steeringService.rightTrigger - steeringService.leftTrigger)
        
        appState.streamingViewModel.sendJoystickInput(
            left: CGPoint(x: steering, y: 0),
            right: CGPoint(x: 0, y: throttleBrake)
        )
    }
}

// MARK: - Immersive 4K Surface (using coordinator)

@available(visionOS 2.0, *)
struct Immersive4KSurface: View {
    let texture: MTLTexture
    let frameId: UInt64
    
    // Cinema-like screen: 6m wide at 4m distance (~85° FOV)
    // 16:9 aspect ratio: 6.0 x 3.375 meters
    private let screenWidth: Float = 6.0
    private let screenHeight: Float = 3.375
    private let screenDistance: Float = 4.0
    private let screenElevation: Float = 1.8
    
    var body: some View {
        RealityView { content in
            let coordinator = ImmersiveTextureCoordinator.shared
            let entity = coordinator.getOrCreateEntity(
                width: screenWidth,
                height: screenHeight,
                distance: screenDistance,
                elevation: screenElevation
            )
            
            if entity.parent == nil {
                content.add(entity)
                print("[Immersive4KSurface] ✅ Entity added to scene")
            }
            
            // Initial texture update
            coordinator.updateTexture(from: texture)
            
        } update: { content in
            let coordinator = ImmersiveTextureCoordinator.shared
            coordinator.updateTexture(from: texture)
            
            // Log periodically
            if frameId == 1 || frameId % 120 == 0 {
                print("[Immersive4KSurface] 📊 Frame \(frameId), texture: \(texture.width)x\(texture.height)")
            }
        }
    }
}

// MARK: - Streaming Surface (1080p fallback)

struct StreamingSurface: View {
    let pixelBuffer: CVPixelBuffer?
    
    // Cinema-like screen: 6m wide at 4m distance (~85° FOV)
    // 16:9 aspect ratio: 6.0 x 3.375 meters
    private let screenWidth: Float = 6.0
    private let screenHeight: Float = 3.375
    private let screenDistance: Float = 4.0
    private let screenElevation: Float = 1.8
    
    var body: some View {
        RealityView { content in
            let mesh = MeshResource.generatePlane(width: screenWidth, height: screenHeight)
            let material = UnlitMaterial(color: .init(red: 0.02, green: 0.02, blue: 0.02, alpha: 1.0))
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.name = "StreamingSurface"
            entity.position = [0, screenElevation, -screenDistance]
            content.add(entity)
            
        } update: { content in
            guard let entity = content.entities.first(where: { $0.name == "StreamingSurface" }) as? ModelEntity,
                  let buffer = pixelBuffer,
                  let texture = createTextureFromPixelBuffer(buffer) else { return }
            
            var material = UnlitMaterial()
            material.color = .init(texture: .init(texture))
            entity.model?.materials = [material]
        }
    }
    
    private func createTextureFromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> TextureResource? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ),
        let cgImage = context.makeImage() else { return nil }
        
        do {
            return try TextureResource.generate(from: cgImage, options: .init(semantic: .color))
        } catch {
            return nil
        }
    }
}

// MARK: - Floating Control Panel (3D Glass UI)

/// Floating control panel with visionOS glass material design
struct FloatingControlPanel: View {
    let isUpscalingEnabled: Bool
    let onExitVR: () -> Void
    let onToggleUpscaling: () -> Void
    
    var body: some View {
        HStack(spacing: 24) {
            // Resolution indicator/toggle
            Button(action: onToggleUpscaling) {
                HStack(spacing: 8) {
                    Image(systemName: isUpscalingEnabled ? "4k.tv.fill" : "tv")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isUpscalingEnabled ? "4K" : "1080p")
                            .font(.headline)
                        Text(isUpscalingEnabled ? "MetalFX Upscaling" : "Native")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(isUpscalingEnabled ? Color.blue.opacity(0.3) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            
            Divider()
                .frame(height: 40)
            
            // Exit VR button
            Button(action: onExitVR) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.title2)
                    Text("Sair do VR")
                        .font(.headline)
                }
                .foregroundColor(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    static let videoFrameReceived = Notification.Name("videoFrameReceived")
}

#Preview(immersionStyle: .mixed) {
    StreamingImmersiveView()
        .environmentObject(AppState())
}
