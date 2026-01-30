import SwiftUI

/// Simplified test view for direct PS5 connection testing
/// Bypasses PSN login for easier debugging
struct SimpleTestView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    
    @State private var host: String = "192.168.100.33"
    @State private var accountId: String = "ttvb8y/FxGE="
    @State private var pin: String = ""
    @State private var isConnecting: Bool = false
    @State private var statusMessage: String = ""
    @State private var showError: Bool = false
    @State private var registeredConsole: Console?
    @State private var savedConsoles: [Console] = []
    
    private let registrationService = RegistrationService()
    
    var body: some View {
        VStack(spacing: 24) {
            // Title
            Text("PS5 Remote Play Test")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Direct connection for testing")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Spacer()
                .frame(height: 20)
            
            // Form fields
            VStack(spacing: 20) {
                // Host field
                HStack {
                    Text("Host:")
                        .frame(width: 150, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    TextField("PS5 IP Address", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }
                
                // Account ID field (base64)
                VStack(spacing: 4) {
                    HStack {
                        Text("PSN Account-ID:")
                            .frame(width: 150, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        TextField("Base64 encoded", text: $accountId)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                    }
                    HStack {
                        Text("")
                            .frame(width: 150)
                        Text("base64")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 250, alignment: .leading)
                    }
                }
                
                // PIN field
                HStack {
                    Text("Remote Play PIN:")
                        .frame(width: 150, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    TextField("8-digit PIN from PS5", text: $pin)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                        .keyboardType(.numberPad)
                }
            }
            
            Spacer()
                .frame(height: 30)
            
            // Action buttons
            HStack(spacing: 20) {
                // Connect/Register button
                Button(action: connect) {
                    HStack {
                        if isConnecting {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text(isConnecting ? "Connecting..." : "Register")
                            .fontWeight(.semibold)
                    }
                    .frame(width: 150, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting || pin.isEmpty)
                
                // Start Streaming button (only shown after registration)
                if let console = registeredConsole, console.rpKey != nil {
                    Button(action: { startStreamingSession(console: console) }) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Start Streaming")
                                .fontWeight(.semibold)
                        }
                        .frame(width: 180, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
            
            // Status message
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(showError ? .red : .green)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            
            // RP-Key display (if registered)
            if let console = registeredConsole, let rpKey = console.rpKey {
                VStack(spacing: 8) {
                    Text("Registration Successful!")
                        .font(.headline)
                        .foregroundStyle(.green)
                    
                    Text("RP-Key: \(rpKey.map { String(format: "%02x", $0) }.joined())")
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                    
                    if let nickname = console.nickname {
                        Text("Console: \(nickname)")
                            .font(.subheadline)
                    }
                }
                .padding()
                .background(.green.opacity(0.1))
                .cornerRadius(12)
            }
            
            // Unregister button (shown when there's a registered console)
            if registeredConsole != nil {
                VStack(spacing: 12) {
                    Divider()
                        .padding(.vertical, 8)
                    
                    Button(action: unregisterConsole) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Unregister Console")
                        }
                        .frame(width: 200, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                }
            }
            
            // Show saved consoles if any
            if !savedConsoles.isEmpty && registeredConsole == nil {
                VStack(spacing: 12) {
                    Text("Previously Registered Consoles")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    ForEach(savedConsoles) { console in
                        HStack {
                            Button {
                                registeredConsole = console
                                statusMessage = "Loaded saved console: \(console.nickname ?? console.name)"
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(console.nickname ?? console.name)
                                            .font(.headline)
                                        Text(console.ipAddress)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if console.psnAccountId != nil {
                                            Text("PSN ID: ✓")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        } else {
                                            Text("PSN ID: ✗ (needs re-register)")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer()
                                    if console.rpKey != nil {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding()
                                .background(.blue.opacity(0.1))
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                            
                            // Delete button for each console
                            Button {
                                deleteConsole(console)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 20)
            }
            
            Spacer()
        }
        .padding(40)
        .onAppear {
            Task {
                await loadSavedConsoles()
            }
        }
    }
    
    /// v10.5.2: Start streaming session and switch to streaming windows
    private func startStreamingSession(console: Console) {
        // Save selected console to app state
        appState.selectedConsole = console
        
        // Hide the console selection UI
        appState.isInStreamingSession = true
        
        // Open all streaming windows
        openWindow(id: "StreamingWindow", value: console)
        openWindow(id: "MenuBarWindow")
        openWindow(id: "ControllerWindow")
        
        print("[SimpleTestView] Started streaming session for: \(console.nickname ?? console.name)")
    }
    
    private func loadSavedConsoles() async {
        savedConsoles = await ConsoleStorageService.shared.getRegisteredConsoles()
        print("[SimpleTestView] Loaded \(savedConsoles.count) saved consoles")
        
        // If there's a saved console for the current host, load it
        if let savedConsole = savedConsoles.first(where: { $0.ipAddress == host }) {
            registeredConsole = savedConsole
            statusMessage = "Found registered console: \(savedConsole.nickname ?? savedConsole.name)"
        }
    }
    
    private func connect() {
        guard !pin.isEmpty else {
            statusMessage = "Please enter the PIN from PS5"
            showError = true
            return
        }
        
        guard pin.count == 8, Int(pin) != nil else {
            statusMessage = "PIN must be 8 digits"
            showError = true
            return
        }
        
        isConnecting = true
        statusMessage = "Connecting to \(host)..."
        showError = false
        
        Task { @MainActor in
            do {
                // Create a mock console object for testing
                var console = Console(
                    name: "PS5 Test",
                    ipAddress: host,
                    macAddress: "00:00:00:00:00:00",
                    type: .ps5,
                    status: .online,
                    isPaired: false
                )
                
                // Account ID should be passed as base64 (NOT converted to hex!)
                // ChiakiCrypto.formatRegistrationPayload expects base64 format
                let accountIdForRegistration = accountId.isEmpty ? nil : accountId
                
                print("[SimpleTest] Connecting to: \(host)")
                print("[SimpleTest] Account ID (base64): \(accountId)")
                print("[SimpleTest] PIN: \(pin)")
                
                // Call registration service
                let success = await registrationService.register(
                    with: console,
                    pin: pin,
                    accountId: accountIdForRegistration
                )
                
                isConnecting = false
                if success {
                    // Update console with registration data
                    if let hostInfo = registrationService.registeredHost {
                        console.rpKey = hostInfo.rpKey
                        console.registKey = hostInfo.registKey
                        console.serverMAC = hostInfo.serverMAC
                        console.nickname = hostInfo.nickname
                        console.isPaired = true
                    }
                    
                    // Save PSN Account ID (convert base64 to 8-byte Data)
                    if !accountId.isEmpty, let accountIdData = Data(base64Encoded: accountId) {
                        console.psnAccountId = accountIdData
                        print("[SimpleTest] Saved PSN Account ID: \(accountIdData.map { String(format: "%02x", $0) }.joined())")
                    } else {
                        print("[SimpleTest] ⚠️ Failed to save PSN Account ID")
                    }
                    
                    registeredConsole = console
                    
                    // Save to storage
                    await ConsoleStorageService.shared.saveRegisteredConsole(console)
                    await loadSavedConsoles()
                    
                    statusMessage = "✅ Successfully registered with PS5!"
                    showError = false
                } else {
                    statusMessage = "❌ Registration failed: \(registrationService.registrationError ?? "Unknown error")"
                    showError = true
                }
            } catch {
                isConnecting = false
                statusMessage = "❌ Error: \(error.localizedDescription)"
                showError = true
                print("[SimpleTest] Error: \(error)")
            }
        }
    }
    
    private func unregisterConsole() {
        guard let console = registeredConsole else { return }
        
        Task {
            // Remove from storage
            await ConsoleStorageService.shared.removeRegisteredConsole(console)
            
            // Clear current state
            registeredConsole = nil
            statusMessage = "Console unregistered. You can now register again."
            showError = false
            
            // Reload saved consoles
            await loadSavedConsoles()
        }
    }
    
    private func deleteConsole(_ console: Console) {
        Task {
            // Remove from storage
            await ConsoleStorageService.shared.removeRegisteredConsole(console)
            
            // Reload saved consoles
            await loadSavedConsoles()
            
            statusMessage = "Console '\(console.nickname ?? console.name)' deleted."
        }
    }
}

#Preview(windowStyle: .automatic) {
    SimpleTestView()
}
