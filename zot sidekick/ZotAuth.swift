//
//  ZotAuth.swift
//  Zot Sidekick
//
//  Writes API keys and subscription OAuth tokens into the bundled binary's
//  ZOT_HOME/auth.json, in exactly the format the zot CLI reads. Ported from
//  the main zot mac app so subscription login works the same way here.
//

import Foundation

nonisolated struct ZotOAuthToken: Codable {
    var accessToken: String
    var refreshToken: String
    var tokenType: String
    var expiry: Date?
    var scope: String
    var clientID: String
    var idToken: String?
    var accountID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiry, scope
        case clientID = "client_id"
        case idToken = "id_token"
        case accountID = "account_id"
    }
}

/// Reads/writes ZOT_HOME/auth.json. Keys are provider names; each holds an
/// "api_key" string and/or an "oauth" object.
nonisolated final class ZotAuthStore {
    private var authURL: URL { SidekickPaths.zotHome.appendingPathComponent("auth.json") }

    func saveAPIKey(provider: String, key: String) throws {
        var root = loadRawAuth()
        let authProvider = provider == "openai-codex" ? "openai" : provider
        var object = (root[authProvider] as? [String: Any]) ?? [:]
        object["api_key"] = key
        if authProvider != "openai" { object.removeValue(forKey: "oauth") }
        root[authProvider] = object
        try writeRawAuth(root)
    }

    func saveOAuth(provider: String, token: ZotOAuthToken) throws {
        var root = loadRawAuth()
        let authProvider = provider == "openai-codex" ? "openai" : provider
        var object = (root[authProvider] as? [String: Any]) ?? [:]
        var oauth: [String: Any] = [
            "access_token": token.accessToken,
            "refresh_token": token.refreshToken,
            "token_type": token.tokenType,
            "scope": token.scope,
            "client_id": token.clientID
        ]
        if let expiry = token.expiry { oauth["expiry"] = Self.rfc3339.string(from: expiry) }
        if let idToken = token.idToken { oauth["id_token"] = idToken }
        if let accountID = token.accountID { oauth["account_id"] = accountID }
        object["oauth"] = oauth
        if authProvider != "openai" { object.removeValue(forKey: "api_key") }
        root[authProvider] = object
        try writeRawAuth(root)
    }

    func removeProvider(_ provider: String) throws {
        var root = loadRawAuth()
        let authProvider = provider == "openai-codex" ? "openai" : provider
        root.removeValue(forKey: authProvider)
        try writeRawAuth(root)
    }

    /// Returns the configured auth method for a provider, for UI display.
    func authStatus(for provider: String) -> AuthStatus {
        let authProvider = provider == "openai-codex" ? "openai" : provider
        let root = loadRawAuth()
        guard let object = root[authProvider] as? [String: Any] else { return .none }
        if object["oauth"] != nil { return .subscription }
        if let key = object["api_key"] as? String, !key.isEmpty { return .apiKey }
        return .none
    }

    enum AuthStatus {
        case none, apiKey, subscription
    }

    private static let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func loadRawAuth() -> [String: Any] {
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func writeRawAuth(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: authURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    }
}
