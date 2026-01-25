import Foundation
import Network
import Combine

// MARK: - Discovery Configuration

/// Configuration for console discovery behavior.
struct DiscoveryConfiguration {
    /// Timeout for each discovery probe (seconds).
    let probeTimeout: TimeInterval
    /// Maximum concurrent probes.
    let maxConcurrentProbes: Int
    /// Known IP addresses to probe directly.
    let knownIPs: [String]
    
    static let `default` = DiscoveryConfiguration(
        probeTimeout: 2.0,
        maxConcurrentProbes: 8,
        knownIPs: []
    )
}

// MARK: - Discovery State

enum DiscoveryState: Equatable {
    case idle
    case searching
    case completed(count: Int)
    case error(String)
}

// MARK: - Console Discovery Service

/// Service for discovering PlayStation consoles on the local network.
/// Uses UDP broadcast via the DDP (Device Discovery Protocol) to find PS5/PS4 consoles.
///
/// All network operations run on a dedicated background queue, ensuring the UI never blocks.
@MainActor
final class ConsoleDiscoveryService: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var discoveredConsoles: [Console] = []
    @Published private(set) var state: DiscoveryState = .idle
    @Published private(set) var statusMessage: String = ""
    
    /// Convenience property for backward compatibility.
    var isSearching: Bool { state == .searching }
    
    // MARK: - Private Properties
    
    private var discoveryTask: Task<Void, Never>?
    private let configuration: DiscoveryConfiguration
    
    /// Dedicated queue for network operations (off main thread).
    private let networkQueue = DispatchQueue(
        label: "com.visionremote.discovery.network",
        qos: .userInitiated,
        attributes: .concurrent
    )
    
    // MARK: - DDP Protocol Constants
    
    private enum DDPProtocol {
        static let ps5Port: UInt16 = 9302
        static let ps4Port: UInt16 = 987
        
        /// DDP v3 search packet (PS5 native).
        static let v3SearchPacket = "SRCH * HTTP/1.1\r\nDevice-Discovery-Protocol-Version: 00030010\r\n\r\n"
        
        /// DDP v2 search packet (PS4, also works for PS5).
        static let v2SearchPacket = "SRCH * HTTP/1.1\r\ndevice-discovery-protocol-version:00020020\r\n\r\n"
    }
    
    // MARK: - Initialization
    
    init(configuration: DiscoveryConfiguration = .default) {
        self.configuration = configuration
        print("[Discovery] Service initialized")
    }
    
    deinit {
        discoveryTask?.cancel()
        print("[Discovery] Service deinitialized")
    }
    
    // MARK: - Public API
    
    /// Start discovering consoles on the local network.
    /// This method returns immediately; discovery runs asynchronously in the background.
    func startDiscovery() {
        guard state != .searching else {
            print("[Discovery] Already searching")
            return
        }
        
        state = .searching
        statusMessage = "Searching for PlayStation consoles..."
        discoveredConsoles = []
        
        print("[Discovery] Starting DDP discovery...")
        
        // Launch discovery in a detached task to ensure UI never blocks
        discoveryTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            let consoles = await self.performDiscovery()
            
            await MainActor.run {
                self.handleDiscoveryComplete(consoles: consoles)
            }
        }
    }
    
    /// Stop any ongoing discovery.
    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        state = .idle
        statusMessage = "Search stopped"
        print("[Discovery] Discovery stopped")
    }
    
    /// Clear all discovered consoles and reset state.
    func clearCache() {
        stopDiscovery()
        discoveredConsoles.removeAll()
        statusMessage = ""
        print("[Discovery] Cache cleared")
    }
    
    /// Add a console manually (for testing or manual pairing).
    func addConsoleManually(name: String, ipAddress: String) {
        let console = Console(
            name: name,
            ipAddress: ipAddress,
            type: .ps5,
            status: .online
        )
        
        if !discoveredConsoles.contains(where: { $0.ipAddress == ipAddress }) {
            discoveredConsoles.append(console)
            statusMessage = "Console added: \(name)"
        }
    }
    
    /// Wake a console using the PS5 wakeup protocol.
    func wakeConsole(_ console: Console) async -> Bool {
        return await WakeOnLanService.shared.wakeConsole(console)
    }
    
    // MARK: - Private: Discovery Logic
    
    /// Performs the actual discovery. Runs entirely off the main thread.
    private nonisolated func performDiscovery() async -> [Console] {
        let broadcastAddresses = getBroadcastAddresses() + ["255.255.255.255"]
        print("[Discovery] Probing \(broadcastAddresses.count) broadcast addresses")
        
        // Use TaskGroup for concurrent probing with automatic cancellation handling
        let consoles = await withTaskGroup(of: Console?.self, returning: [Console].self) { group in
            var discovered: [Console] = []
            var seenIPs = Set<String>()
            
            // Probe all broadcast addresses with both protocols
            for address in broadcastAddresses {
                // PS5 DDP v3 probe
                group.addTask { [self] in
                    await self.sendProbe(
                        to: address,
                        port: DDPProtocol.ps5Port,
                        packet: DDPProtocol.v3SearchPacket
                    )
                }
                
                // PS4/PS5 DDP v2 probe
                group.addTask { [self] in
                    await self.sendProbe(
                        to: address,
                        port: DDPProtocol.ps4Port,
                        packet: DDPProtocol.v2SearchPacket
                    )
                }
            }
            
            // Also probe known IPs directly
            for ip in configuration.knownIPs {
                group.addTask { [self] in
                    await self.sendProbe(
                        to: ip,
                        port: DDPProtocol.ps5Port,
                        packet: DDPProtocol.v3SearchPacket
                    )
                }
            }
            
            // Collect results, deduplicating by IP
            for await console in group {
                guard let console = console else { continue }
                
                if !seenIPs.contains(console.ipAddress) {
                    seenIPs.insert(console.ipAddress)
                    discovered.append(console)
                    print("[Discovery] Found: \(console.name) at \(console.ipAddress)")
                }
            }
            
            return discovered
        }
        
        return consoles
    }
    
    /// Send a single discovery probe and wait for response.
    private nonisolated func sendProbe(to address: String, port: UInt16, packet: String) async -> Console? {
        guard let packetData = packet.data(using: .utf8) else { return nil }
        
        let host = NWEndpoint.Host(address)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        
        // Configure UDP connection
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .wifi  // Prefer WiFi for local discovery
        
        let connection = NWConnection(host: host, port: nwPort, using: params)
        
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumed = AtomicFlag()
                
                // Timeout handler
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(configuration.probeTimeout * 1_000_000_000))
                    if resumed.setIfFalse() {
                        connection.cancel()
                        continuation.resume(returning: nil)
                    }
                }
                
                connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        self.handleConnectionReady(
                            connection: connection,
                            address: address,
                            packetData: packetData,
                            resumed: resumed,
                            timeoutTask: timeoutTask,
                            continuation: continuation
                        )
                        
                    case .failed(let error):
                        if resumed.setIfFalse() {
                            timeoutTask.cancel()
                            print("[Discovery] Probe failed to \(address):\(port) - \(error)")
                            continuation.resume(returning: nil)
                        }
                        
                    case .cancelled:
                        if resumed.setIfFalse() {
                            timeoutTask.cancel()
                            continuation.resume(returning: nil)
                        }
                        
                    default:
                        break
                    }
                }
                
                connection.start(queue: networkQueue)
            }
        } onCancel: {
            connection.cancel()
        }
    }
    
    /// Handle connection ready state - send packet and wait for response.
    private nonisolated func handleConnectionReady(
        connection: NWConnection,
        address: String,
        packetData: Data,
        resumed: AtomicFlag,
        timeoutTask: Task<Void, Never>,
        continuation: CheckedContinuation<Console?, Never>
    ) {
        connection.send(content: packetData, completion: .contentProcessed { [self] error in
            if let error = error {
                if resumed.setIfFalse() {
                    timeoutTask.cancel()
                    connection.cancel()
                    print("[Discovery] Send error to \(address): \(error)")
                    continuation.resume(returning: nil)
                }
                return
            }
            
            // Wait for response
            connection.receiveMessage { data, _, _, error in
                timeoutTask.cancel()
                connection.cancel()
                
                guard resumed.setIfFalse() else { return }
                
                if let error = error {
                    print("[Discovery] Receive error from \(address): \(error)")
                    continuation.resume(returning: nil)
                    return
                }
                
                guard let data = data,
                      let response = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let console = self.parseDiscoveryResponse(response, fromAddress: address)
                continuation.resume(returning: console)
            }
        })
    }
    
    /// Handle discovery completion on main thread.
    private func handleDiscoveryComplete(consoles: [Console]) {
        discoveredConsoles = consoles
        
        if consoles.isEmpty {
            state = .completed(count: 0)
            statusMessage = "No consoles found. Make sure your PS5 is on and Remote Play is enabled."
        } else {
            state = .completed(count: consoles.count)
            statusMessage = "Found \(consoles.count) console(s)"
        }
        
        print("[Discovery] Completed - found \(consoles.count) consoles")
    }
    
    // MARK: - Private: Response Parsing
    
    /// Parse a DDP response into a Console object.
    private nonisolated func parseDiscoveryResponse(_ response: String, fromAddress address: String) -> Console? {
        // DDP responses are HTTP-like:
        // HTTP/1.1 200 Ok
        // host-id:1234567890ABCDEF
        // host-type:PS5
        // host-name:Living Room PS5
        
        guard response.contains("200 Ok") || response.contains("200 OK") else {
            return nil
        }
        
        var headers: [String: String] = [:]
        for line in response.components(separatedBy: "\r\n") {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        
        let hostName = headers["host-name"] ?? "PlayStation"
        let hostId = headers["host-id"] ?? ""
        let hostType = headers["host-type"]?.uppercased() ?? "PS5"
        
        let consoleType: Console.ConsoleType = {
            switch hostType {
            case "PS5": return .ps5
            case "PS5DIGITAL", "PS5 DIGITAL": return .ps5Digital
            case "PS4PRO", "PS4 PRO": return .ps4Pro
            case "PS4": return .ps4
            default: return .ps5
            }
        }()
        
        let status: Console.ConsoleStatus = {
            if response.contains("Standby") || headers["status"]?.lowercased() == "standby" {
                return .standby
            }
            return .online
        }()
        
        return Console(
            name: hostName,
            ipAddress: address,
            macAddress: hostId,
            type: consoleType,
            status: status
        )
    }
    
    // MARK: - Private: Network Helpers
    
    /// Get all broadcast addresses for local network interfaces.
    private nonisolated func getBroadcastAddresses() -> [String] {
        var addresses: [String] = []
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return addresses
        }
        defer { freeifaddrs(ifaddr) }
        
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let interface = ptr {
            let iface = interface.pointee
            let family = iface.ifa_addr.pointee.sa_family
            
            // IPv4 only
            if family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                
                // Skip loopback
                if name != "lo0" {
                    let flags = Int32(iface.ifa_flags)
                    
                    // Check for broadcast capability
                    if (flags & IFF_BROADCAST) != 0, let broadcastAddr = iface.ifa_dstaddr {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(
                            broadcastAddr,
                            socklen_t(broadcastAddr.pointee.sa_len),
                            &hostname,
                            socklen_t(hostname.count),
                            nil, 0,
                            NI_NUMERICHOST
                        ) == 0 {
                            let address = String(cString: hostname)
                            if !addresses.contains(address) {
                                addresses.append(address)
                            }
                        }
                    }
                }
            }
            
            ptr = iface.ifa_next
        }
        
        return addresses
    }
}

// MARK: - Thread-Safe Atomic Flag

/// A thread-safe flag for ensuring single resumption of continuations.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    
    /// Atomically sets the flag to true if currently false.
    /// - Returns: `true` if the flag was successfully set (was false), `false` if already set.
    func setIfFalse() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        if value { return false }
        value = true
        return true
    }
}
