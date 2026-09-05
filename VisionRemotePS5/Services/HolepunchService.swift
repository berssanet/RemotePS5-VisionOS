import Foundation
import Network

// MARK: - Holepunch Service
/// Implements UDP hole punching for NAT traversal to establish Remote Play connections
@MainActor
class HolepunchService: ObservableObject {
    static let shared = HolepunchService()
    
    @Published var isConnecting = false
    @Published var connectionStatus: HolepunchStatus = .idle
    @Published var error: String?
    
    private var controlSocket: NWConnection?
    private var dataSocket: NWConnection?
    
    // STUN servers
    private static let stunServers = [
        "stun.playstation.net:3478",
        "stun1.playstation.net:3478"
    ]
    
    // MARK: - Connection Lifecycle
    
    /// Establish a holepunch connection to a PlayStation console
    func connect(sessionInfo: PSNSessionStartResponse) async throws -> HolepunchConnection {
        isConnecting = true
        connectionStatus = .connecting
        error = nil
        
        defer {
            isConnecting = false
        }
        
        guard let peerAddress = sessionInfo.peerAddress,
              let peerPort = sessionInfo.peerPort else {
            throw HolepunchError.missingPeerInfo
        }
        
        DebugLog.print("[Holepunch] Starting connection to \(peerAddress):\(peerPort)")
        
        // Step 1: Punch control hole
        connectionStatus = .punchingControlHole
        let controlConn = try await punchHole(
            host: peerAddress,
            port: peerPort,
            type: .control
        )
        
        // Step 2: Punch data hole
        connectionStatus = .punchingDataHole
        let dataConn = try await punchHole(
            host: peerAddress,
            port: peerPort + 1,
            type: .data
        )
        
        connectionStatus = .connected
        
        let connection = HolepunchConnection(
            controlConnection: controlConn,
            dataConnection: dataConn,
            peerAddress: peerAddress,
            peerPort: peerPort,
            data1: sessionInfo.data1 ?? "",
            data2: sessionInfo.data2 ?? ""
        )
        
        DebugLog.print("[Holepunch] ✅ Connection established!")
        return connection
    }
    
    /// Disconnect any active connections
    func disconnect() {
        controlSocket?.cancel()
        dataSocket?.cancel()
        controlSocket = nil
        dataSocket = nil
        connectionStatus = .idle
        DebugLog.print("[Holepunch] Disconnected")
    }
    
    // MARK: - Hole Punching
    
    private func punchHole(host: String, port: Int, type: HolepunchPortType) async throws -> NWConnection {
        DebugLog.print("[Holepunch] Punching \(type) hole to \(host):\(port)")
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )
        
        // Use UDP for hole punching
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        let connection = NWConnection(to: endpoint, using: parameters)
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    DebugLog.print("[Holepunch] \(type) connection ready")
                    continuation.resume(returning: connection)
                    
                case .failed(let error):
                    DebugLog.print("[Holepunch] \(type) connection failed: \(error)")
                    continuation.resume(throwing: HolepunchError.connectionFailed(error.localizedDescription))
                    
                case .cancelled:
                    DebugLog.print("[Holepunch] \(type) connection cancelled")
                    continuation.resume(throwing: HolepunchError.cancelled)
                    
                case .preparing, .setup, .waiting:
                    DebugLog.print("[Holepunch] \(type) state: \(state)")
                    
                @unknown default:
                    break
                }
            }
            
            connection.start(queue: .main)
            
            // Send initial punch packet
            let punchPacket = createPunchPacket(type: type)
            connection.send(content: punchPacket, completion: .contentProcessed { error in
                if let error = error {
                    DebugLog.print("[Holepunch] Failed to send punch packet: \(error)")
                } else {
                    DebugLog.print("[Holepunch] Punch packet sent for \(type)")
                }
            })
        }
    }
    
    private func createPunchPacket(type: HolepunchPortType) -> Data {
        // Simple punch packet - just need to traverse NAT
        // The actual protocol negotiation happens after
        var packet = Data()
        
        // Magic bytes for PlayStation Remote Play
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        
        // Packet type
        switch type {
        case .control:
            packet.append(contentsOf: [0x01])
        case .data:
            packet.append(contentsOf: [0x02])
        }
        
        // Padding
        packet.append(contentsOf: [UInt8](repeating: 0, count: 11))
        
        return packet
    }
    
    // MARK: - STUN
    
    /// Get public IP and port via STUN
    func getPublicEndpoint() async throws -> (host: String, port: Int) {
        DebugLog.print("[Holepunch] Getting public endpoint via STUN...")
        
        for server in Self.stunServers {
            let parts = server.split(separator: ":")
            guard parts.count == 2,
                  let port = Int(parts[1]) else { continue }
            
            let host = String(parts[0])
            
            do {
                let result = try await performSTUNRequest(host: host, port: port)
                DebugLog.print("[Holepunch] Public endpoint: \(result.host):\(result.port)")
                return result
            } catch {
                DebugLog.print("[Holepunch] STUN request to \(server) failed: \(error)")
                continue
            }
        }
        
        throw HolepunchError.stunFailed
    }
    
    private func performSTUNRequest(host: String, port: Int) async throws -> (host: String, port: Int) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )
        
        let connection = NWConnection(to: endpoint, using: .udp)
        
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Send STUN binding request
                    let stunRequest = self.createSTUNBindingRequest()
                    connection.send(content: stunRequest, completion: .contentProcessed { error in
                        if let error = error {
                            if gate.tryResume() {
                                continuation.resume(throwing: error)
                            }
                        }
                    })

                    // Receive STUN response
                    connection.receive(minimumIncompleteLength: 20, maximumLength: 1024) { data, _, _, error in
                        defer { connection.cancel() }

                        if let error = error {
                            if gate.tryResume() {
                                continuation.resume(throwing: error)
                            }
                            return
                        }

                        guard let data = data,
                              let result = self.parseSTUNResponse(data) else {
                            if gate.tryResume() {
                                continuation.resume(throwing: HolepunchError.stunParseFailed)
                            }
                            return
                        }

                        if gate.tryResume() {
                            continuation.resume(returning: result)
                        }
                    }

                case .failed(let error):
                    if gate.tryResume() {
                        continuation.resume(throwing: error)
                    }

                default:
                    break
                }
            }

            connection.start(queue: .main)

            // Timeout after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if gate.tryResume() {
                    connection.cancel()
                    continuation.resume(throwing: HolepunchError.timeout)
                }
            }
        }
    }
    
    private nonisolated func createSTUNBindingRequest() -> Data {
        var request = Data()
        
        // STUN Binding Request
        // Message Type: Binding Request (0x0001)
        request.append(contentsOf: [0x00, 0x01])
        
        // Message Length: 0
        request.append(contentsOf: [0x00, 0x00])
        
        // Magic Cookie (RFC 5389)
        request.append(contentsOf: [0x21, 0x12, 0xA4, 0x42])
        
        // Transaction ID (12 bytes random)
        var transactionId = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, 12, &transactionId)
        request.append(contentsOf: transactionId)
        
        return request
    }
    
    private nonisolated func parseSTUNResponse(_ data: Data) -> (host: String, port: Int)? {
        guard data.count >= 20 else { return nil }
        
        let bytes = [UInt8](data)
        
        // Check message type (Binding Success Response: 0x0101)
        guard bytes[0] == 0x01 && bytes[1] == 0x01 else { return nil }
        
        // Parse attributes to find XOR-MAPPED-ADDRESS (0x0020) or MAPPED-ADDRESS (0x0001)
        var offset = 20
        while offset + 4 <= bytes.count {
            let attrType = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            let attrLength = Int(UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3]))
            offset += 4
            
            guard offset + attrLength <= bytes.count else { break }
            
            if attrType == 0x0020 { // XOR-MAPPED-ADDRESS
                guard attrLength >= 8 else { break }
                
                // Family (skip first byte padding)
                let family = bytes[offset + 1]
                guard family == 0x01 else { break } // IPv4
                
                // XOR'd port
                let xorPort = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
                let port = Int(xorPort ^ 0x2112) // XOR with magic cookie high 16 bits
                
                // XOR'd IP
                let xorIP = bytes[offset + 4..<offset + 8]
                let magicCookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
                var ip = [UInt8]()
                for i in 0..<4 {
                    ip.append(xorIP[offset + 4 + i] ^ magicCookie[i])
                }
                
                let host = ip.map { String($0) }.joined(separator: ".")
                return (host, port)
            }
            
            // Move to next attribute (with padding to 4-byte boundary)
            offset += (attrLength + 3) & ~3
        }
        
        return nil
    }
}

// MARK: - Types

enum HolepunchPortType: String {
    case control = "Control"
    case data = "Data"
}

enum HolepunchStatus: String {
    case idle = "Idle"
    case connecting = "Connecting"
    case punchingControlHole = "Punching Control Hole"
    case punchingDataHole = "Punching Data Hole"
    case connected = "Connected"
    case failed = "Failed"
}

struct HolepunchConnection {
    let controlConnection: NWConnection
    let dataConnection: NWConnection
    let peerAddress: String
    let peerPort: Int
    let data1: String
    let data2: String
}

enum HolepunchError: LocalizedError {
    case missingPeerInfo
    case connectionFailed(String)
    case cancelled
    case stunFailed
    case stunParseFailed
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .missingPeerInfo:
            return "Missing peer connection info"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .cancelled:
            return "Connection cancelled"
        case .stunFailed:
            return "STUN request failed"
        case .stunParseFailed:
            return "Failed to parse STUN response"
        case .timeout:
            return "Connection timed out"
        }
    }
}
