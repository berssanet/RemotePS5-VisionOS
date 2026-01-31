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
        
        // v10.5: Streaming window - shows video, hidden in VR mode
        WindowGroup(id: "StreamingWindow", for: Console.self) { $console in
            if let console = console {
                StreamingVideoWindow(console: console)
                    .environmentObject(appState)
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1280, height: 720)
        
        // v10.5: Menu bar window - always visible, movable
        WindowGroup(id: "MenuBarWindow") {
            MenuBarWindow()
                .environmentObject(appState)
        }
        .windowStyle(.plain)
        .defaultSize(width: 500, height: 60)
        
        // v10.5: Controller window - movable independently
        // v10.6: Larger size to accommodate F1 cockpit wheel
        WindowGroup(id: "ControllerWindow") {
            ControllerWindow()
                .environmentObject(appState)
        }
        .windowStyle(.plain)
        .defaultSize(width: 550, height: 280)
        
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
    @Published var isImmersiveActive: Bool = false  // v10.5: Track VR mode globally
    @Published var isInStreamingSession: Bool = false  // v10.5.2: Hide console selection when streaming
    @Published var controllerMode: ControllerMode = .standard  // v10.6: F1 cockpit support
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
    
    /// v10.6: Controller display mode
    enum ControllerMode: String, CaseIterable {
        case standard = "Standard"
        case f1Cockpit = "F1 Cockpit"
        case virtualWheel = "Virtual Wheel"
        
        var icon: String {
            switch self {
            case .standard: return "gamecontroller"
            case .f1Cockpit: return "steeringwheel"
            case .virtualWheel: return "hand.raised.fingers.spread"
            }
        }
        
        var description: String {
            switch self {
            case .standard: return "Touch controls"
            case .f1Cockpit: return "Touch steering wheel"
            case .virtualWheel: return "Hand tracking wheel (VR only)"
            }
        }
    }
}
