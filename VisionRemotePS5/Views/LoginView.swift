import SwiftUI
import WebKit

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @Binding var navigationPath: NavigationPath
    @State private var isLoading = true
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PSNWebView(
                    isLoading: $isLoading,
                    onAuthenticationComplete: handleAuthComplete
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading PSN...")
                            .font(.headline)
                    }
                    .padding(32)
                    .glassBackgroundEffect()
                }
            }
        }
        .frame(minWidth: 400, minHeight: 600)
        .navigationTitle("Sign In to PSN")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    goHome()
                } label: {
                    Label("Home", systemImage: "house.fill")
                }
            }
        }
    }
    
    private func goHome() {
        navigationPath = NavigationPath()
    }
    
    private func handleAuthComplete(success: Bool, code: String?) {
        guard success, let authCode = code else {
            goHome()
            return
        }
        
        // Exchange the authorization code for access token and fetch user profile
        Task {
            do {
                try await appState.psnAuthService.exchangeCodeForToken(authCode)
                await MainActor.run {
                    appState.isAuthenticated = true
                    print("[LoginView] PSN login successful, accountId: \(appState.psnAuthService.userProfile?.accountId ?? "nil")")
                    goHome()
                }
            } catch {
                print("[LoginView] Failed to exchange code for token: \(error)")
                await MainActor.run {
                    goHome()
                }
            }
        }
    }
}

// MARK: - PSN WebView
struct PSNWebView: UIViewRepresentable {
    @Binding var isLoading: Bool
    let onAuthenticationComplete: (Bool, String?) -> Void
    
    // PlayStation Network OAuth URL
    private let psnAuthURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Use non-persistent data store to ensure fresh login each time
        config.websiteDataStore = .nonPersistent()
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 800), configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = true
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.scrollView.isScrollEnabled = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        
        // Build OAuth request
        var components = URLComponents(url: psnAuthURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: "ba495a24-818c-472b-b12d-ff231c1b5745"),
            URLQueryItem(name: "redirect_uri", value: "https://remoteplay.dl.playstation.net/remoteplay/redirect"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "psn:clientapp")
        ]
        
        if let url = components.url {
            webView.load(URLRequest(url: url))
        }
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: PSNWebView
        
        init(_ parent: PSNWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                parent.isLoading = true
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                parent.isLoading = false
            }
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .allow }
            
            if url.absoluteString.contains("remoteplay/redirect") {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
                    
                    // Try to get NPSSO cookie and account ID before completing auth
                    await extractAccountIdFromCookies(webView: webView)
                    
                    await MainActor.run {
                        parent.onAuthenticationComplete(true, code)
                    }
                    return .cancel
                }
            }
            
            return .allow
        }
        
        /// Extract account ID using the NPSSO token from cookies
        private func extractAccountIdFromCookies(webView: WKWebView) async {
            let dataStore = webView.configuration.websiteDataStore
            
            // Get all cookies
            let cookies = await dataStore.httpCookieStore.allCookies()
            
            // Log available cookies for debugging
            let cookieNames = cookies.map { $0.name }.joined(separator: ", ")
            print("[LoginView] Available cookies: \(cookieNames)")
            
            // Look for npsso cookie
            if let npssoCookie = cookies.first(where: { $0.name.lowercased() == "npsso" }) {
                print("[LoginView] Found NPSSO cookie: \(npssoCookie.value.prefix(20))...")
                
                // Use NPSSO to get account ID from SSO cookie endpoint
                await fetchAccountIdWithNPSSO(npsso: npssoCookie.value)
            } else {
                print("[LoginView] NPSSO cookie not found, trying ssocookie endpoint...")
                
                // Alternative: Try to fetch ssocookie directly using current session cookies
                await fetchAccountIdFromSsoCookie(cookies: cookies)
            }
        }
        
        /// Fetch account ID using NPSSO token via proper OAuth exchange
        private func fetchAccountIdWithNPSSO(npsso: String) async {
            print("[LoginView] Exchanging NPSSO for account ID...")
            
            // Step 1: Exchange NPSSO for authorization code
            // Use the auth endpoint with proper scopes that include user identity
            guard let authUrl = URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/authorize") else { return }
            
            var components = URLComponents(url: authUrl, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "client_id", value: "09515159-7237-4370-9b40-3806e67c0891"), // Chiaki client ID
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "psn:mobile.v2.core psn:clientapp"),
                URLQueryItem(name: "redirect_uri", value: "https://remoteplay.dl.playstation.net/remoteplay/redirect")
            ]
            
            var request = URLRequest(url: components.url!)
            request.setValue("npsso=\(npsso)", forHTTPHeaderField: "Cookie")
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else { return }
                print("[LoginView] NPSSO auth response status: \(httpResponse.statusCode)")
                
                // Check for redirect with code
                if httpResponse.statusCode == 302 || httpResponse.statusCode == 303,
                   let location = httpResponse.value(forHTTPHeaderField: "Location"),
                   let redirectUrl = URLComponents(string: location),
                   let code = redirectUrl.queryItems?.first(where: { $0.name == "code" })?.value {
                    print("[LoginView] Got auth code from NPSSO exchange: \(code.prefix(20))...")
                    
                    // Step 2: Exchange code for token
                    await exchangeCodeForAccountId(code: code)
                } else {
                    // If no redirect, try to parse response
                    if let rawResponse = String(data: data, encoding: .utf8) {
                        print("[LoginView] NPSSO auth response: \(rawResponse.prefix(300))...")
                    }
                    
                    // Try alternative: decode the response URL
                    if let finalURL = httpResponse.url,
                       let redirectComponents = URLComponents(url: finalURL, resolvingAgainstBaseURL: false),
                       let code = redirectComponents.queryItems?.first(where: { $0.name == "code" })?.value {
                        print("[LoginView] Got auth code from final URL: \(code.prefix(20))...")
                        await exchangeCodeForAccountId(code: code)
                    }
                }
            } catch {
                print("[LoginView] NPSSO auth exchange failed: \(error)")
            }
        }
        
        /// Exchange authorization code for token and extract account ID
        private func exchangeCodeForAccountId(code: String) async {
            guard let tokenUrl = URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/token") else { return }
            
            var request = URLRequest(url: tokenUrl)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            
            let body = [
                "code": code,
                "redirect_uri": "https://remoteplay.dl.playstation.net/remoteplay/redirect",
                "grant_type": "authorization_code",
                "token_format": "jwt"  // Request JWT format to get user info
            ]
            
            request.httpBody = body.map { "\($0.key)=\($0.value)" }
                .joined(separator: "&")
                .data(using: .utf8)
            
            // Add Basic auth header (Chiaki client)
            let credentials = "09515159-7237-4370-9b40-3806e67c0891:"
            if let credData = credentials.data(using: .utf8) {
                request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else { return }
                print("[LoginView] Token exchange status: \(httpResponse.statusCode)")
                
                if let rawResponse = String(data: data, encoding: .utf8) {
                    print("[LoginView] Token response: \(rawResponse.prefix(400))...")
                }
                
                if httpResponse.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("[LoginView] Token response keys: \(json.keys.joined(separator: ", "))")
                    
                    // Check for account_id directly
                    if let accountId = json["account_id"] as? String ?? json["accountId"] as? String {
                        print("[LoginView] ✅ Found account_id in token response: \(accountId)")
                        await storeAccountId(accountId)
                        return
                    }
                    
                    // Check for id_token (JWT with user info)
                    if let idToken = json["id_token"] as? String {
                        print("[LoginView] Found id_token, decoding...")
                        await decodeIdTokenForAccountId(idToken)
                        return
                    }
                    
                    // Check for access_token that might be a JWT
                    if let accessToken = json["access_token"] as? String {
                        print("[LoginView] Trying to decode access_token as JWT...")
                        await decodeIdTokenForAccountId(accessToken)
                    }
                }
            } catch {
                print("[LoginView] Token exchange failed: \(error)")
            }
        }
        
        /// Decode id_token (JWT) to extract account ID from sub claim
        private func decodeIdTokenForAccountId(_ token: String) async {
            let parts = token.split(separator: ".")
            guard parts.count >= 2 else {
                print("[LoginView] Token is not JWT format (parts: \(parts.count))")
                return
            }
            
            var payloadBase64 = String(parts[1])
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            
            let remainder = payloadBase64.count % 4
            if remainder > 0 {
                payloadBase64 += String(repeating: "=", count: 4 - remainder)
            }
            
            guard let payloadData = Data(base64Encoded: payloadBase64),
                  let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                print("[LoginView] Failed to decode JWT payload")
                return
            }
            
            print("[LoginView] JWT claims: \(json.keys.sorted().joined(separator: ", "))")
            
            // PSN uses 'sub' claim for account ID
            if let sub = json["sub"] as? String {
                print("[LoginView] ✅ Found account ID from JWT sub: \(sub)")
                await storeAccountId(sub)
                return
            }
            
            // Also check for explicit account_id
            if let accountId = json["account_id"] as? String ?? json["accountId"] as? String {
                print("[LoginView] ✅ Found account_id in JWT: \(accountId)")
                await storeAccountId(accountId)
            }
        }
        
        /// Alternative: Try to fetch from ssocookie using session cookies  
        private func fetchAccountIdFromSsoCookie(cookies: [HTTPCookie]) async {
            guard let url = URL(string: "https://ca.account.sony.com/api/v1/ssocookie") else { return }
            
            var request = URLRequest(url: url)
            
            // Add all session cookies
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else { return }
                print("[LoginView] ssocookie (alt) response status: \(httpResponse.statusCode)")
                
                if let rawResponse = String(data: data, encoding: .utf8) {
                    print("[LoginView] ssocookie (alt) response: \(rawResponse.prefix(300))...")
                }
                
                if httpResponse.statusCode == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let npsso = json["npsso"] as? String {
                        print("[LoginView] Got NPSSO from response, using for account ID exchange...")
                        await fetchAccountIdWithNPSSO(npsso: npsso)
                    }
                }
            } catch {
                print("[LoginView] Failed to fetch ssocookie (alt): \(error)")
            }
        }
        
        /// Decode NPSSO token to extract account ID
        private func decodeNpssoForAccountId(_ npsso: String) async {
            // NPSSO might be a JWT - try to decode it
            let parts = npsso.split(separator: ".")
            guard parts.count >= 2 else {
                print("[LoginView] NPSSO is not a JWT format")
                return
            }
            
            var payloadBase64 = String(parts[1])
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            
            let remainder = payloadBase64.count % 4
            if remainder > 0 {
                payloadBase64 += String(repeating: "=", count: 4 - remainder)
            }
            
            guard let payloadData = Data(base64Encoded: payloadBase64),
                  let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                print("[LoginView] Failed to decode NPSSO JWT payload")
                return
            }
            
            print("[LoginView] NPSSO JWT claims: \(json.keys.sorted().joined(separator: ", "))")
            
            if let accountId = json["sub"] as? String ?? json["account_id"] as? String {
                print("[LoginView] ✅ Found accountId from NPSSO: \(accountId)")
                await storeAccountId(accountId)
            }
        }
        
        /// Store the account ID in UserDefaults for later use
        private func storeAccountId(_ accountId: String) async {
            await MainActor.run {
                UserDefaults.standard.set(accountId, forKey: "psn_account_id")
                print("[LoginView] ✅ Stored PSN Account ID: \(accountId)")
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                parent.isLoading = false
                parent.onAuthenticationComplete(false, nil)
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                parent.isLoading = false
                print("WebView navigation error: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    NavigationStack {
        LoginView(navigationPath: .constant(NavigationPath()))
            .environmentObject(AppState())
    }
}
