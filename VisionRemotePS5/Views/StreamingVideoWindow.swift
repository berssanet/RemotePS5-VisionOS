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
                    Text(appState.streamingViewModel.statusMessage)
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
                await appState.streamingViewModel.startStreaming(console: console)
            }
        }
        .onDisappear {
            // v10.5.1: Don't stop streaming or disable pipeline when entering VR mode
            // Only stop when actually closing the window (not VR transition)
            if !appState.isImmersiveActive {
                appState.streamingViewModel.stopStreaming()
                upscalingPipeline.disable()
            }
            // Note: Pipeline stays enabled for VR mode to continue processing frames
        }
    }
}
