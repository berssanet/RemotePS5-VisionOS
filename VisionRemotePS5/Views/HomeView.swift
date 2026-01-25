import SwiftUI

// MARK: - Simplified Home View (PSN Only)
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var authService = PSNAuthService()
    @StateObject private var sessionManager = PSNSessionManager.shared
    @StateObject private var holepunchService = HolepunchService.shared
    
    @State private var showLoginSheet = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isConnecting = false
    @State private var selectedDevice: PSNDevice?
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                headerSection
                
                // Main content based on auth state
                if !authService.isAuthenticated {
                    loginSection
                } else {
                    // Authenticated - show devices
                    authenticatedSection
                    
                    if sessionManager.isLoading {
                        loadingDevicesSection
                    } else if sessionManager.devices.isEmpty {
                        noDevicesSection
                    } else {
                        devicesSection
                    }
                }
                
                // Connection status
                if isConnecting {
                    connectionStatusSection
                }
            }
            .padding()
        }
        .navigationTitle("PS Remote Play")
        .sheet(isPresented: $showLoginSheet) {
            PSNLoginSheet(authService: authService)
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .task {
            if authService.isAuthenticated {
                await loadDevices()
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
    
    private var loginSection: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            
            Text("Sign in to PlayStation Network")
                .font(.title2)
                .bold()
            
            Text("Connect to your PlayStation consoles using your PSN account. No PIN required!")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button {
                showLoginSheet = true
            } label: {
                HStack {
                    Image(systemName: "person.fill")
                    Text("Sign in to PSN")
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(30)
        .glassBackgroundEffect()
    }
    
    private var authenticatedSection: some View {
        HStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Signed In")
                    .font(.headline)
                
                if let profile = authService.userProfile {
                    Text(profile.onlineId ?? "PSN User")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            Button {
                Task {
                    await authService.signOut()
                    sessionManager.devices = []
                }
            } label: {
                Text("Sign Out")
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.red)
        }
        .padding(20)
        .glassBackgroundEffect()
    }
    
    private var loadingDevicesSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Loading your consoles...")
                .font(.headline)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .glassBackgroundEffect()
    }
    
    private var noDevicesSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("No Consoles Found")
                .font(.headline)
            
            Text("Make sure your PlayStation console:\n• Is linked to your PSN account\n• Has Remote Play enabled\n• Is online or in rest mode")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                Task {
                    await loadDevices()
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
    
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Your Consoles")
                    .font(.title2)
                    .bold()
                
                Spacer()
                
                Button {
                    Task {
                        await loadDevices()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            
            ForEach(sessionManager.devices) { device in
                PSNDeviceCard(
                    device: device,
                    isConnecting: isConnecting && selectedDevice?.id == device.id,
                    onConnect: {
                        Task {
                            await connectToDevice(device)
                        }
                    }
                )
            }
        }
    }
    
    private var connectionStatusSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            
            Text(holepunchService.connectionStatus.rawValue)
                .font(.headline)
            
            Button("Cancel") {
                holepunchService.disconnect()
                isConnecting = false
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glassBackgroundEffect()
    }
    
    // MARK: - Actions
    
    private func loadDevices() async {
        do {
            _ = try await sessionManager.listDevices()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func connectToDevice(_ device: PSNDevice) async {
        selectedDevice = device
        isConnecting = true
        
        do {
            // Step 1: Create session
            let session = try await sessionManager.createSession(for: device)
            
            // Step 2: Send command to wake console
            try await sessionManager.sendRemotePlayCommand(to: device, session: session)
            
            // Step 3: Start session
            let startResponse = try await sessionManager.startSession(session, device: device)
            
            // Step 4: Establish holepunch connection
            let connection = try await holepunchService.connect(sessionInfo: startResponse)
            
            print("[Home] ✅ Connected to \(device.name ?? device.deviceId)")
            
            isConnecting = false
            
            // TODO: Start streaming with the connection
            
        } catch {
            isConnecting = false
            errorMessage = error.localizedDescription
            showError = true
            holepunchService.disconnect()
        }
    }
}

// MARK: - PSN Device Card

struct PSNDeviceCard: View {
    let device: PSNDevice
    let isConnecting: Bool
    let onConnect: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Device icon
            Image(systemName: deviceIcon)
                .font(.system(size: 40))
                .foregroundStyle(.blue)
                .frame(width: 60, height: 60)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
            // Device info
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name ?? "PlayStation")
                    .font(.headline)
                
                Text(device.deviceType ?? "Console")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Text(device.deviceId.prefix(20) + "...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Connect button
            if isConnecting {
                ProgressView()
            } else {
                Button {
                    onConnect()
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Connect")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .glassBackgroundEffect()
    }
    
    private var deviceIcon: String {
        switch device.deviceType?.lowercased() {
        case "ps5":
            return "gamecontroller.fill"
        case "ps4":
            return "gamecontroller"
        default:
            return "gamecontroller.fill"
        }
    }
}

// MARK: - Preview

#Preview(windowStyle: .automatic) {
    HomeView()
        .environmentObject(AppState())
}
