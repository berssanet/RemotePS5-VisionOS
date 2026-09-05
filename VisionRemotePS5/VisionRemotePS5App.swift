import SwiftUI

@main
struct VisionRemotePS5App: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        // Main content window (console list, settings, etc)
        // v10.5.2: Uses .contentSize + .plain to minimize during streaming
        WindowGroup(id: "MainWindow") {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        
        // Streaming window: the only thing shown while connected. Input comes from a
        // Bluetooth controller paired with the Vision Pro (GameControllerManager).
        WindowGroup(id: "StreamingWindow", for: Console.self) { $console in
            if let console = console {
                StreamingVideoWindow(console: console)
                    .environmentObject(appState)
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1280, height: 720)
    }
}

/// Global app state shared across views
@MainActor
class AppState: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var isInStreamingSession: Bool = false  // v10.5.2: Hide console selection when streaming
    @Published var selectedConsole: Console?
    @Published var discoveredConsoles: [Console] = []
    @Published var streamQuality: StreamQuality = .hd720
    @Published var connectionStatus: ConnectionStatus = .disconnected
    
    // v10.5: Shared ViewModel for controller input
    let streamingViewModel = StreamingViewModel()
    
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
