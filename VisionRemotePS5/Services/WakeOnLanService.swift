//
//  WakeOnLanService.swift
//  VisionRemotePS5
//
//  Service for waking PlayStation consoles using PS5-specific WAKEUP protocol.
//  Based on chiaki-ng chiaki_discovery_wakeup() implementation in discovery.c.
//
//  NOTE: PS5 does NOT use traditional Wake-on-LAN Magic Packets.
//  It uses a custom UDP protocol with HTTP-like WAKEUP command packets.
//

import Foundation
import Network

/// Service for waking PlayStation consoles using PS5-specific protocol
final class WakeOnLanService {
    
    // MARK: - Singleton
    
    static let shared = WakeOnLanService()
    
    // MARK: - Constants
    
    /// Discovery port for PS4
    private let ps4DiscoveryPort: UInt16 = 987
    
    /// Discovery port for PS5
    private let ps5DiscoveryPort: UInt16 = 9302
    
    /// PS4 discovery protocol version
    private let ps4ProtocolVersion = "00020020"
    
    /// PS5 discovery protocol version
    private let ps5ProtocolVersion = "00030010"
    
    // MARK: - Initialization
    
    private init() {
        print("[WakeOnLan] Service initialized (PS5 WAKEUP protocol)")
    }
    
    // MARK: - Public Methods
    
    /// Wake a PS5 console using the correct WAKEUP protocol
    /// - Parameters:
    ///   - host: IP address of the console
    ///   - registKey: Registration key bytes (obtained during pairing)
    ///   - isPS5: Whether the target is a PS5 (true) or PS4 (false)
    /// - Returns: True if packet was sent successfully
    @discardableResult
    func wakeConsole(host: String, registKey: Data, isPS5: Bool = true) async -> Bool {
        // Convert registKey to user_credential (interpret bytes as hex number)
        let userCredential = registKeyToCredential(registKey)
        
        print("[WakeOnLan] Sending WAKEUP to \(host) | isPS5=\(isPS5) | credential=\(String(format: "%llx", userCredential))")
        
        // Build WAKEUP packet (HTTP-like format as per chiaki_discovery_packet_fmt)
        let protocolVersion = isPS5 ? ps5ProtocolVersion : ps4ProtocolVersion
        let packet = buildWakeupPacket(userCredential: userCredential, protocolVersion: protocolVersion)
        
        guard let packetData = packet.data(using: .utf8) else {
            print("[WakeOnLan] ❌ Failed to encode WAKEUP packet")
            return false
        }
        
        // Append null terminator as chiaki does
        var dataWithNull = packetData
        dataWithNull.append(0x00)
        
        let port = isPS5 ? ps5DiscoveryPort : ps4DiscoveryPort
        let success = await sendUDPPacket(dataWithNull, to: host, port: port)
        
        if success {
            print("[WakeOnLan] ✅ WAKEUP packet sent to \(host):\(port)")
        } else {
            print("[WakeOnLan] ❌ Failed to send WAKEUP packet")
        }
        
        return success
    }
    
    /// Wake a console using its stored Console object
    @discardableResult
    func wakeConsole(_ console: Console) async -> Bool {
        // Check if we have registration key (required for PS5 wakeup)
        guard let registKeyString = console.registKey, !registKeyString.isEmpty else {
            print("[WakeOnLan] ❌ Console \(console.name) has no registration key (required for wakeup)")
            // Fallback: try traditional WoL if we have MAC address (for PS4 compatibility)
            return await wakeConsoleTraditional(console)
        }
        
        // chiaki-ng expects the registKey as a hex STRING, not as bytes!
        // Example: registKey = "12345678" -> credential = strtoull("12345678", NULL, 16) = 0x12345678
        guard let registKeyData = registKeyString.data(using: .utf8) else {
            print("[WakeOnLan] ❌ Invalid registration key encoding")
            return false
        }
        
        let isPS5 = console.type == .ps5 || console.type == .ps5Digital
        return await wakeConsole(host: console.ipAddress, registKey: registKeyData, isPS5: isPS5)
    }
    
    // MARK: - Traditional WoL (PS4 Fallback)
    
    /// Send traditional Wake-on-LAN Magic Packet (for PS4 or fallback)
    func wakeConsoleTraditional(_ console: Console) async -> Bool {
        guard let mac = console.serverMAC, mac.count == 6 else {
            if !console.macAddress.isEmpty {
                let parsed = parseMACString(console.macAddress)
                if parsed.count == 6 {
                    return await sendMagicPacket(macAddress: parsed)
                }
            }
            print("[WakeOnLan] ❌ No valid MAC address for traditional WoL")
            return false
        }
        return await sendMagicPacket(macAddress: mac)
    }
    
    /// Send traditional Magic Packet (6x 0xFF + 16x MAC)
    private func sendMagicPacket(macAddress: [UInt8], broadcast: String = "255.255.255.255") async -> Bool {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macAddress)
        }
        
        let success1 = await sendUDPPacket(packet, to: broadcast, port: 9)
        let success2 = await sendUDPPacket(packet, to: broadcast, port: ps4DiscoveryPort)
        return success1 || success2
    }
    
    // MARK: - Private Methods
    
    /// Build WAKEUP packet in chiaki format (HTTP-like text protocol)
    /// Based on chiaki_discovery_packet_fmt() in discovery.c
    private func buildWakeupPacket(userCredential: UInt64, protocolVersion: String) -> String {
        return """
        WAKEUP * HTTP/1.1
        client-type:vr
        auth-type:R
        model:w
        app-type:r
        user-credential:\(userCredential)
        device-discovery-protocol-version:\(protocolVersion)
        
        """
    }
    
    /// Convert registKey to user_credential
    /// In chiaki-ng (wakeup.c:86): credential = strtoull(registkey, NULL, 16)
    /// The registKey is a string like "12345678" interpreted as HEX number
    private func registKeyToCredential(_ registKey: Data) -> UInt64 {
        // The registKey should be treated as a HEX string (ASCII chars),
        // NOT as raw bytes. Convert to string and parse as hex.
        if let registKeyString = String(data: registKey, encoding: .utf8) {
            // Remove any trailing null bytes or whitespace
            let cleaned = registKeyString.trimmingCharacters(in: .whitespacesAndNewlines)
                                         .replacingOccurrences(of: "\0", with: "")
            if let value = UInt64(cleaned, radix: 16) {
                return value
            }
        }
        
        // Fallback: If registKey is already raw bytes (from hex string parsing),
        // interpret first 8 bytes as big-endian number
        var credential: UInt64 = 0
        let bytesToUse = min(registKey.count, 8)
        for i in 0..<bytesToUse {
            credential = (credential << 8) | UInt64(registKey[i])
        }
        return credential
    }
    
    private func sendUDPPacket(_ data: Data, to address: String, port: UInt16) async -> Bool {
        let host = NWEndpoint.Host(address)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        
        let connection = NWConnection(host: host, port: nwPort, using: params)
        
        return await withCheckedContinuation { continuation in
            var resumed = false
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: data, completion: .contentProcessed { error in
                        connection.cancel()
                        guard !resumed else { return }
                        resumed = true
                        if let error = error {
                            print("[WakeOnLan] Send error to \(address):\(port): \(error)")
                            continuation.resume(returning: false)
                        } else {
                            continuation.resume(returning: true)
                        }
                    })
                    
                case .failed(let error):
                    guard !resumed else { return }
                    resumed = true
                    print("[WakeOnLan] Connection failed to \(address):\(port): \(error)")
                    continuation.resume(returning: false)
                    
                case .cancelled:
                    break
                    
                default:
                    break
                }
            }
            
            connection.start(queue: DispatchQueue.global(qos: .utility))
        }
    }
    
    /// Parse MAC address string like "00:11:22:33:44:55" to bytes
    private func parseMACString(_ mac: String) -> [UInt8] {
        let cleaned = mac.replacingOccurrences(of: ":", with: "")
                         .replacingOccurrences(of: "-", with: "")
        return parseHexString(cleaned)
    }
    
    /// Parse hex string to bytes
    private func parseHexString(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        
        while index < hex.endIndex {
            guard let endIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) else { break }
            if let byte = UInt8(hex[index..<endIndex], radix: 16) {
                bytes.append(byte)
            }
            index = endIndex
        }
        
        return bytes
    }
}

// MARK: - Console Extension

extension Console {
    /// Check if console can be woken up
    /// For PS5: requires registKey. For PS4: MAC address or registKey.
    var canWakeUp: Bool {
        // PS5 requires registration key
        if type == .ps5 || type == .ps5Digital {
            return registKey != nil && !registKey!.isEmpty
        }
        // PS4 can use either registKey or MAC
        return (registKey != nil && !registKey!.isEmpty) ||
               (serverMAC?.count == 6) ||
               !macAddress.isEmpty
    }
    
    /// Wake this console using appropriate method (PS5 protocol or traditional WoL)
    func wake() async -> Bool {
        await WakeOnLanService.shared.wakeConsole(self)
    }
}
