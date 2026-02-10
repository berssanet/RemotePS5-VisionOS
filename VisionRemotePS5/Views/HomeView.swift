import SwiftUI

// MARK: - Home View (Registered Console First)
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    
    @State private var registeredConsoles: [Console] = []
    @State private var isLoading = true
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var connectingConsoleId: UUID?
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                headerSection
                
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
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .task {
            await loadRegisteredConsoles()
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
            
            Text("Register a PlayStation console first to start streaming.\n\n• Make sure your PS5 has Remote Play enabled\n• Use the registration flow to pair your console")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                Task {
                    await loadRegisteredConsoles()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
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
                    Task {
                        await loadRegisteredConsoles()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            
            ForEach(registeredConsoles) { console in
                RegisteredConsoleCard(
                    console: console,
                    isConnecting: connectingConsoleId == console.id,
                    onStartSession: {
                        startSession(console: console)
                    }
                )
            }
        }
    }
    
    // MARK: - Actions
    
    private func loadRegisteredConsoles() async {
        isLoading = true
        registeredConsoles = await ConsoleStorageService.shared.getRegisteredConsoles()
        isLoading = false
    }
    
    private func startSession(console: Console) {
        connectingConsoleId = console.id
        appState.selectedConsole = console
        appState.isInStreamingSession = true
        
        // Open the 3 streaming windows
        openWindow(id: "StreamingWindow", value: console)
        openWindow(id: "MenuBarWindow")
        openWindow(id: "ControllerWindow")
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
    HomeView()
        .environmentObject(AppState())
}
