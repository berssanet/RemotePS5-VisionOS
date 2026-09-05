import XCTest
@testable import VisionRemotePS5

final class LocalConsoleConnectionTests: XCTestCase {
    func testLocalAddressValidationIsSharedWithPairing() {
        XCTAssertEqual(LocalConsoleConnectionService.normalizedAddress(" 192.0.2.33\n"), "192.0.2.33")
        XCTAssertNil(LocalConsoleConnectionService.normalizedAddress("192..0.2.33"))
        XCTAssertNil(LocalConsoleConnectionService.normalizedAddress("192.0.2.33:9295"))
        XCTAssertNil(LocalConsoleConnectionService.normalizedAddress("localhost"))
        XCTAssertNil(LocalConsoleConnectionService.normalizedAddress("::1"))
    }

    private func discovered() -> Console {
        Console(name: "Test PS5", ipAddress: "192.0.2.33", macAddress: "021122334455", status: .online)
    }

    private func registered() -> Console {
        Console(name: "Previous name", ipAddress: "192.0.2.10", type: .ps5, status: .offline,
                isPaired: true, rpKey: Data(repeating: 1, count: 16), registKey: "3132333435363738",
                serverMAC: [2, 17, 34, 51, 68, 85], psnAccountId: Data(repeating: 2, count: 8))
    }

    func testMatchingHardwareReusesRegistrationAtNewAddress() throws {
        let saved = registered()
        let result = try XCTUnwrap(LocalConsoleConnectionService.registeredConsole(
            for: discovered(), among: [saved], accountID: saved.psnAccountId))
        XCTAssertEqual(result.id, saved.id)
        XCTAssertEqual(result.ipAddress, discovered().ipAddress)
        XCTAssertEqual(result.name, discovered().name)
        XCTAssertEqual(result.rpKey, saved.rpKey)
        XCTAssertEqual(result.registKey, saved.registKey)
        XCTAssertEqual(result.status, .online)
        XCTAssertEqual(saved.ipAddress, "192.0.2.10")
    }

    func testExplicitLocalConnectionDoesNotReusePSNTransport() throws {
        var saved = registered()
        saved.psnDeviceID = Data(repeating: 3, count: 32)
        let local = try XCTUnwrap(LocalConsoleConnectionService.registeredConsole(
            for: discovered(), among: [saved], accountID: saved.psnAccountId))
        XCTAssertNil(local.psnDeviceID)
        XCTAssertEqual(local.rpKey, saved.rpKey)
        XCTAssertEqual(local.registKey, saved.registKey)
        XCTAssertNotNil(saved.psnDeviceID)
    }

    func testPSNRouteSurvivesWindowValueEncodingWithoutPairingKeys() throws {
        let console = Console(name: "Remote PS5", ipAddress: "",
                              psnAccountId: Data(repeating: 2, count: 8),
                              psnDeviceID: Data(repeating: 3, count: 32))
        let decoded = try JSONDecoder().decode(Console.self, from: JSONEncoder().encode(console))
        XCTAssertEqual(decoded, console)
        XCTAssertFalse(LocalConsoleConnectionService.hasRegistration(decoded))
    }

    func testExistingLocalConsoleDecodesWithoutPSNDeviceID() throws {
        let data = try JSONEncoder().encode(registered())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["psnDeviceID"])
        let console = try JSONDecoder().decode(Console.self, from: data)
        XCTAssertNil(console.psnDeviceID)
        XCTAssertTrue(LocalConsoleConnectionService.hasRegistration(console))
    }

    func testPSNStreamingDoesNotRequireLocalRegistrationKeys() {
        var config = StreamingConfiguration(host: "", rpKey: Data(), registKey: "",
                                            psnAccountID: Data(repeating: 2, count: 8), isPS5: true,
                                            width: 1920, height: 1080, fps: 60, bitrate: 15000)
        XCTAssertFalse(config.hasValidCredentials)
        config.psnConnection = PSNStreamingConnection(token: "test-token", deviceID: Data(repeating: 3, count: 32))
        XCTAssertTrue(config.hasValidCredentials)
        config.psnConnection = PSNStreamingConnection(token: "", deviceID: Data(repeating: 3, count: 32))
        XCTAssertFalse(config.hasValidCredentials)
        config.psnConnection = PSNStreamingConnection(token: "test-token", deviceID: Data(repeating: 3, count: 31))
        XCTAssertFalse(config.hasValidCredentials)
    }

    func testPSNStreamingRejectsMissingAccountEvenWithLANKeys() {
        let config = StreamingConfiguration(
            host: "192.0.2.33", rpKey: Data(repeating: 1, count: 16), registKey: "3132333435363738",
            psnAccountID: Data(), isPS5: true, width: 1920, height: 1080, fps: 60, bitrate: 15000,
            psnConnection: PSNStreamingConnection(token: "test-token", deviceID: Data(repeating: 3, count: 32)))
        XCTAssertFalse(config.hasValidCredentials)
    }

    func testSameAddressAndNameDoNotAuthorizeDifferentHardware() {
        var saved = registered()
        saved.ipAddress = discovered().ipAddress
        saved.name = discovered().name
        saved.serverMAC = [2, 17, 34, 51, 68, 86]
        XCTAssertNil(LocalConsoleConnectionService.registeredConsole(for: discovered(), among: [saved], accountID: nil))
    }

    func testDifferentSignedInAccountRequiresPairing() {
        XCTAssertNil(LocalConsoleConnectionService.registeredConsole(
            for: discovered(), among: [registered()], accountID: Data(repeating: 3, count: 8)))
    }

    func testStoredRegistrationCanReconnectWithoutPSNSignIn() {
        XCTAssertNotNil(LocalConsoleConnectionService.registeredConsole(
            for: discovered(), among: [registered()], accountID: nil))
    }

    func testRegisteredStandbyConsoleCanUseExistingStreamingWakeup() throws {
        var console = discovered()
        console.status = .standby
        let result = try XCTUnwrap(LocalConsoleConnectionService.registeredConsole(
            for: console, among: [registered()], accountID: nil))
        XCTAssertEqual(result.status, .standby)
    }

    func testMissingHardwareIdentityDoesNotMatchByAddress() {
        var console = discovered()
        console.macAddress = ""
        XCTAssertNil(LocalConsoleConnectionService.registeredConsole(for: console, among: [registered()], accountID: nil))
    }

    func testTextMACNormalizationAndConsoleFamily() {
        var saved = registered()
        saved.serverMAC = nil
        saved.macAddress = "02:11:22:33:44:55"
        saved.type = .ps5Digital
        XCTAssertNotNil(LocalConsoleConnectionService.registeredConsole(for: discovered(), among: [saved], accountID: nil))
        saved.type = .ps4
        XCTAssertNil(LocalConsoleConnectionService.registeredConsole(for: discovered(), among: [saved], accountID: nil))
    }

    func testInvalidRegistrationIsNeverUsedForStreaming() {
        var console = registered()
        XCTAssertTrue(LocalConsoleConnectionService.hasRegistration(console))
        for key in ["", "1", "not-a-key", String(repeating: "a", count: 34)] {
            console.registKey = key
            XCTAssertFalse(LocalConsoleConnectionService.hasRegistration(console))
        }
        console = registered()
        console.rpKey = Data(repeating: 1, count: 15)
        XCTAssertFalse(LocalConsoleConnectionService.hasRegistration(console))
        console = registered()
        console.psnAccountId = nil
        XCTAssertFalse(LocalConsoleConnectionService.hasRegistration(console))
        console = registered()
        console.isPaired = false
        XCTAssertFalse(LocalConsoleConnectionService.hasRegistration(console))
    }

    @MainActor
    func testLocalConnectionReturnsStreamingWithoutPSNRequests() async throws {
        let console = discovered()
        let saved = registered()
        var requestedAddresses: [String] = []
        let service = LocalConsoleConnectionService(discover: { host in
            requestedAddresses.append(host)
            return console
        }, registeredConsoles: { [saved] })
        let route = try await service.connect(to: " 192.0.2.33 \n", accountID: saved.psnAccountId)
        guard case .streaming(let result) = route else { return XCTFail("Expected direct LAN streaming") }
        XCTAssertEqual(result.id, saved.id)
        XCTAssertEqual(requestedAddresses, ["192.0.2.33"])
        XCTAssertFalse(service.isChecking)
    }

    @MainActor
    func testFirstLocalConnectionReturnsPairingNotCloudRegistration() async throws {
        let console = discovered()
        let service = LocalConsoleConnectionService(discover: { _ in console }, registeredConsoles: { [] })
        let route = try await service.connect(to: console.ipAddress, accountID: nil)
        guard case .pairing(let target) = route else { return XCTFail("First connection must require this app's keys") }
        XCTAssertEqual(target, console)
        XCTAssertFalse(target.isPaired)
        XCTAssertFalse(service.isChecking)
    }

    @MainActor
    func testInvalidAddressesDoNotTriggerDiscovery() async {
        var probes = 0
        let service = LocalConsoleConnectionService(discover: { _ in probes += 1; return nil }, registeredConsoles: { [] })
        for address in ["", "http://192.0.2.33", "192.0.2.33:9295", "999.0.0.1", "127.0.0.1", "0.0.0.0", "224.0.0.1"] {
            do {
                _ = try await service.connect(to: address, accountID: nil)
                XCTFail("Invalid address must fail before discovery")
            } catch LocalConsoleConnectionError.invalidAddress {
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(probes, 0)
        XCTAssertFalse(service.isChecking)
    }

    @MainActor
    func testUnreachableConsoleDoesNotLoadKeysOrStartCloudFallback() async {
        var keyLoads = 0
        let service = LocalConsoleConnectionService(discover: { _ in nil }, registeredConsoles: { keyLoads += 1; return [] })
        do {
            _ = try await service.connect(to: discovered().ipAddress, accountID: nil)
            XCTFail("Expected unreachable console error")
        } catch LocalConsoleConnectionError.notFound {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(keyLoads, 0)
        XCTAssertFalse(service.isChecking)
    }

    @MainActor
    func testStandbyConsoleDoesNotStartStreaming() async {
        var console = discovered()
        console.status = .standby
        let service = LocalConsoleConnectionService(discover: { _ in console }, registeredConsoles: { [] })
        do {
            _ = try await service.connect(to: console.ipAddress, accountID: nil)
            XCTFail("Expected standby error")
        } catch LocalConsoleConnectionError.standby {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(service.isChecking)
    }

    @MainActor
    func testInvalidAccountDoesNotProbeTheConsole() async {
        var probes = 0
        let service = LocalConsoleConnectionService(discover: { _ in probes += 1; return nil }, registeredConsoles: { [] })
        do {
            _ = try await service.connect(to: discovered().ipAddress, accountID: Data(repeating: 1, count: 12))
            XCTFail("Expected invalid account error")
        } catch LocalConsoleConnectionError.invalidAccount {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(probes, 0)
    }

    @MainActor
    func testCancellationDoesNotStartDiscovery() async {
        var probes = 0
        let service = LocalConsoleConnectionService(discover: { _ in probes += 1; return nil }, registeredConsoles: { [] })
        let task = Task { try await service.connect(to: "192.0.2.33", accountID: nil) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(probes, 0)
        XCTAssertFalse(service.isChecking)
    }
}
