import SwiftUI

@main
struct VisionRemotePS5App: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        
        // Full Immersive Space using RealityKit
        // Uses StreamingImmersiveView for curved screen 3D experience
        ImmersiveSpace(id: "StreamingSpace") {
            StreamingImmersiveView()
                .environmentObject(appState)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

/// Global app state shared across views
@MainActor
class AppState: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var isStreaming: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var selectedConsole: Console?
    @Published var discoveredConsoles: [Console] = []
    @Published var streamQuality: StreamQuality = .hd720
    @Published var connectionStatus: ConnectionStatus = .disconnected
    
    /// Shared PSN Authentication Service
    let psnAuthService = PSNAuthService()
    
    enum ConnectionStatus: String {
        case disconnected = "Disconnected"
        case connecting = "Connecting..."
        case connected = "Connected"
        case streaming = "Streaming"
        case error = "Error"
    }
    
    enum StreamQuality: String, CaseIterable {
        case sd540 = "540p"
        case hd720 = "720p"
        case hd1080 = "1080p"
        case uhd4k = "4K"
    }
}
