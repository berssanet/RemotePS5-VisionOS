import SwiftUI

@main
struct VisionRemotePS5App: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        // Main content window (console list, settings, etc)
        // Explicit launch size plus home content bounds also recover windows
        // previously restored at the hidden streaming size.
        WindowGroup(id: "MainWindow") {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.plain)
        .defaultSize(width: 840, height: 660)
        .windowResizability(.contentSize)
        .onChange(of: scenePhase) { _, phase in
            // App-level aggregate phase, not a single window losing focus.
            appState.applicationPhaseChanged(phase)
        }
        
        // Streaming window: the only thing shown while connected. Input comes from a
        // Bluetooth controller paired with the Vision Pro (GameControllerManager).
        WindowGroup(id: "StreamingWindow", for: PresentationCoordinator.Surface.self) { $surface in
            if let surface {
                if appState.presentationDriver.ownsWindow(surface) {
                    StreamingVideoWindow(surface: surface, viewModel: appState.streamingViewModel)
                        .environmentObject(appState)
                        .id(surface)
                } else {
                    ExpiredStreamingWindow(surface: surface)
                }
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1280, height: 720)

        ImmersiveSpace(id: "CinemaSpace") {
            if let surface = appState.immersiveSurface {
                ImmersiveCinemaView(surface: surface)
                    .environmentObject(appState)
                    .id(surface)
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
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
    @Published var connectionStatus: ConnectionStatus = .disconnected
    
    // v10.5: Shared ViewModel for controller input
    let streamingViewModel = StreamingViewModel()

    // One app-owned session/presentation authority, independent of view tasks.
    let presentationCoordinator = PresentationCoordinator()
    @Published private(set) var presentationState: PresentationCoordinator.State = .idle
    @Published private(set) var selectedSurface: PresentationCoordinator.Surface?
    @Published private(set) var immersiveSurface: PresentationCoordinator.Surface?
    @Published private(set) var presentationError: String?
    @Published var sessionError: String?
    private var pendingSessionError: String?
    private var windowActions: (open: (PresentationCoordinator.Surface) -> Void,
                                close: (PresentationCoordinator.Surface) -> Void)?
    private var immersiveActions: (open: @MainActor () async -> PresentationCoordinator.OpenResult,
                                   dismiss: @MainActor () async -> Void)?

    lazy var presentationDriver = PresentationSessionDriver(
        coordinator: presentationCoordinator,
        environment: .init(
            serviceIsQuiescent: { StreamingService.shared.isQuiescent },
            start: { [weak self] lease, mayStart, onEvent in
                guard let self, self.presentationCoordinator.lease == lease,
                      let console = self.selectedConsole else { throw CancellationError() }
                try await self.streamingViewModel.startStreaming(
                    console: console, auth: self.psnAuthService, mayStart: mayStart,
                    onStateChange: { state, generation in
                        switch state {
                        case .connecting: onEvent(.connecting)
                        case .negotiating: onEvent(.negotiating)
                        case .streaming: onEvent(.running(generation))
                        case .error(let message): onEvent(.failed(message))
                        case .idle, .stopped: break // Teardown is acknowledged by awaiting its task.
                        }
                    })
            },
            requestStop: { StreamingService.shared.stopStreaming() },
            waitForStop: { await StreamingService.shared.waitForStopCompletion() },
            prepareDelivery: {
                UpscalingPipeline.shared.initialize()
                UpscalingPipeline.shared.enable()
            },
            endDelivery: { UpscalingPipeline.shared.disable() },
            openWindow: { [weak self] surface in self?.windowActions?.open(surface) },
            closeWindow: { [weak self] surface in self?.windowActions?.close(surface) },
            transportStatus: { [weak self] _, event in self?.applyTransportStatus(event) },
            didEnd: { [weak self] _, reason in self?.sessionEnded(reason) },
            didUpdate: { [weak self] in self?.publishPresentationState() },
            selectConsumer: { surface in
                VideoDelivery.shared.selectConsumer(surface?.id)
            },
            openImmersion: { [weak self] operation, surface in
                guard let self, self.presentationCoordinator.lease == operation.lease,
                      self.presentationCoordinator.immersiveSurface == surface,
                      let actions = self.immersiveActions else { return .error }
                self.publishPresentationState()
                return await actions.open()
            },
            dismissImmersion: { [weak self] _ in
                // Actions remain retained until the coordinator acknowledges
                // the actual dismissal and releases the entire session lease.
                await self?.immersiveActions?.dismiss()
            }
        ))

    @discardableResult
    func startSession(console: Console,
                      openWindow: @escaping (PresentationCoordinator.Surface) -> Void,
                      closeWindow: @escaping (PresentationCoordinator.Surface) -> Void) -> Bool {
        guard !presentationDriver.isBusy, StreamingService.shared.isQuiescent else { return false }
        selectedConsole = console
        windowActions = (openWindow, closeWindow)
        sessionError = nil
        pendingSessionError = nil
        presentationError = nil
        let result = presentationDriver.startSession()
        if result.rejection != nil {
            selectedConsole = nil
            windowActions = nil
            return false
        }
        return presentationDriver.isBusy
    }

    var canEnterCinema: Bool {
        (presentationState == .windowed || presentationState == .error)
            && presentationCoordinator.transport == .running
    }

    func enterCinema(open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction) {
        guard canEnterCinema, let lease = presentationCoordinator.lease else { return }
        immersiveActions = (
            open: {
                switch await open(id: "CinemaSpace") {
                case .opened: return .opened
                case .userCancelled: return .userCancelled
                case .error: return .error
                @unknown default: return .unknown
                }
            },
            dismiss: { await dismiss() }
        )
        presentationError = nil
        presentationDriver.send(.enterImmersion(lease))
    }

    func returnToWindow() {
        guard let lease = presentationCoordinator.lease else { return }
        presentationDriver.send(.returnToWindow(lease))
    }

    func refreshCinemaDismiss(surface: PresentationCoordinator.Surface,
                              dismiss: DismissImmersiveSpaceAction) {
        guard presentationCoordinator.lease == surface.lease,
              presentationCoordinator.immersiveSurface == surface,
              let actions = immersiveActions else { return }
        // Once cinema exists, dismissal uses its live scene environment rather
        // than depending on the retired streaming window's environment.
        immersiveActions = (open: actions.open, dismiss: { await dismiss() })
    }

    func applicationPhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: presentationDriver.send(.appPhase(.active))
        case .inactive: presentationDriver.send(.appPhase(.inactive))
        case .background: presentationDriver.send(.appPhase(.background))
        @unknown default: break
        }
    }

    private func applyTransportStatus(_ event: PresentationSessionDriver.TransportEvent) {
        switch event {
        case .connecting:
            streamingViewModel.applyState(.connecting)
            connectionStatus = .connecting
        case .negotiating:
            streamingViewModel.applyState(.negotiating)
            connectionStatus = .connecting
        case .running:
            streamingViewModel.applyState(.streaming)
            isConnected = true
            connectionStatus = .streaming
        case .failed(let message):
            pendingSessionError = message
            streamingViewModel.applyState(.error(message))
            isConnected = false
            connectionStatus = .error
        }
    }

    private func publishPresentationState() {
        presentationState = presentationCoordinator.state
        selectedSurface = presentationCoordinator.selectedSurface
        immersiveSurface = presentationCoordinator.immersiveSurface
        isInStreamingSession = presentationDriver.isBusy
        if presentationState == .error {
            presentationError = "Cinema could not be opened. Your stream is still available in this window."
        } else if presentationState == .windowed || presentationState == .immersive {
            presentationError = nil
        }
        if presentationState == .terminating {
            isConnected = false
            streamingViewModel.isConnected = false
            if !streamingViewModel.statusMessage.hasPrefix("Error:") {
                streamingViewModel.statusMessage = "Ending session…"
            }
        }
    }

    private func sessionEnded(_ reason: PresentationCoordinator.Reason) {
        selectedConsole = nil
        selectedSurface = nil
        immersiveSurface = nil
        windowActions = nil
        immersiveActions = nil
        presentationError = nil
        isConnected = false
        connectionStatus = .disconnected
        streamingViewModel.markStopped()
        isInStreamingSession = false
        switch reason {
        case .windowTimeout, .clockUnavailable, .readinessFailed:
            sessionError = pendingSessionError ?? "The streaming window could not be prepared. Please try again."
        case .transportFailure:
            sessionError = pendingSessionError ?? "The connection ended. Please try again."
        default: break
        }
        pendingSessionError = nil
    }
    
    /// Shared PSN Authentication Service
    let psnAuthService = PSNAuthService()
    
    enum ConnectionStatus: String {
        case disconnected = "Disconnected"
        case connecting = "Connecting..."
        case connected = "Connected"
        case streaming = "Streaming"
        case error = "Error"
    }
    
}

/// A restored window token has no authority to reserve or restart a session.
private struct ExpiredStreamingWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow
    let surface: PresentationCoordinator.Surface

    var body: some View {
        VStack(spacing: 16) {
            Text("This session has ended.")
            Text("Start a new session from the main window.").font(.caption)
            Button("Close") { dismissWindow(id: "StreamingWindow", value: surface) }
        }
        .padding(32)
        .glassBackgroundEffect()
    }
}
