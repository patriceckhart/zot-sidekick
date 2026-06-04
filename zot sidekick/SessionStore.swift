//
//  SessionStore.swift
//  Zot Sidekick
//
//  Persists chat sessions as flat JSON files in Application Support.
//  Modeled on the main zot mac app's ZotSessionStore, but without
//  project folders: every session lives directly in one Sessions directory.
//

import Foundation

// MARK: - Codable models

/// A persisted chat message. Mirrors ChatMessage but is Codable and stores
/// images as base64 so a whole session round-trips through JSON.
nonisolated struct StoredMessage: Codable {
    var role: String
    var content: String
    var isStreaming: Bool
    var images: [StoredImage]
    var date: Date
    // Tool-call fields (optional for backward compatibility).
    var toolName: String? = nil
    var toolArgs: String? = nil
    var toolResult: String? = nil
    var toolIsError: Bool? = nil
}

nonisolated struct StoredImage: Codable {
    var data: Data
    var mimeType: String
    var name: String
}

/// A saved session: metadata plus its messages.
nonisolated struct SavedSession: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String = "New chat"
    var provider: String = "anthropic"
    var model: String = ""
    var workingDirectory: String = NSHomeDirectory()
    var messages: [StoredMessage] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

// MARK: - Paths

nonisolated enum SidekickPaths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("zot sidekick", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Flat directory holding one JSON file per session. No project subfolders.
    static var sessionsRoot: URL {
        let url = appSupport.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The ZOT_HOME we hand to the bundled binary. auth.json (API keys and
    /// subscription OAuth tokens) lives here, exactly as the zot CLI expects.
    static var zotHome: URL {
        let url = appSupport.appendingPathComponent("zot-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Store

nonisolated final class SessionStore {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// All saved sessions, newest first.
    func loadSessions() -> [SavedSession] {
        let root = SidekickPaths.sessionsRoot
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(SavedSession.self, from: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ session: SavedSession) throws {
        let url = SidekickPaths.sessionsRoot.appendingPathComponent("\(session.id.uuidString).json")
        let data = try encoder.encode(session)
        try data.write(to: url, options: [.atomic])
    }

    func delete(_ session: SavedSession) {
        let url = SidekickPaths.sessionsRoot.appendingPathComponent("\(session.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Conversions

extension StoredMessage {
    init(_ message: ChatMessage) {
        self.role = {
            switch message.role {
            case .user: return "user"
            case .assistant: return "assistant"
            case .tool: return "tool"
            case .system: return "system"
            }
        }()
        self.content = message.content
        self.isStreaming = false
        self.images = message.images.map { StoredImage(data: $0.data, mimeType: $0.mimeType, name: $0.name) }
        self.date = message.timestamp
        self.toolName = message.toolName
        self.toolArgs = message.toolArgs
        self.toolResult = message.toolResult
        self.toolIsError = message.toolIsError
    }

    func toChatMessage() -> ChatMessage {
        let r: MessageRole = {
            switch role {
            case "user": return .user
            case "assistant": return .assistant
            case "tool": return .tool
            default: return .system
            }
        }()
        let imgs = images.map { ImageAttachment(data: $0.data, mimeType: $0.mimeType, name: $0.name) }
        var msg = ChatMessage(role: r, content: content, images: imgs, isStreaming: false)
        msg.toolName = toolName
        msg.toolArgs = toolArgs
        msg.toolResult = toolResult
        msg.toolIsError = toolIsError
        return msg
    }
}
