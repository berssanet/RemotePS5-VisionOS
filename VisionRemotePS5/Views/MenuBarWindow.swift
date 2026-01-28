//
//  MenuBarWindow.swift
//  VisionRemotePS5
//
//  v10.5: Floating menu bar - always visible and movable
//  Contains VR toggle, resolution info, and connection status
//

import SwiftUI

struct MenuBarWindow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var upscalingPipeline = UpscalingPipeline.shared
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        HStack(spacing: 16) {
            // Close/Exit button
            Button(action: {
                if appState.isImmersiveActive {
                    exitVRMode()
                } else {
                    // Stop streaming and close all windows
                    appState.streamingViewModel.stopStreaming()
                    dismissWindow(id: "StreamingWindow")
                    dismissWindow(id: "ControllerWindow")
                    dismissWindow(id: "MenuBarWindow")
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }
            
            Spacer()
            
            // VR mode toggle
            Button(action: {
                if appState.isImmersiveActive {
                    exitVRMode()
                } else {
                    enterVRMode()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: appState.isImmersiveActive ? "visionpro.fill" : "visionpro")
                    Text(appState.isImmersiveActive ? "Exit VR" : "VR")
                        .font(.caption)
                }
                .foregroundColor(appState.isImmersiveActive ? .blue : .white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            
            // Resolution badge
            if let texture = upscalingPipeline.upscaledTexture {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles.tv")
                    Text("\(texture.width)x\(texture.height)")
                        .font(.caption)
                }
                .foregroundColor(.cyan)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
            }
            
            // Connection status
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.isConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                
                Text(appState.isConnected ? "Connected" : "Disconnected")
                    .font(.caption)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackgroundEffect()
    }
    
    private func enterVRMode() {
        Task {
            let result = await openImmersiveSpace(id: "StreamingSpace")
            if case .opened = result {
                appState.isImmersiveActive = true
                // Hide streaming window in VR mode
                dismissWindow(id: "StreamingWindow")
            }
        }
    }
    
    private func exitVRMode() {
        Task {
            await dismissImmersiveSpace()
            appState.isImmersiveActive = false
            // Show streaming window again
            if let console = appState.selectedConsole {
                openWindow(id: "StreamingWindow", value: console)
            }
        }
    }
}
