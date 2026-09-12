import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("enableHaptics") private var enableHaptics = true
    @AppStorage(StreamProfile.preferenceKey) private var streamProfile = StreamProfile.minimum.rawValue
    @State private var manualAccountId: String = UserDefaults.standard.string(forKey: "psn_account_id") ?? ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Source quality", selection: $streamProfile) {
                        ForEach(StreamProfile.allCases) { profile in
                            Text(profile.title).tag(profile.rawValue)
                        }
                    }
                    .disabled(appState.isInStreamingSession)
                    Text("60 fps in every profile")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Streaming")
                } footer: {
                    Text(appState.isInStreamingSession
                         ? "End the current session before changing source quality."
                         : "360p uses the least bandwidth. Higher profiles preserve more source detail. MetalFX is selected during playback.")
                }
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
                
                Section {
                    PerformanceReportExportButton()
                } header: {
                    Text("Performance")
                } footer: {
                    Text("Save a report of the current or most recent session.")
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
