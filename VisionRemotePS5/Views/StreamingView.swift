//
//  StreamingView.swift
//  VisionRemotePS5
//

import SwiftUI

// MARK: - Streaming View Model (shared)

@MainActor
class StreamingViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var statusMessage = "Ready"
    
    func startStreaming(console: Console, auth: PSNAuthService) async {
        isConnected = false
        statusMessage = "Connecting..."
        
        // Build configuration from Console
        guard console.psnDeviceID != nil || (console.rpKey != nil && console.registKey != nil) else {
            statusMessage = "Error: Missing registration keys"
            return
        }
        
        let psnAccountId = console.psnAccountId ?? Data(repeating: 0, count: 8)
        let isPS5 = console.type == .ps5 || console.type == .ps5Digital
        
        var config = StreamingConfiguration(
            host: console.ipAddress,
            rpKey: console.rpKey ?? Data(),
            registKey: console.registKey ?? "",
            psnAccountID: psnAccountId,
            isPS5: isPS5,
            width: 1920,
            height: 1080,
            fps: 60,
            bitrate: 15000
        )
        
        do {
            if let deviceID = console.psnDeviceID {
                let token = try await auth.getAccessToken()
                guard let account = auth.userProfile.flatMap({ Data(base64Encoded: $0.accountId) }),
                      account == console.psnAccountId else {
                    throw PSNRemotePlayCoordinator.CoordinatorError.missingAccountId
                }
                config.psnConnection = PSNStreamingConnection(token: token, deviceID: deviceID)
            }
            try Task.checkCancellation()
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
}

// MARK: - Streaming Service Delegate

extension StreamingViewModel: StreamingServiceDelegate {
    nonisolated func streamingService(_ service: StreamingService, didChangeState state: StreamingState) {
        Task { @MainActor in
            switch state {
            case .connecting:
                statusMessage = "Connecting..."
            case .negotiating:
                statusMessage = "Negotiating stream..."
            case .streaming:
                statusMessage = "Streaming"
                isConnected = true
            case .error(let msg):
                statusMessage = "Error: \(msg)"
                isConnected = false
            case .stopped:
                if !statusMessage.hasPrefix("Error:") {
                    statusMessage = "Stopped"
                }
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
