//
//  AppState.swift
//  Zot Sidekick
//
//  Shared application state — manages the Zot RPC bridge,
//  chat messages, streaming state, and authentication.
//

import SwiftUI
import Observation
import UniformTypeIdentifiers

@Observable
final class AppState {
    // MARK: - Connection
    var isConnected = false
    var isStreaming = false
    var bridgeStatus: String = "Disconnected"

    // MARK: - Chat
    var messages: [ChatMessage] = []
    var currentStreamingText: String = ""

    // MARK: - Model selection
    var selectedModel: String = "claude-3-5-sonnet-20241022"
    var availableModels: [ZotModel] = []

    struct ZotModel: Identifiable, Hashable {
        let id: String          // model id
        let name: String        // display name
        let provider: String    // provider id this model belongs to

        // Unique across providers (same model id can appear for two providers).
        var uniqueKey: String { "\(provider)/\(id)" }
        var displayName: String { name }
    }

    // MARK: - Settings
    var zotPath: String = ""
    var workingDirectory: String = NSHomeDirectory()
    var provider: String = "anthropic"
    var apiKey: String = ""

    // MARK: - Auth
    let authStore = ZotAuthStore()
    let oauthManager = ZotOAuthLoginManager()
    /// Live status text shown during/after a subscription login.
    var loginStatus: String = ""

    /// Providers offered in settings, mirroring the main zot app.
    struct ProviderOption: Identifiable, Hashable {
        let id: String           // value passed to `zot rpc --provider`
        let displayName: String
        let supportsSubscription: Bool
        let oauthProvider: String? // provider key for the OAuth manager
        let popularModels: [String]
        /// The auth.json key this provider's credential is stored under.
        var authKey: String { id == "openai-codex" ? "openai" : id }
    }

    let providerOptions: [ProviderOption] = [
        .init(id: "anthropic", displayName: "Anthropic (Claude)", supportsSubscription: true, oauthProvider: "anthropic",
              popularModels: ["claude-sonnet-4-5", "claude-opus-4-1", "claude-opus-4-0", "claude-sonnet-4-0", "claude-haiku-4-5", "claude-3-7-sonnet-20250219", "claude-3-5-sonnet-20241022", "claude-3-5-haiku-latest", "claude-3-opus-20240229", "claude-opus-4-5"]),
        .init(id: "openai", displayName: "OpenAI", supportsSubscription: false, oauthProvider: nil,
              popularModels: ["gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-4.1", "gpt-4.1-mini", "gpt-4o", "gpt-4o-mini", "o4-mini", "o3", "o3-mini"]),
        .init(id: "openai-codex", displayName: "ChatGPT Subscription", supportsSubscription: true, oauthProvider: "openai-codex",
              popularModels: ["gpt-5.2", "gpt-5.3-codex", "gpt-5.3-codex-spark", "gpt-5.4", "gpt-5.4-mini", "gpt-5.5", "gpt-5.5-mini"]),
        .init(id: "kimi", displayName: "Kimi", supportsSubscription: true, oauthProvider: "kimi",
              popularModels: ["kimi-for-coding"]),
        .init(id: "google", displayName: "Google Gemini", supportsSubscription: false, oauthProvider: nil,
              popularModels: ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.0-flash"]),
        .init(id: "deepseek", displayName: "DeepSeek", supportsSubscription: false, oauthProvider: nil,
              popularModels: ["deepseek-v4-pro", "deepseek-v4-flash"]),
        .init(id: "ollama", displayName: "Ollama", supportsSubscription: false, oauthProvider: nil,
              popularModels: [])
    ]

    // MARK: - Paste mode
    var pasteMode = false
    var previousApp: NSRunningApplication?

    // MARK: - Bridge
    private(set) var bridge: ZotBridge?

    // MARK: - Updater
    let updater = ZotUpdater()
    /// Checks for new releases of this app (zot sidekick) itself.
    let appUpdater = AppUpdater()

    // MARK: - Sessions
    private let sessionStore = SessionStore()
    /// All saved sessions, newest first. Refreshed via reloadSavedSessions().
    var savedSessions: [SavedSession] = []
    /// The id of the session currently shown, if it has been saved.
    private(set) var currentSessionID: UUID?
    private var currentSessionCreatedAt = Date()

    init() {
        prepareBinary()
        loadSettings()
        startBridge()
        updater.refreshInstalledVersion()
        updater.checkForUpdate()
        appUpdater.checkForUpdate()
        rebuildModelList()
        refreshAllModels()
        reloadSavedSessions()
        // When the updater installs a newer binary, re-point and restart.
        updater.onInstalled = { [weak self] newPath, _ in
            self?.zotPath = newPath.path
            self?.restartBridge()
        }
    }

    // MARK: - Bundled / Installed Binary

    /// Ensures a runnable zot binary exists in Application Support and points
    /// zotPath at it. The bundled (in-app) copy seeds the install; an updated
    /// copy downloaded by ZotUpdater is preferred and never clobbered by the
    /// bundled one unless the bundled version is newer.
    private func prepareBinary() {
        let fm = FileManager.default
        let destination = ZotUpdater.installedBinaryURL

        guard let bundled = Bundle.main.url(forResource: "zot-bin", withExtension: nil) else {
            // No bundled binary: use whatever is already installed, if any.
            if fm.isExecutableFile(atPath: destination.path) {
                zotPath = destination.path
            } else {
                zotPath = "/usr/local/bin/zot"
                print("[appstate] WARNING: no bundled or installed zot-bin")
            }
            return
        }

        let bundledVersion = ZotUpdater.bundledVersion
        let installedVersion = ZotUpdater.storedInstalledVersion

        let needsSeed = !fm.fileExists(atPath: destination.path)
            || (!bundledVersion.isEmpty && ZotUpdater.isNewer(bundledVersion, than: installedVersion))

        if needsSeed {
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try? fm.copyItem(at: bundled, to: destination)
            if !bundledVersion.isEmpty {
                ZotUpdater.storedInstalledVersion = bundledVersion
            }
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

        zotPath = destination.path
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "zot_provider") {
            provider = saved
        }
        if let saved = defaults.string(forKey: "zot_model") {
            selectedModel = saved
        }
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(provider, forKey: "zot_provider")
        defaults.set(selectedModel, forKey: "zot_model")
    }

    // MARK: - Auth helpers

    /// The configured auth method for the current provider, for the UI.
    func currentAuthStatus() -> ZotAuthStore.AuthStatus {
        authStore.authStatus(for: provider)
    }

    /// Saves an API key into auth.json for the current provider and restarts
    /// the bridge so it takes effect.
    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try authStore.saveAPIKey(provider: provider, key: trimmed)
            apiKey = trimmed
            loginStatus = "API key saved."
            saveSettings()
            restartBridge()
            rebuildModelList()
            refreshAllModels()
        } catch {
            loginStatus = "Failed to save API key: \(error.localizedDescription)"
        }
    }

    /// Begins the OAuth subscription login for the given provider.
    func startSubscriptionLogin(oauthProvider: String) {
        loginStatus = "Starting login…"
        oauthManager.start(provider: oauthProvider) { [weak self] message in
            self?.loginStatus = message
            // When login completes, restart the bridge to use the new token.
            if message.lowercased().contains("logged in") || message.lowercased().contains("configured") {
                self?.saveSettings()
                self?.restartBridge()
                self?.rebuildModelList()
                self?.refreshAllModels()
            }
        }
    }

    /// Removes stored auth for the current provider.
    func signOut() {
        try? authStore.removeProvider(provider)
        apiKey = ""
        loginStatus = "Signed out."
        liveModelsByProvider[provider] = nil
        restartBridge()
        rebuildModelList()
        refreshAllModels()
    }

    // MARK: - Bridge Lifecycle

    func startBridge() {
        bridge = ZotBridge(
            zotPath: zotPath,
            cwd: workingDirectory.isEmpty ? nil : workingDirectory,
            provider: provider,
            model: selectedModel,
            apiKey: apiKey
        )
        bridge?.onStateChange = { [weak self] connected, streaming in
            Task { @MainActor in
                self?.isConnected = connected
                self?.isStreaming = streaming
                self?.bridgeStatus = connected ? (streaming ? "Streaming..." : "Connected") : "Disconnected"
            }
        }
        bridge?.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handleBridgeMessage(message)
            }
        }
        bridge?.start()
    }

    func restartBridge() {
        bridge?.stop()
        messages = []
        currentStreamingText = ""
        availableModels = []
        startBridge()
    }

    func setWorkingDirectory(_ path: String) {
        workingDirectory = path
        restartBridge()
    }

    // MARK: - Send

    func sendPrompt(_ text: String, images: [ImageAttachment] = []) {
        let userMsg = ChatMessage(role: .user, content: text, images: images)
        messages.append(userMsg)
        bridge?.sendPrompt(text, images: images)
    }

    func abort() {
        bridge?.abort()
    }

    func newSession() {
        messages = []
        currentStreamingText = ""
        currentSessionID = nil
        currentSessionCreatedAt = Date()
        bridge?.abort()
        bridge?.newSession()
    }

    // MARK: - Session Persistence

    func reloadSavedSessions() {
        let store = sessionStore
        Task.detached {
            let list = store.loadSessions()
            await MainActor.run { self.savedSessions = list }
        }
    }

    /// Persists the current conversation. Reuses the current session id if
    /// one exists, otherwise creates a new saved session. Empty chats are
    /// not saved.
    @discardableResult
    func saveCurrentSession() -> SavedSession? {
        let realMessages = messages.filter { !$0.content.isEmpty }
        guard !realMessages.isEmpty else { return nil }

        var session = SavedSession()
        session.id = currentSessionID ?? UUID()
        session.title = Self.deriveTitle(from: realMessages)
        session.provider = provider
        session.model = selectedModel
        session.workingDirectory = workingDirectory
        session.messages = realMessages.map { StoredMessage($0) }
        session.createdAt = currentSessionCreatedAt
        session.updatedAt = Date()

        do {
            try sessionStore.save(session)
            currentSessionID = session.id
            reloadSavedSessions()
            return session
        } catch {
            print("[appstate] failed to save session: \(error)")
            return nil
        }
    }

    /// Loads a saved session into the panel. Restarts the bridge so the
    /// chosen working directory and model take effect.
    func loadSession(_ session: SavedSession) {
        currentSessionID = session.id
        currentSessionCreatedAt = session.createdAt
        provider = session.provider
        if !session.model.isEmpty { selectedModel = session.model }
        workingDirectory = session.workingDirectory
        messages = session.messages.map { $0.toChatMessage() }
        currentStreamingText = ""
        restartBridgeKeepingMessages()
    }

    func deleteSession(_ session: SavedSession) {
        sessionStore.delete(session)
        if currentSessionID == session.id {
            currentSessionID = nil
        }
        reloadSavedSessions()
    }

    /// Like restartBridge() but does not wipe the already-loaded messages.
    private func restartBridgeKeepingMessages() {
        bridge?.stop()
        availableModels = []
        startBridge()
    }

    private static func deriveTitle(from messages: [ChatMessage]) -> String {
        if let firstUser = messages.first(where: { $0.role == .user }) {
            let trimmed = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let oneLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
            return oneLine.isEmpty ? "New chat" : String(oneLine.prefix(60))
        }
        return "New chat"
    }

    // MARK: - Paste into active app

    func pasteResultIntoApp() {
        guard let lastAssistant = messages.last(where: { $0.role == .assistant }) else { return }
        let text = lastAssistant.content

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        if let app = previousApp {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let source = CGEventSource(stateID: .hidSystemState)
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
                keyDown?.flags = .maskCommand
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
                keyUp?.flags = .maskCommand
                keyDown?.post(tap: .cghidEventTap)
                keyUp?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Message Handling

    /// Tracks the streaming assistant message id and open tool calls.
    private var streamingIndex: Int?
    private var toolIndexByCallID: [String: Int] = [:]

    private func handleBridgeMessage(_ event: ZotEvent) {
        switch event.type {
        case "assistant_start":
            currentStreamingText = ""
            let msg = ChatMessage(role: .assistant, content: "", isStreaming: true)
            messages.append(msg)
            streamingIndex = messages.count - 1

        case "text_delta":
            guard let delta = event.delta else { return }
            currentStreamingText += delta
            if let idx = streamingIndex, messages.indices.contains(idx) {
                messages[idx].content = currentStreamingText
            } else {
                let msg = ChatMessage(role: .assistant, content: currentStreamingText, isStreaming: true)
                messages.append(msg)
                streamingIndex = messages.count - 1
            }

        case "assistant_message":
            if let content = event.content, !content.isEmpty,
               let idx = streamingIndex, messages.indices.contains(idx),
               messages[idx].content.isEmpty {
                messages[idx].content = content
            }

        case "tool_call":
            // The current assistant text turn is done; finalize it.
            finishStreaming()
            let callID = event.id ?? UUID().uuidString
            let name = event.toolName ?? "tool"
            let msg = ChatMessage(role: .tool, content: "Running \(name)…", isStreaming: true)
            messages.append(msg)
            toolIndexByCallID[callID] = messages.count - 1

        case "tool_result":
            let callID = event.id ?? ""
            let result = event.content ?? ""
            let trimmed = result.count > 400 ? String(result.prefix(400)) + "…" : result
            if let idx = toolIndexByCallID[callID], messages.indices.contains(idx) {
                let name = messages[idx].content
                    .replacingOccurrences(of: "Running ", with: "")
                    .replacingOccurrences(of: "…", with: "")
                let mark = (event.isError ?? false) ? "x" : "ok"
                messages[idx].content = "[\(mark)] \(name): \(trimmed)"
                messages[idx].isStreaming = false
            }

        case "error":
            let text = event.message ?? event.errorText ?? "Error"
            messages.append(ChatMessage(role: .system, content: text))
            finishStreaming()

        case "turn_end":
            if event.stop == "tool_use" { finishStreaming() }

        case "done":
            finishStreaming()
            for i in messages.indices where messages[i].role == .tool { messages[i].isStreaming = false }
            saveCurrentSession()

        case "response":
            handleRpcResponse(event)

        default:
            break
        }
    }

    private func finishStreaming() {
        if let idx = streamingIndex, messages.indices.contains(idx) {
            messages[idx].isStreaming = false
        }
        streamingIndex = nil
        currentStreamingText = ""
    }

    private func handleRpcResponse(_ event: ZotEvent) {
        let command = event.command ?? ""
        let success = event.success ?? false

        switch command {
        case "get_models":
            guard success,
                  let data = event.data,
                  let models = data["models"] as? [[String: Any]] else {
                print("[appstate] failed to get models: \(event.errorText ?? "unknown")")
                return
            }
            // Live models for the currently connected provider. Merge them
            // with the static lists from the other authenticated providers.
            let live: [ZotModel] = models.compactMap { dict in
                guard let id = dict["id"] as? String else { return nil }
                let name = (dict["name"] as? String) ?? id
                return ZotModel(id: id, name: name, provider: provider)
            }
            rebuildModelList(liveForCurrentProvider: live)
            print("[appstate] loaded \(availableModels.count) models across providers")

        case "hello":
            // Initial handshake. Pull the model list now that we're connected.
            bridge?.getModels()

        case "set_model":
            if !success {
                print("[appstate] failed to set model: \(event.errorText ?? "unknown")")
            }

        default:
            break
        }
    }

    /// Whether a specific provider option is logged in. The OpenAI pair
    /// shares one auth.json key, so distinguish them by method:
    ///   - "openai-codex" (ChatGPT subscription) requires an oauth entry,
    ///   - "openai" (API) requires an api_key entry.
    func isAuthenticated(_ option: ProviderOption) -> Bool {
        let status = authStore.authStatus(for: option.id)
        switch option.id {
        case "openai-codex": return status == .subscription
        case "openai":       return status == .apiKey
        default:             return status != .none
        }
    }

    /// Providers the user is logged into (api key or subscription).
    func authenticatedProviders() -> [ProviderOption] {
        providerOptions.filter { isAuthenticated($0) }
    }

    /// Live model ids fetched per provider (provider id -> [model id]).
    private var liveModelsByProvider: [String: [String]] = [:]

    /// Builds availableModels from every authenticated provider, using live
    /// models if we have fetched them, otherwise the known popular list.
    func rebuildModelList(liveForCurrentProvider live: [ZotModel] = []) {
        if !live.isEmpty {
            liveModelsByProvider[provider] = live.map { $0.id }
        }
        var result: [ZotModel] = []
        for option in authenticatedProviders() {
            let ids = liveModelsByProvider[option.id] ?? option.popularModels
            result.append(contentsOf: ids.map { ZotModel(id: $0, name: $0, provider: option.id) })
        }
        var seen = Set<String>()
        availableModels = result.filter { seen.insert($0.uniqueKey).inserted }

        if selectedModel.isEmpty, let first = availableModels.first {
            selectedModel = first.id
            provider = first.provider
        }
    }

    /// Fetches the full live model list for every authenticated provider via
    /// short-lived one-shot RPC processes, then rebuilds the menu.
    func refreshAllModels() {
        let path = zotPath
        let home = SidekickPaths.zotHome.path
        let providers = authenticatedProviders().map { $0.id }
        Task.detached {
            var fetched: [String: [String]] = [:]
            for p in providers {
                let ids = ZotModelFetcher.fetchModels(zotPath: path, provider: p, zotHome: home)
                if !ids.isEmpty { fetched[p] = ids }
            }
            await MainActor.run {
                for (p, ids) in fetched { self.liveModelsByProvider[p] = ids }
                self.rebuildModelList()
            }
        }
    }

    func selectModel(_ model: ZotModel) {
        let providerChanged = model.provider != provider
        selectedModel = model.id
        provider = model.provider
        saveSettings()
        if providerChanged {
            // Switching provider means a new bridge with the right credential.
            restartBridgeKeepingMessages()
        } else {
            bridge?.setModel(model.id)
        }
    }
}

// MARK: - Data Types

struct ChatMessage: Identifiable {
    let id = UUID()
    var role: MessageRole
    var content: String
    var images: [ImageAttachment] = []
    var isStreaming: Bool = false
    let timestamp = Date()
}

enum MessageRole {
    case user, assistant, tool, system
}

struct ImageAttachment: Identifiable {
    let id = UUID()
    let data: Data
    let mimeType: String
    let name: String

    var base64: String {
        data.base64EncodedString()
    }
}
