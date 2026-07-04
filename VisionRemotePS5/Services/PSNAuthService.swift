import Foundation
import Security

// MARK: - PSN Auth Constants

/// PSN OAuth constants. Phase 5.19: secrets are sourced from Info.plist
/// (`PSNClientID`, `PSNClientSecret`) which are populated at build time from
/// `Local.xcconfig` (gitignored) — never hardcoded in source. The app falls back
/// to empty strings if missing, which causes login to fail loudly rather than
/// shipping someone else's PSN client.
struct PSNAuthConstants {
    static var clientID: String {
        return (Bundle.main.object(forInfoDictionaryKey: "PSNClientID") as? String) ?? ""
    }
    static var clientSecret: String {
        return (Bundle.main.object(forInfoDictionaryKey: "PSNClientSecret") as? String) ?? ""
    }
    static let tokenURL = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"
    static let redirectURI = "https://remoteplay.dl.playstation.net/remoteplay/redirect"

    static let scopes = [
        "psn:clientapp",
        "referenceDataService:countryConfig.read",
        "pushNotification:webSocket.desktop.connect",
        "sessionManager:remotePlaySession.system.update"
    ].joined(separator: " ")
    
    static var loginURL: String {
        var components = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "service_entity", value: "urn:service-entity:psn"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "request_locale", value: "en_US"),
            URLQueryItem(name: "ui", value: "pr"),
            URLQueryItem(name: "service_logo", value: "ps"),
            URLQueryItem(name: "layout_type", value: "popup"),
            URLQueryItem(name: "smcid", value: "remoteplay"),
            URLQueryItem(name: "prompt", value: "always"),
            URLQueryItem(name: "PlatformPrivacyWs1", value: "minimal")
        ]
        return components.url!.absoluteString
    }
}

// MARK: - PSN Auth Service

/// Service for handling PlayStation Network authentication using modern async/await patterns.
/// All network operations are fully asynchronous with proper error handling.
@MainActor
class PSNAuthService: ObservableObject {
    
    // MARK: - Published State
    
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var userProfile: PSNUserProfile?
    @Published var lastError: PSNAuthError?
    
    // MARK: - Private Constants
    
    private enum KeychainKeys {
        static let accessToken = "com.visionremote.ps5.accessToken"
        static let refreshToken = "com.visionremote.ps5.refreshToken"
        static let tokenExpiry = "com.visionremote.ps5.tokenExpiry"
    }
    
    private enum APIEndpoints {
        static let authBase = "https://auth.api.sonyentertainmentnetwork.com"
        static let profileBase = "https://web.np.playstation.com"
        
        static var tokenURL: URL { URL(string: "\(authBase)/2.0/oauth/token")! }
        static var profileURL: URL { URL(string: "\(profileBase)/api/basicProfile/v1/profile/users/me")! }
    }
    
    /// Phase 5.19: collapsed to a thin alias over `PSNAuthConstants` so there
    /// is a single source of truth and the literal secret string never appears
    /// in the binary.
    private enum ClientCredentials {
        static var clientId: String { PSNAuthConstants.clientID }
        static var clientSecret: String { PSNAuthConstants.clientSecret }
        static var redirectURI: String { PSNAuthConstants.redirectURI }
    }
    
    // MARK: - Initialization
    
    init() {
        Task {
            await loadStoredCredentials()
        }
    }
    
    // MARK: - Public API
    
    /// Exchange an OAuth authorization code for access and refresh tokens.
    /// - Parameter code: The authorization code from the PSN login redirect.
    /// - Throws: `PSNAuthError` if token exchange fails.
    func exchangeCodeForToken(_ code: String) async throws {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let tokenResponse = try await performTokenExchange(code: code)
            try await storeTokens(tokenResponse)
            
            isAuthenticated = true
            
            // Try to extract user profile from JWT, then fallback to API
            await loadUserProfile(from: tokenResponse.accessToken)
            
            DebugLog.print("[PSNAuth] ✅ Authentication successful")
            
        } catch let error as PSNAuthError {
            lastError = error
            throw error
        } catch {
            let authError = PSNAuthError.tokenExchangeFailed(underlying: error)
            lastError = authError
            throw authError
        }
    }
    
    /// Refresh the access token using the stored refresh token.
    /// - Throws: `PSNAuthError` if refresh fails or no refresh token is available.
    func refreshAccessToken() async throws {
        guard let refreshToken = try? keychainGet(key: KeychainKeys.refreshToken) else {
            throw PSNAuthError.noRefreshToken
        }
        
        do {
            let tokenResponse = try await performTokenRefresh(refreshToken: refreshToken)
            try await storeTokens(tokenResponse)
            DebugLog.print("[PSNAuth] ✅ Token refreshed successfully")
            
        } catch {
            // Refresh failed - sign out and require re-authentication
            await signOut()
            throw PSNAuthError.refreshFailed(underlying: error)
        }
    }
    
    /// Sign out and clear all stored credentials.
    func signOut() async {
        isAuthenticated = false
        userProfile = nil
        lastError = nil
        
        // Clear keychain (ignore errors)
        try? keychainDelete(key: KeychainKeys.accessToken)
        try? keychainDelete(key: KeychainKeys.refreshToken)
        try? keychainDelete(key: KeychainKeys.tokenExpiry)
        
        DebugLog.print("[PSNAuth] Signed out")
    }
    
    /// Get the current access token, refreshing if expired.
    /// - Returns: A valid access token.
    /// - Throws: `PSNAuthError` if no token is available or refresh fails.
    func getAccessToken() async throws -> String {
        // Check if token is expired (with 5 minute buffer)
        if isTokenExpired() {
            try await refreshAccessToken()
        }
        
        guard let token = try? keychainGet(key: KeychainKeys.accessToken) else {
            throw PSNAuthError.noAccessToken
        }
        
        return token
    }
    
    // MARK: - Private: Token Operations
    
    private func performTokenExchange(code: String) async throws -> TokenResponse {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": ClientCredentials.redirectURI,
            "client_id": ClientCredentials.clientId,
            "client_secret": ClientCredentials.clientSecret
        ]
        
        return try await performTokenRequest(body: body)
    }
    
    private func performTokenRefresh(refreshToken: String) async throws -> TokenResponse {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": ClientCredentials.clientId,
            "client_secret": ClientCredentials.clientSecret
        ]
        
        return try await performTokenRequest(body: body)
    }
    
    private func performTokenRequest(body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: APIEndpoints.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.urlEncodedString.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PSNAuthError.invalidResponse
        }
        
        // Debug logging
        if let rawResponse = String(data: data, encoding: .utf8) {
            DebugLog.print("[PSNAuth] Token response (\(httpResponse.statusCode)): \(rawResponse.prefix(300))...")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw PSNAuthError.httpError(statusCode: httpResponse.statusCode)
        }
        
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw PSNAuthError.decodingFailed(underlying: error)
        }
    }
    
    private func storeTokens(_ response: TokenResponse) async throws {
        try keychainSet(value: response.accessToken, key: KeychainKeys.accessToken)
        
        if let refreshToken = response.refreshToken {
            try keychainSet(value: refreshToken, key: KeychainKeys.refreshToken)
        }
        
        let expiry = Date().timeIntervalSince1970 + Double(response.expiresIn)
        try keychainSet(value: String(expiry), key: KeychainKeys.tokenExpiry)
    }
    
    private func isTokenExpired() -> Bool {
        guard let expiryString = try? keychainGet(key: KeychainKeys.tokenExpiry),
              let expiry = Double(expiryString) else {
            return true
        }
        
        // Consider expired if less than 5 minutes remaining
        return Date().timeIntervalSince1970 > expiry - 300
    }
    
    // MARK: - Private: Profile Operations
    
    private func loadStoredCredentials() async {
        guard let token = try? keychainGet(key: KeychainKeys.accessToken) else {
            return
        }
        
        isAuthenticated = true
        await loadUserProfile(from: token)
    }
    
    private func loadUserProfile(from accessToken: String) async {
        // Try JWT extraction first (faster, no network)
        if let profile = extractProfileFromJWT(accessToken) {
            userProfile = profile
            return
        }
        
        // Fallback to API call
        do {
            userProfile = try await fetchUserProfileFromAPI()
        } catch {
            DebugLog.print("[PSNAuth] Profile fetch failed: \(error.localizedDescription)")
        }
    }
    
    private func fetchUserProfileFromAPI() async throws -> PSNUserProfile {
        let token = try await getAccessToken()
        
        var request = URLRequest(url: APIEndpoints.profileURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PSNAuthError.invalidResponse
        }
        
        DebugLog.print("[PSNAuth] Profile response status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            throw PSNAuthError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try parseUserProfile(from: data)
    }
    
    private func parseUserProfile(from data: Data) throws -> PSNUserProfile {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PSNAuthError.decodingFailed(underlying: nil)
        }
        
        let accountId = json["accountId"] as? String
        let onlineId = json["onlineId"] as? String
        
        // Check nested profile object (older API format)
        var nestedAccountId: String?
        var nestedOnlineId: String?
        if let profile = json["profile"] as? [String: Any] {
            nestedAccountId = profile["accountId"] as? String
            nestedOnlineId = profile["onlineId"] as? String
        }
        
        let finalAccountId = accountId ?? nestedAccountId ?? ""
        let finalOnlineId = onlineId ?? nestedOnlineId ?? "PSN User"
        
        guard !finalAccountId.isEmpty || !finalOnlineId.isEmpty else {
            throw PSNAuthError.profileNotFound
        }
        
        DebugLog.print("[PSNAuth] ✅ Profile parsed - onlineId: \(finalOnlineId)")
        return PSNUserProfile(onlineId: finalOnlineId, accountId: finalAccountId)
    }
    
    // MARK: - Private: JWT Parsing
    
    private func extractProfileFromJWT(_ token: String) -> PSNUserProfile? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }
        
        guard let payloadData = decodeBase64URL(String(parts[1])) else {
            return nil
        }
        
        do {
            guard let json = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                return nil
            }
            
            // Extract account ID from standard JWT claims
            let accountId = (json["sub"] as? String) ?? (json["account_id"] as? String)
            let onlineId = (json["online_id"] as? String) ?? (json["username"] as? String)
            
            guard let accountId = accountId else {
                return nil
            }
            
            DebugLog.print("[PSNAuth] ✅ Extracted profile from JWT - accountId: \(accountId)")
            return PSNUserProfile(onlineId: onlineId ?? "PSN User", accountId: accountId)
            
        } catch {
            return nil
        }
    }
    
    private func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        
        return Data(base64Encoded: base64)
    }
    
    // MARK: - Keychain Operations
    
    private func keychainSet(value: String, key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw PSNAuthError.keychainError(operation: "encode")
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        // Delete existing item first
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PSNAuthError.keychainError(operation: "write")
        }
    }
    
    private func keychainGet(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return value
    }
    
    private func keychainDelete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Models

struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

struct PSNUserProfile: Codable, Equatable {
    let onlineId: String
    let accountId: String
    
    init(onlineId: String, accountId: String) {
        self.onlineId = onlineId
        self.accountId = accountId
    }
}

// MARK: - Errors

enum PSNAuthError: LocalizedError, Equatable {
    case tokenExchangeFailed(underlying: Error?)
    case refreshFailed(underlying: Error?)
    case noAccessToken
    case noRefreshToken
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingFailed(underlying: Error?)
    case profileNotFound
    case keychainError(operation: String)
    
    var errorDescription: String? {
        switch self {
        case .tokenExchangeFailed(let error):
            return "Token exchange failed: \(error?.localizedDescription ?? "Unknown")"
        case .refreshFailed(let error):
            return "Token refresh failed: \(error?.localizedDescription ?? "Unknown")"
        case .noAccessToken:
            return "No access token available. Please sign in."
        case .noRefreshToken:
            return "No refresh token available. Please sign in again."
        case .invalidResponse:
            return "Invalid response from PSN server"
        case .httpError(let code):
            return "HTTP error \(code) from PSN server"
        case .decodingFailed(let error):
            return "Failed to decode response: \(error?.localizedDescription ?? "Unknown")"
        case .profileNotFound:
            return "User profile not found"
        case .keychainError(let operation):
            return "Keychain \(operation) failed"
        }
    }
    
    // Equatable conformance (ignore underlying errors)
    static func == (lhs: PSNAuthError, rhs: PSNAuthError) -> Bool {
        switch (lhs, rhs) {
        case (.tokenExchangeFailed, .tokenExchangeFailed): return true
        case (.refreshFailed, .refreshFailed): return true
        case (.noAccessToken, .noAccessToken): return true
        case (.noRefreshToken, .noRefreshToken): return true
        case (.invalidResponse, .invalidResponse): return true
        case (.httpError(let l), .httpError(let r)): return l == r
        case (.decodingFailed, .decodingFailed): return true
        case (.profileNotFound, .profileNotFound): return true
        case (.keychainError(let l), .keychainError(let r)): return l == r
        default: return false
        }
    }
}

// MARK: - Extensions

private extension Dictionary where Key == String, Value == String {
    /// Encode dictionary as URL query string.
    var urlEncodedString: String {
        map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }
}
