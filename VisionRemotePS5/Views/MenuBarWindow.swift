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
            // Close/Exit button - End session and return to console selection
            Button(action: {
                endSession()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }
            
            Spacer()
            
            // v10.6: Controller mode selector
            Menu {
                ForEach(AppState.ControllerMode.allCases, id: \.self) { mode in
                    Button(action: {
                        appState.controllerMode = mode
                    }) {
                        Label(mode.rawValue, systemImage: mode.icon)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: appState.controllerMode.icon)
                    Text("Pad")
                        .font(.caption)
                }
                .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            
            // v11.0: GPU Quality Menu
            Menu {
                Button("🏎️ Racing") {
                    appState.gpuPreset = .racing
                }
                Button("🔫 FPS") {
                    appState.gpuPreset = .fps
                }
                Button("🛡️ RPG") {
                    appState.gpuPreset = .rpg
                }
                Button("🎬 Cinematic") {
                    appState.gpuPreset = .cinematic
                }
                Divider()
                Button("✨ Auto") {
                    appState.gpuPreset = .auto
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cpu.fill")
                    Text(gpuPresetLabel)
                        .font(.caption)
                }
                .foregroundColor(.cyan)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            
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
    
    private var gpuPresetLabel: String {
        switch appState.gpuPreset {
        case .auto: return "Auto"
        case .racing: return "Racing"
        case .fps: return "FPS"
        case .rpg: return "RPG"
        case .cinematic: return "Cinema"
        }
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
    
    /// v10.5.2: End streaming session and return to console selection
    private func endSession() {
        Task {
            // 1. Exit VR mode if active
            if appState.isImmersiveActive {
                await dismissImmersiveSpace()
                appState.isImmersiveActive = false
            }
            
            // 2. Stop streaming
            appState.streamingViewModel.stopStreaming()
            
            // 3. Disable upscaling pipeline
            upscalingPipeline.disable()
            
            // 4. Clear selected console and reset state
            appState.selectedConsole = nil
            appState.isConnected = false
            appState.connectionStatus = .disconnected
            
            // 5. Show console selection UI again
            appState.isInStreamingSession = false
            
            // 6. Close streaming-related windows
            dismissWindow(id: "StreamingWindow")
            dismissWindow(id: "ControllerWindow")
            dismissWindow(id: "MenuBarWindow")
            
            print("[MenuBarWindow] Session ended, returned to console selection")
        }
    }
}
