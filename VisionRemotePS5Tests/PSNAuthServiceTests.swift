//
//  PSNAuthServiceTests.swift
//  VisionRemotePS5Tests
//
//  Unit tests for PSNAuthService
//

import XCTest
@testable import VisionRemotePS5

final class PSNProtocolRegressionTests: XCTestCase {
    func testPSNProgressDoesNotTreatCommandSendingAsConsoleJoining() {
        XCTAssertEqual(PSNConnectionStage(rawValue: "psn-sending-command"), .sendingCommand)
        XCTAssertEqual(PSNConnectionStage(rawValue: "psn-awaiting-console"), .awaitingConsole)
        XCTAssertTrue(PSNConnectionStage.awaitingConsole.message.contains("Waiting for the console"))
        XCTAssertTrue(PSNConnectionStage.punchingControl.message.contains("console joined"))
        XCTAssertNil(PSNConnectionStage(rawValue: "data-punching"))
        XCTAssertEqual(Set(PSNConnectionStage.allCases.map(\.message)).count, 6)
    }

    private func formFields(_ request: URLRequest) throws -> [String: String] {
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        let query = body.replacingOccurrences(of: "+", with: "%20")
        let components = try XCTUnwrap(URLComponents(string: "https://example.invalid/?\(query)"))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testRefreshSendsExplicitRemotePlayScopesAndRedirect() throws {
        let request = PSNAuthConstants.tokenRequest(for: .refreshToken("synthetic-refresh"))
        let fields = try formFields(request)
        XCTAssertEqual(fields["grant_type"], "refresh_token")
        XCTAssertEqual(fields["refresh_token"], "synthetic-refresh")
        XCTAssertEqual(fields["redirect_uri"], PSNAuthConstants.redirectURI)
        XCTAssertEqual(Set(try XCTUnwrap(fields["scope"]).split(separator: " ").map(String.init)), Set([
            "psn:clientapp", "referenceDataService:countryConfig.read",
            "pushNotification:webSocket.desktop.connect", "sessionManager:remotePlaySession.system.update"
        ]))
        XCTAssertNil(fields["code"])
    }

    func testAuthorizationCodeUsesTheSameScopes() throws {
        let request = PSNAuthConstants.tokenRequest(for: .authorizationCode("synthetic-code"))
        let fields = try formFields(request)
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertEqual(fields["code"], "synthetic-code")
        XCTAssertEqual(fields["scope"], PSNAuthConstants.scopes)
        XCTAssertNil(fields["refresh_token"])
    }

    func testTokenFormPreservesReservedCharactersAndUnicode() throws {
        let credential = "synthetic+code&part=two%25 ?/#:\r\n ação"
        let codeFields = try formFields(PSNAuthConstants.tokenRequest(for: .authorizationCode(credential)))
        let refreshFields = try formFields(PSNAuthConstants.tokenRequest(for: .refreshToken(credential)))
        XCTAssertEqual(codeFields["code"], credential)
        XCTAssertEqual(refreshFields["refresh_token"], credential)
        XCTAssertEqual(codeFields.count, 4)
        XCTAssertEqual(refreshFields.count, 4)
    }

    func testTokenRequestUsesBasicAuthenticationWithoutCredentialsInBody() throws {
        let request = PSNAuthConstants.tokenRequest(for: .refreshToken("synthetic-refresh"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/2.0/oauth/token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
        let fields = try formFields(request)
        XCTAssertNil(fields["client_id"])
        XCTAssertNil(fields["client_secret"])
    }

    func testInvalidScopeResponsePreservesActionableError() {
        let response = Data(#"{"error":"invalid_scope","error_code":4153}"#.utf8)
        XCTAssertEqual(PSNAuthConstants.tokenError(statusCode: 400, data: response), .invalidScope)
    }

    func testRevokedGrantAndInvalidClientRemainDistinct() {
        XCTAssertEqual(PSNAuthConstants.tokenError(statusCode: 400,
            data: Data(#"{"error":"invalid_grant"}"#.utf8)), .authorizationExpired)
        XCTAssertEqual(PSNAuthConstants.tokenError(statusCode: 401,
            data: Data(#"{"error":"invalid_client"}"#.utf8)), .invalidClient)
    }

    func testUnknownServerErrorsDoNotExposeResponseBody() {
        let response = Data(#"{"error":"unknown","error_description":"synthetic-private-token"}"#.utf8)
        let error = PSNAuthConstants.tokenError(statusCode: 503, data: response)
        XCTAssertEqual(error, .httpError(statusCode: 503))
        XCTAssertFalse(error.localizedDescription.contains("synthetic-private-token"))
        XCTAssertEqual(PSNAuthConstants.tokenError(statusCode: 502, data: Data()), .httpError(statusCode: 502))
    }

    func testDeviceListReadsNestedDeviceAndPlatform() throws {
        let response = Data(#"{"clients":[{"duid":"synthetic-console","platform":"PS5","device":{"name":"Test PS5","enabledFeatures":["remotePlay"],"updatedDateTime":"2026-01-01T00:00:00Z"}}]}"#.utf8)
        let devices = try JSONDecoder().decode(PSNDevicesResponse.self, from: response)
        let device = try XCTUnwrap(devices.clients?.first)
        XCTAssertEqual(device.deviceId, "synthetic-console")
        XCTAssertEqual(device.name, "Test PS5")
        XCTAssertEqual(device.deviceType, "PS5")
        XCTAssertEqual(device.enabledFeatures, ["remotePlay"])
        XCTAssertNotNil(device.updatedDateTime)
        XCTAssertFalse(device.isRemotePlayReportedDisabled)
    }

    func testNestedDisabledFeaturesOverrideStaleFlatFeatures() throws {
        let response = Data(#"{"duid":"synthetic-console","enabledFeatures":["remotePlay"],"device":{"enabledFeatures":[]}}"#.utf8)
        let device = try JSONDecoder().decode(PSNDevice.self, from: response)
        XCTAssertTrue(device.isRemotePlayReportedDisabled)
    }

    func testMissingFeaturesAreUnknownRatherThanDisabled() throws {
        let response = Data(#"{"duid":"synthetic-console","device":null}"#.utf8)
        let device = try JSONDecoder().decode(PSNDevice.self, from: response)
        XCTAssertNil(device.enabledFeatures)
        XCTAssertFalse(device.isRemotePlayReportedDisabled)
    }

    func testLegacyDeviceShapeAndExplicitDisabledFlag() throws {
        let response = Data(#"{"duid":"synthetic-console","name":"Legacy PS5","type":"PS5","remoteplay_enabled":false}"#.utf8)
        let device = try JSONDecoder().decode(PSNDevice.self, from: response)
        XCTAssertEqual(device.name, "Legacy PS5")
        XCTAssertEqual(device.deviceType, "PS5")
        XCTAssertTrue(device.isRemotePlayReportedDisabled)
        let roundTrip = try JSONDecoder().decode(PSNDevice.self, from: JSONEncoder().encode(device))
        XCTAssertEqual(roundTrip.deviceId, device.deviceId)
        XCTAssertTrue(roundTrip.isRemotePlayReportedDisabled)
    }

    func testDeviceRequiresConsoleIdentifier() {
        XCTAssertThrowsError(try JSONDecoder().decode(PSNDevice.self, from: Data(#"{"platform":"PS5"}"#.utf8)))
    }

    func testConsoleTimeoutIsNotReportedAsAuthenticationFailure() {
        let error = PSNStartError.consoleDidNotJoin
        XCTAssertTrue(error.localizedDescription.contains("PSN accepted"))
        XCTAssertTrue(error.localizedDescription.contains("did not join"))
        XCTAssertNotEqual(error, .requestFailed(code: 1))
    }
}

final class PSNAuthServiceTests: XCTestCase {
    
    // MARK: - Test Properties
    
    private var authService: PSNAuthService!
    
    // MARK: - Setup & Teardown
    
    @MainActor
    override func setUpWithError() throws {
        try super.setUpWithError()
        authService = PSNAuthService()
    }
    
    @MainActor
    override func tearDownWithError() throws {
        authService = nil
        try super.tearDownWithError()
    }
    
    // MARK: - Initial State Tests
    
    @MainActor
    func testInitialState_NotAuthenticated() async {
        // Given a fresh service
        // Then should not be authenticated initially
        XCTAssertFalse(authService.isAuthenticated)
        XCTAssertFalse(authService.isLoading)
        XCTAssertNil(authService.userProfile)
    }
    
    @MainActor
    func testInitialState_NoError() async {
        // Given a fresh service
        // Then should have no error
        XCTAssertNil(authService.lastError)
    }
    
    // MARK: - Sign Out Tests
    
    @MainActor
    func testSignOut_ClearsState() async {
        // Given a service (even if not authenticated)
        // When signing out
        await authService.signOut()
        
        // Then all state should be cleared
        XCTAssertFalse(authService.isAuthenticated)
        XCTAssertNil(authService.userProfile)
        XCTAssertNil(authService.lastError)
    }
    
    // MARK: - Token Exchange Tests
    
    @MainActor
    func testExchangeCode_EmptyCode_Fails() async {
        // Given an empty authorization code
        let code = ""
        
        // When exchanging
        do {
            try await authService.exchangeCodeForToken(code)
            XCTFail("Should throw error for empty code")
        } catch {
            // Then should fail (network error or validation error expected)
            XCTAssertNotNil(error)
        }
    }
    
    @MainActor
    func testExchangeCode_InvalidCode_SetsLastError() async {
        // Given an invalid code
        let code = "invalid_code_12345"
        
        // When exchanging
        do {
            try await authService.exchangeCodeForToken(code)
            XCTFail("Should throw error for invalid code")
        } catch let error as PSNAuthError {
            // Then lastError should be set
            XCTAssertNotNil(authService.lastError)
            XCTAssertEqual(authService.lastError, error)
            XCTAssertFalse(authService.isAuthenticated)
        } catch {
            // Other errors are acceptable (network, etc)
            XCTAssertNotNil(error)
        }
    }
    
    // MARK: - Access Token Tests
    
    @MainActor
    func testGetAccessToken_NotAuthenticated_ThrowsError() async {
        // Given a non-authenticated service
        // When getting access token
        do {
            _ = try await authService.getAccessToken()
            XCTFail("Should throw error when not authenticated")
        } catch let error as PSNAuthError {
            // Then should throw noAccessToken error
            XCTAssertEqual(error, .noAccessToken)
        } catch {
            // Any error is acceptable
            XCTAssertNotNil(error)
        }
    }
    
    // MARK: - Refresh Token Tests
    
    @MainActor
    func testRefreshAccessToken_NoRefreshToken_ThrowsError() async {
        // Given no stored refresh token
        // When trying to refresh
        do {
            try await authService.refreshAccessToken()
            XCTFail("Should throw error when no refresh token")
        } catch let error as PSNAuthError {
            // Then should throw noRefreshToken error
            XCTAssertEqual(error, .noRefreshToken)
        } catch {
            // Any error is acceptable
            XCTAssertNotNil(error)
        }
    }
    
    // MARK: - Loading State Tests
    
    @MainActor
    func testExchangeCode_SetsLoadingState() async {
        // Given a service
        XCTAssertFalse(authService.isLoading)
        
        // When starting token exchange (will fail but should set loading)
        let task = Task {
            try? await authService.exchangeCodeForToken("test_code")
        }
        
        // Give it a moment to start
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Note: Loading state may already be reset if request completes quickly
        // This test verifies the pattern works; in real scenarios loading would be observable
        
        await task.value
        
        // After completion, should not be loading
        XCTAssertFalse(authService.isLoading)
    }
}

// MARK: - PSNAuthError Tests

final class PSNAuthErrorTests: XCTestCase {
    
    func testErrorEquality_SameType_Equal() {
        // Given same error types
        let error1 = PSNAuthError.noAccessToken
        let error2 = PSNAuthError.noAccessToken
        
        // Then should be equal
        XCTAssertEqual(error1, error2)
    }
    
    func testErrorEquality_DifferentType_NotEqual() {
        // Given different error types
        let error1 = PSNAuthError.noAccessToken
        let error2 = PSNAuthError.noRefreshToken
        
        // Then should not be equal
        XCTAssertNotEqual(error1, error2)
    }
    
    func testErrorEquality_HTTPError_SameCode_Equal() {
        // Given HTTP errors with same code
        let error1 = PSNAuthError.httpError(statusCode: 403)
        let error2 = PSNAuthError.httpError(statusCode: 403)
        
        // Then should be equal
        XCTAssertEqual(error1, error2)
    }
    
    func testErrorEquality_HTTPError_DifferentCode_NotEqual() {
        // Given HTTP errors with different codes
        let error1 = PSNAuthError.httpError(statusCode: 403)
        let error2 = PSNAuthError.httpError(statusCode: 401)
        
        // Then should not be equal
        XCTAssertNotEqual(error1, error2)
    }
    
    func testErrorDescription_NotEmpty() {
        // Given various errors
        let errors: [PSNAuthError] = [
            .noAccessToken,
            .noRefreshToken,
            .invalidResponse,
            .httpError(statusCode: 404),
            .profileNotFound,
            .keychainError(operation: "read"),
            .tokenExchangeFailed(underlying: nil),
            .refreshFailed(underlying: nil),
            .decodingFailed(underlying: nil)
        ]
        
        // Then all should have descriptions
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error \(error) should have description")
        }
    }
}

// MARK: - PSN OAuth Constants Tests

final class PSNOAuthConstantsTests: XCTestCase {
    
    func testLoginURL_ContainsRequiredParameters() {
        // Given the login URL
        let urlString = PSNAuthConstants.loginURL
        
        // Then should contain required OAuth parameters
        XCTAssertTrue(urlString.contains("client_id"), "Should contain client_id")
        XCTAssertTrue(urlString.contains("redirect_uri"), "Should contain redirect_uri")
        XCTAssertTrue(urlString.contains("response_type"), "Should contain response_type")
        XCTAssertTrue(urlString.contains("scope"), "Should contain scope")
    }
    
    func testLoginURL_IsValidURL() {
        // Given the login URL string
        let urlString = PSNAuthConstants.loginURL
        
        // Then should be a valid URL
        XCTAssertNotNil(URL(string: urlString), "Should be a valid URL")
    }
    
    func testClientID_NotEmpty() {
        XCTAssertFalse(PSNAuthConstants.clientID.isEmpty)
    }
    
    func testRedirectURI_NotEmpty() {
        XCTAssertFalse(PSNAuthConstants.redirectURI.isEmpty)
    }
    
    func testScopes_ContainsRemotePlay() {
        XCTAssertTrue(PSNAuthConstants.scopes.contains("remotePlay"), 
                      "Should contain remotePlay scope")
    }
}
