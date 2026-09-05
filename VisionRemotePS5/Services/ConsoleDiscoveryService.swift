import Foundation
import Combine

// MARK: - Discovery Configuration

/// Configuration for console discovery behavior.
struct DiscoveryConfiguration {
    /// Time to wait for replies to each probe (seconds).
    let probeTimeout: TimeInterval
    /// Known IP addresses to probe directly (unicast) in addition to the broadcasts.
    let knownIPs: [String]

    static let `default` = DiscoveryConfiguration(probeTimeout: 2.0, knownIPs: [])
}

// MARK: - Discovery State

enum DiscoveryState: Equatable {
    case idle
    case searching
    case completed(count: Int)
    case error(String)
}

// MARK: - Console Discovery Service

/// Finds PlayStation consoles on the local network with the DDP (Device Discovery Protocol)
/// broadcast the official Remote Play app uses (`SRCH * HTTP/1.1`, UDP 9302 for PS5 and
/// 987 for PS4). Uses BSD sockets with SO_BROADCAST: Network.framework cannot send to
/// broadcast addresses. Consoles in rest mode answer `620 Server Standby` and are listed too.
@MainActor
final class ConsoleDiscoveryService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var discoveredConsoles: [Console] = []
    @Published private(set) var state: DiscoveryState = .idle
    @Published private(set) var statusMessage: String = ""

    var isSearching: Bool { state == .searching }

    // MARK: - Private Properties

    private var discoveryTask: Task<Void, Never>?
    private let configuration: DiscoveryConfiguration
    /// Set when a broadcast sendto is refused (EPERM/EACCES): visionOS may require the
    /// Multicast Networking entitlement for 255.255.255.255; unicast probes still work.
    private var broadcastBlocked: Bool = false
    private var completedRuns: Int = 0

    /// Dedicated queue for the blocking socket work (off the main thread).
    private let networkQueue = DispatchQueue(
        label: "com.visionremote.discovery.network",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // MARK: - DDP Protocol Constants

    private enum DDPProtocol {
        static let ps5Port: UInt16 = 9302
        static let ps4Port: UInt16 = 987
        /// DDP v3 search packet (PS5) — byte-exact copy of chiaki_discovery_packet_fmt.
        static let v3SearchPacket = "SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n"
        /// DDP v2 search packet (PS4, also answered by PS5).
        static let v2SearchPacket = "SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00020020\n"
    }

    // MARK: - Initialization

    init(configuration: DiscoveryConfiguration = .default) {
        self.configuration = configuration
    }

    deinit {
        discoveryTask?.cancel()
    }

    // MARK: - Public API

    func discoverConsole(at address: String) async -> Console? {
        var ps5 = await Self.probe(on: networkQueue, address: address, port: DDPProtocol.ps5Port,
                                  packet: DDPProtocol.v3SearchPacket, timeout: configuration.probeTimeout)
        if ps5.sendRefused {
            DebugLog.print("[Discovery] Local probe refused; waiting briefly for Local Network permission")
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch { return nil }
            ps5 = await Self.probe(on: networkQueue, address: address, port: DDPProtocol.ps5Port,
                                  packet: DDPProtocol.v3SearchPacket, timeout: configuration.probeTimeout)
            if ps5.sendRefused { return nil }
        }
        if let console = ps5.consoles.first(where: { $0.ipAddress == address }) { return console }
        guard !Task.isCancelled else { return nil }
        let ps4 = await Self.probe(on: networkQueue, address: address, port: DDPProtocol.ps4Port,
                                  packet: DDPProtocol.v2SearchPacket, timeout: configuration.probeTimeout)
        return ps4.consoles.first(where: { $0.ipAddress == address })
    }

    /// Start discovering consoles on the local network. Returns immediately.
    /// `unicastTargets` (e.g. the IP typed by the user) are probed directly, on top of the
    /// broadcasts and every registered console's address — no entitlement needed for those.
    func startDiscovery(unicastTargets: [String] = []) {
        guard state != .searching else { return }
        state = .searching
        statusMessage = "Searching for PlayStation consoles..."
        discoveredConsoles = []
        broadcastBlocked = false
        DebugLog.print("[Discovery] Starting DDP discovery...")
        let startedAt = Date()

        discoveryTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let registered = await ConsoleStorageService.shared.getRegisteredConsoles().map(\.ipAddress)
            let result = await self.performDiscovery(unicastTargets: unicastTargets + registered)
            await MainActor.run {
                self.handleDiscoveryComplete(consoles: result.consoles, broadcastBlocked: result.broadcastBlocked)
                // The first run races the local-network permission prompt: retry once.
                if result.consoles.isEmpty, self.completedRuns == 1, Date().timeIntervalSince(startedAt) < 3 {
                    DebugLog.print("[Discovery] First run may have raced the local-network prompt; retrying once")
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        self.startDiscovery(unicastTargets: unicastTargets)
                    }
                }
            }
        }
    }

    /// Stop any ongoing discovery.
    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        state = .idle
        statusMessage = "Search stopped"
    }

    /// Clear all discovered consoles and reset state.
    func clearCache() {
        stopDiscovery()
        discoveredConsoles.removeAll()
        statusMessage = ""
    }

    /// Add a console manually (for testing or manual pairing).
    func addConsoleManually(name: String, ipAddress: String) {
        let console = Console(name: name, ipAddress: ipAddress, type: .ps5, status: .online)
        if !discoveredConsoles.contains(where: { $0.ipAddress == ipAddress }) {
            discoveredConsoles.append(console)
            statusMessage = "Console added: \(name)"
        }
    }

    // MARK: - Private: Discovery Logic

    private struct DiscoveryRun {
        let consoles: [Console]
        let broadcastBlocked: Bool
    }

    private struct ProbeResult {
        let consoles: [Console]
        let sendRefused: Bool // EPERM / EACCES on sendto (broadcast not permitted)
    }

    /// Probes every broadcast address and every unicast target with both DDP versions concurrently.
    private nonisolated func performDiscovery(unicastTargets: [String]) async -> DiscoveryRun {
        let broadcasts = Self.broadcastAddresses() + ["255.255.255.255"]
        let unicast = Array(Set(unicastTargets + configuration.knownIPs)).filter { !$0.isEmpty }
        DebugLog.print("[Discovery] Probing broadcast \(broadcasts.joined(separator: ", ")) + unicast \(unicast.joined(separator: ", "))")
        let timeout = configuration.probeTimeout
        let queue = networkQueue

        return await withTaskGroup(of: (ProbeResult, Bool).self, returning: DiscoveryRun.self) { group in
            for address in broadcasts {
                group.addTask {
                    (await Self.probe(on: queue, address: address, port: DDPProtocol.ps5Port,
                                      packet: DDPProtocol.v3SearchPacket, timeout: timeout), true)
                }
                group.addTask {
                    (await Self.probe(on: queue, address: address, port: DDPProtocol.ps4Port,
                                      packet: DDPProtocol.v2SearchPacket, timeout: timeout), true)
                }
            }
            for ip in unicast {
                group.addTask {
                    (await Self.probe(on: queue, address: ip, port: DDPProtocol.ps5Port,
                                      packet: DDPProtocol.v3SearchPacket, timeout: timeout), false)
                }
            }

            var discovered: [Console] = []
            var seenIPs = Set<String>()
            var broadcastRefused = false
            for await (result, isBroadcast) in group {
                if isBroadcast, result.sendRefused { broadcastRefused = true }
                for console in result.consoles where !seenIPs.contains(console.ipAddress) {
                    seenIPs.insert(console.ipAddress)
                    discovered.append(console)
                    DebugLog.print("[Discovery] Found: \(console.name) at \(console.ipAddress) (\(console.status.rawValue))")
                }
            }
            return DiscoveryRun(consoles: discovered, broadcastBlocked: broadcastRefused)
        }
    }

    private nonisolated static func probe(
        on queue: DispatchQueue, address: String, port: UInt16, packet: String, timeout: TimeInterval
    ) async -> ProbeResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: broadcastProbe(address: address, port: port, packet: packet, timeout: timeout))
            }
        }
    }

    /// One UDP socket: SO_BROADCAST, send the probe, then collect every reply until `timeout`.
    private nonisolated static func broadcastProbe(
        address: String, port: UInt16, packet: String, timeout: TimeInterval
    ) -> ProbeResult {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            DebugLog.print("[Discovery] socket() failed: \(String(cString: strerror(errno)))")
            return ProbeResult(consoles: [], sendRefused: false)
        }
        defer { close(fd) }

        var enable: Int32 = 1
        let intSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, intSize)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enable, intSize)
        let wholeSeconds = Int(timeout)
        var receiveTimeout = timeval(
            tv_sec: wholeSeconds,
            tv_usec: Int32((timeout - Double(wholeSeconds)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else {
            return ProbeResult(consoles: [], sendRefused: false)
        }

        let payload = Array(packet.utf8) + [0] // chiaki sends len + 1 (NUL terminator)
        let sent = withUnsafePointer(to: &destination) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                sendto(fd, payload, payload.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == payload.count else {
            let code = errno
            DebugLog.print("[Discovery] sendto \(address):\(port) failed: \(String(cString: strerror(code)))")
            return ProbeResult(consoles: [], sendRefused: code == EPERM || code == EACCES)
        }

        var results: [Console] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &sender) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    recvfrom(fd, &buffer, buffer.count, 0, sockaddrPointer, &senderLength)
                }
            }
            guard received > 0 else { break } // timeout (EAGAIN) or error: this probe is done
            var addressBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var senderAddress = sender.sin_addr
            guard inet_ntop(AF_INET, &senderAddress, &addressBuffer, socklen_t(addressBuffer.count)) != nil else { continue }
            let fromAddress = String(cString: addressBuffer)
            guard let text = String(bytes: buffer[0..<received], encoding: .utf8) else { continue }
            if let console = parseDiscoveryResponse(text, fromAddress: fromAddress) {
                results.append(console)
            }
        }
        return ProbeResult(consoles: results, sendRefused: false)
    }

    /// Discovery completion on the main thread.
    private func handleDiscoveryComplete(consoles: [Console], broadcastBlocked: Bool) {
        completedRuns += 1
        discoveredConsoles = consoles
        self.broadcastBlocked = broadcastBlocked
        if consoles.isEmpty {
            state = .completed(count: 0)
            statusMessage = broadcastBlocked
                ? "Broadcast search is not permitted on this device. Type the PS5 IP address to probe it directly."
                : "No consoles found. Make sure your PS5 is on and Remote Play is enabled."
        } else {
            state = .completed(count: consoles.count)
            statusMessage = "Found \(consoles.count) console(s)"
        }
        DebugLog.print("[Discovery] Completed - found \(consoles.count) consoles (broadcastBlocked=\(broadcastBlocked))")
    }

    // MARK: - Private: Response Parsing

    /// DDP replies are HTTP-like: `HTTP/1.1 200 Ok` (awake) or `HTTP/1.1 620 Server Standby`
    /// (rest mode), followed by `host-id`, `host-type`, `host-name`, ... headers.
    private nonisolated static func parseDiscoveryResponse(_ response: String, fromAddress address: String) -> Console? {
        // The PS5 answers with LF line endings (chiaki_http_response_parse accepts both).
        let lines = response.components(separatedBy: "\n").map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/1.1") else { return nil }
        let status: Console.ConsoleStatus
        if statusLine.contains(" 200 ") {
            status = .online
        } else if statusLine.contains(" 620 ") {
            status = .standby
        } else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIndex]).lowercased()
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let consoleType: Console.ConsoleType
        switch (headers["host-type"] ?? "PS5").uppercased() {
        case "PS4": consoleType = .ps4
        case "PS4PRO", "PS4 PRO": consoleType = .ps4Pro
        default: consoleType = .ps5
        }

        return Console(
            name: headers["host-name"] ?? "PlayStation",
            ipAddress: address,
            macAddress: headers["host-id"] ?? "",
            type: consoleType,
            status: status
        )
    }

    // MARK: - Private: Network Helpers

    /// Broadcast addresses of every IPv4 interface with IFF_BROADCAST (skipping loopback).
    private nonisolated static func broadcastAddresses() -> [String] {
        var addresses: [String] = []
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let first = interfaceList else { return addresses }
        defer { freeifaddrs(interfaceList) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = pointer {
            let entry = interface.pointee
            pointer = entry.ifa_next
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name != "lo0", (Int32(entry.ifa_flags) & IFF_BROADCAST) != 0,
                  let broadcast = entry.ifa_dstaddr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let resolved = getnameinfo(broadcast, socklen_t(broadcast.pointee.sa_len),
                                       &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard resolved == 0 else { continue }
            let address = String(cString: host)
            if !addresses.contains(address) {
                addresses.append(address)
            }
        }
        return addresses
    }
}
