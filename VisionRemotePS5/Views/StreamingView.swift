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
    
    func startStreaming(
        console: Console,
        auth: PSNAuthService,
        mayStart: @escaping @MainActor () -> Bool,
        onStateChange: @escaping @MainActor @Sendable (StreamingState, MetricSessionID) -> Void
    ) async throws {
        @MainActor func validateStartup() throws {
            try Task.checkCancellation()
            guard mayStart() else { throw CancellationError() }
        }
        try validateStartup()

        // Build configuration from Console
        guard console.psnDeviceID != nil || (console.rpKey != nil && console.registKey != nil) else {
            throw StreamingError.invalidConfiguration
        }

        isConnected = false
        statusMessage = "Connecting..."
        
        let psnAccountId = console.psnAccountId ?? Data(repeating: 0, count: 8)
        let isPS5 = console.type == .ps5 || console.type == .ps5Digital
        let profile = StreamProfile.selected
        
        var config = StreamingConfiguration(
            host: console.ipAddress,
            rpKey: console.rpKey ?? Data(),
            registKey: console.registKey ?? "",
            psnAccountID: psnAccountId,
            isPS5: isPS5,
            width: profile.width,
            height: profile.height,
            fps: profile.framesPerSecond,
            bitrate: profile.bitrateKbps
        )
        
        if let deviceID = console.psnDeviceID {
            try validateStartup()
            let token = try await auth.getAccessToken()
            try validateStartup()
            guard let account = auth.userProfile.flatMap({ Data(base64Encoded: $0.accountId) }),
                  account == console.psnAccountId else {
                throw PSNRemotePlayCoordinator.CoordinatorError.missingAccountId
            }
            config.psnConnection = PSNStreamingConnection(token: token, deviceID: deviceID)
        }
        try validateStartup()
        statusMessage = "Starting stream..."
        // The driver captures S in this callback and owns error publication and
        // teardown. After this await, startup permission may legitimately have
        // ended because the current transport is already running.
        try await StreamingService.shared.startStreaming(configuration: config, onStateChange: onStateChange)
    }

    /// The driver validates the captured lease before applying service state.
    func applyState(_ state: StreamingState) {
        switch state {
        case .connecting:
            statusMessage = "Connecting..."
        case .negotiating:
            statusMessage = "Negotiating stream..."
        case .streaming:
            statusMessage = "Streaming"
            isConnected = true
        case .error(let message):
            statusMessage = "Error: \(message)"
            isConnected = false
        case .stopped:
            markStopped()
        case .idle:
            statusMessage = "Ready"
        }
    }

    func markStopped() {
        isConnected = false
        if !statusMessage.hasPrefix("Error:") {
            statusMessage = "Stopped"
        }
    }
    
    // MARK: - Controller Input
    
    func sendButtonPress(_ button: ControllerButton) {
        StreamingService.shared.pressButton(button)
    }
    
    func sendButtonRelease(_ button: ControllerButton) {
        StreamingService.shared.releaseButton(button)
    }
}
