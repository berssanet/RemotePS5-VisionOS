//
//  StreamingVideoWindow.swift
//  VisionRemotePS5
//
//  v10.5: Separate window for video streaming display
//  This window is hidden when VR mode is active
//

import SwiftUI
import RealityKit

struct StreamingVideoWindow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var upscalingPipeline = UpscalingPipeline.shared
    @ObservedObject private var streamingService = StreamingService.shared
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    let console: Console
    
    var body: some View {
        ZStack {
            // Video content
            if upscalingPipeline.isEnabled,
               let texture = upscalingPipeline.upscaledTexture {
                MetalTextureView(texture: texture, frameId: upscalingPipeline.textureFrameId)
                    .aspectRatio(16/9, contentMode: .fit)
                    .cornerRadius(16)
            } else if appState.streamingViewModel.isConnected {
                // Buffering state
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
                // Connecting state
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
        .task {
            // Initialize upscaling pipeline
            upscalingPipeline.initialize()
            upscalingPipeline.enable()

            // v10.5.1: Only start streaming if not already connected
            // (e.g., when returning from VR mode, streaming is already active)
            if !appState.streamingViewModel.isConnected {
                await appState.streamingViewModel.startStreaming(console: console, auth: appState.psnAuthService)
            }
        }
        .task(id: streamingService.isStreaming) {
            guard !Task.isCancelled, streamingService.isStreaming else { return }
            if appState.controllerMode == .handGesture,
               !appState.isImmersiveActive, !appState.isHoloPadSpaceActive {
                let result = await openImmersiveSpace(id: "HoloPadSpace")
                if case .opened = result {
                    appState.isHoloPadSpaceActive = true
                    DebugLog.info("StreamingWindow", "🖐️ HoloPad space opened (windowed input)")
                }
            }
        }
        .onDisappear {
            // v10.5.1: Don't stop streaming or disable pipeline when entering VR mode
            // Only stop when actually closing the window (not VR transition)
            if !appState.isImmersiveActive {
                appState.streamingViewModel.stopStreaming()
                upscalingPipeline.disable()
                // v12.6: tear down the companion HoloPad space with the window
                if appState.isHoloPadSpaceActive {
                    appState.isHoloPadSpaceActive = false
                    Task { await dismissImmersiveSpace() }
                }
            }
            // Note: Pipeline stays enabled for VR mode to continue processing frames
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
