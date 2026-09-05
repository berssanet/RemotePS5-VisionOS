import SwiftUI

// MARK: - Home Navigation

/// Destinations pushed from HomeView onto the NavigationStack owned by ContentView.
enum HomeRoute: Hashable {
    case addConsole
    case pairLocalConsole(Console)
}

// MARK: - Home View (Registered Console First)
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    /// Owned by ContentView. PairingView resets it to NavigationPath() to come back here.
    @Binding var navigationPath: NavigationPath

    @State private var registeredConsoles: [Console] = []
    @State private var isLoading = true
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var connectingConsoleId: UUID?
    @State private var showSettings = false
    @State private var isPreparingConnection = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                headerSection

                LocalConsoleConnectionView(
                    auth: appState.psnAuthService,
                    registeredConsoles: registeredConsoles,
                    isPreparingConnection: $isPreparingConnection,
                    onStreaming: { startSession(console: $0) },
                    onPairing: { navigationPath.append(HomeRoute.pairLocalConsole($0)) }
                )
                .disabled(appState.isInStreamingSession)

                PSNConsolesSection(auth: appState.psnAuthService,
                                   isPreparingConnection: $isPreparingConnection) { console in
                    startSession(console: console)
                }
                .disabled(appState.isInStreamingSession)

                // v13.0: practice the controller before connecting to a PS5
                testRangeCard

                if isLoading {
                    loadingSection
                } else if registeredConsoles.isEmpty {
                    noConsolesSection
                } else {
                    // Show registered consoles with "Start Session" button
                    registeredConsolesSection
                }
            }
            .padding()
        }
        .navigationTitle("PS Remote Play")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openAddConsole()
                } label: {
                    Label("Add Console", systemImage: "plus.circle")
                }
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .navigationDestination(for: HomeRoute.self) { route in
            switch route {
            case .addConsole:
                PairingView(navigationPath: $navigationPath)
            case .pairLocalConsole(let console):
                PairingView(navigationPath: $navigationPath, console: console)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(appState)
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .task {
            await loadRegisteredConsoles()
        }
        .onChange(of: navigationPath.count) { _, count in
            // Back on the home screen (e.g. right after pairing): pick up newly registered consoles.
            guard count == 0 else { return }
            Task {
                await loadRegisteredConsoles()
            }
        }
    }
    
    // MARK: - Sections
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("PlayStation Remote Play")
                .font(.largeTitle)
                .bold()
            
            Text("Play your PS5 games anywhere")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 30)
    }
    
    /// v13.0: entry point to the Controller Test Range immersive space.
    /// Available with zero registered consoles — you can practice first.
    private var testRangeCard: some View {
        Button {
            openTestRange()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "figure.mixed.cardio")
                    .font(.system(size: 34))
                    .foregroundStyle(.purple)
                    .frame(width: 60, height: 60)
                    .background(Color.purple.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Controller Test Range")
                        .font(.headline)
                    Text("Try, tune and calibrate the virtual controller with a test dummy — no PS5 needed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .glassBackgroundEffect()
        }
        .buttonStyle(.plain)
        .disabled(appState.isTrainingRangeActive)
    }

    private var loadingSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Loading consoles...")
                .font(.headline)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .glassBackgroundEffect()
    }
    
    private var noConsolesSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("No Registered Consoles")
                .font(.headline)
            
            Text("Register a PlayStation console first to start streaming.\n\n• Make sure your PS5 has Remote Play enabled\n• Tap Add Console, then enter its IP address and the PIN from Settings > System > Remote Play > Link Device")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            HStack(spacing: 12) {
                Button {
                    openAddConsole()
                } label: {
                    Label("Add Console", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                
                Button {
                    Task {
                        await loadRegisteredConsoles()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .glassBackgroundEffect()
    }
    
    private var registeredConsolesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Your Consoles")
                    .font(.title2)
                    .bold()
                
                Spacer()
                
                Button {
                    openAddConsole()
                } label: {
                    Label("Add Console", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                
                Button {
                    Task {
                        await loadRegisteredConsoles()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Refresh")
            }
            
            ForEach(registeredConsoles) { console in
                RegisteredConsoleCard(
                    console: console,
                    isConnecting: connectingConsoleId == console.id,
                    onStartSession: {
                        startSession(console: console)
                    }
                )
                .disabled(isPreparingConnection || appState.isInStreamingSession)
            }
        }
    }
    
    // MARK: - Actions
    
    private func loadRegisteredConsoles() async {
        isLoading = true
        registeredConsoles = await ConsoleStorageService.shared.getRegisteredConsoles()
        isLoading = false
    }

    private func openAddConsole() {
        navigationPath.append(HomeRoute.addConsole)
    }
    
    private func startSession(console: Console) {
        guard !appState.isInStreamingSession else { return }
        guard console.psnDeviceID?.count == 32 || LocalConsoleConnectionService.hasRegistration(console) else {
            navigationPath.append(HomeRoute.pairLocalConsole(console))
            return
        }
        connectingConsoleId = console.id
        appState.selectedConsole = console
        appState.isInStreamingSession = true

        // v13.0: if the test range is open, FULLY close it before opening the
        // streaming windows. StreamingVideoWindow opens the HoloPad companion
        // space on appear, and visionOS allows only one immersive space at a
        // time — an un-awaited dismissal would race that open and leave
        // windowed hand tracking dead. Mirror MenuBarWindow.enterVRMode():
        // await the dismissal, THEN open the windows.
        if appState.isTrainingRangeActive {
            Task {
                await dismissImmersiveSpace()
                appState.isTrainingRangeActive = false
                openStreamingWindows(console: console)
            }
        } else {
            openStreamingWindows(console: console)
        }
    }

    private func openStreamingWindows(console: Console) {
        openWindow(id: "StreamingWindow", value: console)
        openWindow(id: "MenuBarWindow")
        openWindow(id: "ControllerWindow")
    }

    /// v13.0: open the Controller Test Range immersive space. Guarded so it
    /// never stacks on another space (visionOS allows one at a time) or a
    /// live streaming session.
    private func openTestRange() {
        guard !appState.isTrainingRangeActive,
              !appState.isImmersiveActive,
              !appState.isHoloPadSpaceActive,
              !appState.isInStreamingSession else { return }
        Task {
            let result = await openImmersiveSpace(id: "TrainingRangeSpace")
            if case .opened = result {
                appState.isTrainingRangeActive = true
            } else {
                DebugLog.warning("TestRange", "Failed to open training space: \(result)")
            }
        }
    }
}

// MARK: - Registered Console Card

struct RegisteredConsoleCard: View {
    let console: Console
    let isConnecting: Bool
    let onStartSession: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Device icon
            Image(systemName: deviceIcon)
                .font(.system(size: 40))
                .foregroundStyle(.blue)
                .frame(width: 60, height: 60)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
            // Console info
            VStack(alignment: .leading, spacing: 4) {
                Text(console.nickname ?? console.name)
                    .font(.headline)
                
                Text(console.type.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(console.ipAddress)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            // Start Session button
            if isConnecting {
                ProgressView()
            } else {
                Button {
                    onStartSession()
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Start Session")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .glassBackgroundEffect()
    }
    
    private var deviceIcon: String {
        switch console.type {
        case .ps5, .ps5Digital:
            return "gamecontroller.fill"
        case .ps4, .ps4Pro:
            return "gamecontroller"
        }
    }
    
    private var statusColor: Color {
        switch console.status {
        case .online: return .green
        case .standby: return .yellow
        case .offline: return .gray
        }
    }
}

// MARK: - Preview

#Preview(windowStyle: .automatic) {
    NavigationStack {
        HomeView(navigationPath: .constant(NavigationPath()))
            .environmentObject(AppState())
    }
}
