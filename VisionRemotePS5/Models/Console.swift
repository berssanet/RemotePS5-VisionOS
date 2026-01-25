import Foundation

/// Represents a PlayStation console discovered on the network
struct Console: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var ipAddress: String
    var macAddress: String
    var type: ConsoleType
    var status: ConsoleStatus
    var isPaired: Bool
    var lastConnected: Date?
    
    // Registration data (obtained during pairing)
    var rpKey: Data?           // 16-byte Remote Play key
    var registKey: String?     // Registration key string
    var serverMAC: [UInt8]?    // 6-byte MAC address from registration
    var nickname: String?      // Console nickname from registration
    var psnAccountId: Data?    // 8-byte PSN Account ID (from PSNAuthService)
    
    /// Convenience property for IP address
    var address: String { ipAddress }
    
    enum ConsoleType: String, Codable {
        case ps5 = "PS5"
        case ps5Digital = "PS5 Digital"
        case ps4 = "PS4"
        case ps4Pro = "PS4 Pro"
    }
    
    enum ConsoleStatus: String, Codable {
        case online = "Online"
        case standby = "Standby"
        case offline = "Offline"
    }
    
    init(
        id: UUID = UUID(),
        name: String,
        ipAddress: String,
        macAddress: String = "",
        type: ConsoleType = .ps5,
        status: ConsoleStatus = .offline,
        isPaired: Bool = false,
        lastConnected: Date? = nil,
        rpKey: Data? = nil,
        registKey: String? = nil,
        serverMAC: [UInt8]? = nil,
        nickname: String? = nil,
        psnAccountId: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.type = type
        self.status = status
        self.isPaired = isPaired
        self.lastConnected = lastConnected
        self.rpKey = rpKey
        self.registKey = registKey
        self.serverMAC = serverMAC
        self.nickname = nickname
        self.psnAccountId = psnAccountId
    }
}

// MARK: - Preview Helpers
extension Console {
    static var preview: Console {
        Console(
            name: "PlayStation 5",
            ipAddress: "192.168.1.100",
            macAddress: "00:11:22:33:44:55",
            type: .ps5,
            status: .online,
            isPaired: true,
            lastConnected: Date()
        )
    }
    
    static var previewList: [Console] {
        [
            Console(name: "Living Room PS5", ipAddress: "192.168.1.100", type: .ps5, status: .online, isPaired: true),
            Console(name: "Bedroom PS5", ipAddress: "192.168.1.101", type: .ps5Digital, status: .standby, isPaired: true),
            Console(name: "Office PS4", ipAddress: "192.168.1.102", type: .ps4Pro, status: .offline, isPaired: false)
        ]
    }
}
