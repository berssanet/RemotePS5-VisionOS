import Foundation
import Combine
import Network

enum LocalConsoleRoute {
    case streaming(Console)
    case pairing(Console)
}

enum LocalConsoleConnectionError: LocalizedError {
    case busy
    case invalidAddress
    case invalidAccount
    case notFound
    case standby

    var errorDescription: String? {
        switch self {
        case .busy: return "A local connection check is already running."
        case .invalidAddress: return "Enter the console's IPv4 address, without a URL or port."
        case .invalidAccount: return "The signed-in PSN Account ID is not ready. Refresh your PSN sign-in before pairing."
        case .notFound: return "No PlayStation answered at this IP. Check its address and allow Local Network access for this app."
        case .standby: return "Turn on the console before connecting locally."
        }
    }
}

@MainActor
final class LocalConsoleConnectionService: ObservableObject {
    @Published private(set) var isChecking = false

    private let discover: @MainActor (String) async -> Console?
    private let registeredConsoles: @MainActor () async -> [Console]

    convenience init() {
        self.init(discover: { address in
            await ConsoleDiscoveryService().discoverConsole(at: address)
        }, registeredConsoles: {
            await ConsoleStorageService.shared.getRegisteredConsoles()
        })
    }

    init(
        discover: @escaping @MainActor (String) async -> Console?,
        registeredConsoles: @escaping @MainActor () async -> [Console]
    ) {
        self.discover = discover
        self.registeredConsoles = registeredConsoles
    }

    func connect(to input: String, accountID: Data?) async throws -> LocalConsoleRoute {
        guard !isChecking else { throw LocalConsoleConnectionError.busy }
        guard let address = Self.normalizedAddress(input) else {
            throw LocalConsoleConnectionError.invalidAddress
        }
        guard accountID == nil || accountID?.count == 8 else {
            throw LocalConsoleConnectionError.invalidAccount
        }
        try Task.checkCancellation()
        isChecking = true
        defer { isChecking = false }
        let discovered = await discover(address)
        try Task.checkCancellation()
        guard let discovered, discovered.ipAddress == address, discovered.status != .offline else {
            throw LocalConsoleConnectionError.notFound
        }
        let registered = await registeredConsoles()
        try Task.checkCancellation()
        if let console = Self.registeredConsole(for: discovered, among: registered, accountID: accountID) {
            DebugLog.print("[LocalConnection] Using this app's saved registration for direct LAN streaming")
            return .streaming(console)
        }
        guard discovered.status == .online else { throw LocalConsoleConnectionError.standby }
        DebugLog.print("[LocalConnection] Console found; this app needs local pairing, not a PSN session")
        return .pairing(discovered)
    }

    nonisolated static func normalizedAddress(_ input: String) -> String? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ip = IPv4Address(address), ip.rawValue[0] > 0,
              ip.rawValue[0] != 127, ip.rawValue[0] < 224 else { return nil }
        return ip.rawValue.map { String($0) }.joined(separator: ".")
    }

    nonisolated static func hasRegistration(_ console: Console) -> Bool {
        guard console.isPaired, console.rpKey?.count == 16, console.psnAccountId?.count == 8,
              let key = console.registKey, (2...32).contains(key.count), key.count % 2 == 0 else { return false }
        return key.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    nonisolated static func registeredConsole(
        for discovered: Console, among registered: [Console], accountID: Data?
    ) -> Console? {
        guard let mac = normalizedMAC(discovered), discovered.status != .offline,
              accountID == nil || accountID?.count == 8 else { return nil }
        guard var console = registered.first(where: {
            hasRegistration($0) && normalizedMAC($0) == mac && isPS5($0) == isPS5(discovered) &&
                (accountID == nil || $0.psnAccountId == accountID)
        }) else { return nil }
        console.ipAddress = discovered.ipAddress
        console.status = discovered.status
        console.name = discovered.name
        console.psnDeviceID = nil
        return console
    }

    nonisolated private static func isPS5(_ console: Console) -> Bool {
        console.type == .ps5 || console.type == .ps5Digital
    }

    nonisolated private static func normalizedMAC(_ console: Console) -> String? {
        let mac: String
        if let bytes = console.serverMAC, bytes.count == 6 {
            mac = bytes.map { String(format: "%02x", $0) }.joined()
        } else {
            mac = console.macAddress.replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "").lowercased()
        }
        guard mac.count == 12, mac != "000000000000", mac != "ffffffffffff",
              mac.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return mac
    }
}
