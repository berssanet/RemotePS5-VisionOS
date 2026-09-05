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
        // Only the stream window opens; closing it ends the session (StreamingVideoWindow).
        openWindow(id: "StreamingWindow", value: console)
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
