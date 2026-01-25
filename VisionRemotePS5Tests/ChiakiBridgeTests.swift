//
//  ChiakiBridgeTests.swift
//  VisionRemotePS5Tests
//
//  Unit tests for ChiakiBridge Swift-C++ interoperability layer
//

import XCTest
@testable import VisionRemotePS5

final class ChiakiBridgeTests: XCTestCase {
    
    // MARK: - Test Properties
    
    private var bridge: ChiakiBridge!
    private var validAmbassador: Data!
    private var validAccountId: Data!
    
    // MARK: - Setup & Teardown
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        bridge = ChiakiBridge.shared
        validAmbassador = Data([
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10
        ])
        validAccountId = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    }
    
    override func tearDownWithError() throws {
        bridge = nil
        validAmbassador = nil
        validAccountId = nil
        try super.tearDownWithError()
    }
    
    // MARK: - Singleton Tests
    
    func testSharedInstance_ReturnsSameInstance() {
        // Given two references to shared instance
        let instance1 = ChiakiBridge.shared
        let instance2 = ChiakiBridge.shared
        
        // Then they should be the same instance
        XCTAssertTrue(instance1 === instance2, "Shared instance should always return same object")
    }
    
    // MARK: - RPCrypt Initialization Tests
    
    func testInitRPCryptRegistration_ValidInput_Success() throws {
        // Given valid input
        let target = ChiakiTargetSwift.ps5_1
        let pin: UInt32 = 12345678
        
        // When initializing RPCrypt
        let rpcrypt = try bridge.initRPCryptRegistration(
            target: target,
            ambassador: validAmbassador,
            keyOffset: 0,
            pin: pin
        )
        
        // Then result should have correct properties
        XCTAssertEqual(rpcrypt.target, target)
        XCTAssertEqual(rpcrypt.bright.count, 16, "Bright key should be 16 bytes")
        XCTAssertEqual(rpcrypt.ambassador.count, 16, "Ambassador should be 16 bytes")
    }
    
    func testInitRPCryptRegistration_InvalidAmbassadorSize_Throws() {
        // Given invalid ambassador (wrong size)
        let invalidAmbassador = Data([0x01, 0x02, 0x03]) // Only 3 bytes
        
        // When initializing RPCrypt
        // Then it should throw
        XCTAssertThrowsError(
            try bridge.initRPCryptRegistration(
                target: .ps5_1,
                ambassador: invalidAmbassador,
                keyOffset: 0,
                pin: 12345678
            )
        ) { error in
            if let chiakiError = error as? ChiakiError {
                XCTAssertEqual(chiakiError, .invalidData)
            }
        }
    }
    
    func testInitRPCryptRegistration_InvalidKeyOffset_Throws() {
        // Given invalid key offset (>= 0x20)
        let invalidKeyOffset = 0x20
        
        // When initializing RPCrypt
        // Then it should throw
        XCTAssertThrowsError(
            try bridge.initRPCryptRegistration(
                target: .ps5_1,
                ambassador: validAmbassador,
                keyOffset: invalidKeyOffset,
                pin: 12345678
            )
        )
    }
    
    // MARK: - Encryption Tests
    
    func testEncrypt_ValidRPCrypt_ReturnsData() throws {
        // Given an initialized RPCrypt and data
        let rpcrypt = try bridge.initRPCryptRegistration(
            target: .ps5_1,
            ambassador: validAmbassador,
            keyOffset: 0,
            pin: 12345678
        )
        let testData = "Test encryption via bridge".data(using: .utf8)!
        
        // When encrypting
        let encrypted = try bridge.encrypt(rpcrypt: rpcrypt, counter: 0, data: testData)
        
        // Then encrypted data should be returned
        XCTAssertEqual(encrypted.count, testData.count)
        XCTAssertNotEqual(encrypted, testData, "Encrypted data should differ from original")
    }
    
    // MARK: - Decryption Tests
    
    func testDecrypt_ValidRPCrypt_ReturnsData() throws {
        // Given encrypted data
        let rpcrypt = try bridge.initRPCryptRegistration(
            target: .ps5_1,
            ambassador: validAmbassador,
            keyOffset: 0,
            pin: 12345678
        )
        let originalData = "Test decryption via bridge".data(using: .utf8)!
        let encrypted = try bridge.encrypt(rpcrypt: rpcrypt, counter: 0, data: originalData)
        
        // When decrypting
        let decrypted = try bridge.decrypt(rpcrypt: rpcrypt, counter: 0, data: encrypted)
        
        // Then original data should be restored
        XCTAssertEqual(decrypted, originalData)
    }
    
    func testEncryptDecrypt_Roundtrip_Success() throws {
        // Given test data
        let rpcrypt = try bridge.initRPCryptRegistration(
            target: .ps5_1,
            ambassador: validAmbassador,
            keyOffset: 0,
            pin: 12345678
        )
        
        let testCases = [
            "Short",
            "Medium length test string",
            String(repeating: "A", count: 1000)
        ]
        
        for (index, testString) in testCases.enumerated() {
            let originalData = testString.data(using: .utf8)!
            let counter = UInt64(index)
            
            // When encrypting and decrypting
            let encrypted = try bridge.encrypt(rpcrypt: rpcrypt, counter: counter, data: originalData)
            let decrypted = try bridge.decrypt(rpcrypt: rpcrypt, counter: counter, data: encrypted)
            
            // Then original should be restored
            XCTAssertEqual(decrypted, originalData, "Roundtrip failed for case \(index)")
        }
    }
    
    // MARK: - Target Conversion Tests
    
    func testTargetToC_PS5_ReturnsCorrectValue() {
        let ps5Target = ChiakiTargetSwift.ps5_1
        let cValue = bridge.targetToC(ps5Target)
        XCTAssertEqual(cValue, 1000100, "PS5_1 should convert to 1000100")
    }
    
    func testTargetToC_PS4_ReturnsCorrectValue() {
        let ps4Target = ChiakiTargetSwift.ps4_10
        let cValue = bridge.targetToC(ps4Target)
        XCTAssertEqual(cValue, 1000, "PS4_10 should convert to 1000")
    }
    
    // MARK: - ChiakiTargetSwift Tests
    
    func testChiakiTargetSwift_PS5_IsPS5ReturnsTrue() {
        XCTAssertTrue(ChiakiTargetSwift.ps5_1.isPS5)
        XCTAssertTrue(ChiakiTargetSwift.ps5Unknown.isPS5)
    }
    
    func testChiakiTargetSwift_PS4_IsPS5ReturnsFalse() {
        XCTAssertFalse(ChiakiTargetSwift.ps4_8.isPS5)
        XCTAssertFalse(ChiakiTargetSwift.ps4_9.isPS5)
        XCTAssertFalse(ChiakiTargetSwift.ps4Unknown.isPS5)
    }
    
    // MARK: - ChiakiError Tests
    
    func testChiakiError_Success_IsZero() {
        XCTAssertEqual(ChiakiError.success.rawValue, 0)
    }
    
    func testChiakiError_LocalizedDescription_ReturnsMessage() {
        let error = ChiakiError.connectionRefused
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }
    
    // MARK: - ChiakiRPCryptSwift Tests
    
    func testChiakiRPCryptSwift_Init_HasCorrectDefaults() {
        var rpcrypt = ChiakiRPCryptSwift()
        rpcrypt.target = .ps5_1
        
        XCTAssertEqual(rpcrypt.target, .ps5_1)
        XCTAssertEqual(rpcrypt.bright.count, 16)
        XCTAssertEqual(rpcrypt.ambassador.count, 16)
        XCTAssertTrue(rpcrypt.bright.allSatisfy { $0 == 0 }, "Default bright should be zeros")
        XCTAssertTrue(rpcrypt.ambassador.allSatisfy { $0 == 0 }, "Default ambassador should be zeros")
    }
    
    // MARK: - ChiakiRegisteredHostSwift Tests
    
    func testChiakiRegisteredHostSwift_Init_SetsProperties() {
        let host = ChiakiRegisteredHostSwift(
            target: .ps5_1,
            apSSID: "TestSSID",
            apBSSID: "TestBSSID",
            apKey: "TestKey",
            apName: "TestName",
            serverMAC: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06],
            serverNickname: "PlayStation 5",
            rpRegistKey: [UInt8](repeating: 0, count: 16),
            rpKey: [UInt8](repeating: 0, count: 16)
        )
        
        XCTAssertEqual(host.target, .ps5_1)
        XCTAssertEqual(host.apSSID, "TestSSID")
        XCTAssertEqual(host.serverNickname, "PlayStation 5")
    }
}
