//
//  ChiakiBridgeService.swift (formerly ChiakiCrypto.swift)
//  VisionRemotePS5
//
//  Bridge layer between Swift and Chiaki C Core
//  Uses Swift/C interoperability to directly call chiaki-ng functions
//
//  NOTE: This file replaces ChiakiBridge.swift to ensure compilation in target.
//

import Foundation

// MARK: - Swift Types mirroring Chiaki C Types

/// PlayStation target version
public enum ChiakiTargetSwift: UInt32 {
    case ps4Unknown = 0
    case ps4_8 = 800
    case ps4_9 = 900
    case ps4_10 = 1000
    case ps5Unknown = 1000000
    case ps5_1 = 1000100
    
    var isPS5: Bool { self.rawValue >= 1000000 }
}

/// Chiaki Bridge error codes
public enum ChiakiBridgeError: Int32, Error {
    case success = 0
    case unknown = 1
    case parseAddr = 2
    case thread = 3
    case memory = 4
    case overflow = 5
    case network = 6
    case connectionRefused = 7
    case hostDown = 8
    case hostUnreach = 9
    case disconnected = 10
    case invalidData = 11
    case bufTooSmall = 12
    case mutexLocked = 13
    case canceled = 14
    case timeout = 15
    case invalidResponse = 16
    case invalidMac = 17
    case uninitialized = 18
    case fecFailed = 19
    case versionMismatch = 20
    case httpNonOk = 21
    
    var localizedDescription: String {
        switch self {
        case .success: return "Success"
        case .unknown: return "Unknown error"
        case .network: return "Network error"
        case .connectionRefused: return "Connection refused"
        case .timeout: return "Connection timeout"
        case .invalidResponse: return "Invalid response from console"
        case .canceled: return "Operation canceled"
        default: return "Error code: \(self.rawValue)"
        }
    }
}

/// Registration event type
public enum ChiakiRegistEventTypeSwift {
    case canceled
    case failed
    case success
}

/// Registered host information
public struct ChiakiRegisteredHostSwift {
    public let target: ChiakiTargetSwift
    public let apSSID: String
    public let apBSSID: String
    public let apKey: String
    public let apName: String
    public let serverMAC: [UInt8]
    public let serverNickname: String
    public let rpRegistKey: Data
    public let rpKeyType: UInt32
    public let rpKey: Data
    public let consolePin: UInt32
}

/// RPCrypt structure for encryption
public struct ChiakiRPCryptSwift {
    public var target: ChiakiTargetSwift
    public var bright: [UInt8]      // 16 bytes
    public var ambassador: [UInt8]  // 16 bytes
    
    public init(target: ChiakiTargetSwift = .ps5_1) {
        self.target = target
        self.bright = [UInt8](repeating: 0, count: 16)
        self.ambassador = [UInt8](repeating: 0, count: 16)
    }
}

// MARK: - ChiakiBridgeService

/// Bridge class to call Chiaki C functions from Swift
/// This is the main interface for using chiaki-ng core functionality
public final class ChiakiBridgeService {
    
    public static let shared = ChiakiBridgeService()
    
    private init() {
        // Initialize chiaki library
        print("[ChiakiBridgeService] Initializing Chiaki C Core")
    }
    
    // MARK: - RPCrypt Functions
    
    /// Initialize RPCrypt for PS5 registration
    /// Wraps: chiaki_rpcrypt_init_regist()
    public func initRPCryptRegistration(
        target: ChiakiTargetSwift,
        ambassador: Data,
        keyOffset: Int,
        pin: UInt32
    ) throws -> ChiakiRPCryptSwift {
        guard ambassador.count == 16 else {
            throw ChiakiBridgeError.invalidData
        }
        guard keyOffset < 0x20 else {
            throw ChiakiBridgeError.invalidData
        }
        
        var cRpcrypt = ChiakiRPCrypt()
        
        // Call chiaki_rpcrypt_init_regist from C library
        let result = ambassador.withUnsafeBytes { ambPtr -> ChiakiErrorCode in
            let ambassadorPtr = ambPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return chiaki_rpcrypt_init_regist(
                &cRpcrypt,
                ChiakiTarget(rawValue: target.rawValue),
                ambassadorPtr,
                keyOffset,
                pin
            )
        }
        
        guard result == CHIAKI_ERR_SUCCESS else {
            print("[ChiakiBridgeService] RPCrypt init failed with error: \(result.rawValue)")
            throw ChiakiBridgeError(rawValue: Int32(result.rawValue)) ?? .unknown
        }
        
        // Convert C struct to Swift struct
        var swiftRpcrypt = ChiakiRPCryptSwift(target: target)
        
        // Copy bright key (16 bytes)
        withUnsafeBytes(of: cRpcrypt.bright) { brightPtr in
            swiftRpcrypt.bright = Array(UnsafeBufferPointer(
                start: brightPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                count: 16
            ))
        }
        
        // Copy ambassador (16 bytes)
        withUnsafeBytes(of: cRpcrypt.ambassador) { ambPtr in
            swiftRpcrypt.ambassador = Array(UnsafeBufferPointer(
                start: ambPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                count: 16
            ))
        }
        
        print("[ChiakiBridgeService] ✅ Initialized RPCrypt for target: \(target)")
        print("[ChiakiBridgeService] Bright: \(swiftRpcrypt.bright.map { String(format: "%02x", $0) }.joined())")
        return swiftRpcrypt
    }
    
    /// Encrypt data using RPCrypt
    /// Wraps: chiaki_rpcrypt_encrypt()
    public func encrypt(
        rpcrypt: ChiakiRPCryptSwift,
        counter: UInt64,
        data: Data
    ) throws -> Data {
        // Convert Swift struct back to C struct
        var cRpcrypt = ChiakiRPCrypt()
        cRpcrypt.target = ChiakiTarget(rawValue: rpcrypt.target.rawValue)
        
        // Copy bright and ambassador arrays
        for i in 0..<16 {
            withUnsafeMutableBytes(of: &cRpcrypt.bright) { ptr in
                ptr[i] = rpcrypt.bright[i]
            }
            withUnsafeMutableBytes(of: &cRpcrypt.ambassador) { ptr in
                ptr[i] = rpcrypt.ambassador[i]
            }
        }
        
        // Allocate output buffer
        var outputData = Data(count: data.count)
        
        // Call chiaki_rpcrypt_encrypt
        let result = data.withUnsafeBytes { inputPtr -> ChiakiErrorCode in
            outputData.withUnsafeMutableBytes { outputPtr in
                let inPtr = inputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let outPtr = outputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return chiaki_rpcrypt_encrypt(&cRpcrypt, counter, inPtr, outPtr, data.count)
            }
        }
        
        guard result == CHIAKI_ERR_SUCCESS else {
            print("[ChiakiBridgeService] Encryption failed with error: \(result.rawValue)")
            throw ChiakiBridgeError(rawValue: Int32(result.rawValue)) ?? .unknown
        }
        
        print("[ChiakiBridgeService] ✅ Encrypted \(data.count) bytes with counter \(counter)")
        return outputData
    }
    
    /// Decrypt data using RPCrypt
    /// Wraps: chiaki_rpcrypt_decrypt()
    public func decrypt(
        rpcrypt: ChiakiRPCryptSwift,
        counter: UInt64,
        data: Data
    ) throws -> Data {
        // Convert Swift struct back to C struct
        var cRpcrypt = ChiakiRPCrypt()
        cRpcrypt.target = ChiakiTarget(rawValue: rpcrypt.target.rawValue)
        
        // Copy bright and ambassador arrays
        for i in 0..<16 {
            withUnsafeMutableBytes(of: &cRpcrypt.bright) { ptr in
                ptr[i] = rpcrypt.bright[i]
            }
            withUnsafeMutableBytes(of: &cRpcrypt.ambassador) { ptr in
                ptr[i] = rpcrypt.ambassador[i]
            }
        }
        
        // Allocate output buffer
        var outputData = Data(count: data.count)
        
        // Call chiaki_rpcrypt_decrypt
        let result = data.withUnsafeBytes { inputPtr -> ChiakiErrorCode in
            outputData.withUnsafeMutableBytes { outputPtr in
                let inPtr = inputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let outPtr = outputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return chiaki_rpcrypt_decrypt(&cRpcrypt, counter, inPtr, outPtr, data.count)
            }
        }
        
        guard result == CHIAKI_ERR_SUCCESS else {
            print("[ChiakiBridgeService] Decryption failed with error: \(result.rawValue)")
            throw ChiakiBridgeError(rawValue: Int32(result.rawValue)) ?? .unknown
        }
        
        print("[ChiakiBridgeService] ✅ Decrypted \(data.count) bytes with counter \(counter)")
        return outputData
    }
    

    /// Calculate Aeropause
    /// Wraps: chiaki_rpcrypt_aeropause()
    public func calculateAeropause(
        target: ChiakiTargetSwift,
        keyOffset: Int,
        ambassador: Data
    ) throws -> Data {
        guard ambassador.count == 16 else {
            throw ChiakiBridgeError.invalidData
        }
        
        var outputAeropause = Data(count: 16)
        
        let result = ambassador.withUnsafeBytes { ambPtr -> ChiakiErrorCode in
            outputAeropause.withUnsafeMutableBytes { aeroPtr in
                let ambC = ambPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let aeroC = aeroPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                
                return chiaki_rpcrypt_aeropause(
                    ChiakiTarget(rawValue: target.rawValue),
                    keyOffset,
                    aeroC,
                    ambC
                )
            }
        }
        
        guard result == CHIAKI_ERR_SUCCESS else {
            print("[ChiakiBridgeService] Aeropause calculation failed with error: \(result.rawValue)")
            throw ChiakiBridgeError(rawValue: Int32(result.rawValue)) ?? .unknown
        }
        
        print("[ChiakiBridgeService] ✅ Calculated Aeropause: \(outputAeropause.map { String(format: "%02x", $0) }.joined())")
        return outputAeropause
    }

    // MARK: - Registration Functions
    
    /// Start registration with a PlayStation console
    /// Wraps: chiaki_regist_start()
    public func startRegistration(
        host: String,
        pin: UInt32,
        accountId: Data,
        target: ChiakiTargetSwift,
        completion: @escaping (Result<ChiakiRegisteredHostSwift, ChiakiBridgeError>) -> Void
    ) {
        print("[ChiakiBridgeService] Starting registration with host: \(host), target: \(target)")
        
        // This would be implemented as:
        // 1. Create ChiakiRegistInfo struct
        // 2. Create callback wrapper
        // 3. Call chiaki_regist_start()
        // 4. Wait for callback and convert result
        
        // For now, dispatch async to simulate the C callback
        DispatchQueue.global().async {
            // Placeholder implementation
            // Actual implementation calls C registration function
            
            DispatchQueue.main.async {
                // Return placeholder error - actual implementation returns real result
                completion(.failure(.unknown))
            }
        }
    }
    
    /// Format registration request payload
    /// Wraps: chiaki_regist_request_payload_format() logic (implemented in Swift via Bridge)
    public func formatRegistrationPayload(
        target: ChiakiTargetSwift,
        ambassador: Data,
        accountId: String?,
        pin: UInt32
    ) throws -> (payload: Data, rpcrypt: ChiakiRPCryptSwift) {
        // Build payload buffer (0x400 bytes like Chiaki)
        var payload = [UInt8](repeating: 0, count: 0x400)
        
        // Step 1: Fill with 'A' (0x41) like Chiaki does
        for i in 0..<0x1e0 {
            payload[i] = 0x41  // 'A'
        }
        
        // Step 2: Extract key offsets from the payload
        // key_0_off = buf[0x18D] & 0x1F = 0x41 & 0x1F = 1
        // key_1_off = buf[0] >> 3 = 0x41 >> 3 = 8
        let key0Offset = Int(payload[0x18D] & 0x1F)
        let key1Offset = Int(payload[0] >> 3)
        
        print("[ChiakiBridgeService] key_0_off: \(key0Offset), key_1_off: \(key1Offset)")
        
        // Step 3: Initialize RPCrypt with PIN
        let rpcrypt = try initRPCryptRegistration(
            target: target,
            ambassador: ambassador,
            keyOffset: key0Offset,
            pin: pin
        )
        
        print("[ChiakiBridgeService] Bright key: \(rpcrypt.bright.map { String(format: "%02x", $0) }.joined())")
        
        // Step 4: Generate aeropause
        let aeropause = try calculateAeropause(
            target: target,
            keyOffset: key1Offset,
            ambassador: Data(rpcrypt.ambassador)
        )
        
        print("[ChiakiBridgeService] Aeropause: \(aeropause.map { String(format: "%02x", $0) }.joined())")
        
        // Place aeropause at specific offsets
        let aeropauseBytes = [UInt8](aeropause)
        for i in 0..<8 {
            payload[0xc7 + i] = aeropauseBytes[8 + i]
            payload[0x191 + i] = aeropauseBytes[i]
        }
        
        // Step 5: Build inner header
        let clientType = "dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931afcf0adc0d34f"
        let finalAccountId: String
        if let acc = accountId, !acc.isEmpty {
            finalAccountId = acc
        } else {
            finalAccountId = Data(repeating: 0, count: 8).base64EncodedString()
        }
        
        let innerHeader = "Client-Type: \(clientType)\r\nNp-AccountId: \(finalAccountId)\r\n"
        
        guard let innerData = innerHeader.data(using: .utf8) else {
            throw ChiakiBridgeError.invalidData
        }
        
        print("[ChiakiBridgeService] Inner header size: \(innerData.count)")
        
        // Step 6: Encrypt inner header
        let encryptedInner = try encrypt(
            rpcrypt: rpcrypt,
            counter: 0,
            data: innerData
        )
        
        // Place at offset 0x1e0
        let innerOffset = 0x1e0
        let encryptedBytes = [UInt8](encryptedInner)
        for i in 0..<encryptedBytes.count {
            payload[innerOffset + i] = encryptedBytes[i]
        }
        
        // Final size
        let finalSize = innerOffset + encryptedInner.count
        
        return (Data(payload.prefix(finalSize)), rpcrypt)
    }
    
    // MARK: - Utility Functions
    
    /// Generate random ambassador (16 bytes)
    public func generateAmbassador() -> Data {
        var data = Data(count: 16)
        _ = data.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 16, ptr.baseAddress!)
        }
        return data
    }
    
    /// Convert Swift target to C target value
    public func targetToC(_ target: ChiakiTargetSwift) -> UInt32 {
        return target.rawValue
    }
}

// MARK: - ChiakiBridgeService+Convenience

extension ChiakiBridgeService {
    
    /// Convenience method for PS5 registration
    public func registerPS5(
        ipAddress: String,
        pin: String,
        accountId: Data,
        completion: @escaping (Result<ChiakiRegisteredHostSwift, ChiakiBridgeError>) -> Void
    ) {
        guard let pinValue = UInt32(pin), pin.count == 8 else {
            completion(.failure(.invalidData))
            return
        }
        
        startRegistration(
            host: ipAddress,
            pin: pinValue,
            accountId: accountId,
            target: .ps5_1,
            completion: completion
        )
    }
    
    // MARK: - Native C-Core Payload Formatting
    
    /// Format registration payload using DIRECT C-core call (bit-perfect parity)
    /// This calls chiaki_regist_request_payload_format via wrapper
    /// Returns payload, brightKey (for encryption), and ambassadorKey (COMPUTED, for decryption)
    public func formatRegistrationPayloadNative(
        target: ChiakiTargetSwift,
        ambassador: Data,
        accountId: String?,
        pin: UInt32
    ) throws -> (payload: Data, brightKey: [UInt8], ambassadorKey: [UInt8]) {
        guard ambassador.count == 16 else {
            throw ChiakiBridgeError.invalidData
        }
        
        // Decode account ID from Base64 to raw 8 bytes
        let accountIdBytes: [UInt8]
        if let accStr = accountId, !accStr.isEmpty,
           let accData = Data(base64Encoded: accStr),
           accData.count == 8 {
            accountIdBytes = [UInt8](accData)
        } else {
            // Default: all zeros
            accountIdBytes = [UInt8](repeating: 0, count: 8)
        }
        
        // Prepare buffers
        var payloadBuffer = [UInt8](repeating: 0, count: 0x400)
        var payloadSize = 0x400
        var brightKey = [UInt8](repeating: 0, count: 16)
        var ambassadorKey = [UInt8](repeating: 0, count: 16)  // Computed ambassador from rpcrypt
        
        let result = ambassador.withUnsafeBytes { ambPtr -> ChiakiErrorCode in
            accountIdBytes.withUnsafeBytes { accPtr -> ChiakiErrorCode in
                payloadBuffer.withUnsafeMutableBytes { payloadPtr -> ChiakiErrorCode in
                    brightKey.withUnsafeMutableBytes { brightPtr -> ChiakiErrorCode in
                        ambassadorKey.withUnsafeMutableBytes { ambassadorPtr -> ChiakiErrorCode in
                            chiaki_format_regist_payload_wrapper(
                                ChiakiTarget(rawValue: target.rawValue),
                                ambPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                accPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                pin,
                                payloadPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                &payloadSize,
                                brightPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                ambassadorPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                            )
                        }
                    }
                }
            }
        }
        
        guard result == CHIAKI_ERR_SUCCESS else {
            print("[ChiakiBridgeService] Native payload format failed with error: \(result.rawValue)")
            throw ChiakiBridgeError(rawValue: Int32(result.rawValue)) ?? .unknown
        }
        
        print("[ChiakiBridgeService] ✅ Native payload formatted: \(payloadSize) bytes")
        print("[ChiakiBridgeService] Native Bright: \(brightKey.map { String(format: "%02x", $0) }.joined())")
        print("[ChiakiBridgeService] Native Ambassador (computed): \(ambassadorKey.map { String(format: "%02x", $0) }.joined())")
        
        return (Data(payloadBuffer.prefix(payloadSize)), brightKey, ambassadorKey)
    }
    
    // MARK: - Registration Response Decryption
    
    /// Represents parsed registration host info from PS5
    public struct RegisteredHostInfo {
        public let rpKey: Data           // 16 bytes - used for session
        public let registKey: String     // PS5-RegistKey
        public let serverMAC: [UInt8]    // 6 bytes
        public let nickname: String
        public let rpKeyType: UInt32
    }
    
    /// Decrypt and parse the registration response body
    /// - Parameters:
    ///   - target: PS5 target
    ///   - brightKey: Bright key from payload generation
    ///   - ambassadorKey: Ambassador key from payload generation (needed for IV)
    ///   - encryptedData: Response body after HTTP headers
    /// - Returns: Parsed host info containing RP-Key and other registration data
    public func decryptRegistrationResponse(
        target: ChiakiTargetSwift,
        brightKey: [UInt8],
        ambassadorKey: [UInt8],
        encryptedData: Data
    ) throws -> RegisteredHostInfo {
        guard brightKey.count == 16, ambassadorKey.count == 16 else {
            throw ChiakiBridgeError.invalidData
        }
        
        var hostInfo = ChiakiRegisteredHost()
        
        let result = brightKey.withUnsafeBytes { brightPtr -> ChiakiErrorCode in
            ambassadorKey.withUnsafeBytes { ambassadorPtr -> ChiakiErrorCode in
                encryptedData.withUnsafeBytes { dataPtr -> ChiakiErrorCode in
                    chiaki_decrypt_regist_response_wrapper(
                        ChiakiTarget(rawValue: target.rawValue),
                        brightPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ambassadorPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        dataPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        encryptedData.count,
                        &hostInfo
                    )
                }
            }
        }
        
        guard result == CHIAKI_ERR_SUCCESS else {
            print("[ChiakiBridgeService] Response decryption failed: \(result.rawValue)")
            throw ChiakiBridgeError(rawValue: Int32(result.rawValue)) ?? .unknown
        }
        
        // Extract info from C struct safely (avoiding null-termination issues)
        let rpKey = Data(bytes: &hostInfo.rp_key, count: 16)
        
        // Extract registKey as binary bytes and convert to hex string
        // rp_regist_key contains parsed hex bytes, not ASCII string
        let registKeyData = withUnsafePointer(to: &hostInfo.rp_regist_key) { ptr -> Data in
            let bytes = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
            // Find length (first null or 16 bytes max)
            var len = 0
            while len < 16 && bytes[len] != 0 { len += 1 }
            return Data(bytes: bytes, count: len)
        }
        
        // Convert binary bytes to hex string for session init
        let registKey: String
        if registKeyData.isEmpty {
            registKey = ""
            print("[ChiakiBridgeService] RegistKey: empty")
        } else {
            registKey = registKeyData.map { String(format: "%02x", $0) }.joined()
            print("[ChiakiBridgeService] RegistKey bytes: \(registKeyData.map { String(format: "%02x", $0) }.joined())")
        }
        
        let serverMAC = Array(UnsafeBufferPointer(start: &hostInfo.server_mac.0, count: 6))
        
        let nickname = withUnsafePointer(to: &hostInfo.server_nickname) { ptr -> String in
            let cstr = UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            var len = 0
            while len < 128 && cstr[len] != 0 { len += 1 }
            return String(bytes: UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(cstr)), count: len), encoding: .utf8) ?? ""
        }
        
        print("[ChiakiBridgeService] ✅ Decrypted response - Nickname: \(nickname), RP-Key: \(rpKey.map { String(format: "%02x", $0) }.joined())")
        
        return RegisteredHostInfo(
            rpKey: rpKey,
            registKey: registKey,
            serverMAC: serverMAC,
            nickname: nickname,
            rpKeyType: hostInfo.rp_key_type
        )
    }
    
    // MARK: - Session Crypto Functions
    
    /// Session header information for authenticated streaming
    public struct SessionHeaders {
        public let rpAuth: String          // Encrypted regist_key base64 (counter 0)
        public let rpDid: String           // Encrypted device ID base64 (counter 1)
        public let rpOsType: String        // Encrypted OS type base64 (counter 2)
        public let rpStartBitrate: String  // Encrypted bitrate base64 (counter 3, required for PS5)
        public let rpStreamingType: String // Encrypted streaming type base64 (counter 4, required for PS5)
    }
    
    /// Generate encrypted session headers for streaming
    /// Uses: chiaki_session_generate_headers_wrapper()
    public func generateSessionHeaders(
        target: ChiakiTargetSwift,
        nonce: Data,          // 16 bytes from initial handshake
        rpKey: Data,          // 16 bytes (morning)
        registKey: Data,      // 16 bytes binary registration key
        deviceId: Data        // 32 bytes
    ) throws -> SessionHeaders {
        guard nonce.count == 16 else {
            throw ChiakiBridgeError.invalidData
        }
        guard rpKey.count == 16 else {
            throw ChiakiBridgeError.invalidData
        }
        // Note: registKey may be less than 16 bytes, will be padded below
        guard deviceId.count == 32 else {
            throw ChiakiBridgeError.invalidData
        }
        
        // Ensure registKey is exactly 16 bytes (pad with zeros if needed)
        var registKeyPadded = Data(count: 16)
        registKeyPadded.replaceSubrange(0..<min(registKey.count, 16), with: registKey.prefix(16))
        
        print("[ChiakiBridgeService] Generating session headers...")
        print("[ChiakiBridgeService] Nonce: \(nonce.map { String(format: "%02x", $0) }.joined())")
        print("[ChiakiBridgeService] RP-Key: \(rpKey.map { String(format: "%02x", $0) }.joined())")
        print("[ChiakiBridgeService] RegistKey: \(registKeyPadded.map { String(format: "%02x", $0) }.joined())")
        
        // Allocate output buffers
        var rpAuthBuffer = [Int8](repeating: 0, count: 64)
        var rpDidBuffer = [Int8](repeating: 0, count: 64)
        var rpOsTypeBuffer = [Int8](repeating: 0, count: 256)
        
        // Call C wrapper
        let result = nonce.withUnsafeBytes { noncePtr in
            rpKey.withUnsafeBytes { rpKeyPtr in
                registKeyPadded.withUnsafeBytes { registKeyPtr in
                    deviceId.withUnsafeBytes { didPtr in
                        chiaki_session_generate_headers_wrapper(
                            ChiakiTarget(rawValue: target.rawValue),
                            noncePtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            rpKeyPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            registKeyPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            didPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            &rpAuthBuffer,
                            &rpDidBuffer,
                            &rpOsTypeBuffer
                        )
                    }
                }
            }
        }
        
        if result != CHIAKI_ERR_SUCCESS {
            print("[ChiakiBridgeService] ❌ Failed to generate session headers: \(result.rawValue)")
            throw ChiakiBridgeError(rawValue: Int32(result.rawValue)) ?? .unknown
        }
        
        let rpAuth = String(cString: rpAuthBuffer)
        let rpDid = String(cString: rpDidBuffer)
        let rpOsType = String(cString: rpOsTypeBuffer)
        
        print("[ChiakiBridgeService] ✅ Basic headers generated")
        print("[ChiakiBridgeService] RP-Auth: \(rpAuth)")
        print("[ChiakiBridgeService] RP-Did: \(rpDid)")
        print("[ChiakiBridgeService] RP-OSType: \(rpOsType)")
        
        // Generate RP-StartBitrate (required for PS5, counter 3)
        var rpStartBitrateBuffer = [Int8](repeating: 0, count: 32)
        let bitrateResult = chiaki_session_generate_bitrate_wrapper(
            &rpStartBitrateBuffer,
            32
        )
        
        if bitrateResult != CHIAKI_ERR_SUCCESS {
            print("[ChiakiBridgeService] ❌ Failed to generate bitrate: \(bitrateResult.rawValue)")
            throw ChiakiBridgeError(rawValue: Int32(bitrateResult.rawValue)) ?? .unknown
        }
        
        let rpStartBitrate = String(cString: rpStartBitrateBuffer)
        
        // Generate RP-StreamingType (required for PS5, counter 4)
        var rpStreamingTypeBuffer2 = [Int8](repeating: 0, count: 32)
        let streamResult2 = chiaki_session_generate_streaming_type_wrapper(
            &rpStreamingTypeBuffer2,
            32
        )
        
        if streamResult2 != CHIAKI_ERR_SUCCESS {
            print("[ChiakiBridgeService] ❌ Failed to generate streaming type: \(streamResult2.rawValue)")
            throw ChiakiBridgeError(rawValue: Int32(streamResult2.rawValue)) ?? .unknown
        }
        
        let rpStreamingTypeFinal = String(cString: rpStreamingTypeBuffer2)
        
        print("[ChiakiBridgeService] RP-StartBitrate: \(rpStartBitrate)")
        print("[ChiakiBridgeService] RP-StreamingType (final): \(rpStreamingTypeFinal)")
        
        return SessionHeaders(
            rpAuth: rpAuth,
            rpDid: rpDid,
            rpOsType: rpOsType,
            rpStartBitrate: rpStartBitrate,
            rpStreamingType: rpStreamingTypeFinal
        )
    }
    
    /// Reset session crypto state
    public func resetSessionCrypto() {
        chiaki_session_crypto_reset_wrapper()
        print("[ChiakiBridgeService] Session crypto reset")
    }
}

