import SwiftUI

struct PairingView: View {
    @EnvironmentObject var appState: AppState
    @Binding var navigationPath: NavigationPath
    @StateObject private var registrationService = RegistrationService()
    @State private var pinCode: String = ""
    @State private var ipAddress: String = ""
    @State private var selectedConsole: Console?
    @StateObject private var discovery = ConsoleDiscoveryService()
    /// Base64 PSN Account ID. Prefilled from the value saved in Settings; saved back on pairing.
    @State private var accountId: String = UserDefaults.standard.string(forKey: "psn_account_id") ?? ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?
    
    enum Field {
        case ip
        case pin
    }
    
    /// PSN sign-in only resolves the Account ID here. The remote "Connect via PSN" (holepunch)
    /// flow is not finished (PSNConnectionView TODO) and trips PSN's 403 retry-interval throttle,
    /// so it is not offered from this screen.
    @State private var showPSNLogin = false

    init(navigationPath: Binding<NavigationPath>, console: Console? = nil) {
        _navigationPath = navigationPath
        _ipAddress = State(initialValue: console?.ipAddress ?? "")
        _selectedConsole = State(initialValue: console)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Instructions Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Local pairing — once for this app")
                        .font(.title3.bold())
                    Text("A PSN login does not transfer the official app's registration. The PIN below creates this app's own keys for direct local connections.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("To pair your console:")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        InstructionRow(number: 1, text: "Go to Settings on your PS5")
                        InstructionRow(number: 2, text: "Select System > Remote Play")
                        InstructionRow(number: 3, text: "Select 'Link Device'")
                        InstructionRow(number: 4, text: "Enter the PIN code below")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassBackgroundEffect()
                
                // Consoles found on the local network (like the official app).
                discoverySection

                // Console Address Section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Console Address")
                            .font(.headline)
                        Spacer()
                        Button {
                            // The typed IP is probed directly too (works without broadcast).
                            discovery.startDiscovery(unicastTargets: [ipAddress.trimmingCharacters(in: .whitespaces)])
                        } label: {
                            Label("Search", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .disabled(discovery.isSearching)
                    }
                    
                    TextField("IP Address (e.g., 192.168.1.100)", text: $ipAddress)
                        .keyboardType(.default)
                        .textContentType(.none)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .ip)
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(10)
                }
                .padding()
                .glassBackgroundEffect()
                
                // PSN Account ID Section (the PS5 requires it in the registration payload)
                VStack(alignment: .leading, spacing: 8) {
                    Text("PSN Account ID")
                        .font(.headline)
                    
                    TextField("Base64 Account ID", text: $accountId)
                        .keyboardType(.default)
                        .textContentType(.none)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(10)
                    
                    Button {
                        showPSNLogin = true
                    } label: {
                        HStack {
                            Image(systemName: "person.fill")
                            Text(appState.psnAuthService.isAuthenticated ? "Refresh from PSN" : "Sign in to PSN")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                    .buttonStyle(.bordered)
                    
                    Text("Required by the PS5. Sign in to fill it automatically, or paste it from flipscreen.games/psn.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .glassBackgroundEffect()
                
                // PIN Code Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("PIN Code")
                        .font(.headline)
                    
                    TextField("8-digit PIN", text: $pinCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focusedField, equals: .pin)
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(10)
                        .onChange(of: pinCode) { _, newValue in
                            let filtered = newValue.filter { $0.isNumber }
                            if filtered.count > 8 {
                                pinCode = String(filtered.prefix(8))
                            } else {
                                pinCode = filtered
                            }
                        }
                    
                    if !pinCode.isEmpty {
                        Text("PIN: \(formattedPin)")
                            .font(.title2)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.blue)
                            .padding(.top, 4)
                    }
                }
                .padding()
                .glassBackgroundEffect()
                
                // Error Message
                if let error = errorMessage ?? registrationService.registrationError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(error)
                            .foregroundStyle(.red)
                    }
                    .padding()
                    .glassBackgroundEffect()
                }
                
                // Pair Button
                Button {
                    pairConsole()
                } label: {
                    HStack {
                        if registrationService.isRegistering {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Text(registrationService.isRegistering ? "Pairing..." : "Pair Console")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidInput || registrationService.isRegistering)
                .padding(.horizontal)
            }
            .padding()
        }
        .navigationTitle("Add Console")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    goHome()
                } label: {
                    Label("Home", systemImage: "house.fill")
                }
            }
        }
        .sheet(isPresented: $showPSNLogin) {
            PSNLoginSheet(authService: appState.psnAuthService)
        }
        .onAppear {
            fillAccountIdFromProfile()
            if discovery.discoveredConsoles.isEmpty {
                discovery.startDiscovery(unicastTargets: ipAddress.isEmpty ? [] : [ipAddress])
            }
        }
        .onDisappear { discovery.stopDiscovery() }
        .onChange(of: showPSNLogin) { _, presented in
            // exchangeCodeForToken awaits the account-info fetch before the sheet dismisses.
            if !presented {
                fillAccountIdFromProfile()
            }
        }
    }
    
    private func fillAccountIdFromProfile() {
        guard let resolved = appState.psnAuthService.userProfile?.accountId,
              !resolved.isEmpty else { return }
        accountId = resolved
    }

    /// v14.0: list PS5/PS4 consoles discovered on the LAN via DDP broadcast. Tapping one
    /// fills the IP so the user never types it — matching the official Remote Play app.
    @ViewBuilder
    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wifi")
                Text("Consoles on this network")
                    .font(.headline)
                Spacer()
                if discovery.isSearching {
                    ProgressView()
                }
            }

            if discovery.discoveredConsoles.isEmpty {
                Text(discovery.isSearching
                     ? "Searching…"
                     : (discovery.statusMessage.isEmpty
                        ? "None found yet. Make sure the PS5 is on (or in rest mode) with Remote Play enabled, then tap Search."
                        : discovery.statusMessage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(discovery.discoveredConsoles) { console in
                    Button {
                        selectDiscovered(console)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "gamecontroller.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(console.name).font(.subheadline).bold()
                                Text("\(console.ipAddress) • \(console.type.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if ipAddress == console.ipAddress {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(ipAddress == console.ipAddress ? 0.12 : 0.05))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassBackgroundEffect()
    }

    private func selectDiscovered(_ console: Console) {
        selectedConsole = console
        ipAddress = console.ipAddress
        errorMessage = nil
    }

    private func goHome() {
        navigationPath = NavigationPath()
    }
    
    private var formattedPin: String {
        let pin = pinCode.padding(toLength: 8, withPad: "•", startingAt: 0)
        return "\(pin.prefix(4)) \(pin.suffix(4))"
    }
    
    private var isValidInput: Bool {
        pinCode.utf8.count == 8 && pinCode.utf8.allSatisfy { (48...57).contains($0) } && isValidIPAddress(ipAddress)
    }
    
    private func isValidIPAddress(_ ip: String) -> Bool {
        LocalConsoleConnectionService.normalizedAddress(ip) != nil
    }
    
    private func pairConsole() {
        errorMessage = nil
        
        guard let host = LocalConsoleConnectionService.normalizedAddress(ipAddress) else {
            errorMessage = LocalConsoleConnectionError.invalidAddress.localizedDescription
            return
        }
        let console = selectedConsole.flatMap { $0.ipAddress == host ? $0 : nil } ?? Console(
            name: "PlayStation 5",
            ipAddress: host,
            type: .ps5,
            status: .online,
            isPaired: false
        )
        
        // Account ID precedence: the field on this screen, then the PSN sign-in profile.
        let typedAccountId = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedAccountId: String? = typedAccountId.isEmpty ? nil : typedAccountId
        if resolvedAccountId == nil,
           let profileAccountId = appState.psnAuthService.userProfile?.accountId,
           !profileAccountId.isEmpty {
            resolvedAccountId = profileAccountId
            DebugLog.print("[PairingView] Using PSN Account ID from the signed-in profile")
        }
        guard let candidate = resolvedAccountId, Data(base64Encoded: candidate)?.count == 8 else {
            errorMessage = "Sign in to PSN or enter a Base64 Account ID containing exactly 8 bytes."
            return
        }
        UserDefaults.standard.set(candidate, forKey: "psn_account_id")
        registrationService.clearRPKey(for: console)
        
        Task {
            let success = await registrationService.register(with: console, pin: pinCode, accountId: resolvedAccountId)
            
            await MainActor.run {
                if success {
                    UserDefaults.standard.set(console.ipAddress, forKey: "local_console_address")
                    // Update console to paired status
                    var pairedConsole = console
                    pairedConsole.isPaired = true
                    
                    // Add to app state
                    appState.discoveredConsoles.append(pairedConsole)
                    goHome()
                }
            }
        }
    }
}

// MARK: - Instruction Row
struct InstructionRow: View {
    let number: Int
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "\(number).circle")
                .foregroundStyle(.blue)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        PairingView(navigationPath: .constant(NavigationPath()))
            .environmentObject(AppState())
    }
}
