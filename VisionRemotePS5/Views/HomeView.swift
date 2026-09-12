import SwiftUI

/// Destinations share the NavigationStack owned by ContentView. Pairing resets
/// that path to return to the launch screen after saving a console.
enum HomeRoute: Hashable {
    case connectionOptions
    case addConsole
    case pairLocalConsole(Console)
}

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Binding var navigationPath: NavigationPath

    @AppStorage("home_selected_console_id") private var selectedConsoleID = ""
    @AppStorage(StreamProfile.preferenceKey) private var streamProfile = StreamProfile.minimum.rawValue
    @State private var registeredConsoles: [Console] = []
    @State private var isLoading = true
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var connectingConsoleId: UUID?
    @State private var showSettings = false
    @State private var isPreparingConnection = false
    @State private var connectionMethod = ConnectionMethod.local

    private enum ConnectionMethod: String, CaseIterable, Identifiable {
        case local = "Local network"
        case psn = "PlayStation Network"
        var id: Self { self }
    }

    private var selectedConsole: Console? {
        registeredConsoles.first { $0.id.uuidString == selectedConsoleID }
            ?? registeredConsoles.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                if isLoading {
                    ProgressView("Loading your consoles…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let console = selectedConsole {
                    consoleCard(console)
                } else {
                    setupCard
                }
                if !registeredConsoles.isEmpty {
                    Button {
                        navigationPath.append(HomeRoute.connectionOptions)
                    } label: {
                        Label("Connection options", systemImage: "network")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isPreparingConnection || appState.isInStreamingSession)
                }
            }
            .frame(maxWidth: 660)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 24)
            .padding(.bottom, 36)
        }
        .navigationTitle("Vision Remote")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Settings")
            }
        }
        .navigationDestination(for: HomeRoute.self) { route in
            switch route {
            case .connectionOptions:
                connectionOptions
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
        .alert("Connection error", isPresented: $showError) {
            Button("OK") { appState.sessionError = nil }
        } message: {
            Text(errorMessage)
        }
        .task {
            await loadRegisteredConsoles()
        }
        .onChange(of: navigationPath.count) { _, count in
            guard count == 0 else { return }
            Task { await loadRegisteredConsoles() }
        }
        .onChange(of: appState.sessionError, initial: true) { _, message in
            guard let message else { return }
            errorMessage = message
            showError = true
        }
        .onChange(of: appState.isInStreamingSession) { _, active in
            if !active { connectingConsoleId = nil }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 22))
            Text(registeredConsoles.isEmpty ? "Your PlayStation, here" : "Ready to play")
                .font(.largeTitle.bold())
            Text(registeredConsoles.isEmpty
                 ? "Connect your console to get started."
                 : "Start a session with your saved console.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    private func consoleCard(_ console: Console) -> some View {
        VStack(spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 30))
                    .foregroundStyle(.blue)
                    .frame(width: 60, height: 60)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 5) {
                    Text(console.nickname ?? console.name)
                        .font(.title2.bold())
                        .lineLimit(2)
                    Text("\(console.type.rawValue) · Saved console")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if registeredConsoles.count > 1 {
                    Menu {
                        Picker("Console", selection: $selectedConsoleID) {
                            ForEach(registeredConsoles) { saved in
                                Text(saved.nickname ?? saved.name).tag(saved.id.uuidString)
                            }
                        }
                    } label: {
                        Label("Change console", systemImage: "chevron.up.chevron.down")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Change console")
                    .disabled(isPreparingConnection || appState.isInStreamingSession)
                }
            }
            HStack {
                Label("Stream", systemImage: "wifi")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Source quality", selection: $streamProfile) {
                    ForEach(StreamProfile.allCases) { profile in
                        Text(profile.title).tag(profile.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(isPreparingConnection || appState.isInStreamingSession)
            }
            Button {
                startSession(console: console)
            } label: {
                HStack(spacing: 10) {
                    if connectingConsoleId == console.id {
                        ProgressView()
                        Text("Connecting…")
                    } else {
                        Image(systemName: "play.fill")
                        Text("Connect")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isPreparingConnection || appState.isInStreamingSession)
        }
        .padding(28)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 28))
    }

    private var setupCard: some View {
        VStack(spacing: 20) {
            Text("Enable Remote Play on your PS5, then add it here. Your console will be ready for a quick connection next time.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                navigationPath.append(HomeRoute.connectionOptions)
            } label: {
                Label("Set up console", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(28)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 28))
    }

    /// Connection setup is intentionally a second screen; existing users only
    /// need their saved console and Connect on launch.
    private var connectionOptions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Choose how to reach your console.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Picker("Connection method", selection: $connectionMethod) {
                    ForEach(ConnectionMethod.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isPreparingConnection)

                switch connectionMethod {
                case .local:
                    LocalConsoleConnectionView(
                        auth: appState.psnAuthService,
                        registeredConsoles: registeredConsoles,
                        isPreparingConnection: $isPreparingConnection,
                        onStreaming: { startSession(console: $0) },
                        onPairing: { navigationPath.append(HomeRoute.pairLocalConsole($0)) }
                    )
                case .psn:
                    PSNConsolesSection(auth: appState.psnAuthService,
                                       isPreparingConnection: $isPreparingConnection) { console in
                        startSession(console: console)
                    }
                }

                HStack {
                    Button {
                        navigationPath.append(HomeRoute.addConsole)
                    } label: {
                        Label("Register with a PIN", systemImage: "number")
                    }
                    Spacer()
                    Button {
                        Task { await loadRegisteredConsoles() }
                    } label: {
                        Label("Refresh saved consoles", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isPreparingConnection || isLoading)
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .padding(32)
        }
        .navigationTitle("Connection options")
        .disabled(appState.isInStreamingSession)
    }

    private func loadRegisteredConsoles() async {
        isLoading = true
        registeredConsoles = await ConsoleStorageService.shared.getRegisteredConsoles().sorted {
            if $0.lastConnected != $1.lastConnected {
                return ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast)
            }
            return ($0.nickname ?? $0.name).localizedStandardCompare($1.nickname ?? $1.name) == .orderedAscending
        }
        if !registeredConsoles.contains(where: { $0.id.uuidString == selectedConsoleID }) {
            selectedConsoleID = registeredConsoles.first?.id.uuidString ?? ""
        }
        isLoading = false
    }

    private func startSession(console: Console) {
        guard !appState.isInStreamingSession else { return }
        guard console.psnDeviceID?.count == 32 || LocalConsoleConnectionService.hasRegistration(console) else {
            navigationPath.append(HomeRoute.pairLocalConsole(console))
            return
        }
        if appState.startSession(console: console, openWindow: { surface in
            openWindow(id: "StreamingWindow", value: surface)
        }, closeWindow: { surface in
            dismissWindow(id: "StreamingWindow", value: surface)
        }) {
            selectedConsoleID = console.id.uuidString
            connectingConsoleId = console.id
        }
    }
}

#Preview(windowStyle: .automatic) {
    NavigationStack {
        HomeView(navigationPath: .constant(NavigationPath()))
            .environmentObject(AppState())
    }
    .frame(width: 840, height: 660)
}
