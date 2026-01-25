//
//  ChiakiCryptoTests.swift
//  VisionRemotePS5Tests
//
//  Unit tests for ChiakiCrypto cryptographic operations
//

import XCTest
@testable import VisionRemotePS5

final class ChiakiCryptoTests: XCTestCase {
    
    // MARK: - Test Properties
    
    private var validAmbassador: Data!
    private var validPIN: UInt32!
    
    // MARK: - Setup & Teardown
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        // Create a valid 16-byte ambassador for testing
        validAmbassador = Data([
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10
        ])
        validPIN = 12345678
    }
    
    override func tearDownWithError() throws {
        validAmbassador = nil
        validPIN = nil
        try super.tearDownWithError()
    }
    
    // MARK: - RPCrypt Initialization Tests
    
    func testInitRegistration_ValidInput_ReturnsRPCrypt() throws {
        // Given valid ambassador and PIN
        // When initializing registration
        let rpcrypt = try ChiakiCrypto.initRegistration(
            ambassador: validAmbassador,
            pin: validPIN,
            keyOffset: 0
        )
        
        // Then RPCrypt should have valid bright and ambassador keys
        XCTAssertEqual(rpcrypt.bright.count, ChiakiCrypto.keySize, "Bright key should be 16 bytes")
        XCTAssertEqual(rpcrypt.ambassador.count, ChiakiCrypto.keySize, "Ambassador should be 16 bytes")
        XCTAssertFalse(rpcrypt.bright.allSatisfy { $0 == 0 }, "Bright key should not be all zeros")
    }
    
    func testInitRegistration_InvalidKeyOffset_Throws() {
        // Given an invalid key offset (>= 0x20)
        let invalidKeyOffset = 0x20
        
        // When initializing registration
        // Then it should throw an error
        XCTAssertThrowsError(
            try ChiakiCrypto.initRegistration(
                ambassador: validAmbassador,
                pin: validPIN,
                keyOffset: invalidKeyOffset
            )
        ) { error in
            XCTAssertTrue(error is ChiakiError, "Should throw ChiakiError")
        }
    }
    
    func testInitRegistration_DifferentKeyOffsets_ProduceDifferentKeys() throws {
        // Given different key offsets
        let rpcrypt0 = try ChiakiCrypto.initRegistration(
            ambassador: validAmbassador,
            pin: validPIN,
            keyOffset: 0
        )
        
        let rpcrypt1 = try ChiakiCrypto.initRegistration(
            ambassador: validAmbassador,
            pin: validPIN,
            keyOffset: 1
        )
        
        // Then the bright keys should be different
        XCTAssertNotEqual(rpcrypt0.bright, rpcrypt1.bright, "Different key offsets should produce different keys")
    }
    
    // MARK: - IV Generation Tests
    
    func testGenerateIV_ReturnsCorrect16Bytes() throws {
        // Given an initialized RPCrypt
        let rpcrypt = try ChiakiCrypto.initRegistration(
            ambassador: validAmbassador,
            pin: validPIN,
            keyOffset: 0
        )
        
        // When generating IV
        let iv = ChiakiCrypto.generateIV(rpcrypt: rpcrypt, counter: 0)
        
        // Then IV should be 16 bytes
        XCTAssertEqual(iv.count, 16, "IV should be 16 bytes")
    }
    
    func testGenerateIV_DifferentCounters_ProduceDifferentIVs() throws {
        // Given an initialized RPCrypt
        let rpcrypt = try ChiakiCrypto.initRegistration(
            ambassador: validAmbassador,
            pin: validPIN,
            keyOffset: 0
        )
        
        // When generating IVs with different counters
        let iv0 = ChiakiCrypto.generateIV(rpcrypt: rpcrypt, counter: 0)
        let iv1 = ChiakiCrypto.generateIV(rpcrypt: rpcrypt, counter: 1)
        
        // Then IVs should be different
        XCTAssertNotEqual(iv0, iv1, "Different counters should produce different IVs")
    }
    
    func testGenerateIV_SameCounter_ProducesSameIV() throws {
        // Given an initialized RPCrypt
        let rpcrypt = try ChiakiCrypto.initRegistration(
            ambassador: validAmbassador,
            pin: validPIN,
            keyOffset: 0
        )
        
        // When generating IVs with the same counter
        let iv1 = ChiakiCrypto.generateIV(rpcrypt: rpcrypt, counter: 42)
        let iv2 = ChiakiCrypto.generateIV(rpcrypt: rpcrypt, counter: 42)
        
        // Then IVs should be identical
        XCTAssertEqual(iv1, iv2, "Same counter should produce same IV")
    }
    
    // MARK: - Encryption Tests
    
    func testEncrypt_ValidData_ReturnsEncryptedData() throws {
        // Given an initialized RPCrypt and test data
        let rpcrypt = try ChiakiCrypto.initRegistration(
            ambassador: validAmbassador,
            pin: validPIN,
            keyOffset: 0
        )
        let testData = "Hello, PlayStation!".data(using: .utf8)!
        
        // When encrypting
        let encrypted = try ChiakiCrypto.encrypt(rpcrypt: rpcrypt, counter: 0, data: testData)
        
        // Then encrypted data should be returned
        XCTAssertEqual(encrypted.count, testData.count, "Encrypted data should have same length as input (CFB mode)")
        XCTAssertNotEqual(encrypted, testData, "Encrypted data should differ from original")
    }
    
    func testEncrypt_EmptyData_ReturnsEmptyData() throws {
        // Given an initialized RPCrypt and empty data
        let rpcrypt = try ChiakiCrypto.initRegistration(
            ambassador: validAmbassador,
            pin: validPIN,
            keyOffset: 0
        )
        let emptyData = Data()
        
        // When encrypting empty data
        let encrypted = try ChiakiCrypto.encrypt(rpcrypt: rpcrypt, counter: 0, data: emptyData)
        
        // Then result should be empty
        XCTAssertTrue(encrypted.isEmpty, "Encrypting empty data should return empty data")
    }
    
    // MARK: - Decryption Tests
    
    func testDecrypt_ValidData_ReturnsOriginalData() throws {
        // Given an initialized RPCrypt and encrypted data
        let rpcrypt = try ChiakiCrypto.initRegistration(
            ambassador: validAmbassador,
            pin: validPIN,
            keyOffset: 0
        )
        let originalData = "Test decryption works correctly!".data(using: .utf8)!
        let encrypted = try ChiakiCrypto.encrypt(rpcrypt: rpcrypt, counter: 0, data: originalData)
        
        // When decrypting
        let decrypted = try ChiakiCrypto.decrypt(rpcrypt: rpcrypt, counter: 0, data: encrypted)
        
        // Then original data should be restored
        XCTAssertEqual(decrypted, originalData, "Decrypted data should match original")
    }
    
    // MARK: - Roundtrip Tests
    
    func testEncryptDecrypt_Roundtrip_Success() throws {
        // Given various test data
        let testCases: [Data] = [
            "Short".data(using: .utf8)!,
            "This is a medium length test string for encryption".data(using: .utf8)!,
            Data(repeating: 0xAB, count: 256),
            Data(repeating: 0x00, count: 16),
            Data((0..<128).map { UInt8($0) })
        ]
        
        let rpcrypt = try ChiakiCrypto.initRegistration(
            ambassador: validAmbassador,
            pin: validPIN,
            keyOffset: 0
        )
        
        // When encrypting and decrypting each test case
        for (index, originalData) in testCases.enumerated() {
            let counter = UInt64(index)
            let encrypted = try ChiakiCrypto.encrypt(rpcrypt: rpcrypt, counter: counter, data: originalData)
            let decrypted = try ChiakiCrypto.decrypt(rpcrypt: rpcrypt, counter: counter, data: encrypted)
            
            // Then original data should be restored
            XCTAssertEqual(decrypted, originalData, "Roundtrip failed for test case \(index)")
        }
    }
    
    func testEncryptDecrypt_WrongCounter_FailsToRestore() throws {
        // Given encrypted data
        let rpcrypt = try ChiakiCrypto.initRegistration(
            ambassador: validAmbassador,
            pin: validPIN,
            keyOffset: 0
        )
        let originalData = "Secret message".data(using: .utf8)!
        let encrypted = try ChiakiCrypto.encrypt(rpcrypt: rpcrypt, counter: 0, data: originalData)
        
        // When decrypting with wrong counter
        let decrypted = try ChiakiCrypto.decrypt(rpcrypt: rpcrypt, counter: 1, data: encrypted)
        
        // Then data should NOT be restored correctly
        XCTAssertNotEqual(decrypted, originalData, "Wrong counter should produce incorrect decryption")
    }
    
    // MARK: - Key Derivation Tests
    
    func testDeriveKey_DifferentPINs_ProduceDifferentKeys() throws {
        // Given different PINs
        let rpcrypt1 = try ChiakiCrypto.initRegistration(
            ambassador: validAmbassador,
            pin: 12345678,
            keyOffset: 0
        )
        
        let rpcrypt2 = try ChiakiCrypto.initRegistration(
            ambassador: validAmbassador,
            pin: 87654321,
            keyOffset: 0
        )
        
        // Then bright keys should be different
        XCTAssertNotEqual(rpcrypt1.bright, rpcrypt2.bright, "Different PINs should produce different keys")
    }
    
    func testDeriveKey_DifferentAmbassadors_ProduceDifferentKeys() throws {
        // Given different ambassadors
        let ambassador1 = Data(repeating: 0x11, count: 16)
        let ambassador2 = Data(repeating: 0x22, count: 16)
        
        let rpcrypt1 = try ChiakiCrypto.initRegistration(
            ambassador: ambassador1,
            pin: validPIN,
            keyOffset: 0
        )
        
        let rpcrypt2 = try ChiakiCrypto.initRegistration(
            ambassador: ambassador2,
            pin: validPIN,
            keyOffset: 0
        )
        
        // Then bright keys should be different
        XCTAssertNotEqual(rpcrypt1.bright, rpcrypt2.bright, "Different ambassadors should produce different keys")
    }
    
    // MARK: - Constants Tests
    
    func testKeySize_Is16() {
        XCTAssertEqual(ChiakiCrypto.keySize, 16, "Key size should be 16 bytes")
    }
    
    func testPS5Keys0_HasCorrectLength() {
        // PS5 key table should have 512 entries (indexed as i*0x20 + key_off where i=0..15, key_off=0..31)
        XCTAssertEqual(ChiakiCrypto.ps5Keys0.count, 512, "PS5 keys0 table should have 512 entries")
    }
    
    func testPS5Keys1_HasCorrectLength() {
        // PS5 key table should have 512 entries (indexed as i*0x20 + key_off where i=0..15, key_off=0..31)
        XCTAssertEqual(ChiakiCrypto.ps5Keys1.count, 512, "PS5 keys1 table should have 512 entries")
    }
}
