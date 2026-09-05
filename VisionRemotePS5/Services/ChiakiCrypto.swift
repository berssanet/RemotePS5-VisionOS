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
}

// MARK: - ChiakiBridgeService

/// Bridge class to call Chiaki C functions from Swift
/// This is the main interface for using chiaki-ng core functionality
public final class ChiakiBridgeService {
    
    public static let shared = ChiakiBridgeService()
    
    private init() {
        // Initialize chiaki library
        DebugLog.print("[ChiakiBridgeService] Initializing Chiaki C Core")
    }
}

// MARK: - ChiakiBridgeService+Convenience

extension ChiakiBridgeService {
    
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
            DebugLog.print("[ChiakiBridgeService] Native payload format failed with error: \(result.rawValue)")
            throw ChiakiBridgeError(rawValue: Int32(result.rawValue)) ?? .unknown
        }
        
        DebugLog.print("[ChiakiBridgeService] ✅ Native payload formatted: \(payloadSize) bytes")
        
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
            DebugLog.print("[ChiakiBridgeService] Response decryption failed: \(result.rawValue)")
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
            DebugLog.print("[ChiakiBridgeService] RegistKey: empty")
        } else {
            registKey = registKeyData.map { String(format: "%02x", $0) }.joined()
            DebugLog.print("[ChiakiBridgeService] RegistKey bytes: \(registKeyData.map { String(format: "%02x", $0) }.joined())")
        }
        
        let serverMAC = withUnsafeBytes(of: hostInfo.server_mac) { Array($0.prefix(6)) }
        
        let nicknameFieldSize = MemoryLayout.size(ofValue: hostInfo.server_nickname)  // char[0x20] in regist.h
        let nickname = withUnsafePointer(to: &hostInfo.server_nickname) { ptr -> String in
            let cstr = UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            var len = 0
            while len < nicknameFieldSize && cstr[len] != 0 { len += 1 }
            return String(bytes: UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(cstr)), count: len), encoding: .utf8) ?? ""
        }
        
        DebugLog.print("[ChiakiBridgeService] ✅ Decrypted response - Nickname: \(nickname), RP-Key: \(rpKey.map { String(format: "%02x", $0) }.joined())")
        
        return RegisteredHostInfo(
            rpKey: rpKey,
            registKey: registKey,
            serverMAC: serverMAC,
            nickname: nickname,
            rpKeyType: hostInfo.rp_key_type
        )
    }
}

