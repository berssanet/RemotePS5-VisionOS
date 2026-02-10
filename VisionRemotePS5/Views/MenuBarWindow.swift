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
        HStack(spacing: 12) {
            // Close/Exit button
            Button(action: { endSession() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.white)
            }
            .help("End Session")
            
            Spacer()
            
            // v10.6: Controller mode selector (icon-only)
            Menu {
                ForEach(AppState.ControllerMode.allCases, id: \.self) { mode in
                    Button(action: {
                        appState.controllerMode = mode
                    }) {
                        Label(mode.rawValue, systemImage: mode.icon)
                    }
                }
            } label: {
                Image(systemName: appState.controllerMode.icon)
                    .font(.title3)
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .help("Controller: \(appState.controllerMode.rawValue)")
            
            // v11.0: GPU Quality Menu (icon-only)
            Menu {
                Button("🏎️ Racing") { appState.gpuPreset = .racing }
                Button("🔫 FPS") { appState.gpuPreset = .fps }
                Button("🛡️ RPG") { appState.gpuPreset = .rpg }
                Button("🎬 Cinematic") { appState.gpuPreset = .cinematic }
                Divider()
                Button("✨ Auto") { appState.gpuPreset = .auto }
            } label: {
                Image(systemName: appState.gpuPreset.icon)
                    .font(.title3)
                    .foregroundColor(.cyan)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .help("GPU: \(gpuPresetLabel)")
            
            // VR mode toggle (icon-only)
            Button(action: {
                if appState.isImmersiveActive {
                    exitVRMode()
                } else {
                    enterVRMode()
                }
            }) {
                Image(systemName: appState.isImmersiveActive ? "visionpro.fill" : "visionpro")
                    .font(.title3)
                    .foregroundColor(appState.isImmersiveActive ? .blue : .white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .help(appState.isImmersiveActive ? "Exit VR" : "Enter VR")
            
            // Resolution badge (icon-only, compact)
            if let texture = upscalingPipeline.upscaledTexture {
                Image(systemName: "sparkles.tv")
                    .font(.title3)
                    .foregroundColor(.cyan)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .help("\(texture.width)×\(texture.height)")
            }
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
        // Prevent opening another immersive space if one is already active
        guard !appState.isImmersiveActive else {
            print("[MenuBar] ⚠️ ImmersiveSpace already active, skipping")
            return
        }
        
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
