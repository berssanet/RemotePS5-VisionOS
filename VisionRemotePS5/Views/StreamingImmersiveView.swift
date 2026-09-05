//
//  StreamingImmersiveView.swift
//  VisionRemotePS5
//
//  Immersive view for streaming in VR space
//  Uses a texture coordinator that mutates RealityKit entities in place to avoid duplicate entities
//

import SwiftUI
import RealityKit
import CoreVideo
import Metal
import QuartzCore  // Phase 5.11: monotonic clock (CACurrentMediaTime), avoids NTP-induced judder

// MARK: - Immersive Texture Coordinator

/// Separate coordinator for immersive mode (doesn't conflict with windowed mode)
/// v11.2: Fixed white flashes and VR re-entry issues with synchronous GPU operations
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
    
    // v11.2: Atomic update tracking to prevent white flashes
    private var updateInProgress = false
    private var lastUpdateTime: CFAbsoluteTime = 0
    private var sessionId: UInt64 = 0  // Track VR sessions to detect re-entry
    
    private(set) var videoEntity: ModelEntity?

    /// Spatial 3D mode reuses this resource on the displaced screen — the
    /// backing LowLevelTexture updates in place, so every material
    /// referencing it shows new frames automatically.
    var currentTextureResource: TextureResource? { textureResource }
    
    private init() {}
    
    func getOrCreateEntity(width: Float, height: Float, distance: Float, elevation: Float) -> ModelEntity {
        // v11.2: Check if entity exists but belongs to old session
        if let existing = videoEntity {
            // Reuse existing entity
            return existing
        }
        
        // Create new entity
        sessionId += 1
        
        let mesh = MeshResource.generatePlane(width: width, height: height)
        let entity = ModelEntity(mesh: mesh)
        
        // v11.2: Start with solid BLACK to prevent any flash
        var material = UnlitMaterial()
        material.color = .init(tint: .black)
        entity.model?.materials = [material]
        entity.position = [0, elevation, -distance]
        entity.name = "ImmersiveVideoPlane"
        
        videoEntity = entity
        
        DebugLog.info("ImmersiveCoordinator", "✅ Entity created (session \(sessionId)): \(width)x\(height)")
        
        return entity
    }
    
    func updateTexture(from sourceTexture: MTLTexture) {
        let newSize = (sourceTexture.width, sourceTexture.height)
        
        // v11.2: Timeout protection - if update stuck for >100ms, force reset
        // Phase 5.11: monotonic clock so NTP adjustments don't trigger spurious resets
        let now = CACurrentMediaTime()
        if updateInProgress && (now - lastUpdateTime) > 0.1 {
            DebugLog.warning("ImmersiveCoordinator", "Update timeout, forcing reset")
            updateInProgress = false
        }
        
        // Skip if already updating
        guard !updateInProgress else { return }
        
        if isInitialized && textureSize == newSize {
            copyTextureContentSync(from: sourceTexture)
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
            
            DebugLog.info("ImmersiveCoordinator", "✅ Texture: \(sourceTexture.width)x\(sourceTexture.height)")
            
            applyToEntity()
            copyTextureContentSync(from: sourceTexture)
            
        } catch {
            isInitializing = false
            DebugLog.error("ImmersiveCoordinator", "Failed: \(error)")
        }
    }
    
    func applyToEntity() {
        guard let entity = videoEntity, let resource = textureResource else { return }
        
        var material = UnlitMaterial()
        material.color = .init(texture: .init(resource))
        entity.model?.materials = [material]
        
        DebugLog.info("ImmersiveCoordinator", "🎨 Material applied with texture")
    }
    
    /// v11.2: Synchronous texture copy - waits for GPU to complete before returning
    /// This prevents the white flash caused by displaying partially copied textures
    private func copyTextureContentSync(from sourceTexture: MTLTexture) {
        guard let llTexture = lowLevelTexture,
              let queue = commandQueue,
              isInitialized,
              !updateInProgress else { return }
        
        updateInProgress = true
        lastUpdateTime = CACurrentMediaTime()  // Phase 5.11: monotonic clock
        
        guard let commandBuffer = queue.makeCommandBuffer() else {
            updateInProgress = false
            return
        }
        
        let destTexture = llTexture.replace(using: commandBuffer)
        
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            updateInProgress = false
            return
        }
        
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
        
        // v12.0: Async commit with completion handler — avoids blocking ~1ms/frame.
        // The updateInProgress flag gates new copies, preserving ordering without CPU stall.
        commandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateInProgress = false
            }
        }
        commandBuffer.commit()
    }
    
    /// v11.2: Full reset - clears everything including entity for clean VR re-entry
    func reset() {
        // Wait for any pending update
        if updateInProgress {
            updateInProgress = false
        }
        
        lowLevelTexture = nil
        textureResource = nil
        commandQueue = nil
        textureSize = (0, 0)
        isInitialized = false
        isInitializing = false
        
        // v11.2: Also clear entity to force recreation on next VR entry
        if let entity = videoEntity {
            entity.removeFromParent()
        }
        videoEntity = nil
        
        DebugLog.info("ImmersiveCoordinator", "🔄 Full reset (session \(sessionId) ended)")
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

    // v12.2: HoloPad gesture controller
    @StateObject private var gestureService = HandGestureControllerService()
    @State private var gestureInputTimer: Timer?
    
    // v11.x: Button bitmask for wheel panel buttons (wired into 120Hz input loop)
    @State private var pressedButtons: UInt32 = 0
    
    var body: some View {
        ZStack {
            // Main streaming surface with GPU processing
            if upscalingPipeline.isEnabled,
               let texture4K = upscalingPipeline.upscaledTexture {
                if #available(visionOS 2.0, *) {
                    // v12.1: depth-displaced spatial screen vs flat cinema screen
                    if appState.spatial3DEnabled {
                        Spatial3DSurface(
                            texture: texture4K,
                            frameId: upscalingPipeline.textureFrameId,
                            showWheel: appState.controllerMode == .virtualWheel
                        )
                    } else {
                        Immersive4KSurface(
                            texture: texture4K,
                            frameId: upscalingPipeline.textureFrameId,
                            showWheel: appState.controllerMode == .virtualWheel,
                            steeringValue: steeringService.steeringValue
                        )
                    }
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
                            isSpatial3DEnabled: appState.spatial3DEnabled,
                            showHoloPadProfile: appState.controllerMode == .handGesture,
                            isCyborgProfile: gestureService.inputProfile == .cyborgPaddles,
                            onExitVR: { Task { await exitImmersive() } },
                            onToggleUpscaling: { upscalingPipeline.isEnabled.toggle() },
                            onToggleSpatial3D: { appState.spatial3DEnabled.toggle() },
                            onToggleHoloPadProfile: {
                                gestureService.inputProfile =
                                    gestureService.inputProfile == .thumbTaps ? .cyborgPaddles : .thumbTaps
                            }
                        )
                    }
                }
                .transition(.opacity)
            }
            
            // v12.2: HoloPad holographic feedback (fingertip orbs + ghost sticks)
            if appState.controllerMode == .handGesture {
                if #available(visionOS 2.0, *) {
                    HoloPadFeedbackView(service: gestureService)
                }
            }

            // v11.x: Wheel button panel + HUD (rendered as RealityView attachment)
            if appState.controllerMode == .virtualWheel {
                RealityView { content, attachments in
                    let anchor = AnchorEntity(world: [0, 0.45, -1.2])  // Below the wheel
                    if let panel = attachments.entity(for: "wheelButtons") {
                        panel.position = [0, 0, 0]
                        anchor.addChild(panel)
                    }
                    content.add(anchor)
                } attachments: {
                    Attachment(id: "wheelButtons") {
                        VStack(spacing: 12) {
                            // Racing button panel
                            HStack(spacing: 16) {
                                // Face buttons
                                HStack(spacing: 8) {
                                    WheelButton(label: "✕", color: .blue, mask: 0x0001, pressedButtons: $pressedButtons)
                                    WheelButton(label: "○", color: .red, mask: 0x0002, pressedButtons: $pressedButtons)
                                    WheelButton(label: "□", color: .pink, mask: 0x0004, pressedButtons: $pressedButtons)
                                    WheelButton(label: "△", color: .green, mask: 0x0008, pressedButtons: $pressedButtons)
                                }
                                
                                Divider().frame(height: 30)
                                
                                // D-Pad
                                HStack(spacing: 8) {
                                    WheelButton(label: "◀", color: .white, mask: 0x0010, pressedButtons: $pressedButtons)
                                    VStack(spacing: 4) {
                                        WheelButton(label: "▲", color: .white, mask: 0x0040, pressedButtons: $pressedButtons)
                                        WheelButton(label: "▼", color: .white, mask: 0x0080, pressedButtons: $pressedButtons)
                                    }
                                    WheelButton(label: "▶", color: .white, mask: 0x0020, pressedButtons: $pressedButtons)
                                }
                                
                                Divider().frame(height: 30)
                                
                                // System buttons
                                HStack(spacing: 8) {
                                    WheelButton(label: "OPT", color: .gray, mask: 0x1000, pressedButtons: $pressedButtons, fontSize: 10)
                                    WheelButton(label: "PS", color: .cyan, mask: 0x8000, pressedButtons: $pressedButtons, fontSize: 11)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .cornerRadius(16)
                            
                            // HUD
                            HStack(spacing: 40) {
                                VStack(spacing: 4) {
                                    Text("L2 BRAKE").font(.caption2).foregroundColor(.red)
                                    ProgressView(value: Double(steeringService.leftTrigger)).tint(.red).frame(width: 80)
                                }
                                VStack(spacing: 4) {
                                    Text("STEERING").font(.caption2).foregroundColor(.white)
                                    Text(String(format: "%+.0f%%", steeringService.steeringValue * 100))
                                        .font(.headline).monospacedDigit()
                                        .foregroundColor(steeringService.isTracking ? .green : .gray)
                                }
                                VStack(spacing: 4) {
                                    Text("R2 ACCEL").font(.caption2).foregroundColor(.green)
                                    ProgressView(value: Double(steeringService.rightTrigger)).tint(.green).frame(width: 80)
                                }
                            }
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                        }
                    }
                }
            }
        }
        .onTapGesture {
            toggleControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoFrameReceived)) { notification in
            // CVPixelBuffer is a CF type: conditional-cast via CFTypeID check
            // is overkill here, but never force-cast a notification payload.
            guard let object = notification.object, CFGetTypeID(object as CFTypeRef) == CVPixelBufferGetTypeID() else { return }
            let frame = object as! CVPixelBuffer
            currentFrame = frame

            if upscalingPipeline.isEnabled {
                // v10.0: Update EDR headroom from monitored scene value
                // On visionOS, we estimate based on device thermal state
                // TODO: Implement thermal state monitoring via ProcessInfo
                upscalingPipeline.updateEDRHeadroom(from: currentEDRHeadroom)

                // v12.1: the frame was ALREADY upscaled by StreamingViewModel
                // before this notification was posted (same actor, ordered) —
                // do NOT call processFrame again here. The previous duplicate
                // call doubled the MetalFX GPU cost for every frame in VR.

                // v10.5.1: Direct update to ImmersiveTextureCoordinator
                // RealityView.update doesn't trigger reliably, so we update directly
                if #available(visionOS 2.0, *) {
                    if let upscaledTexture = upscalingPipeline.upscaledTexture {
                        ImmersiveTextureCoordinator.shared.updateTexture(from: upscaledTexture)
                        if appState.spatial3DEnabled,
                           let resource = ImmersiveTextureCoordinator.shared.currentTextureResource {
                            SpatialScreenCoordinator.shared.adoptVideoTexture(resource)
                        }
                    }

                    // v12.1: feed the Neural Engine depth estimator (drop-frame:
                    // returns nil instantly while an inference is in flight, so
                    // this never queues up work behind the video path).
                    if appState.spatial3DEnabled {
                        Task {
                            if let depthFrame = await DepthEstimationService.shared.estimate(from: frame) {
                                SpatialScreenCoordinator.shared.updateDepth(depthFrame)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            upscalingPipeline.initialize()
            
            // v10.6: Start hand tracking if virtual wheel mode
            DebugLog.print("[StreamingImmersive] 🎮 Controller mode: \(appState.controllerMode)")
            let isSteeringMode = appState.controllerMode == .virtualWheel
            if isSteeringMode {
                DebugLog.print("[StreamingImmersive] 🎯 Virtual Wheel mode ACTIVE - starting hand tracking...")
                Task {
                    do {
                        try await steeringService.startTracking()
                        DebugLog.print("[StreamingImmersive] ✅ Hand tracking started successfully")
                    } catch {
                        DebugLog.print("[StreamingImmersive] ❌ Hand tracking failed: \(error)")
                    }
                }
                // Start input loop at 120Hz for lower latency
                steeringInputTimer = Timer.scheduledTimer(withTimeInterval: 1.0/120.0, repeats: true) { _ in
                    // Timer is scheduled on the main run loop, so it always
                    // fires on the main thread — assumeIsolated avoids a
                    // 120Hz Task allocation (Phase 5.20 hot-path pattern).
                    MainActor.assumeIsolated {
                        guard steeringService.isTracking else { return }
                        
                        // Get steering and trigger values
                        let steering = steeringService.steeringValue
                        let leftTrig = steeringService.leftTrigger   // L2 = brake
                        let rightTrig = steeringService.rightTrigger // R2 = accelerator
                        
                        // Send directly to ChiakiFullSession with L2/R2 triggers!
                        ChiakiFullSession.shared.setControllerState(
                            buttons: pressedButtons,  // Wheel panel buttons
                            leftX: Int16(steering * 32767),  // Steering on left stick X
                            leftY: 0,
                            rightX: 0,
                            rightY: 0,
                            l2: UInt8(leftTrig * 255),   // L2 trigger = brake
                            r2: UInt8(rightTrig * 255)   // R2 trigger = accelerator
                        )
                    }
                }
                DebugLog.print("[StreamingImmersive] ⏱️ Input timer started at 120Hz (~8ms latency)")
            } else if appState.controllerMode == .handGesture {
                // v12.2: HoloPad — full gesture controller
                DebugLog.print("[StreamingImmersive] 🖐️ HoloPad mode ACTIVE - starting hand tracking...")
                Task {
                    do {
                        try await gestureService.startTracking()
                    } catch {
                        DebugLog.print("[StreamingImmersive] ❌ HoloPad hand tracking failed: \(error)")
                    }
                }
                gestureInputTimer = Timer.scheduledTimer(withTimeInterval: 1.0/120.0, repeats: true) { _ in
                    // Main-runloop timer fires on the main thread (5.20 pattern).
                    MainActor.assumeIsolated {
                        // While a hand is untracked, keep sending NEUTRAL state:
                        // the console latches the last state received, so going
                        // silent mid-press would leave a button stuck down.
                        guard gestureService.isTracking else {
                            ChiakiFullSession.shared.setControllerState(
                                buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0, l2: 0, r2: 0
                            )
                            return
                        }
                        ChiakiFullSession.shared.setControllerState(
                            buttons: gestureService.buttonsBitmask,
                            leftX: Int16(gestureService.leftStick.x * 32767),
                            leftY: Int16(gestureService.leftStick.y * 32767),
                            rightX: Int16(gestureService.rightStick.x * 32767),
                            rightY: Int16(gestureService.rightStick.y * 32767),
                            l2: UInt8(gestureService.leftTrigger * 255),
                            r2: UInt8(gestureService.rightTrigger * 255)
                        )
                    }
                }
                DebugLog.print("[StreamingImmersive] ⏱️ HoloPad input timer started at 120Hz")
            } else {
                DebugLog.print("[StreamingImmersive] ℹ️ Standard controller mode, skipping hand tracking")
            }
        }
        .onDisappear {
            controlHideTimer?.invalidate()
            controlHideTimer = nil
            // Reset immersive coordinators
            if #available(visionOS 2.0, *) {
                ImmersiveTextureCoordinator.shared.reset()
                SpatialScreenCoordinator.shared.reset()
                Task { await DepthEstimationService.shared.resetRange() }
            }
            // v10.6: Stop hand tracking and input timer
            steeringInputTimer?.invalidate()
            steeringInputTimer = nil
            steeringService.stopTracking()
            // v12.2: Stop HoloPad
            gestureInputTimer?.invalidate()
            gestureInputTimer = nil
            gestureService.stopTracking()
            if #available(visionOS 2.0, *) {
                HoloPadFeedbackCoordinator.shared.reset()
            }
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
}

// MARK: - Immersive 4K Surface (using coordinator - original without GPU)

@available(visionOS 2.0, *)
struct Immersive4KSurface: View {
    let texture: MTLTexture
    let frameId: UInt64
    
    // v11.x: Wheel in same RealityView as video surface
    var showWheel: Bool = false
    var steeringValue: Float = 0
    
    // Cinema-like screen: 6m wide at 4m distance (~85° FOV)
    // 16:9 aspect ratio: 6.0 x 3.375 meters
    private let screenWidth: Float = 6.0
    private let screenHeight: Float = 3.375
    private let screenDistance: Float = 4.0
    private let screenElevation: Float = 1.8
    
    // Wheel placement: below screen, closer to user
    private let wheelPos: SIMD3<Float> = [0, 0.9, -1.2]
    private let wheelScale: Float = 0.35  // Realistic hand-held wheel size at ~1.2m
    
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
                DebugLog.print("[Immersive4KSurface] ✅ Entity added to scene")
            }
            
            // Initial texture update
            coordinator.updateTexture(from: texture)
            
            // v11.x: Load 3D wheel into SAME scene as video surface
            if showWheel {
                do {
                    DebugLog.print("[Immersive4KSurface] 🎡 Loading MercedesF1Wheel...")
                    let wheelEntity = try await Entity(named: "MercedesF1Wheel")
                    
                    wheelEntity.position = wheelPos
                    wheelEntity.scale = SIMD3<Float>(repeating: wheelScale)
                    wheelEntity.name = "F1WheelRoot"
                    
                    // USDZ model: face/buttons point toward -Y in model space.
                    // RealityKit world: user looks down -Z, +Y is up.
                    // Step 1: Rotate +90° around X to bring -Y face toward +Z (user).
                    //   RX(+90°): -Y → +Z (face toward user) ✓
                    // Step 2: Tilt top of wheel toward user by +20° (cockpit angle).
                    let faceToUser = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
                    let cockpitTilt = simd_quatf(angle: .pi * 0.11, axis: [1, 0, 0])  // +20°
                    wheelEntity.orientation = cockpitTilt * faceToUser
                    
                    content.add(wheelEntity)
                    DebugLog.print("[Immersive4KSurface] ✅ Wheel added — pos:\(wheelPos) scale:\(wheelScale)")
                } catch {
                    DebugLog.print("[Immersive4KSurface] ❌ Failed to load wheel: \(error)")
                }
            }
            
        } update: { content in
            let coordinator = ImmersiveTextureCoordinator.shared
            coordinator.updateTexture(from: texture)
            
            if frameId == 1 || frameId % 120 == 0 {
                DebugLog.print("[Immersive4KSurface] 📊 Frame \(frameId), texture: \(texture.width)x\(texture.height)")
            }
            
            // v11.x: Update wheel steering rotation
            if showWheel, let wheelEntity = content.entities.first(where: { $0.name == "F1WheelRoot" }) {
                // Base orientation: face toward user + cockpit tilt
                let faceToUser = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
                let cockpitTilt = simd_quatf(angle: .pi * 0.11, axis: [1, 0, 0])
                let baseOrientation = cockpitTilt * faceToUser
                
                // Steering: rotate around model's LOCAL -Y axis (the face normal)
                // Applied first (right side of multiply), then base orientation transforms to world
                let steeringAngle = Float(-steeringValue) * (.pi / 2)  // ±90°
                let steeringRot = simd_quatf(angle: steeringAngle, axis: [0, -1, 0])
                wheelEntity.orientation = baseOrientation * steeringRot
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
            return try TextureResource(image: cgImage, options: .init(semantic: .color))
        } catch {
            return nil
        }
    }
}

// MARK: - Floating Control Panel (3D Glass UI)

/// Floating control panel with visionOS glass material design
struct FloatingControlPanel: View {
    let isUpscalingEnabled: Bool
    let isSpatial3DEnabled: Bool
    var showHoloPadProfile: Bool = false
    var isCyborgProfile: Bool = false
    let onExitVR: () -> Void
    let onToggleUpscaling: () -> Void
    let onToggleSpatial3D: () -> Void
    var onToggleHoloPadProfile: () -> Void = {}

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

            // v12.1: Spatial 3D (AI depth) toggle
            Button(action: onToggleSpatial3D) {
                HStack(spacing: 8) {
                    Image(systemName: isSpatial3DEnabled ? "view.3d" : "view.2d")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isSpatial3DEnabled ? "3D" : "2D")
                            .font(.headline)
                        Text(isSpatial3DEnabled ? "AI Depth (Neural Engine)" : "Flat Screen")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(isSpatial3DEnabled ? Color.purple.opacity(0.3) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // v12.4: HoloPad input profile (Thumb Taps ↔ Cyborg Paddles)
            if showHoloPadProfile {
                Divider()
                    .frame(height: 40)

                Button(action: onToggleHoloPadProfile) {
                    HStack(spacing: 8) {
                        Image(systemName: isCyborgProfile ? "keyboard.fill" : "hand.tap")
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isCyborgProfile ? "Paddles" : "Taps")
                                .font(.headline)
                            Text(isCyborgProfile ? "Cyborg: press fingers down" : "Thumb-to-finger taps")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(isCyborgProfile ? Color.orange.opacity(0.3) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

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

// MARK: - Wheel Button Component

/// Reusable button for the racing wheel panel — toggles bits in the shared pressedButtons bitmask
struct WheelButton: View {
    let label: String
    let color: Color
    let mask: UInt32
    @Binding var pressedButtons: UInt32
    var fontSize: CGFloat = 16
    
    @State private var isPressed = false
    
    var body: some View {
        Text(label)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundColor(isPressed ? .black : color)
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(isPressed ? color : color.opacity(0.15))
            )
            .overlay(Circle().stroke(color.opacity(0.6), lineWidth: 1.5))
            .scaleEffect(isPressed ? 0.88 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            pressedButtons |= mask
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        pressedButtons &= ~mask
                    }
            )
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
