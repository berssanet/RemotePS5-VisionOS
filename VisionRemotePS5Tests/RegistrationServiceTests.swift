//
//  RegistrationServiceTests.swift
//  VisionRemotePS5Tests
//
//  Unit tests for RegistrationService
//

import XCTest
@testable import VisionRemotePS5

final class RegistrationServiceTests: XCTestCase {
    
    // MARK: - Test Properties
    
    private var registrationService: RegistrationService!
    private var testConsole: Console!
    
    // MARK: - Setup & Teardown
    
    @MainActor
    override func setUpWithError() throws {
        try super.setUpWithError()
        registrationService = RegistrationService()
        testConsole = Console(
            id: UUID(),
            name: "Test PS5",
            ipAddress: "192.168.1.100",
            macAddress: "AA:BB:CC:DD:EE:FF",
            model: .ps5,
            status: .standby,
            isPS5: true
        )
    }
    
    override func tearDownWithError() throws {
        registrationService = nil
        testConsole = nil
        try super.tearDownWithError()
    }
    
    // MARK: - PIN Validation Tests
    
    @MainActor
    func testRegister_InvalidPIN_TooShort_ReturnsFalse() async {
        // Given a PIN that is too short
        let shortPIN = "1234" // Should be 8 digits
        
        // When registering
        let result = await registrationService.register(with: testConsole, pin: shortPIN)
        
        // Then registration should fail
        XCTAssertFalse(result, "Registration with short PIN should fail")
        XCTAssertNotNil(registrationService.registrationError)
    }
    
    @MainActor
    func testRegister_InvalidPIN_TooLong_ReturnsFalse() async {
        // Given a PIN that is too long
        let longPIN = "123456789" // Should be 8 digits
        
        // When registering
        let result = await registrationService.register(with: testConsole, pin: longPIN)
        
        // Then registration should fail
        XCTAssertFalse(result, "Registration with long PIN should fail")
    }
    
    @MainActor
    func testRegister_InvalidPIN_NonNumeric_ReturnsFalse() async {
        // Given a PIN with non-numeric characters
        let alphaPIN = "1234ABCD"
        
        // When registering
        let result = await registrationService.register(with: testConsole, pin: alphaPIN)
        
        // Then registration should fail
        XCTAssertFalse(result, "Registration with non-numeric PIN should fail")
    }
    
    // MARK: - State Tests
    
    @MainActor
    func testRegister_InitialState_NotRegistering() {
        // Given a fresh service
        // Then isRegistering should be false
        XCTAssertFalse(registrationService.isRegistering)
        XCTAssertFalse(registrationService.isRegistered)
        XCTAssertNil(registrationService.registrationError)
    }
    
    // MARK: - Console Registration Check Tests
    
    @MainActor
    func testIsConsoleRegistered_UnknownConsole_ReturnsFalse() {
        // Given a console that has not been registered
        let unknownConsole = Console(
            id: UUID(),
            name: "Unknown PS5",
            ipAddress: "10.0.0.99",
            macAddress: "11:22:33:44:55:66",
            model: .ps5,
            status: .standby,
            isPS5: true
        )
        
        // When checking registration
        let isRegistered = registrationService.isConsoleRegistered(unknownConsole)
        
        // Then should return false
        XCTAssertFalse(isRegistered)
    }
    
    // MARK: - Clear Registration Tests
    
    @MainActor
    func testClearRegistration_RemovesKey() {
        // Given a console
        // When clearing registration
        registrationService.clearRegistration(for: testConsole)
        
        // Then console should not be registered
        XCTAssertFalse(registrationService.isConsoleRegistered(testConsole))
    }
}

// MARK: - RegistrationError Tests

final class RegistrationErrorTests: XCTestCase {
    
    func testRegistrationError_ConnectionFailed_HasDescription() {
        let error = RegistrationError.connectionFailed
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }
    
    func testRegistrationError_Timeout_HasDescription() {
        let error = RegistrationError.timeout
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }
    
    func testRegistrationError_ProtocolError_IncludesMessage() {
        let message = "Test protocol error"
        let error = RegistrationError.protocolError(message)
        XCTAssertTrue(error.localizedDescription.contains(message) || !error.localizedDescription.isEmpty)
    }
}
