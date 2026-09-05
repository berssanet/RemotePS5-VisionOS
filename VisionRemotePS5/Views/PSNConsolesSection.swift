import SwiftUI

struct PSNConsolesSection: View {
    @ObservedObject var auth: PSNAuthService
    @Binding var isPreparingConnection: Bool
    let onConnect: (Console) -> Void

    @StateObject private var sessionManager = PSNSessionManager.shared
    @StateObject private var coordinator = PSNRemotePlayCoordinator()
    @State private var showLogin = false
    @State private var errorMessage: String?
    @State private var connectingDeviceId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("PlayStation Network")
                    .font(.title2)
                    .bold()
                Spacer()
                if auth.isAuthenticated {
                    Button {
                        Task { await loadDevices() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Refresh PSN consoles")
                    .disabled(sessionManager.isLoading || isPreparingConnection)
                }
            }

            if !auth.isAuthenticated {
                signInRow
            } else if sessionManager.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading your consoles…")
                        .foregroundStyle(.secondary)
                }
            } else if sessionManager.devices.isEmpty {
                Text("No console linked to this PSN account. Make sure Remote Play is enabled on the PS5, then refresh.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessionManager.devices) { device in
                    deviceRow(device)
                }
                Text("On the same network? Use Local Network above. Connect via PSN uses a separate remote session, without a local PIN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The PS5 accepts one Remote Play client at a time: quit the official Remote Play app before connecting here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if coordinator.isBusy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(coordinator.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassBackgroundEffect()
        .sheet(isPresented: $showLogin) {
            PSNLoginSheet(authService: auth)
        }
        .task(id: auth.isAuthenticated) {
            if auth.isAuthenticated {
                await loadDevices()
            }
        }
    }

    private var signInRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in to fill your Account ID for local pairing and list consoles on PSN. Local streaming uses this app's own registration keys.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                showLogin = true
            } label: {
                Label("Sign in to PSN", systemImage: "person.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPreparingConnection)
        }
    }

    private func deviceRow(_ device: PSNDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name ?? "PlayStation")
                    .font(.headline)
                Text(device.deviceType ?? "PS5")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if device.isRemotePlayReportedDisabled {
                    Label("Remote Play is off on this console (per PSN). Enable it in the PS5 settings, then Refresh.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if connectingDeviceId == device.id {
                ProgressView()
            } else {
                Button {
                    connect(device)
                } label: {
                    Label("Connect via PSN", systemImage: "network")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPreparingConnection || device.isRemotePlayReportedDisabled)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private func loadDevices() async {
        errorMessage = nil
        sessionManager.authService = auth
        do {
            _ = try await sessionManager.listDevices()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func connect(_ device: PSNDevice) {
        guard !isPreparingConnection else { return }
        isPreparingConnection = true
        errorMessage = nil
        connectingDeviceId = device.id
        Task {
            defer {
                connectingDeviceId = nil
                isPreparingConnection = false
            }
            do {
                let console = try await coordinator.prepareStreamingConsole(device: device, auth: auth)
                onConnect(console)
            } catch {
                errorMessage = error.localizedDescription
                DebugLog.print("[PSNConsolesSection] ❌ \(error.localizedDescription)")
            }
        }
    }
}
