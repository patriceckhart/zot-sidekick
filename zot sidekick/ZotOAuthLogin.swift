//
//  ZotOAuthLogin.swift
//  Zot Sidekick
//
//  Subscription login (OAuth) for Anthropic Claude, ChatGPT, and Kimi.
//  Ported from the main zot mac app. Tokens are written to
//  ZOT_HOME/auth.json so the bundled zot binary uses the subscription.
//

import Foundation
import CryptoKit
import Network
import AppKit

nonisolated struct ZotOAuthProviderConfig {
    let provider: String
    let authProvider: String
    let authURL: String
    let tokenURL: String
    let clientID: String
    let scopes: [String]
    let redirectHost: String
    let redirectPort: UInt16
    let redirectPath: String
    let extraAuthArgs: [String: String]
    let tokenBodyJSON: Bool
    let stateEqualsVerifier: Bool
    let includeStateInTokenRequest: Bool

    var redirectURI: String { "http://\(redirectHost):\(redirectPort)\(redirectPath)" }

    static let anthropic = ZotOAuthProviderConfig(
        provider: "anthropic",
        authProvider: "anthropic",
        authURL: "https://claude.ai/oauth/authorize",
        tokenURL: "https://platform.claude.com/v1/oauth/token",
        clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        scopes: ["org:create_api_key", "user:profile", "user:inference"],
        redirectHost: "localhost",
        redirectPort: 53692,
        redirectPath: "/callback",
        extraAuthArgs: ["code": "true"],
        tokenBodyJSON: true,
        stateEqualsVerifier: true,
        includeStateInTokenRequest: true
    )

    static let openAI = ZotOAuthProviderConfig(
        provider: "openai-codex",
        authProvider: "openai",
        authURL: "https://auth.openai.com/oauth/authorize",
        tokenURL: "https://auth.openai.com/oauth/token",
        clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
        scopes: ["openid", "profile", "email", "offline_access"],
        redirectHost: "localhost",
        redirectPort: 1455,
        redirectPath: "/auth/callback",
        extraAuthArgs: [
            "id_token_add_organizations": "true",
            "codex_cli_simplified_flow": "true",
            "originator": "zot"
        ],
        tokenBodyJSON: false,
        stateEqualsVerifier: false,
        includeStateInTokenRequest: false
    )

    static func forProvider(_ provider: String) -> ZotOAuthProviderConfig? {
        switch provider {
        case "anthropic": return anthropic
        case "openai-codex", "openai": return openAI
        default: return nil
        }
    }
}

nonisolated final class ZotOAuthLoginManager: @unchecked Sendable {
    private var listener: NWListener?
    private let authStore = ZotAuthStore()

    func start(provider: String, status: @escaping @MainActor (String) -> Void) {
        if provider == "kimi" {
            Task { await startKimi(status: status) }
            return
        }
        guard let config = ZotOAuthProviderConfig.forProvider(provider) else {
            Task { @MainActor in status("Subscription login is available for Anthropic, ChatGPT, and Kimi.") }
            return
        }
        Task { await startLoopback(config: config, status: status) }
    }

    private func startLoopback(config: ZotOAuthProviderConfig, status: @escaping @MainActor (String) -> Void) async {
        do {
            let pkce = makePKCE()
            let state = config.stateEqualsVerifier ? pkce.verifier : randomHex(byteCount: 16)
            let url = authorizeURL(config: config, pkce: pkce, state: state)
            await MainActor.run { status("Opening login in your browser…") }
            try startCallbackServer(config: config, state: state) { [weak self] result in
                guard let self else { return }
                Task {
                    switch result {
                    case .success(let code):
                        await MainActor.run { status("Exchanging authorization code…") }
                        do {
                            let token = try await self.exchange(config: config, code: code, state: state, pkce: pkce)
                            try self.authStore.saveOAuth(provider: config.authProvider, token: token)
                            await MainActor.run { status("Logged in. Subscription is configured.") }
                        } catch {
                            await MainActor.run { status(error.localizedDescription) }
                        }
                    case .failure(let error):
                        await MainActor.run { status(error.localizedDescription) }
                    }
                    self.listener?.cancel()
                    self.listener = nil
                }
            }
            openBrowser(url)
        } catch {
            await MainActor.run { status(error.localizedDescription) }
        }
    }

    private func startCallbackServer(config: ZotOAuthProviderConfig, state: String, completion: @escaping (Result<String, Error>) -> Void) throws {
        listener?.cancel()
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: config.redirectPort)!)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error { completion(.failure(error)); return }
                guard let data, let request = String(data: data, encoding: .utf8) else { return }
                let firstLine = request.components(separatedBy: "\r\n").first ?? ""
                let pathPart = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let result = self.parseCallback(pathPart: pathPart, expectedPath: config.redirectPath, expectedState: state)
                let html: String
                switch result {
                case .success:
                    html = Self.successHTML()
                case .failure(let error):
                    html = Self.errorHTML(error.localizedDescription)
                }
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
                completion(result)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func parseCallback(pathPart: String, expectedPath: String, expectedState: String) -> Result<String, Error> {
        guard let components = URLComponents(string: "http://localhost\(pathPart)") else {
            return .failure(oauthError("Invalid callback URL."))
        }
        guard components.path == expectedPath else {
            return .failure(oauthError("Unexpected callback path."))
        }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            return .failure(oauthError(error))
        }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else {
            return .failure(oauthError("OAuth state mismatch."))
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return .failure(oauthError("Missing authorization code."))
        }
        return .success(code)
    }

    private func exchange(config: ZotOAuthProviderConfig, code: String, state: String, pkce: (verifier: String, challenge: String)) async throws -> ZotOAuthToken {
        var payload = [
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "code": code,
            "redirect_uri": config.redirectURI,
            "code_verifier": pkce.verifier
        ]
        if config.includeStateInTokenRequest { payload["state"] = state }
        let data: Data
        var request = URLRequest(url: URL(string: config.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if config.tokenBodyJSON {
            data = try JSONSerialization.data(withJSONObject: payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else {
            data = formEncoded(payload).data(using: .utf8)!
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = data
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw oauthError(String(data: responseData, encoding: .utf8) ?? "Token exchange failed")
        }
        var token = try decodeToken(responseData, clientID: config.clientID)
        if config.provider == "openai-codex", let idToken = token.idToken {
            token.accountID = extractOpenAIAccountID(idToken)
        }
        return token
    }

    private func startKimi(status: @escaping @MainActor (String) -> Void) async {
        do {
            await MainActor.run { status("Starting Kimi device login…") }
            let auth = try await requestKimiDeviceAuthorization()
            await MainActor.run { status("Kimi code: \(auth.userCode). Complete login in your browser.") }
            if let url = URL(string: auth.verificationURIComplete.isEmpty ? auth.verificationURI : auth.verificationURIComplete) {
                openBrowser(url.absoluteString)
            }
            let token = try await pollKimi(auth)
            try authStore.saveOAuth(provider: "kimi", token: token)
            await MainActor.run { status("Logged in to Kimi subscription.") }
        } catch {
            await MainActor.run { status(error.localizedDescription) }
        }
    }

    private struct KimiDeviceAuth: Decodable {
        let userCode: String
        let deviceCode: String
        let verificationURI: String
        let verificationURIComplete: String
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case userCode = "user_code"
            case deviceCode = "device_code"
            case verificationURI = "verification_uri"
            case verificationURIComplete = "verification_uri_complete"
            case interval
        }
    }

    private func requestKimiDeviceAuthorization() async throws -> KimiDeviceAuth {
        var request = URLRequest(url: URL(string: "https://auth.kimi.com/api/oauth/device_authorization")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zot", forHTTPHeaderField: "User-Agent")
        request.httpBody = "client_id=17e5f671-d194-4dfb-9706-5516cb48c098".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw oauthError(String(data: data, encoding: .utf8) ?? "Kimi device authorization failed")
        }
        return try JSONDecoder().decode(KimiDeviceAuth.self, from: data)
    }

    private func pollKimi(_ auth: KimiDeviceAuth) async throws -> ZotOAuthToken {
        while true {
            var request = URLRequest(url: URL(string: "https://auth.kimi.com/api/oauth/token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("zot", forHTTPHeaderField: "User-Agent")
            request.httpBody = "client_id=17e5f671-d194-4dfb-9706-5516cb48c098&device_code=\(auth.deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code".data(using: .utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return try decodeToken(data, clientID: "17e5f671-d194-4dfb-9706-5516cb48c098")
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? String,
               error != "authorization_pending", error != "slow_down" {
                throw oauthError(error)
            }
            try await Task.sleep(for: .seconds(max(auth.interval, 5)))
        }
    }

    private func decodeToken(_ data: Data, clientID: String) throws -> ZotOAuthToken {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let access = object?["access_token"] as? String, !access.isEmpty else { throw oauthError("Empty access token.") }
        var expiry: Date?
        if let seconds = object?["expires_in"] as? Double { expiry = Date().addingTimeInterval(seconds) }
        if let seconds = object?["expires_in"] as? Int { expiry = Date().addingTimeInterval(TimeInterval(seconds)) }
        return ZotOAuthToken(
            accessToken: access,
            refreshToken: object?["refresh_token"] as? String ?? "",
            tokenType: object?["token_type"] as? String ?? "",
            expiry: expiry,
            scope: object?["scope"] as? String ?? "",
            clientID: clientID,
            idToken: object?["id_token"] as? String,
            accountID: nil
        )
    }

    private func authorizeURL(config: ZotOAuthProviderConfig, pkce: (verifier: String, challenge: String), state: String) -> String {
        var components = URLComponents(string: config.authURL)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        items += config.extraAuthArgs.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        return components.url!.absoluteString
    }

    private func makePKCE() -> (verifier: String, challenge: String) {
        let verifier = randomBase64URL(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return (verifier, Data(digest).base64URLEncodedString())
    }

    private func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private func formEncoded(_ values: [String: String]) -> String {
        values.map { key, value in "\(escape(key))=\(escape(value))" }.joined(separator: "&")
    }

    private func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func openBrowser(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    private func extractOpenAIAccountID(_ idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2, let data = Data(base64URLString: String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = object["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    private static func successHTML() -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"/><title>zot - logged in</title>\(monoStyle)</head><body>
        <h1><span class="mark">OK</span> logged in</h1>
        <hr class="rule">
        <p class="muted"><span class="zot">zot</span> received the callback. You can close this tab and return to the app.</p>
        </body></html>
        """
    }

    private static func errorHTML(_ message: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"/><title>zot - error</title>\(monoStyle)</head><body>
        <h1><span class="mark">X</span> login failed</h1>
        <hr class="rule">
        <p class="msg mono">\(htmlEscape(message))</p>
        <p class="muted">Go back to <span class="zot">zot</span> and try again.</p>
        </body></html>
        """
    }

    private static let monoStyle = """
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; background: #0a0a0a; color: #ffffff; max-width: 44rem; margin: 0 auto; padding: 3rem 1.5rem; line-height: 1.55; }
          h1 { font-size: 1rem; font-weight: 600; margin: 0 0 0.25rem; }
          .zot { color: #7ed3fc; }
          .rule { border: 0; border-top: 1px solid #ffffff; margin: 1.5rem 0; }
          .muted { color: #9ca3af; }
          .mono { word-break: break-all; }
        </style>
        """

    private static func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func oauthError(_ message: String) -> NSError {
        NSError(domain: "ZotOAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString: String) {
        var value = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        self.init(base64Encoded: value)
    }
}
