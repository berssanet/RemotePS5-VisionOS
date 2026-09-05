import SwiftUI

struct LocalConsoleConnectionView: View {
    @ObservedObject var auth: PSNAuthService
    let registeredConsoles: [Console]
    @Binding var isPreparingConnection: Bool
    let onStreaming: (Console) -> Void
    let onPairing: (Console) -> Void

    @AppStorage("local_console_address") private var address = ""
    @StateObject private var connection = LocalConsoleConnectionService()
    @State private var connectionTask: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Local Network", systemImage: "wifi")
                .font(.title2.bold())
            Text("On the same network as your PS5? Connect directly here, without creating a PSN session.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Console IP address", text: $address)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(isPreparingConnection)
                .accessibilityLabel("Local console IPv4 address")
            Button(action: connect) {
                if connection.isChecking {
                    HStack {
                        ProgressView()
                        Text("Checking the console on your LAN…")
                    }
                } else {
                    Label("Connect locally", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPreparingConnection || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("First connection in this app: enter the PS5's Link Device PIN once. Existing registration keys are reused on later connections. Signing in to PSN fills the Account ID; it does not import the official app's pairing keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassBackgroundEffect()
        .onAppear(perform: fillSavedAddress)
        .onChange(of: registeredConsoles) { _, _ in fillSavedAddress() }
        .onDisappear { connectionTask?.cancel() }
    }

    private func fillSavedAddress() {
        if address.isEmpty, registeredConsoles.count == 1 {
            address = registeredConsoles[0].ipAddress
        }
    }

    private func connect() {
        guard !isPreparingConnection else { return }
        errorMessage = nil
        let accountID = auth.userProfile.flatMap { Data(base64Encoded: $0.accountId) }
        guard !auth.isAuthenticated || accountID?.count == 8 else {
            errorMessage = LocalConsoleConnectionError.invalidAccount.localizedDescription
            return
        }
        isPreparingConnection = true
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        connectionTask = Task {
            defer {
                isPreparingConnection = false
                connectionTask = nil
            }
            do {
                let route = try await connection.connect(to: host, accountID: accountID)
                switch route {
                case .streaming(let console):
                    address = console.ipAddress
                    onStreaming(console)
                case .pairing(let console):
                    address = console.ipAddress
                    onPairing(console)
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
