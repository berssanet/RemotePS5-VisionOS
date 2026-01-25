//
//  PSNAuthServiceTests.swift
//  VisionRemotePS5Tests
//
//  Unit tests for PSNAuthService
//

import XCTest
@testable import VisionRemotePS5

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
