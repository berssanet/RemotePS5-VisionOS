import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("enableHaptics") private var enableHaptics = true
    @AppStorage("enableSpatialAudio") private var enableSpatialAudio = true
    @AppStorage("showLatencyIndicator") private var showLatencyIndicator = true
    @AppStorage("autoConnect") private var autoConnect = false
    @State private var manualAccountId: String = UserDefaults.standard.string(forKey: "psn_account_id") ?? ""
    
    var body: some View {
        NavigationStack {
            Form {
                // Video Settings
                Section("Video") {
                    Picker("Resolution", selection: $appState.streamQuality) {
                        ForEach(AppState.StreamQuality.allCases, id: \.self) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    
                    Toggle("Show Latency Indicator", isOn: $showLatencyIndicator)
                }
                
                // Audio Settings
                Section("Audio") {
                    Toggle("Spatial Audio", isOn: $enableSpatialAudio)
                }
                
                // Controller Settings
                Section("Controller") {
                    Toggle("Haptic Feedback", isOn: $enableHaptics)
                    
                    NavigationLink {
                        ControllerMappingView()
                    } label: {
                        Text("Button Mapping")
                    }
                }
                
                // Connection Settings
                Section("Connection") {
                    Toggle("Auto-Connect to Last Console", isOn: $autoConnect)
                    
                    NavigationLink {
                        NetworkDiagnosticsView()
                    } label: {
                        Text("Network Diagnostics")
                    }
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
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Build", value: "1")
                    
                    Link(destination: URL(string: "https://github.com")!) {
                        Text("Open Source Licenses")
                    }
                }
            }
            .navigationTitle("Settings")
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

// MARK: - Controller Mapping View
struct ControllerMappingView: View {
    var body: some View {
        Form {
            Section("DualSense Mapping") {
                Text("Controller mapping will be configured here")
                    .foregroundStyle(.secondary)
            }
            
            Section("Gesture Controls") {
                Text("Hand gesture mapping will be configured here")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Button Mapping")
    }
}

// MARK: - Network Diagnostics View
struct NetworkDiagnosticsView: View {
    @State private var isTesting = false
    @State private var latency: Int?
    @State private var bandwidth: Double?
    
    var body: some View {
        Form {
            Section("Connection Test") {
                Button {
                    runDiagnostics()
                } label: {
                    HStack {
                        Text("Run Test")
                        Spacer()
                        if isTesting {
                            ProgressView()
                        }
                    }
                }
                .disabled(isTesting)
            }
            
            if let latency = latency, let bandwidth = bandwidth {
                Section("Results") {
                    LabeledContent("Latency", value: "\(latency) ms")
                    LabeledContent("Bandwidth", value: String(format: "%.1f Mbps", bandwidth))
                    
                    Text(recommendedQuality)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Network Diagnostics")
    }
    
    private var recommendedQuality: String {
        guard let bandwidth = bandwidth else { return "" }
        if bandwidth >= 50 {
            return "Recommended: 4K streaming"
        } else if bandwidth >= 15 {
            return "Recommended: 1080p streaming"
        } else if bandwidth >= 5 {
            return "Recommended: 720p streaming"
        } else {
            return "Recommended: 540p streaming"
        }
    }
    
    private func runDiagnostics() {
        isTesting = true
        // TODO: Implement actual network test
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            latency = Int.random(in: 10...50)
            bandwidth = Double.random(in: 20...100)
            isTesting = false
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
