//
//  StreamingVideoWindow.swift
//  VisionRemotePS5
//
//  The only window shown while connected: the PS5 video stream. Controller input
//  comes from a Bluetooth gamepad paired with the Vision Pro (GameControllerManager,
//  120 Hz input thread into StreamingService). Closing the window ends the session.
//
//  visionOS turns gamepad input into gaze + pinch events unless the gazed view opts
//  in: the MTKView carries a GCEventInteraction and this container claims SwiftUI
//  focus for handlesGameControllerEvents. The Metal view is mounted from the start
//  so the interaction and the shader pipeline exist before the stream begins.
//

import GameController
import SwiftUI

struct StreamingVideoWindow: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @ObservedObject private var upscalingPipeline = UpscalingPipeline.shared
    @ObservedObject private var streamingService = StreamingService.shared
    /// handlesGameControllerEvents only acts while the view holds focus, so the
    /// stream surface is focusable and claims focus as soon as it appears.
    @FocusState private var streamHasFocus: Bool

    let surface: PresentationCoordinator.Surface
    @ObservedObject var viewModel: StreamingViewModel

    @State private var hasVideo = false
    @State private var processingStatus = "Waiting for video…"

    var body: some View {
        ZStack {
            MetalTextureView(frames: upscalingPipeline.frames, surfaceID: surface.id, onFirstFrame: {
                hasVideo = true
            }, onProcessingStatus: { processingStatus = $0 })
            .id(surface.id)
            .aspectRatio(16/9, contentMode: .fit)
            .cornerRadius(16)

            if !hasVideo {
                statusOverlay
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            VStack(spacing: 8) {
                HStack {
                    Label("Window", systemImage: "macwindow")
                    Spacer()
                    if appState.presentationState == .opening {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { appState.returnToWindow() }
                    } else {
                        Button {
                            appState.enterCinema(open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
                        } label: {
                            Label("Enter Cinema", systemImage: "visionpro")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!appState.canEnterCinema)
                    }
                }
                VideoQualityControls { streamHasFocus = true }
                if let message = appState.presentationError {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                Text(processingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PerformanceReportExportButton(compact: true) {
                    streamHasFocus = true
                }
                Text("Compare the received image with MetalFX. Change source quality before connecting.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 480)
            .padding()
            .glassBackgroundEffect()
        }
        .focusable()
        .focusEffectDisabled()
        .focused($streamHasFocus)
        .defaultFocus($streamHasFocus, true)
        // Route gamepad input to GCController while this window has focus.
        .handlesGameControllerEvents(matching: .gamepad)
        .onTapGesture {
            // A gamepad press landing here was converted to gaze + pinch: the opt-in is not active.
            DebugLog.print("[Controller] ⚠️ Tap reached SwiftUI (pinch, or gamepad still routed as pinch)")
        }
        .onChange(of: streamHasFocus) { _, focused in
            DebugLog.print("[Controller] Stream window focus: \(focused)")
        }
        .onChange(of: appState.selectedSurface) { _, selected in
            if selected == surface { streamHasFocus = true }
        }
        .onChange(of: appState.presentationState) { _, state in
            if (state == .windowed || state == .error), appState.selectedSurface == surface {
                streamHasFocus = true
            }
        }
        .onAppear {
            streamHasFocus = true
            appState.presentationDriver.windowMounted(surface)
            appState.presentationDriver.consumerPrepared(surface)
        }
        .onDisappear {
            // The immutable surface token distinguishes authorized retirement
            // from losing the required window. Global cleanup belongs to S.
            appState.presentationDriver.surfaceDetached(surface)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if viewModel.isConnected {
            VStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Buffering...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(16/9, contentMode: .fit)
            .background(Color.black.opacity(0.8))
            .cornerRadius(16)
        } else {
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(2)
                Text(connectionMessage)
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.8))
            .cornerRadius(16)
        }
    }

    private var connectionMessage: String {
        switch streamingService.state {
        case .error(let reason):
            return "Error: \(reason)"
        case .connecting, .negotiating:
            return streamingService.connectionStatusMessage.isEmpty
                ? viewModel.statusMessage : streamingService.connectionStatusMessage
        default:
            return viewModel.statusMessage
        }
    }
}
