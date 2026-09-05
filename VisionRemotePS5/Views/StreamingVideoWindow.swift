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
    @ObservedObject private var upscalingPipeline = UpscalingPipeline.shared
    @ObservedObject private var streamingService = StreamingService.shared
    /// handlesGameControllerEvents only acts while the view holds focus, so the
    /// stream surface is focusable and claims focus as soon as it appears.
    @FocusState private var streamHasFocus: Bool

    let console: Console

    private var hasVideo: Bool {
        upscalingPipeline.isEnabled && upscalingPipeline.upscaledTexture != nil
    }

    var body: some View {
        ZStack {
            MetalTextureView(
                texture: hasVideo ? upscalingPipeline.upscaledTexture : nil,
                frameId: upscalingPipeline.textureFrameId
            )
            .aspectRatio(16/9, contentMode: .fit)
            .cornerRadius(16)

            if !hasVideo {
                statusOverlay
            }
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
        .onAppear { streamHasFocus = true }
        .task {
            // Initialize upscaling pipeline
            upscalingPipeline.initialize()
            upscalingPipeline.enable()
            streamHasFocus = true

            if !appState.streamingViewModel.isConnected {
                await appState.streamingViewModel.startStreaming(console: console, auth: appState.psnAuthService)
            }
        }
        .onDisappear {
            // Closing the window ends the session and brings the console list back.
            appState.streamingViewModel.stopStreaming()
            upscalingPipeline.disable()
            appState.selectedConsole = nil
            appState.isConnected = false
            appState.connectionStatus = .disconnected
            appState.isInStreamingSession = false
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if appState.streamingViewModel.isConnected {
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
                ? appState.streamingViewModel.statusMessage : streamingService.connectionStatusMessage
        default:
            return appState.streamingViewModel.statusMessage
        }
    }
}
