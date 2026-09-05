import Foundation

enum PSNConnectionStage: String, CaseIterable {
    case creatingSession = "psn-creating-session"
    case preparingNetwork = "psn-preparing-network"
    case sendingCommand = "psn-sending-command"
    case awaitingConsole = "psn-awaiting-console"
    case punchingControl = "psn-punching-control"
    case registering = "psn-registering"

    var message: String {
        switch self {
        case .creatingSession: return "Creating the PlayStation Network session…"
        case .preparingNetwork: return "Preparing the network connection (STUN/IPv4)…"
        case .sendingCommand: return "Sending the Remote Play command to PSN…"
        case .awaitingConsole: return "PSN accepted the request. Waiting for the console to join…"
        case .punchingControl: return "The console joined. Establishing the control connection…"
        case .registering: return "Registering with the console…"
        }
    }
}

/// Drives the official Remote Play app flow through the chiaki-ng holepunch code shipped
/// in libchiaki_full.a: PSN token -> PSN session (wakes the console) -> RUDP registration
/// with the PSN-provided secret (no PIN, no IP) -> persisted `Console`.
@MainActor
final class PSNRemotePlayCoordinator: ObservableObject {
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var statusMessage: String = ""

    enum CoordinatorError: LocalizedError {
        case sessionBusy
        case invalidDeviceId
        case missingAccountId
        case registrationFailed(String)
        case noConsoleAddress
        case timeout(stage: String)
        case remotePlayDisabled

        var errorDescription: String? {
            switch self {
            case .sessionBusy: return "A session is already running"
            case .invalidDeviceId: return "PSN returned an invalid console id"
            case .missingAccountId: return "PSN Account ID not available yet. Sign in again."
            case .registrationFailed(let reason): return "PSN registration failed: \(reason). If the official Remote Play app is connected to this PS5, quit it first (one client at a time) and retry."
            case .noConsoleAddress: return "PSN registration succeeded but no console address was selected"
            case .timeout(let stage): return "PSN connection setup exceeded 120 seconds. Last stage: \(stage). This timeout alone does not mean Remote Play is disabled or another client is connected."
            case .remotePlayDisabled: return "PSN reports Remote Play is not enabled on this console, so it will ignore the connection request. On the PS5 go to Settings > System > Remote Play and turn on Enable Remote Play, then tap Refresh."
            }
        }
    }

    private static let registrationTimeoutNs: UInt64 = 120_000_000_000

    func prepareStreamingConsole(device: PSNDevice, auth: PSNAuthService) async throws -> Console {
        guard !isBusy, !ChiakiFullSession.shared.isActive, !chiaki_fullsession_is_active_wrapper() else {
            throw CoordinatorError.sessionBusy
        }
        isBusy = true
        defer { isBusy = false }
        guard let duid = Self.hexToData(device.deviceId), duid.count == 32 else {
            throw CoordinatorError.invalidDeviceId
        }
        guard !device.isRemotePlayReportedDisabled else {
            throw CoordinatorError.remotePlayDisabled
        }
        statusMessage = "Checking your PSN account…"
        _ = try await auth.getAccessToken()
        if Self.resolveAccountId(auth: auth) == nil {
            try await auth.reloadProfile()
        }
        guard let accountId = Self.resolveAccountId(auth: auth) else {
            throw CoordinatorError.missingAccountId
        }
        try Task.checkCancellation()
        let isPS5 = (device.deviceType ?? "PS5").uppercased().contains("PS5")
        return Console(
            name: device.name ?? (isPS5 ? "PlayStation 5" : "PlayStation 4"),
            ipAddress: "",
            type: isPS5 ? .ps5 : .ps4,
            psnAccountId: accountId,
            psnDeviceID: duid
        )
    }

    /// Registers `device` through PSN and stores it like a PIN-registered console.
    func registerViaPSN(device: PSNDevice, auth: PSNAuthService) async throws -> Console {
        guard !isBusy, !ChiakiFullSession.shared.isActive, !chiaki_fullsession_is_active_wrapper() else {
            throw CoordinatorError.sessionBusy
        }
        isBusy = true
        defer { isBusy = false }

        statusMessage = "Contacting PlayStation Network…"
        let token = try await auth.getAccessToken()
        guard let duid = Self.hexToData(device.deviceId), duid.count == 32 else {
            throw CoordinatorError.invalidDeviceId
        }
        // When PSN explicitly reports Remote Play as disabled, the PS5 ignores the
        // remotePlay command and the session start times out after 30 s. Fail fast instead.
        guard !device.isRemotePlayReportedDisabled else {
            throw CoordinatorError.remotePlayDisabled
        }
        var resolvedAccountId = Self.resolveAccountId(auth: auth)
        if resolvedAccountId == nil {
            statusMessage = "Resolving your PSN Account ID…"
            try await auth.reloadProfile()
            resolvedAccountId = Self.resolveAccountId(auth: auth)
        }
        guard let accountId = resolvedAccountId else {
            throw CoordinatorError.missingAccountId
        }
        let isPS5 = (device.deviceType ?? "PS5").uppercased().contains("PS5")
        let displayName = device.name ?? (isPS5 ? "PlayStation 5" : "PlayStation 4")
        statusMessage = "Waking \(displayName) and registering via PSN…"

        var host: ChiakiFullSession.PSNRegisteredHost
        do {
            host = try await runAutoRegistration(token: token, duid: duid, isPS5: isPS5, accountId: accountId)
        } catch PSNStartError.consoleDidNotJoin {
            statusMessage = "\(displayName) did not answer yet. Waiting 20 s and trying again…"
            DebugLog.print("[PSNCoordinator] Console did not join; retrying once after 20 s")
            try await Task.sleep(nanoseconds: 20_000_000_000)
            statusMessage = "Registering \(displayName) via PSN (second attempt)…"
            let retryToken = try await auth.getAccessToken()
            host = try await runAutoRegistration(token: retryToken, duid: duid, isPS5: isPS5, accountId: accountId)
        }
        guard !host.consoleIP.isEmpty else {
            throw CoordinatorError.noConsoleAddress
        }

        let nickname = host.nickname.isEmpty ? displayName : host.nickname
        let console = Console(
            name: nickname,
            ipAddress: host.consoleIP,
            macAddress: host.serverMAC.map { String(format: "%02x", $0) }.joined(separator: ":"),
            type: isPS5 ? .ps5 : .ps4,
            status: .online,
            isPaired: true,
            lastConnected: Date(),
            rpKey: host.rpKey,
            registKey: host.registKey,
            serverMAC: host.serverMAC,
            nickname: nickname,
            psnAccountId: accountId
        )
        await ConsoleStorageService.shared.saveRegisteredConsole(console)
        statusMessage = "Registered \(nickname) at \(host.consoleIP)"
        DebugLog.print("[PSNCoordinator] ✅ Registered \(nickname) via PSN at \(host.consoleIP)")
        return console
    }

    // MARK: - Private

    /// Runs the blocking PSN start on a background thread and waits for `.regist` / `.quit`.
    private func runAutoRegistration(
        token: String, duid: Data, isPS5: Bool, accountId: Data
    ) async throws -> ChiakiFullSession.PSNRegisteredHost {
        let session = ChiakiFullSession.shared
        let gate = ContinuationGate()
        // The blocking start (websocket + notifications + holepunch) runs here; it must
        // finish (or be cancelled) before the library session is torn down.
        var startTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        defer {
            session.onEvent = nil
            timeoutTask?.cancel()
        }
        do {
            let host: ChiakiFullSession.PSNRegisteredHost = try await withCheckedThrowingContinuation { continuation in
                session.onEvent = { [weak self] event, reason in
                    switch event {
                    case .regist:
                        guard gate.tryResume() else { return }
                        if let registered = session.copyRegisteredHost() {
                            continuation.resume(returning: registered)
                        } else {
                            continuation.resume(throwing: CoordinatorError.registrationFailed("no host data"))
                        }
                    case .quit:
                        guard gate.tryResume() else { return }
                        continuation.resume(throwing: CoordinatorError.registrationFailed(reason ?? "session quit"))
                    case .holepunch:
                        if let reason, let stage = PSNConnectionStage(rawValue: reason) {
                            self?.statusMessage = stage.message
                        }
                        DebugLog.print("[PSNCoordinator] holepunch: \(reason ?? "")")
                    default:
                        break
                    }
                }
                startTask = Task.detached(priority: .userInitiated) {
                    do {
                        try session.startPSN(
                            token: token, consoleDUID: duid, isPS5: isPS5,
                            psnAccountID: accountId, autoRegist: true
                        )
                    } catch {
                        if gate.tryResume() {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: Self.registrationTimeoutNs)
                    } catch {
                        return
                    }
                    if gate.tryResume() {
                        session.cancelPSN() // unblocks an in-flight holepunch phase
                        continuation.resume(throwing: CoordinatorError.timeout(stage: statusMessage))
                    }
                }
            }
            await Self.finish(session: session, startTask: startTask)
            return host
        } catch {
            // Every failure path must release the C session, or every later
            // PSN / LAN start fails with "Session already active".
            session.cancelPSN()
            await Self.finish(session: session, startTask: startTask)
            throw error
        }
    }

    /// Wait for the blocking start to return, then join + free the library session.
    private static func finish(session: ChiakiFullSession, startTask: Task<Void, Never>?) async {
        if let startTask {
            _ = await startTask.value
        }
        await Task.detached(priority: .userInitiated) {
            session.teardown()
        }.value
    }

    private static func resolveAccountId(auth: PSNAuthService) -> Data? {
        guard let value = auth.userProfile?.accountId,
              let accountId = Data(base64Encoded: value), accountId.count == 8 else { return nil }
        return accountId
    }

    private static func hexToData(_ hex: String) -> Data? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0, cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
