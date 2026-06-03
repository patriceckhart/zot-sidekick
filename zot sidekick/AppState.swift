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
        let id: String
        let name: String
        let provider: String

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
    }

    let providerOptions: [ProviderOption] = [
        .init(id: "anthropic", displayName: "Anthropic (Claude)", supportsSubscription: true, oauthProvider: "anthropic"),
        .init(id: "openai", displayName: "OpenAI", supportsSubscription: false, oauthProvider: nil),
        .init(id: "openai-codex", displayName: "ChatGPT Subscription", supportsSubscription: true, oauthProvider: "openai-codex"),
        .init(id: "kimi", displayName: "Kimi", supportsSubscription: true, oauthProvider: "kimi"),
        .init(id: "google", displayName: "Google Gemini", supportsSubscription: false, oauthProvider: nil),
        .init(id: "deepseek", displayName: "DeepSeek", supportsSubscription: false, oauthProvider: nil),
        .init(id: "ollama", displayName: "Ollama", supportsSubscription: false, oauthProvider: nil)
    ]

    // MARK: - Paste mode
    var pasteMode = false
    var previousApp: NSRunningApplication?

    // MARK: - Bridge
    private(set) var bridge: ZotBridge?

    // MARK: - Updater
    let updater = ZotUpdater()

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
            }
        }
    }

    /// Removes stored auth for the current provider.
    func signOut() {
        try? authStore.removeProvider(provider)
        apiKey = ""
        loginStatus = "Signed out."
        restartBridge()
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
            availableModels = models.compactMap { dict in
                guard let id = dict["id"] as? String else { return nil }
                let name = (dict["name"] as? String) ?? id
                return ZotModel(id: id, name: name, provider: provider)
            }
            if selectedModel.isEmpty, let first = availableModels.first {
                selectedModel = first.id
            }
            print("[appstate] loaded \(availableModels.count) models")

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

    func selectModel(_ model: ZotModel) {
        selectedModel = model.id
        bridge?.setModel(model.id)
        saveSettings()
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
