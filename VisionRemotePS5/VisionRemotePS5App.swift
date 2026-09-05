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
        .defaultSize(width: 320, height: 60)
        
        // v10.5: Controller window - movable independently
        // v10.6: Larger size to accommodate F1 cockpit wheel
        WindowGroup(id: "ControllerWindow") {
            ControllerWindow()
                .environmentObject(appState)
        }
        .windowStyle(.plain)
        .defaultSize(width: 620, height: 280)
        
        // Full Immersive Space using RealityKit
        // Uses StreamingImmersiveView for curved screen 3D experience
        ImmersiveSpace(id: "StreamingSpace") {
            StreamingImmersiveView()
                .environmentObject(appState)
        }
        .immersionStyle(selection: .constant(.full), in: .full)

        // v12.6: HoloPad companion space for WINDOWED streaming — mixed
        // immersion (full passthrough, windows stay visible). Hand tracking
        // requires an open immersive space; this one renders only the
        // hand-anchored HoloPad feedback.
        ImmersiveSpace(id: "HoloPadSpace") {
            HoloPadSpaceView()
                .environmentObject(appState)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        // v13.0: Controller Test Range — practice/calibrate the virtual
        // controller with two mini-games, no PS5 session required.
        // v13.1: FULL immersion — the player sees ONLY the app (a virtual
        // arena) while configuring, per user direction. Two view modes:
        // first-person shooting range and third-person runner.
        ImmersiveSpace(id: "TrainingRangeSpace") {
            ControllerTestRangeView()
                .environmentObject(appState)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

/// Global app state shared across views
@MainActor
class AppState: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var isImmersiveActive: Bool = false  // v10.5: Track VR mode globally
    @Published var isHoloPadSpaceActive: Bool = false  // v12.6: mixed HoloPad space (windowed input)
    @Published var isTrainingRangeActive: Bool = false  // v13.0: Controller Test Range (no PS5)
    @Published var isInStreamingSession: Bool = false  // v10.5.2: Hide console selection when streaming
    // v12.5: HoloPad is THE controller (user direction 2026-07-04). The other
    // modes stay in code but are not selectable — see ControllerMode.selectable.
    @Published var controllerMode: ControllerMode = .handGesture
    // v12.8.2: back to OFF by default — the first on-device VR run with 3D
    // active ended in a freeze+disconnect; validate the spatial pipeline in
    // isolation via the 2D/3D panel toggle before making it the default.
    @Published var spatial3DEnabled: Bool = false
    @Published var gpuPreset: GPUPreset = .auto  // v11.0: GPU optimization preset
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
        case virtualWheel = "Virtual Wheel"
        case handGesture = "HoloPad"

        /// Modes offered in the UI. Standard overlay and the wheel are
        /// quarantined per user direction (2026-07-04) — HoloPad only.
        static let selectable: [ControllerMode] = [.handGesture]

        var icon: String {
            switch self {
            case .standard: return "gamecontroller"
            case .virtualWheel: return "hand.raised.fingers.spread"
            case .handGesture: return "hand.point.up.braille"
            }
        }
    }
    
    /// v11.0: GPU Processing Preset
    enum GPUPreset: String, CaseIterable {
        case auto = "Auto"
        case racing = "Racing"
        case fps = "FPS"
        case rpg = "RPG"
        case cinematic = "Cinematic"
        
        var icon: String {
            switch self {
            case .auto: return "sparkles.rectangle.stack"
            case .racing: return "steeringwheel"
            case .fps: return "scope"
            case .rpg: return "shield.fill"
            case .cinematic: return "film.fill"
            }
        }
    }
}
