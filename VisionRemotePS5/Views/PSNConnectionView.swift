import SwiftUI

/// View for connecting to PlayStation via PSN (without PIN)
struct PSNConnectionView: View {
    @StateObject private var sessionManager = PSNSessionManager.shared
    @StateObject private var holepunchService = HolepunchService.shared
    @StateObject private var authService = PSNAuthService()
    
    @State private var selectedDevice: PSNDevice?
    @State private var showLoginSheet = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isConnecting = false
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Header
                headerSection
                
                if !authService.isAuthenticated {
                    // Not logged in
                    loginSection
                } else if sessionManager.isLoading {
                    // Loading devices
                    loadingSection
                } else if sessionManager.devices.isEmpty {
                    // No devices found
                    noDevicesSection
                } else {
                    // Device list
                    deviceListSection
                }
                
                Spacer()
                
                // Connection status
                if isConnecting {
                    connectionStatusSection
                }
            }
            .padding()
            .navigationTitle("Connect via PSN")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                if authService.isAuthenticated {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Sign Out") {
                            Task {
                                await authService.signOut()
                            }
                        }
                    }
                }
            }
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
    }
    
    // MARK: - Sections
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi")
                .font(.system(size: 50))
                .foregroundStyle(.blue)
            
            Text("Remote Connection via PSN")
                .font(.title2)
                .bold()
            
            Text("Connect to your PlayStation without entering a PIN")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }
    
    private var loginSection: some View {
        VStack(spacing: 16) {
            Text("Sign in with your PlayStation Network account to see your registered consoles.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                showLoginSheet = true
            } label: {
                HStack {
                    Image(systemName: "person.fill")
                    Text("Sign in to PSN")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
    
    private var loadingSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Loading devices...")
                .font(.headline)
        }
        .padding()
    }
    
    private var noDevicesSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            
            Text("No PlayStation consoles found")
                .font(.headline)
            
            Text("Make sure your console is registered with your PSN account and has Remote Play enabled.")
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
        .padding()
    }
    
    private var deviceListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Consoles")
                .font(.headline)
            
            ForEach(sessionManager.devices) { device in
                DeviceRow(device: device, isSelected: selectedDevice?.id == device.id) {
                    selectedDevice = device
                    Task {
                        await connectToDevice(device)
                    }
                }
            }
            
            Button {
                Task {
                    await loadDevices()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
        }
    }
    
    private var connectionStatusSection: some View {
        VStack(spacing: 12) {
            ProgressView()
            
            Text(holepunchService.connectionStatus.rawValue)
                .font(.headline)
            
            Button("Cancel") {
                holepunchService.disconnect()
                isConnecting = false
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
        isConnecting = true
        
        do {
            // Step 1: Create session
            let session = try await sessionManager.createSession(for: device)
            
            // Step 2: Start session
            let startResponse = try await sessionManager.startSession(session, device: device)
            
            // Step 3: Establish holepunch connection
            _ = try await holepunchService.connect(sessionInfo: startResponse)
            
            // Step 4: Connection successful!
            DebugLog.print("[PSNConnection] ✅ Connected to \(device.name ?? "PlayStation")")
            
            isConnecting = false
            dismiss()
            
            // TODO: Start streaming session with the established connection
            
        } catch {
            isConnecting = false
            errorMessage = error.localizedDescription
            showError = true
            
            // Cleanup
            holepunchService.disconnect()
        }
    }
}

// MARK: - Device Row

struct DeviceRow: View {
    let device: PSNDevice
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: deviceIcon)
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 40)
                
                VStack(alignment: .leading) {
                    Text(device.name ?? "PlayStation")
                        .font(.headline)
                    
                    Text(device.deviceType ?? "Unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if device.remotePlayEnabled == true {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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

// MARK: - PSN Login Sheet

struct PSNLoginSheet: View {
    @ObservedObject var authService: PSNAuthService
    @State private var authCode = ""
    @State private var isLoading = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Sign in to PlayStation Network")
                    .font(.title2)
                    .bold()
                
                Text("1. Tap the button below to open the PSN login page\n2. Sign in with your account\n3. Copy the redirect URL and paste it below")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                if let loginURL = URL(string: PSNAuthConstants.loginURL) {
                    Link(destination: loginURL) {
                        HStack {
                            Image(systemName: "globe")
                            Text("Open PSN Login")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                
                TextField("Paste redirect URL here", text: $authCode)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                
                Button {
                    Task {
                        await authenticate()
                    }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Sign In")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(authCode.isEmpty || isLoading)
                
                Spacer()
            }
            .padding()
            .navigationTitle("PSN Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func authenticate() async {
        isLoading = true
        
        // Extract code from URL if user pasted full URL
        var code = authCode
        if let url = URL(string: authCode),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let codeParam = components.queryItems?.first(where: { $0.name == "code" })?.value {
            code = codeParam
        }
        
        do {
            try await authService.exchangeCodeForToken(code)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        
        isLoading = false
    }
}

// MARK: - Preview

#Preview {
    PSNConnectionView()
}
