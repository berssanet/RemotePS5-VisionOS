import GameController
import RealityKit
import SwiftUI

/// A curved screen placed around the viewer once, then held stable in space.
struct ImmersiveCinemaView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @ObservedObject private var pipeline = UpscalingPipeline.shared
    @StateObject private var renderer: ImmersiveCinemaRenderer
    @FocusState private var cinemaHasFocus: Bool
    @State private var screen: ModelEntity?
    @State private var cinemaRoot = Entity()
    @State private var cinemaAnchor: AnchorEntity?
    @State private var controlsEntity: Entity?
    @State private var controlsExpanded = true
    @State private var imageOptionsExpanded = true
    @State private var controlsDragOrigin: SIMD3<Float>?
    @GestureState private var controlsAreDragging = false
    let surface: PresentationCoordinator.Surface

    init(surface: PresentationCoordinator.Surface) {
        self.surface = surface
        _renderer = StateObject(wrappedValue: ImmersiveCinemaRenderer(
            frames: VideoDelivery.shared, surfaceID: surface.id))
    }

    var body: some View {
        RealityView { content, attachments in
            appState.refreshCinemaDismiss(surface: surface, dismiss: dismissImmersiveSpace)
            // Full immersion is selected by the owning ImmersiveSpace. An
            // inward-facing black shell makes the visual surround explicit.
            var black = UnlitMaterial(applyPostProcessToneMap: false)
            black.color = .init(tint: .black)
            black.faceCulling = .front
            let surround = ModelEntity(mesh: .generateSphere(radius: 50), materials: [black])
            surround.name = "CinemaSurround"
            content.add(surround)
            content.add(cinemaRoot)
            do {
                let screen = try await renderer.prepare()
                guard !Task.isCancelled,
                      appState.presentationCoordinator.immersiveSurface == surface else {
                    renderer.stop()
                    return
                }
                self.screen = screen
                guard let controls = attachments.entity(for: "cinemaControls") else {
                    throw ImmersiveCinemaRenderer.Failure.preparationFailed
                }
                controlsEntity = controls
                placeCinema(screen: screen, controls: controls)
                renderer.start(content: content, mayConsume: { [weak appState = appState] generation in
                    appState?.presentationCoordinator.mayConsume(surface, generation: generation) == true
                }, onFailure: { [weak appState = appState] in
                    appState?.presentationDriver.send(.readinessFailed(surface))
                })
                // This is resource readiness, never an assertion of first frame
                // or photon presentation. Selection happens in the coordinator.
                appState.presentationDriver.consumerPrepared(surface)
                cinemaHasFocus = true
            } catch {
                renderer.stop()
                if !Task.isCancelled {
                    appState.presentationDriver.send(.readinessFailed(surface))
                }
            }
        } attachments: {
            Attachment(id: "cinemaControls") { controls }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($cinemaHasFocus)
        .defaultFocus($cinemaHasFocus, true)
        // Apple recommends the opt-in directly on the RealityView. Its focused
        // descendants include the spatial controls; no invisible UIKit overlay.
        .handlesGameControllerEvents(matching: .gamepad)
        .onChange(of: appState.selectedSurface) { _, selected in
            if selected == surface { cinemaHasFocus = true }
        }
        .onDisappear {
            renderer.stop()
            cinemaAnchor?.removeFromParent()
            cinemaAnchor = nil
            screen = nil
            controlsEntity = nil
            controlsDragOrigin = nil
            appState.presentationDriver.surfaceDetached(surface)
        }
    }

    /// One stable coordinate system keeps the movable panel inside the curved
    /// screen, including after recentering. No head-pose readback is needed.
    private func placeCinema(screen: ModelEntity, controls: Entity) {
        controlsDragOrigin = nil
        let previous = cinemaAnchor
        let anchor = AnchorEntity(.head, trackingMode: .once)
        cinemaRoot.addChild(anchor)
        anchor.addChild(screen, preservingWorldTransform: false)
        screen.transform = .identity
        anchor.addChild(controls, preservingWorldTransform: false)
        controls.position = [0, 0, -1.2]
        previous?.removeFromParent()
        cinemaAnchor = anchor
        cinemaHasFocus = true
    }

    /// The handle alone owns this gesture. Buttons and sliders keep their own
    /// input, and the RealityView keeps its game-controller event preference.
    @ViewBuilder
    private var moveHandle: some View {
        if #available(visionOS 26.0, *), let anchor = cinemaAnchor {
            Label(controlsAreDragging ? "Moving panel…" : "Move panel", systemImage: "hand.draw")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.white.opacity(controlsAreDragging ? 0.18 : 0.08), in: Capsule())
                .contentShape(Capsule())
                .hoverEffect(.highlight)
                .accessibilityLabel("Move controls")
                .accessibilityHint("Pinch and hold, then move your hand to move the panel, including closer or farther away.")
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace3D: anchor)
                        .updating($controlsAreDragging) { _, dragging, _ in dragging = true }
                        .onChanged { value in
                            moveControls(translation: SIMD3<Float>(Float(value.translation3D.x),
                                Float(value.translation3D.y), Float(value.translation3D.z)), relativeTo: anchor)
                        }
                        .onEnded { value in
                            if controlsDragOrigin != nil {
                                moveControls(translation: SIMD3<Float>(Float(value.translation3D.x),
                                    Float(value.translation3D.y), Float(value.translation3D.z)), relativeTo: anchor)
                            }
                            // Keep the entity's final position; only the gesture
                            // origin is released. No animation snaps it back.
                            controlsDragOrigin = nil
                            cinemaHasFocus = true
                        }
                )
                .onChange(of: controlsAreDragging) { _, dragging in
                    if !dragging {
                        controlsDragOrigin = nil
                        cinemaHasFocus = true
                    }
                }
                .help("Pinch and hold this handle, then move your hand to reposition the panel")
        } else {
            // The 3D-coordinate SwiftUI initializer is available on visionOS26+.
            // Keep explicit distance controls on the deployment target of 2.0.
            HStack {
                Text("Panel distance").font(.subheadline)
                Button("Nearer") { adjustControlsDistance(by: 0.2) }
                Button("Farther") { adjustControlsDistance(by: -0.2) }
            }
        }
    }

    private func moveControls(translation: SIMD3<Float>, relativeTo anchor: AnchorEntity) {
        guard cinemaAnchor === anchor, let controls = controlsEntity,
              controls.parent === anchor,
              translation.x.isFinite, translation.y.isFinite, translation.z.isFinite else { return }
        if controlsDragOrigin == nil { controlsDragOrigin = controls.position }
        guard let origin = controlsDragOrigin else { return }
        // DragGesture supplies meters in the stationary anchor's coordinate
        // space. Only read/write the child's local position, never head pose or
        // an anchored transform relative to world/immersive space.
        let proposed = origin + translation
        controls.position = CinemaScreenGeometry.constrainedControlPosition(proposed)
    }

    private func adjustControlsDistance(by offset: Float) {
        guard let controls = controlsEntity else { return }
        controls.position = CinemaScreenGeometry.constrainedControlPosition(
            controls.position + SIMD3(0, 0, offset))
        cinemaHasFocus = true
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                moveHandle
                Button {
                    if let screen, let controlsEntity { placeCinema(screen: screen, controls: controlsEntity) }
                } label: {
                    Image(systemName: "scope")
                }
                .help("Recenter the screen and controls in front of you")
                .accessibilityLabel("Recenter cinema")
            }
            HStack {
                Button {
                    controlsExpanded.toggle()
                    cinemaHasFocus = true
                } label: {
                    Label(controlsExpanded ? "Hide controls" : "Controls",
                          systemImage: controlsExpanded ? "chevron.up" : "slider.horizontal.3")
                }
                if !controlsExpanded && pipeline.inspectionFrozen {
                    Button("Resume image") {
                        pipeline.setInspectionFrozen(false)
                        cinemaHasFocus = true
                    }
                    .tint(.orange)
                }
                Spacer()
                Button {
                    appState.returnToWindow()
                } label: {
                    Label("Return to Window", systemImage: "macwindow")
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.presentationState == .closing || appState.presentationState == .terminating)
            }
            if controlsExpanded {
                DisclosureGroup("Image filters", isExpanded: $imageOptionsExpanded) {
                    VideoQualityControls { cinemaHasFocus = true }
                        .padding(.top, 8)
                }
                .onChange(of: imageOptionsExpanded) { _, _ in cinemaHasFocus = true }
                HStack {
                    Text("Screen coverage")
                    Slider(value: Binding(get: { renderer.horizontalCoverage },
                                          set: { renderer.setHorizontalCoverage($0) }),
                           in: CinemaScreenGeometry.coverageRange, step: 5) { _ in cinemaHasFocus = true }
                        .accessibilityLabel("Curved screen coverage")
                    Text("\(Int(renderer.horizontalCoverage))°")
                        .monospacedDigit()
                }
                HStack {
                    Button("Reset coverage") {
                        renderer.setHorizontalCoverage(CinemaScreenGeometry.defaultHorizontalCoverage)
                        cinemaHasFocus = true
                    }
                    Button("Recenter cinema", systemImage: "scope") {
                        if let screen, let controlsEntity { placeCinema(screen: screen, controls: controlsEntity) }
                        cinemaHasFocus = true
                    }
                }
                if let error = renderer.screenAdjustmentError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Text(renderer.processingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Look around the curved screen. Adjust coverage to bring its edges into view. Move or hide this panel while playing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 520)
        .padding(20)
        .glassBackgroundEffect()
    }
}
