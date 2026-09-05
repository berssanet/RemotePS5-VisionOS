//
//  StreamingVideoWindow.swift
//  VisionRemotePS5
//
//  The only window shown while connected: the PS5 video stream. Controller input
//  comes from a Bluetooth gamepad paired with the Vision Pro (GameControllerManager,
//  120 Hz polling into StreamingService). Closing the window ends the session.
//

import SwiftUI

struct StreamingVideoWindow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var upscalingPipeline = UpscalingPipeline.shared
    @ObservedObject private var streamingService = StreamingService.shared

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
