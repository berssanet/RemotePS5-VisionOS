import SwiftUI

struct PairingView: View {
    @EnvironmentObject var appState: AppState
    @Binding var navigationPath: NavigationPath
    @StateObject private var registrationService = RegistrationService()
    @State private var pinCode: String = ""
    @State private var ipAddress: String = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?
    
    enum Field {
        case ip
        case pin
    }
    
    @State private var showPSNConnection = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Instructions Section
                VStack(alignment: .leading, spacing: 12) {
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
                
                // PSN Connection Alternative
                VStack(spacing: 12) {
                    Text("— OR —")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Button {
                        showPSNConnection = true
                    } label: {
                        HStack {
                            Image(systemName: "wifi")
                            Text("Connect via PSN")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                    .buttonStyle(.bordered)
                    
                    Text("Connect without PIN using your PSN account")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .glassBackgroundEffect()
                
                // Console Address Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Console Address")
                        .font(.headline)
                    
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
        .sheet(isPresented: $showPSNConnection) {
            PSNConnectionView()
        }
    }
    
    private func goHome() {
        navigationPath = NavigationPath()
    }
    
    private var formattedPin: String {
        let pin = pinCode.padding(toLength: 8, withPad: "•", startingAt: 0)
        return "\(pin.prefix(4)) \(pin.suffix(4))"
    }
    
    private var isValidInput: Bool {
        pinCode.count == 8 && isValidIPAddress(ipAddress)
    }
    
    private func isValidIPAddress(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let num = Int(part) else { return false }
            return num >= 0 && num <= 255
        }
    }
    
    private func pairConsole() {
        errorMessage = nil
        
        // Create console object
        let console = Console(
            name: "PlayStation 5",
            ipAddress: ipAddress,
            type: .ps5,
            status: .online,
            isPaired: false
        )
        
        // Clear any old RP-Key to force fresh registration
        registrationService.clearRPKey(for: console)
        
        // Get account ID from PSN auth service, or fallback to UserDefaults (set during login)
        var accountId = appState.psnAuthService.userProfile?.accountId
        
        // Fallback: check UserDefaults (where we store it from NPSSO cookie)
        if accountId == nil || accountId?.isEmpty == true {
            accountId = UserDefaults.standard.string(forKey: "psn_account_id")
            print("[PairingView] Using stored PSN Account ID from UserDefaults")
        }
        
        print("[PairingView] Final PSN Account ID: \(accountId ?? "nil")")
        
        Task {
            let success = await registrationService.register(with: console, pin: pinCode, accountId: accountId)
            
            await MainActor.run {
                if success {
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
