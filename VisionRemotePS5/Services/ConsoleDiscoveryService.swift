import Foundation
import Network
import Combine

/// Service for discovering PlayStation consoles on the local network
/// Uses UDP broadcast to find PS5 consoles via the DDP v3 protocol
final class ConsoleDiscoveryService: ObservableObject {
    
    // MARK: - Published Properties
    @Published private(set) var discoveredConsoles: [Console] = []
    @Published private(set) var isSearching: Bool = false
    @Published private(set) var statusMessage: String = ""
    
    // MARK: - Private Properties
    private var searchTask: Task<Void, Never>?
    private let discoveryQueue = DispatchQueue(label: "com.visionremote.discovery", qos: .userInitiated)
    
    // DDP Protocol Constants
    private let ps5SearchPort: UInt16 = 9302
    private let ps4SearchPort: UInt16 = 987
    
    // DDP v3 Search Packet for PS5
    private let ddpV3SearchPacket = "SRCH * HTTP/1.1\r\nDevice-Discovery-Protocol-Version: 00030010\r\n\r\n"
    
    // DDP v2 Search Packet for PS4, also works for PS5
    private let ddpV2SearchPacket = "SRCH * HTTP/1.1\r\ndevice-discovery-protocol-version:00020020\r\n\r\n"
    
    init() {
        print("[Discovery] Service initialized")
    }
    
    deinit {
        searchTask?.cancel()
        print("[Discovery] Service deinitialized")
    }
    
    // MARK: - Public Methods
    
    /// Start discovering consoles on the network
    @MainActor
    func startDiscovery() {
        guard !isSearching else {
            print("[Discovery] Already searching")
            return
        }
        
        isSearching = true
        statusMessage = "Searching for PlayStation consoles..."
        discoveredConsoles = []
        
        print("[Discovery] Starting real DDP discovery...")
        
        searchTask = Task {
            await performDiscovery()
        }
    }
    
    /// Stop any ongoing discovery
    @MainActor
    func stopDiscovery() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        statusMessage = "Search stopped"
        print("[Discovery] Discovery stopped")
    }
    
    /// Clear all cached data
    @MainActor
    func clearCache() {
        searchTask?.cancel()
        searchTask = nil
        discoveredConsoles.removeAll()
        isSearching = false
        statusMessage = ""
        print("[Discovery] Cache cleared")
    }
    
    /// Add a console manually (for testing or manual pairing)
    @MainActor
    func addConsoleManually(name: String, ipAddress: String) {
        let console = Console(
            name: name,
            ipAddress: ipAddress,
            type: .ps5,
            status: .online
        )
        if !discoveredConsoles.contains(where: { $0.ipAddress == ipAddress }) {
            discoveredConsoles.append(console)
        }
        statusMessage = "Console added: \(name)"
    }
    
    /// Wake a console using Wake-on-LAN magic packet
    /// - Parameter console: The console to wake (must have registKey for PS5)
    /// - Returns: True if the wake packet was sent successfully
    func wakeConsole(_ console: Console) async -> Bool {
        return await WakeOnLanService.shared.wakeConsole(console)
    }
    
    /// Wake a console by host IP and registKey (required for PS5)
    /// For PS5, registKey is required. For PS4, falls back to traditional WoL with MAC.
    func wakeConsole(host: String, registKey: Data, isPS5: Bool = true) async -> Bool {
        return await WakeOnLanService.shared.wakeConsole(host: host, registKey: registKey, isPS5: isPS5)
    }
    
    // MARK: - Private Discovery Implementation
    
    private func performDiscovery() async {
        // Get all broadcast addresses for local interfaces
        let broadcastAddresses = getBroadcastAddresses()
        print("[Discovery] Found broadcast addresses: \(broadcastAddresses)")
        
        // Create UDP connections for each broadcast address
        var connections: [NWConnection] = []
        var foundConsoles: [Console] = []
        
        // Add generic broadcast
        let allAddresses = broadcastAddresses + ["255.255.255.255"]
        
        for address in allAddresses {
            // Try PS5 port 9302
            if let console = await sendDiscoveryPacket(to: address, port: ps5SearchPort, packet: ddpV3SearchPacket) {
                if !foundConsoles.contains(where: { $0.ipAddress == console.ipAddress }) {
                    foundConsoles.append(console)
                    print("[Discovery] Found PS5: \(console.name) at \(console.ipAddress)")
                }
            }
            
            // Try PS4/PS5 port 987
            if let console = await sendDiscoveryPacket(to: address, port: ps4SearchPort, packet: ddpV2SearchPacket) {
                if !foundConsoles.contains(where: { $0.ipAddress == console.ipAddress }) {
                    foundConsoles.append(console)
                    print("[Discovery] Found console: \(console.name) at \(console.ipAddress)")
                }
            }
            
            // Check for cancellation
            if Task.isCancelled { break }
        }
        
        // Also try direct discovery to user's known IP
        let knownIPs = ["192.168.100.33"] // Could be loaded from UserDefaults
        for ip in knownIPs {
            if let console = await sendDiscoveryPacket(to: ip, port: ps5SearchPort, packet: ddpV3SearchPacket) {
                if !foundConsoles.contains(where: { $0.ipAddress == console.ipAddress }) {
                    foundConsoles.append(console)
                    print("[Discovery] Found PS5 at known IP: \(console.name) at \(console.ipAddress)")
                }
            }
        }
        
        // Update UI on main thread
        await MainActor.run {
            self.discoveredConsoles = foundConsoles
            self.isSearching = false
            
            if foundConsoles.isEmpty {
                self.statusMessage = "No consoles found. Make sure your PS5 is on and Remote Play is enabled."
            } else {
                self.statusMessage = "Found \(foundConsoles.count) console(s)"
            }
            print("[Discovery] Discovery completed - found \(foundConsoles.count) consoles")
        }
    }
    
    private func sendDiscoveryPacket(to address: String, port: UInt16, packet: String) async -> Console? {
        guard let data = packet.data(using: .utf8) else { return nil }
        
        let host = NWEndpoint.Host(address)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        
        // Create UDP connection
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        
        let connection = NWConnection(host: host, port: nwPort, using: params)
        
        // Thread-safe box to prevent double continuation resume
        final class ResumeGuard: @unchecked Sendable {
            private let lock = NSLock()
            private var _resumed = false
            
            func tryResume() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if _resumed { return false }
                _resumed = true
                return true
            }
        }
        
        let guard_ = ResumeGuard()
        
        return await withCheckedContinuation { continuation in
            var timeoutTask: Task<Void, Never>?
            
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 second timeout
                if guard_.tryResume() {
                    connection.cancel()
                    continuation.resume(returning: nil)
                }
            }
            
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    // Send discovery packet
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error = error {
                            print("[Discovery] Send error to \(address): \(error)")
                            if guard_.tryResume() {
                                timeoutTask?.cancel()
                                connection.cancel()
                                continuation.resume(returning: nil)
                            }
                            return
                        }
                        
                        // Receive response
                        connection.receiveMessage { data, _, _, error in
                            timeoutTask?.cancel()
                            connection.cancel()
                            
                            guard guard_.tryResume() else { return }
                            
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
                            
                            print("[Discovery] Response from \(address):\n\(response)")
                            
                            // Parse response
                            if let console = self?.parseDiscoveryResponse(response, fromAddress: address) {
                                continuation.resume(returning: console)
                            } else {
                                continuation.resume(returning: nil)
                            }
                        }
                    })
                    
                case .failed(let error):
                    if guard_.tryResume() {
                        timeoutTask?.cancel()
                        print("[Discovery] Connection failed to \(address): \(error)")
                        continuation.resume(returning: nil)
                    }
                    
                case .cancelled:
                    if guard_.tryResume() {
                        timeoutTask?.cancel()
                        continuation.resume(returning: nil)
                    }
                    
                default:
                    break
                }
            }
            
            connection.start(queue: discoveryQueue)
        }
    }
    
    private func parseDiscoveryResponse(_ response: String, fromAddress address: String) -> Console? {
        // DDP responses are HTTP-like headers
        // Example:
        // HTTP/1.1 200 Ok
        // host-id:1234567890ABCDEF
        // host-type:PS5
        // host-name:Living Room PS5
        // host-request-port:997
        // device-discovery-protocol-version:00030010
        
        var headers: [String: String] = [:]
        let lines = response.components(separatedBy: "\r\n")
        
        for line in lines {
            if let colonRange = line.range(of: ":") {
                let key = String(line[..<colonRange.lowerBound]).lowercased()
                let value = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        
        // Check if this is a valid response
        guard response.contains("200 Ok") || response.contains("200 OK") else {
            return nil
        }
        
        // Extract console info
        let hostId = headers["host-id"] ?? ""
        let hostName = headers["host-name"] ?? "PlayStation"
        let hostType = headers["host-type"]?.uppercased() ?? "PS5"
        
        // Determine console type
        let consoleType: Console.ConsoleType
        switch hostType {
        case "PS5":
            consoleType = .ps5
        case "PS5DIGITAL", "PS5 DIGITAL":
            consoleType = .ps5Digital
        case "PS4PRO", "PS4 PRO":
            consoleType = .ps4Pro
        case "PS4":
            consoleType = .ps4
        default:
            consoleType = .ps5
        }
        
        // Determine status from response
        let status: Console.ConsoleStatus
        if response.contains("Standby") || headers["status"]?.lowercased() == "standby" {
            status = .standby
        } else {
            status = .online
        }
        
        return Console(
            name: hostName,
            ipAddress: address,
            macAddress: hostId,
            type: consoleType,
            status: status
        )
    }
    
    // MARK: - Network Helpers
    
    private func getBroadcastAddresses() -> [String] {
        var addresses: [String] = []
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return addresses
        }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            
            // Check for IPv4
            if family == UInt8(AF_INET) {
                // Get interface name
                let name = String(cString: interface.ifa_name)
                
                // Skip loopback
                guard name != "lo0" else {
                    if let next = interface.ifa_next {
                        ptr = next
                        continue
                    } else {
                        break
                    }
                }
                
                // Check if interface has broadcast flag
                let flags = Int32(interface.ifa_flags)
                if (flags & IFF_BROADCAST) != 0, let broadcastAddr = interface.ifa_dstaddr {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(broadcastAddr, socklen_t(broadcastAddr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let address = String(cString: hostname)
                        if !addresses.contains(address) {
                            addresses.append(address)
                        }
                    }
                }
            }
            
            if let next = interface.ifa_next {
                ptr = next
            } else {
                break
            }
        }
        
        return addresses
    }
}
