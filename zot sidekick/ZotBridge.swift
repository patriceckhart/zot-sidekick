//
//  ZotBridge.swift
//  Zot Sidekick
//
//  Spawns `zot rpc` as a child process and communicates via JSON-line stdin/stdout.
//

import Foundation

struct ZotEvent {
    let type: String
    let raw: [String: Any]

    /// streaming text chunk (field name is "delta")
    var delta: String? { raw["delta"] as? String }

    /// tool name on tool_call
    var toolName: String? { raw["name"] as? String }

    /// tool result / assistant_message text (field name is "content")
    var content: String? { raw["content"] as? String }

    var id: String? { raw["id"] as? String }
    var command: String? { raw["command"] as? String }
    var success: Bool? { raw["success"] as? Bool }
    var stop: String? { raw["stop"] as? String }
    var message: String? { raw["message"] as? String }
    var errorText: String? { raw["error"] as? String }
    var isError: Bool? { raw["is_error"] as? Bool }
    var data: [String: Any]? { raw["data"] as? [String: Any] }

    /// Pretty-printed tool-call arguments, if present.
    var argsJSON: String? {
        guard let args = raw["args"] else { return nil }
        if let s = args as? String { return s }
        if let obj = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: obj, encoding: .utf8) {
            return s
        }
        return nil
    }
}

final class ZotBridge: @unchecked Sendable {
    private let zotPath: String
    private(set) var cwd: String?
    private var provider: String
    private var model: String
    private var apiKey: String
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var readBuffer = ""

    var onStateChange: ((_ connected: Bool, _ streaming: Bool) -> Void)?
    var onMessage: ((ZotEvent) -> Void)?

    private var isStreaming = false

    init(zotPath: String, cwd: String? = nil, provider: String = "anthropic", model: String = "", apiKey: String = "") {
        self.zotPath = zotPath
        self.cwd = cwd
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
    }

    func start() {
        guard process == nil else { return }

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        // Run the bundled binary directly (not via a shell) so we always
        // execute the zot version that ships inside the app bundle.
        proc.executableURL = URL(fileURLWithPath: zotPath)

        var args = ["rpc", "--provider", provider]
        if !model.isEmpty {
            args += ["--model", model]
        }
        proc.arguments = args
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        
        var env = ProcessInfo.processInfo.environment
        // Point the binary at our writable home so it reads auth.json
        // (API keys and subscription OAuth tokens) from there.
        env["ZOT_HOME"] = SidekickPaths.zotHome.path
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        if env["PATH"] == nil || env["PATH"]?.isEmpty == true {
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        if !apiKey.isEmpty {
            env["ANTHROPIC_API_KEY"] = apiKey
        }
        proc.environment = env
        
        if let cwd {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.handleOutput(text)
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                print("[zot stderr] \(text)")
            }
        }

        proc.terminationHandler = { [weak self] _ in
            print("[bridge] zot process terminated")
            self?.onStateChange?(false, false)
            self?.process = nil
        }

        do {
            try proc.run()
            print("[bridge] zot started (pid: \(proc.processIdentifier))")
            onStateChange?(true, false)
            // Handshake. The response triggers model loading in AppState.
            sendCommand(["id": "hello", "type": "hello"])
        } catch {
            print("[bridge] failed to start zot: \(error)")
            onStateChange?(false, false)
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        readBuffer = ""
        onStateChange?(false, false)
    }

    func sendCommand(_ command: [String: Any]) {
        guard let pipe = stdinPipe else {
            print("[bridge] zot not running, can't send command")
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: command)
            var line = data
            line.append(contentsOf: "\n".utf8)
            pipe.fileHandleForWriting.write(line)

            let type = command["type"] as? String ?? "?"
            print("[ext → zot] \(type)")
        } catch {
            print("[bridge] failed to serialize command: \(error)")
        }
    }

    func sendPrompt(_ text: String, images: [ImageAttachment] = []) {
        // Match the zot RPC protocol: images carry mime_type + base64 data.
        let imagePayload: [[String: String]] = images
            .filter { $0.mimeType.hasPrefix("image/") }
            .map { ["mime_type": $0.mimeType, "data": $0.base64] }
        sendCommand([
            "id": UUID().uuidString,
            "type": "prompt",
            "message": text,
            "images": imagePayload
        ])
    }

    func abort() {
        sendCommand(["id": UUID().uuidString, "type": "abort"])
    }

    func newSession() {
        sendCommand(["id": UUID().uuidString, "type": "new_session"])
    }

    func getModels() {
        sendCommand(["id": UUID().uuidString, "type": "get_models"])
    }

    func setModel(_ modelId: String) {
        sendCommand(["id": UUID().uuidString, "type": "set_model", "model": modelId])
    }

    private func handleOutput(_ text: String) {
        readBuffer += text

        while let newlineRange = readBuffer.range(of: "\n") {
            let line = String(readBuffer[readBuffer.startIndex..<newlineRange.lowerBound])
            readBuffer = String(readBuffer[newlineRange.upperBound...])

            guard !line.isEmpty else { continue }

            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            let event = ZotEvent(type: type, raw: json)

            switch type {
            case "assistant_start":
                isStreaming = true
                onStateChange?(true, true)
            case "done":
                isStreaming = false
                onStateChange?(true, false)
            default:
                break
            }

            onMessage?(event)
        }
    }
}

// MARK: - One-shot model fetch

enum ZotModelFetcher {
    /// Spawns a short-lived `zot rpc --provider <provider>`, requests the model
    /// list, and returns the model ids. Runs off the main actor.
    nonisolated static func fetchModels(
        zotPath: String,
        provider: String,
        zotHome: String,
        timeout: TimeInterval = 12
    ) -> [String] {
        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        proc.executableURL = URL(fileURLWithPath: zotPath)
        proc.arguments = ["rpc", "--provider", provider]
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = Pipe()

        var env = ProcessInfo.processInfo.environment
        env["ZOT_HOME"] = zotHome
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        if env["PATH"] == nil || env["PATH"]?.isEmpty == true {
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        proc.environment = env

        do { try proc.run() } catch { return [] }

        // Ask for the model list.
        let cmds = """
        {"id":"hello","type":"hello"}
        {"id":"m","type":"get_models"}
        """ + "\n"
        stdin.fileHandleForWriting.write(Data(cmds.utf8))

        // Read until we see the get_models response or time out.
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = ""
        var result: [String] = []
        let handle = stdout.fileHandleForReading

        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer += String(data: chunk, encoding: .utf8) ?? ""
            var done = false
            while let nl = buffer.range(of: "\n") {
                let line = String(buffer[buffer.startIndex..<nl.lowerBound])
                buffer = String(buffer[nl.upperBound...])
                guard let d = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if json["type"] as? String == "response",
                   json["command"] as? String == "get_models" {
                    if let data = json["data"] as? [String: Any],
                       let models = data["models"] as? [[String: Any]] {
                        result = models.compactMap { $0["id"] as? String }
                    }
                    done = true
                    break
                }
            }
            if done { break }
        }

        proc.terminate()
        return result
    }
}
