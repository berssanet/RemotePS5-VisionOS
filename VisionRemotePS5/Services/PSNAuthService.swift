import Foundation
import Security

// MARK: - PSN Auth Constants
struct PSNAuthConstants {
    static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let clientSecret = "mvaiZkRsAsI1IBkY"
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

/// Service for handling PlayStation Network authentication
@MainActor
class PSNAuthService: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var userProfile: PSNUserProfile?
    @Published var lastError: Error?
    
    // Keychain keys
    private static let accessTokenKey = "com.visionremote.ps5.accessToken"
    private static let refreshTokenKey = "com.visionremote.ps5.refreshToken"
    private static let tokenExpiryKey = "com.visionremote.ps5.tokenExpiry"
    
    // PSN OAuth endpoints
    private static let authBaseURL = "https://auth.api.sonyentertainmentnetwork.com"
    private static let profileBaseURL = "https://web.np.playstation.com"
    
    // Client credentials (from public Remote Play app)
    private static let clientId = "ba495a24-818c-472b-b12d-ff231c1b5745"
    private static let clientSecret = "mvaiZkRsAsI1IBkY"
    private static let redirectURI = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    
    init() {
        Task {
            await loadStoredCredentials()
        }
    }
    
    // MARK: - Public Methods
    
    /// Exchange authorization code for access token
    func exchangeCodeForToken(_ code: String) async throws {
        isLoading = true
        defer { isLoading = false }
        
        let url = URL(string: "\(Self.authBaseURL)/2.0/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientId,
            "client_secret": Self.clientSecret
        ]
        
        request.httpBody = body.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Log raw response for debugging
        if let rawResponse = String(data: data, encoding: .utf8) {
            print("[PSNAuth] Raw token response: \(rawResponse.prefix(500))...")
        }
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw PSNAuthError.tokenExchangeFailed
        }
        
        // Try to parse as generic JSON first to see all available fields
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            print("[PSNAuth] Token response keys: \(json.keys.sorted().joined(separator: ", "))")
            
            // Check for account_id or user_id in response
            if let accountId = json["user_id"] as? String {
                print("[PSNAuth] Found user_id in token response: \(accountId)")
            }
            if let accountId = json["account_id"] as? String {
                print("[PSNAuth] Found account_id in token response: \(accountId)")
            }
            
            // Check for id_token which might be a JWT with user info
            if let idToken = json["id_token"] as? String {
                print("[PSNAuth] Found id_token, attempting to decode...")
                extractAccountIdFromToken(idToken)
            }
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        
        // Log access token format
        print("[PSNAuth] Access token format: \(tokenResponse.accessToken.prefix(50))...")
        print("[PSNAuth] Access token parts count: \(tokenResponse.accessToken.split(separator: ".").count)")
        
        try await storeTokens(tokenResponse)
        
        isAuthenticated = true
        
        // Try to extract account ID from JWT token first (if it's a JWT)
        if userProfile == nil {
            extractAccountIdFromToken(tokenResponse.accessToken)
        }
        
        // If that failed, try the profile API as fallback
        if userProfile == nil {
            try await fetchUserProfile()
        }
    }
    
    /// Refresh the access token
    func refreshAccessToken() async throws {
        guard let refreshToken = try getKeychainValue(for: Self.refreshTokenKey) else {
            throw PSNAuthError.noRefreshToken
        }
        
        let url = URL(string: "\(Self.authBaseURL)/2.0/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientId,
            "client_secret": Self.clientSecret
        ]
        
        request.httpBody = body.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            // Refresh failed, need to re-authenticate
            await signOut()
            throw PSNAuthError.refreshFailed
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        try await storeTokens(tokenResponse)
    }
    
    /// Sign out and clear credentials
    func signOut() async {
        isAuthenticated = false
        userProfile = nil
        
        try? deleteKeychainValue(for: Self.accessTokenKey)
        try? deleteKeychainValue(for: Self.refreshTokenKey)
        try? deleteKeychainValue(for: Self.tokenExpiryKey)
    }
    
    /// Get current access token, refreshing if needed
    func getAccessToken() async throws -> String {
        // Check if token is expired
        if let expiryString = try? getKeychainValue(for: Self.tokenExpiryKey),
           let expiry = Double(expiryString),
           Date().timeIntervalSince1970 > expiry - 300 { // 5 min buffer
            try await refreshAccessToken()
        }
        
        guard let token = try getKeychainValue(for: Self.accessTokenKey) else {
            throw PSNAuthError.noAccessToken
        }
        
        return token
    }
    
    // MARK: - Private Methods
    
    private func loadStoredCredentials() async {
        if let token = try? getKeychainValue(for: Self.accessTokenKey) {
            isAuthenticated = true
            // Try to extract from stored token first
            extractAccountIdFromToken(token)
            // Fallback to API
            if userProfile == nil {
                try? await fetchUserProfile()
            }
        }
    }
    
    /// Decode JWT token to extract account ID from the 'sub' claim
    private func extractAccountIdFromToken(_ token: String) {
        // JWT has 3 parts separated by dots: header.payload.signature
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            print("[PSNAuth] Token is not a valid JWT format")
            return
        }
        
        // Get the payload (second part)
        var payloadBase64 = String(parts[1])
        
        // Base64URL to Base64 conversion
        payloadBase64 = payloadBase64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        // Add padding if needed
        let remainder = payloadBase64.count % 4
        if remainder > 0 {
            payloadBase64 += String(repeating: "=", count: 4 - remainder)
        }
        
        guard let payloadData = Data(base64Encoded: payloadBase64) else {
            print("[PSNAuth] Failed to decode JWT payload")
            return
        }
        
        // Log raw payload for debugging
        if let rawPayload = String(data: payloadData, encoding: .utf8) {
            print("[PSNAuth] JWT payload: \(rawPayload.prefix(300))...")
        }
        
        // Parse JSON
        do {
            if let json = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                print("[PSNAuth] JWT claims: \(json.keys.sorted().joined(separator: ", "))")
                
                // Look for account ID in various possible claims
                var accountId: String?
                var onlineId: String?
                
                // PSN typically uses 'sub' for account ID
                if let sub = json["sub"] as? String {
                    accountId = sub
                    print("[PSNAuth] Found sub claim: \(sub)")
                }
                
                // Also check for explicit account_id
                if let accId = json["account_id"] as? String {
                    accountId = accId
                    print("[PSNAuth] Found account_id claim: \(accId)")
                }
                
                // Check for online_id / username
                if let username = json["online_id"] as? String {
                    onlineId = username
                } else if let username = json["username"] as? String {
                    onlineId = username
                }
                
                if let accountId = accountId {
                    userProfile = PSNUserProfile(
                        onlineId: onlineId ?? "PSN User",
                        accountId: accountId
                    )
                    print("[PSNAuth] ✅ Extracted from JWT - accountId: \(accountId), onlineId: \(onlineId ?? "Unknown")")
                } else {
                    print("[PSNAuth] No account ID found in JWT claims")
                }
            }
        } catch {
            print("[PSNAuth] Failed to parse JWT payload: \(error)")
        }
    }
    
    private func fetchUserProfile() async throws {
        let token = try await getAccessToken()
        
        // Use the correct basicProfile endpoint
        let url = URL(string: "\(Self.profileBaseURL)/api/basicProfile/v1/profile/users/me")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Add required headers for PSN API
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        
        print("[PSNAuth] Fetching user profile from: \(url)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("[PSNAuth] Invalid response type")
            return
        }
        
        print("[PSNAuth] Profile response status: \(httpResponse.statusCode)")
        
        // Log raw response for debugging
        if let rawJSON = String(data: data, encoding: .utf8) {
            print("[PSNAuth] Raw profile response: \(rawJSON.prefix(500))...")
        }
        
        guard httpResponse.statusCode == 200 else {
            print("[PSNAuth] Profile fetch failed with status: \(httpResponse.statusCode)")
            return
        }
        
        // Try to parse the response flexibly
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("[PSNAuth] Available top-level keys: \(json.keys.sorted().joined(separator: ", "))")
                
                // The basicProfile API returns profile data with accountId and onlineId
                let accountId = json["accountId"] as? String
                let onlineId = json["onlineId"] as? String
                
                // Also check nested profile object for older API format
                if let profile = json["profile"] as? [String: Any] {
                    print("[PSNAuth] Profile keys: \(profile.keys.sorted().joined(separator: ", "))")
                }
                
                if accountId != nil || onlineId != nil {
                    userProfile = PSNUserProfile(
                        onlineId: onlineId ?? "Unknown",
                        accountId: accountId ?? ""
                    )
                    print("[PSNAuth] Parsed profile - onlineId: \(userProfile?.onlineId ?? "nil"), accountId: \(userProfile?.accountId ?? "nil")")
                } else {
                    print("[PSNAuth] Could not find accountId or onlineId in response")
                }
            }
        } catch {
            print("[PSNAuth] Failed to parse profile JSON: \(error)")
        }
    }
    
    private func storeTokens(_ response: TokenResponse) async throws {
        try setKeychainValue(response.accessToken, for: Self.accessTokenKey)
        
        if let refreshToken = response.refreshToken {
            try setKeychainValue(refreshToken, for: Self.refreshTokenKey)
        }
        
        let expiry = Date().timeIntervalSince1970 + Double(response.expiresIn)
        try setKeychainValue(String(expiry), for: Self.tokenExpiryKey)
    }
    
    // MARK: - Keychain Helpers
    
    private func setKeychainValue(_ value: String, for key: String) throws {
        let data = value.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PSNAuthError.keychainError
        }
    }
    
    private func getKeychainValue(for key: String) throws -> String? {
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
    
    private func deleteKeychainValue(for key: String) throws {
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

struct PSNUserProfile: Codable {
    let onlineId: String
    let accountId: String
    
    init(onlineId: String, accountId: String) {
        self.onlineId = onlineId
        self.accountId = accountId
    }
    
    enum CodingKeys: String, CodingKey {
        case onlineId
        case accountId
    }
}

// MARK: - Errors

enum PSNAuthError: LocalizedError {
    case tokenExchangeFailed
    case refreshFailed
    case noAccessToken
    case noRefreshToken
    case keychainError
    
    var errorDescription: String? {
        switch self {
        case .tokenExchangeFailed:
            return "Failed to exchange authorization code for token"
        case .refreshFailed:
            return "Failed to refresh access token"
        case .noAccessToken:
            return "No access token available"
        case .noRefreshToken:
            return "No refresh token available"
        case .keychainError:
            return "Failed to store credentials securely"
        }
    }
}
