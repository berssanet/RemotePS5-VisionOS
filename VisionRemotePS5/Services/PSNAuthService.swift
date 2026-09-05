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
    static let redirectURI = "https://remoteplay.dl.playstation.net/remoteplay/redirect"

    /// Client device id bound to the OAuth token. holepunch.h: the token "must have been
    /// initially created with a duid parameter" or the push WebSocket refuses it (403).
    /// Generated once by the library in PSN format and persisted.
    static var clientDUID: String {
        let key = "psn_client_duid"
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
            return stored
        }
        let generated = ChiakiFullSession.makeClientDUID() ?? ""
        if !generated.isEmpty {
            UserDefaults.standard.set(generated, forKey: key)
        }
        return generated
    }

    /// Tokens minted before the duid binding existed must be replaced by a fresh sign-in.
    static let tokenDUIDBoundKey = "psn_token_duid_bound"

    static let scopes = [
        "psn:clientapp",
        "referenceDataService:countryConfig.read",
        "pushNotification:webSocket.desktop.connect",
        "sessionManager:remotePlaySession.system.update"
    ].joined(separator: " ")

    enum TokenGrant {
        case authorizationCode(String)
        case refreshToken(String)
    }

    static func tokenRequest(for grant: TokenGrant) -> URLRequest {
        var fields = ["scope": scopes, "redirect_uri": redirectURI]
        switch grant {
        case .authorizationCode(let code):
            fields["grant_type"] = "authorization_code"
            fields["code"] = code
        case .refreshToken(let token):
            fields["grant_type"] = "refresh_token"
            fields["refresh_token"] = token
        }
        var request = URLRequest(url: URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        request.httpBody = Data(fields.urlEncodedString.utf8)
        return request
    }

    static func tokenError(statusCode: Int, data: Data) -> PSNAuthError {
        let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch response?["error"] as? String {
        case "invalid_scope": return .invalidScope
        case "invalid_grant": return .authorizationExpired
        case "invalid_client": return .invalidClient
        default: return .httpError(statusCode: statusCode)
        }
    }
    
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
            URLQueryItem(name: "PlatformPrivacyWs1", value: "minimal"),
            URLQueryItem(name: "duid", value: clientDUID)
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

    private var refreshTask: Task<Void, Error>?
    
    // MARK: - Private Constants
    
    private enum KeychainKeys {
        static let accessToken = "com.visionremote.ps5.accessToken"
        static let refreshToken = "com.visionremote.ps5.refreshToken"
        static let tokenExpiry = "com.visionremote.ps5.tokenExpiry"
    }
    
    private enum APIEndpoints {
        static let authBase = "https://auth.api.sonyentertainmentnetwork.com"
        
        static var tokenURL: URL { URL(string: "\(authBase)/2.0/oauth/token")! }
        /// Token introspection endpoint (chiaki-ng psnaccountid.cpp): returns the numeric `user_id`
        /// that Remote Play registration uses as the 8-byte PSN Account ID. Basic-auth, not Bearer.
        static func accountInfoURL(accessToken: String) -> URL? {
            var components = URLComponents(string: "\(authBase)/2.0/oauth/token")
            components?.path += "/" + accessToken
            return components?.url
        }
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
            UserDefaults.standard.set(true, forKey: PSNAuthConstants.tokenDUIDBoundKey)
            
            try await reloadProfile()
            isAuthenticated = true
            
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
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let refreshToken = try? keychainGet(key: KeychainKeys.refreshToken) else {
            throw PSNAuthError.noRefreshToken
        }

        let task = Task {
            do {
                let tokenResponse = try await performTokenRequest(for: .refreshToken(refreshToken))
                try Task.checkCancellation()
                try await storeTokens(tokenResponse)
                DebugLog.print("[PSNAuth] ✅ Token refreshed successfully")
            } catch {
                if let authError = error as? PSNAuthError,
                   authError == .authorizationExpired || authError == .invalidClient {
                    await signOut()
                }
                throw PSNAuthError.refreshFailed(underlying: error)
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }
    
    /// Sign out and clear all stored credentials.
    func signOut() async {
        refreshTask?.cancel()
        isAuthenticated = false
        userProfile = nil
        lastError = nil
        
        // Clear keychain (ignore errors)
        try? keychainDelete(key: KeychainKeys.accessToken)
        try? keychainDelete(key: KeychainKeys.refreshToken)
        try? keychainDelete(key: KeychainKeys.tokenExpiry)
        UserDefaults.standard.removeObject(forKey: PSNAuthConstants.tokenDUIDBoundKey)
        UserDefaults.standard.removeObject(forKey: "psn_account_id")
        
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
        return try await performTokenRequest(for: .authorizationCode(code))
    }
    
    private func performTokenRequest(for grant: PSNAuthConstants.TokenGrant) async throws -> TokenResponse {
        let request = PSNAuthConstants.tokenRequest(for: grant)
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PSNAuthError.invalidResponse
        }
        
        DebugLog.print("[PSNAuth] Token request status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            throw PSNAuthConstants.tokenError(statusCode: httpResponse.statusCode, data: data)
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
    
    /// Re-resolve the PSN Account ID (token-info endpoint) for a signed-in user.
    func reloadProfile() async throws {
        userProfile = try await fetchUserProfileFromAPI()
    }

    // MARK: - Private: Profile Operations
    
    private func loadStoredCredentials() async {
        guard (try? keychainGet(key: KeychainKeys.accessToken)) != nil else {
            return
        }
        guard UserDefaults.standard.bool(forKey: PSNAuthConstants.tokenDUIDBoundKey) else {
            DebugLog.print("[PSNAuth] Stored token predates the duid binding; sign in again")
            await signOut()
            return
        }
        
        do {
            try await reloadProfile()
            isAuthenticated = true
        } catch {
            lastError = (error as? PSNAuthError) ?? .tokenExchangeFailed(underlying: error)
            DebugLog.print("[PSNAuth] Profile fetch failed: \(error.localizedDescription)")
        }
    }
    
    /// Resolve the PSN Account ID from the token-info endpoint, exactly like chiaki-ng's
    /// `PSNAccountID::handUserIDResponse`: `GET <tokenURL>/<access_token>` with Basic auth,
    /// then `user_id` (decimal) -> 8 bytes little-endian -> Base64.
    private func fetchUserProfileFromAPI() async throws -> PSNUserProfile {
        let token = try await getAccessToken()
        
        guard let url = APIEndpoints.accountInfoURL(accessToken: token) else {
            throw PSNAuthError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue(Self.basicAuthorizationHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PSNAuthError.invalidResponse
        }
        
        DebugLog.print("[PSNAuth] Account info response status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            throw PSNAuthError.httpError(statusCode: httpResponse.statusCode)
        }
        
        let profile = try parseUserProfile(from: data)
        // Single source of truth shared with PairingView / SettingsView.
        UserDefaults.standard.set(profile.accountId, forKey: "psn_account_id")
        return profile
    }

    private static func basicAuthorizationHeader() -> String {
        let credentials = "\(PSNAuthConstants.clientID):\(PSNAuthConstants.clientSecret)"
        return "Basic " + Data(credentials.utf8).base64EncodedString()
    }
    
    private func parseUserProfile(from data: Data) throws -> PSNUserProfile {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PSNAuthError.decodingFailed(underlying: nil)
        }
        
        // `user_id` arrives as a decimal string (chiaki-ng: std::stoll); tolerate a JSON number too.
        let userId: UInt64?
        if let text = json["user_id"] as? String {
            userId = UInt64(text)
        } else if let number = json["user_id"] as? NSNumber {
            userId = number.uint64Value
        } else {
            userId = nil
        }
        guard let userId else {
            throw PSNAuthError.profileNotFound
        }
        
        let accountId = Self.accountIdBase64(userId: userId)
        let onlineId = (json["online_id"] as? String) ?? "PSN User"
        
        DebugLog.print("[PSNAuth] ✅ Account ID resolved")
        return PSNUserProfile(onlineId: onlineId, accountId: accountId)
    }
    
    /// `user_id.to_bytes(8, "little")` + Base64 — the format the PS5 registration payload expects.
    private static func accountIdBase64(userId: UInt64) -> String {
        var littleEndian = userId.littleEndian
        let bytes = withUnsafeBytes(of: &littleEndian) { Data($0) }
        return bytes.base64EncodedString()
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
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
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
    case invalidScope
    case authorizationExpired
    case invalidClient
    
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
        case .invalidScope:
            return "PSN rejected the requested permissions (invalid_scope). Sign in again using this app's PSN login link."
        case .authorizationExpired:
            return "PSN authorization expired or was revoked. Sign in again using a new redirect URL."
        case .invalidClient:
            return "PSN rejected the app's OAuth client configuration. Check PSNClientID and PSNClientSecret."
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
        case (.invalidScope, .invalidScope): return true
        case (.authorizationExpired, .authorizationExpired): return true
        case (.invalidClient, .invalidClient): return true
        default: return false
        }
    }
}

// MARK: - Extensions

private extension Dictionary where Key == String, Value == String {
    var urlEncodedString: String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return keys.sorted().map { key in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed)!
            let encodedValue = self[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }
}
