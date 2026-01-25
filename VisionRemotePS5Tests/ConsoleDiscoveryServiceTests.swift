//
//  ConsoleDiscoveryServiceTests.swift
//  VisionRemotePS5Tests
//
//  Unit tests for ConsoleDiscoveryService
//

import XCTest
@testable import VisionRemotePS5

final class ConsoleDiscoveryServiceTests: XCTestCase {
    
    // MARK: - Test Properties
    
    private var discoveryService: ConsoleDiscoveryService!
    
    // MARK: - Setup & Teardown
    
    @MainActor
    override func setUpWithError() throws {
        try super.setUpWithError()
        discoveryService = ConsoleDiscoveryService()
    }
    
    @MainActor
    override func tearDownWithError() throws {
        discoveryService?.stopDiscovery()
        discoveryService = nil
        try super.tearDownWithError()
    }
    
    // MARK: - Initial State Tests
    
    @MainActor
    func testInitialState_NoConsolesDiscovered() {
        // Given a fresh service
        // Then no consoles should be discovered
        XCTAssertTrue(discoveryService.discoveredConsoles.isEmpty)
        XCTAssertEqual(discoveryService.state, .idle)
        XCTAssertFalse(discoveryService.isSearching)
    }
    
    @MainActor
    func testInitialState_EmptyStatusMessage() {
        // Given a fresh service
        // Then status message should be empty
        XCTAssertTrue(discoveryService.statusMessage.isEmpty)
    }
    
    // MARK: - Discovery State Tests
    
    @MainActor
    func testStartDiscovery_SetsSearchingState() async throws {
        // When starting discovery
        discoveryService.startDiscovery()
        
        // Then state should be searching
        XCTAssertEqual(discoveryService.state, .searching)
        XCTAssertTrue(discoveryService.isSearching)
        
        // And status message should be set
        XCTAssertFalse(discoveryService.statusMessage.isEmpty)
        
        // Cleanup
        discoveryService.stopDiscovery()
    }
    
    @MainActor
    func testStopDiscovery_SetsIdleState() async throws {
        // Given a searching service
        discoveryService.startDiscovery()
        
        // When stopping discovery
        discoveryService.stopDiscovery()
        
        // Then state should be idle
        XCTAssertEqual(discoveryService.state, .idle)
        XCTAssertFalse(discoveryService.isSearching)
    }
    
    @MainActor
    func testStartDiscovery_WhenAlreadySearching_DoesNotRestart() async throws {
        // Given a searching service
        discoveryService.startDiscovery()
        let initialState = discoveryService.state
        
        // When trying to start again
        discoveryService.startDiscovery()
        
        // Then state should remain the same
        XCTAssertEqual(discoveryService.state, initialState)
        
        // Cleanup
        discoveryService.stopDiscovery()
    }
    
    // MARK: - Clear Cache Tests
    
    @MainActor
    func testClearCache_RemovesAllConsoles() async throws {
        // Given a service with a manually added console
        discoveryService.addConsoleManually(name: "Test PS5", ipAddress: "192.168.1.100")
        XCTAssertFalse(discoveryService.discoveredConsoles.isEmpty)
        
        // When clearing cache
        discoveryService.clearCache()
        
        // Then consoles should be empty
        XCTAssertTrue(discoveryService.discoveredConsoles.isEmpty)
        XCTAssertEqual(discoveryService.state, .idle)
    }
    
    @MainActor
    func testClearCache_ClearsStatusMessage() async throws {
        // Given a service with status message
        discoveryService.startDiscovery()
        XCTAssertFalse(discoveryService.statusMessage.isEmpty)
        
        // When clearing cache
        discoveryService.clearCache()
        
        // Then status message should be empty
        XCTAssertTrue(discoveryService.statusMessage.isEmpty)
    }
    
    // MARK: - Manual Console Addition Tests
    
    @MainActor
    func testAddConsoleManually_AddsConsole() {
        // Given a fresh service
        XCTAssertTrue(discoveryService.discoveredConsoles.isEmpty)
        
        // When adding a console manually
        discoveryService.addConsoleManually(name: "Test PS5", ipAddress: "192.168.1.100")
        
        // Then console should be added
        XCTAssertEqual(discoveryService.discoveredConsoles.count, 1)
        XCTAssertEqual(discoveryService.discoveredConsoles.first?.name, "Test PS5")
        XCTAssertEqual(discoveryService.discoveredConsoles.first?.ipAddress, "192.168.1.100")
    }
    
    @MainActor
    func testAddConsoleManually_DuplicateIP_DoesNotAdd() {
        // Given a service with one console
        discoveryService.addConsoleManually(name: "First PS5", ipAddress: "192.168.1.100")
        
        // When adding another console with same IP
        discoveryService.addConsoleManually(name: "Second PS5", ipAddress: "192.168.1.100")
        
        // Then only one console should exist
        XCTAssertEqual(discoveryService.discoveredConsoles.count, 1)
        XCTAssertEqual(discoveryService.discoveredConsoles.first?.name, "First PS5")
    }
    
    @MainActor
    func testAddConsoleManually_DifferentIPs_AddsBoth() {
        // When adding consoles with different IPs
        discoveryService.addConsoleManually(name: "PS5 #1", ipAddress: "192.168.1.100")
        discoveryService.addConsoleManually(name: "PS5 #2", ipAddress: "192.168.1.101")
        
        // Then both should be added
        XCTAssertEqual(discoveryService.discoveredConsoles.count, 2)
    }
    
    @MainActor
    func testAddConsoleManually_SetsDefaultType() {
        // When adding a console
        discoveryService.addConsoleManually(name: "Test PS5", ipAddress: "192.168.1.100")
        
        // Then type should be PS5 and status online
        let console = discoveryService.discoveredConsoles.first
        XCTAssertEqual(console?.type, .ps5)
        XCTAssertEqual(console?.status, .online)
    }
}

// MARK: - Discovery State Tests

final class DiscoveryStateTests: XCTestCase {
    
    func testDiscoveryState_Equatable() {
        // Given same states
        XCTAssertEqual(DiscoveryState.idle, DiscoveryState.idle)
        XCTAssertEqual(DiscoveryState.searching, DiscoveryState.searching)
        XCTAssertEqual(DiscoveryState.completed(count: 2), DiscoveryState.completed(count: 2))
        XCTAssertEqual(DiscoveryState.error("test"), DiscoveryState.error("test"))
        
        // Given different states
        XCTAssertNotEqual(DiscoveryState.idle, DiscoveryState.searching)
        XCTAssertNotEqual(DiscoveryState.completed(count: 1), DiscoveryState.completed(count: 2))
        XCTAssertNotEqual(DiscoveryState.error("a"), DiscoveryState.error("b"))
    }
}

// MARK: - Console Model Integration Tests

final class ConsoleDiscoveryIntegrationTests: XCTestCase {
    
    func testConsoleModel_HasRequiredFields() {
        // Given a console
        let console = Console(
            name: "Discovered PS5",
            ipAddress: "192.168.1.100",
            macAddress: "AA:BB:CC:DD:EE:FF",
            type: .ps5,
            status: .online
        )
        
        // Then all required fields should be set
        XCTAssertFalse(console.name.isEmpty)
        XCTAssertFalse(console.ipAddress.isEmpty)
        XCTAssertFalse(console.macAddress.isEmpty)
        XCTAssertEqual(console.type, .ps5)
        XCTAssertEqual(console.status, .online)
    }
    
    func testConsoleType_AllCasesExist() {
        // Then all console types should be accessible
        let types: [Console.ConsoleType] = [.ps5, .ps5Digital, .ps4, .ps4Pro]
        XCTAssertEqual(types.count, 4)
    }
    
    func testConsoleStatus_AllCasesExist() {
        // Then all console statuses should be accessible
        let statuses: [Console.ConsoleStatus] = [.online, .standby, .offline]
        XCTAssertEqual(statuses.count, 3)
    }
}
