//
//  StreamingView.swift
//  VisionRemotePS5
//
//  v10.5: Launcher view that opens 3 separate movable windows:
//  1. MenuBarWindow - Top bar with controls
//  2. StreamingVideoWindow - Video display (hidden in VR)
//  3. ControllerWindow - Gamepad controls
//

import SwiftUI

struct StreamingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    
    let console: Console
    
    var body: some View {
        // This view just launches the windows and closes itself
        Color.clear
            .frame(width: 1, height: 1)
            .task {
                // Store selected console
                appState.selectedConsole = console
                
                // Open all 3 windows
                openWindow(id: "StreamingWindow", value: console)
                openWindow(id: "MenuBarWindow")
                openWindow(id: "ControllerWindow")
                
                // Close this launcher window
                dismiss()
            }
    }
}

// MARK: - Streaming View Model (shared)

@MainActor
class StreamingViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var statusMessage = "Ready"
    @Published var showControls = true
    
    func startStreaming(console: Console) async {
        isConnected = false
        statusMessage = "Connecting..."
        
        // Build configuration from Console
        guard let rpKey = console.rpKey,
              let registKey = console.registKey else {
            statusMessage = "Error: Missing registration keys"
            return
        }
        
        let psnAccountId = console.psnAccountId ?? Data(repeating: 0, count: 8)
        let isPS5 = console.type == .ps5 || console.type == .ps5Digital
        
        let config = StreamingConfiguration(
            host: console.ipAddress,
            rpKey: rpKey,
            registKey: registKey,
            psnAccountID: psnAccountId,
            isPS5: isPS5,
            width: 1920,
            height: 1080,
            fps: 60,
            bitrate: 15000
        )
        
        do {
            statusMessage = "Starting stream..."
            StreamingService.shared.delegate = self
            try await StreamingService.shared.startStreaming(configuration: config)
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
            isConnected = false
        }
    }
    
    func stopStreaming() {
        StreamingService.shared.stopStreaming()
        isConnected = false
        statusMessage = "Stopped"
    }
    
    // MARK: - Controller Input
    
    func sendButtonPress(_ button: ControllerButton) {
        StreamingService.shared.pressButton(button)
    }
    
    func sendButtonRelease(_ button: ControllerButton) {
        StreamingService.shared.releaseButton(button)
    }
    
    func sendJoystickInput(left: CGPoint, right: CGPoint) {
        StreamingService.shared.setLeftStick(
            x: Int16(left.x * 32767),
            y: Int16(left.y * 32767)
        )
        StreamingService.shared.setRightStick(
            x: Int16(right.x * 32767),
            y: Int16(right.y * 32767)
        )
    }
}

// MARK: - Streaming Service Delegate

extension StreamingViewModel: StreamingServiceDelegate {
    nonisolated func streamingService(_ service: StreamingService, didChangeState state: StreamingState) {
        Task { @MainActor in
            switch state {
            case .connecting:
                statusMessage = "Connecting..."
            case .requestingSession:
                statusMessage = "Requesting session..."
            case .negotiating:
                statusMessage = "Negotiating stream..."
            case .streaming:
                statusMessage = "Streaming"
                isConnected = true
            case .error(let msg):
                statusMessage = "Error: \(msg)"
                isConnected = false
            case .stopped:
                statusMessage = "Stopped"
                isConnected = false
            case .idle:
                statusMessage = "Ready"
            }
        }
    }
    
    nonisolated func streamingService(_ service: StreamingService, didReceiveVideoFrame frame: CVPixelBuffer, timestamp: UInt64) {
        // Video frames are processed via UpscalingPipeline
        Task { @MainActor in
            let upscalingPipeline = UpscalingPipeline.shared
            if upscalingPipeline.isEnabled {
                _ = upscalingPipeline.processFrame(frame)
            }
        }
    }
    
    nonisolated func streamingService(_ service: StreamingService, didReceiveAudioData data: Data, sampleRate: Int, channels: Int) {
        // Audio handled by LowLatencyAudio
    }
    
    nonisolated func streamingService(_ service: StreamingService, didReceiveError error: Error) {
        Task { @MainActor in
            statusMessage = "Error: \(error.localizedDescription)"
            isConnected = false
        }
    }
}
