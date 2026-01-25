//
//  ConsoleTests.swift
//  VisionRemotePS5Tests
//
//  Unit tests for Console model
//

import XCTest
@testable import VisionRemotePS5

final class ConsoleTests: XCTestCase {
    
    // MARK: - Initialization Tests
    
    func testConsoleInit_SetsPropertiesCorrectly() {
        // Given console properties
        let id = UUID()
        let name = "My PlayStation 5"
        let ipAddress = "192.168.1.100"
        let macAddress = "AA:BB:CC:DD:EE:FF"
        let model = ConsoleModel.ps5
        let status = ConsoleStatus.awake
        
        // When creating console
        let console = Console(
            id: id,
            name: name,
            ipAddress: ipAddress,
            macAddress: macAddress,
            model: model,
            status: status,
            isPS5: true
        )
        
        // Then properties should be set correctly
        XCTAssertEqual(console.id, id)
        XCTAssertEqual(console.name, name)
        XCTAssertEqual(console.ipAddress, ipAddress)
        XCTAssertEqual(console.macAddress, macAddress)
        XCTAssertEqual(console.model, model)
        XCTAssertEqual(console.status, status)
        XCTAssertTrue(console.isPS5)
    }
    
    func testConsole_PS4_IsPS5ReturnsFalse() {
        // Given a PS4 console
        let console = Console(
            id: UUID(),
            name: "PlayStation 4",
            ipAddress: "192.168.1.101",
            macAddress: "11:22:33:44:55:66",
            model: .ps4,
            status: .awake,
            isPS5: false
        )
        
        // Then isPS5 should be false
        XCTAssertFalse(console.isPS5)
    }
    
    // MARK: - Codable Tests
    
    func testConsoleCodable_EncodesDecodesCorrectly() throws {
        // Given a console
        let originalConsole = Console(
            id: UUID(),
            name: "Test Console",
            ipAddress: "10.0.0.50",
            macAddress: "AA:BB:CC:DD:EE:FF",
            model: .ps5,
            status: .standby,
            isPS5: true
        )
        
        // When encoding and decoding
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalConsole)
        
        let decoder = JSONDecoder()
        let decodedConsole = try decoder.decode(Console.self, from: data)
        
        // Then decoded console should match original
        XCTAssertEqual(decodedConsole.id, originalConsole.id)
        XCTAssertEqual(decodedConsole.name, originalConsole.name)
        XCTAssertEqual(decodedConsole.ipAddress, originalConsole.ipAddress)
        XCTAssertEqual(decodedConsole.macAddress, originalConsole.macAddress)
        XCTAssertEqual(decodedConsole.model, originalConsole.model)
        XCTAssertEqual(decodedConsole.status, originalConsole.status)
        XCTAssertEqual(decodedConsole.isPS5, originalConsole.isPS5)
    }
    
    func testConsoleArray_EncodesDecodesCorrectly() throws {
        // Given multiple consoles
        let consoles = [
            Console(id: UUID(), name: "PS5-1", ipAddress: "192.168.1.10", macAddress: "AA:AA:AA:AA:AA:AA", model: .ps5, status: .awake, isPS5: true),
            Console(id: UUID(), name: "PS5-2", ipAddress: "192.168.1.11", macAddress: "BB:BB:BB:BB:BB:BB", model: .ps5, status: .standby, isPS5: true),
            Console(id: UUID(), name: "PS4", ipAddress: "192.168.1.12", macAddress: "CC:CC:CC:CC:CC:CC", model: .ps4, status: .awake, isPS5: false)
        ]
        
        // When encoding and decoding
        let data = try JSONEncoder().encode(consoles)
        let decoded = try JSONDecoder().decode([Console].self, from: data)
        
        // Then count should match
        XCTAssertEqual(decoded.count, consoles.count)
    }
    
    // MARK: - Equatable Tests
    
    func testConsoleEquatable_SameID_ReturnsTrue() {
        // Given two consoles with same ID
        let id = UUID()
        let console1 = Console(id: id, name: "Console 1", ipAddress: "192.168.1.1", macAddress: "AA:AA:AA:AA:AA:AA", model: .ps5, status: .awake, isPS5: true)
        let console2 = Console(id: id, name: "Console 2", ipAddress: "192.168.1.2", macAddress: "BB:BB:BB:BB:BB:BB", model: .ps5, status: .standby, isPS5: true)
        
        // Then they should be equal (assuming equality is based on ID)
        XCTAssertEqual(console1.id, console2.id)
    }
    
    func testConsoleEquatable_DifferentID_ReturnsFalse() {
        // Given two consoles with different IDs
        let console1 = Console(id: UUID(), name: "Console", ipAddress: "192.168.1.1", macAddress: "AA:AA:AA:AA:AA:AA", model: .ps5, status: .awake, isPS5: true)
        let console2 = Console(id: UUID(), name: "Console", ipAddress: "192.168.1.1", macAddress: "AA:AA:AA:AA:AA:AA", model: .ps5, status: .awake, isPS5: true)
        
        // Then they should not be equal
        XCTAssertNotEqual(console1.id, console2.id)
    }
    
    // MARK: - Hashable Tests
    
    func testConsoleHashable_CanBeUsedInSet() {
        // Given consoles
        let console1 = Console(id: UUID(), name: "PS5-1", ipAddress: "192.168.1.10", macAddress: "AA:AA:AA:AA:AA:AA", model: .ps5, status: .awake, isPS5: true)
        let console2 = Console(id: UUID(), name: "PS5-2", ipAddress: "192.168.1.11", macAddress: "BB:BB:BB:BB:BB:BB", model: .ps5, status: .standby, isPS5: true)
        
        // When adding to set
        var consoleSet = Set<Console>()
        consoleSet.insert(console1)
        consoleSet.insert(console2)
        
        // Then both should be in set
        XCTAssertEqual(consoleSet.count, 2)
    }
    
    func testConsoleHashable_DuplicateNotAdded() {
        // Given same console
        let id = UUID()
        let console1 = Console(id: id, name: "PS5", ipAddress: "192.168.1.10", macAddress: "AA:AA:AA:AA:AA:AA", model: .ps5, status: .awake, isPS5: true)
        let console2 = Console(id: id, name: "PS5", ipAddress: "192.168.1.10", macAddress: "AA:AA:AA:AA:AA:AA", model: .ps5, status: .awake, isPS5: true)
        
        // When adding to set
        var consoleSet = Set<Console>()
        consoleSet.insert(console1)
        consoleSet.insert(console2)
        
        // Then only one should be in set
        XCTAssertEqual(consoleSet.count, 1)
    }
}

// MARK: - ConsoleModel Tests

final class ConsoleModelTests: XCTestCase {
    
    func testConsoleModel_PS5_RawValue() {
        XCTAssertEqual(ConsoleModel.ps5.rawValue, "ps5")
    }
    
    func testConsoleModel_PS4_RawValue() {
        XCTAssertEqual(ConsoleModel.ps4.rawValue, "ps4")
    }
}

// MARK: - ConsoleStatus Tests

final class ConsoleStatusTests: XCTestCase {
    
    func testConsoleStatus_Awake() {
        let status = ConsoleStatus.awake
        XCTAssertEqual(status.rawValue, "awake")
    }
    
    func testConsoleStatus_Standby() {
        let status = ConsoleStatus.standby
        XCTAssertEqual(status.rawValue, "standby")
    }
}
