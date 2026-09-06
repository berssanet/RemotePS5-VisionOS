import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("enableHaptics") private var enableHaptics = true
    @State private var manualAccountId: String = UserDefaults.standard.string(forKey: "psn_account_id") ?? ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Controller") {
                    Toggle("Haptic Feedback", isOn: $enableHaptics)
                }

                // Account Section - Always show Account ID field
                Section(header: Text("PSN Account"), footer: Text("Get your Account ID from flipscreen.games/psn - Enter your PSN username there.")) {
                    // Manual Account ID entry - ALWAYS visible
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Account ID (Base64)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Paste your Account ID here", text: $manualAccountId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit {
                                saveAccountId()
                            }
                    }
                    
                    // Save button for explicit save
                    Button("Save Account ID") {
                        saveAccountId()
                    }
                    .disabled(manualAccountId.isEmpty)
                    
                    if !manualAccountId.isEmpty {
                        Text("✅ Account ID saved")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    
                    if appState.isAuthenticated {
                        Button(role: .destructive) {
                            signOut()
                        } label: {
                            Text("Sign Out")
                        }
                    } else {
                        Text("Not signed in to PSN (optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // About Section
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                    LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown")
                    
                    Link(destination: URL(string: "https://github.com/berssanet/RemotePS5-VisionOS")!) {
                        Text("Project Repository")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func saveAccountId() {
        if !manualAccountId.isEmpty {
            UserDefaults.standard.set(manualAccountId, forKey: "psn_account_id")
            DebugLog.print("[Settings] ✅ Saved Account ID: \(manualAccountId)")
        }
    }
    
    private func signOut() {
        Task {
            await appState.psnAuthService.signOut()
            appState.isAuthenticated = false
            appState.discoveredConsoles = []
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
