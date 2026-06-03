//
//  ZotUpdater.swift
//  Zot Sidekick
//
//  Checks GitHub releases for newer versions of the zot binary and can
//  download and install a newer build entirely in Swift (no shell script).
//  The installed binary lives in Application Support so it can be replaced
//  at runtime; the app prefers it over the read-only bundled copy.
//

import Foundation
import Observation

@Observable
final class ZotUpdater {
    /// The version currently in use (installed copy if present, else bundled).
    private(set) var installedVersion: String = "unknown"
    /// The latest version available on GitHub, once fetched.
    private(set) var latestVersion: String?
    /// True when latestVersion is strictly newer than installedVersion.
    private(set) var updateAvailable = false
    /// URL of the GitHub release page, for the "Open" button.
    private(set) var releaseURL: URL?
    private(set) var isChecking = false
    /// True while a binary download/install is in progress.
    private(set) var isUpdating = false
    private(set) var lastError: String?

    /// Called after a successful binary install so the app can re-point and
    /// restart the bridge against the new binary.
    var onInstalled: ((_ newPath: URL, _ version: String) -> Void)?

    private let repo = "patriceckhart/zot"

    /// Where the updatable binary is installed (matches AppState).
    static var installedBinaryURL: URL {
        SidekickPaths.appSupport.appendingPathComponent("zot-bin")
    }

    /// UserDefaults key under which the installed binary's version is stored.
    static let installedVersionDefaultsKey = "zot_installed_version"

    /// The version that ships inside the app bundle (read-only build marker).
    static var bundledVersion: String {
        if let url = Bundle.main.url(forResource: "zot-version", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// The version of the binary currently installed in Application Support,
    /// persisted in app userdata (UserDefaults).
    static var storedInstalledVersion: String {
        get { UserDefaults.standard.string(forKey: installedVersionDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: installedVersionDefaultsKey) }
    }

    init() {
        installedVersion = Self.readInstalledVersion()
    }

    /// Refreshes the in-use version (call after AppState prepares the binary,
    /// in case it was just installed/updated).
    func refreshInstalledVersion() {
        installedVersion = Self.readInstalledVersion()
        if let latest = latestVersion {
            updateAvailable = Self.isNewer(latest, than: installedVersion)
        }
    }

    /// Reads the installed version from userdata, falling back to bundled.
    private static func readInstalledVersion() -> String {
        let stored = storedInstalledVersion
        if !stored.isEmpty { return stored }
        let bundled = bundledVersion
        return bundled.isEmpty ? "unknown" : bundled
    }

    // MARK: - Check

    /// Queries the GitHub releases API for the latest version.
    func checkForUpdate() {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil

        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Zot-Sidekick", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            Task { @MainActor in
                self.isChecking = false

                if let error {
                    self.lastError = error.localizedDescription
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    self.lastError = "Could not parse GitHub response"
                    return
                }

                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                self.latestVersion = latest
                if let html = json["html_url"] as? String {
                    self.releaseURL = URL(string: html)
                }
                self.updateAvailable = Self.isNewer(latest, than: self.installedVersion)
            }
        }.resume()
    }

    // MARK: - Install

    /// Downloads the latest darwin binary for this architecture, extracts it,
    /// and atomically replaces the installed binary. All in Swift.
    func downloadAndInstall() {
        guard !isUpdating, let version = latestVersion else { return }
        isUpdating = true
        lastError = nil

        let arch: String
        #if arch(arm64)
        arch = "darwin_arm64"
        #else
        arch = "darwin_amd64"
        #endif

        let urlString = "https://github.com/\(repo)/releases/download/v\(version)/zot_\(version)_\(arch).tar.gz"
        guard let url = URL(string: urlString) else {
            Task { @MainActor in
                self.isUpdating = false
                self.lastError = "Bad download URL"
            }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Zot-Sidekick", forHTTPHeaderField: "User-Agent")

        URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self else { return }
            do {
                if let error { throw error }
                guard let tempURL,
                      let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                    throw NSError(domain: "ZotUpdater", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Download failed"])
                }
                let newBinary = try Self.extractBinary(from: tempURL)
                try Self.installBinary(at: newBinary, version: version)
                Task { @MainActor in
                    self.isUpdating = false
                    self.installedVersion = version
                    self.updateAvailable = false
                    self.lastError = nil
                    self.onInstalled?(Self.installedBinaryURL, version)
                }
            } catch {
                Task { @MainActor in
                    self.isUpdating = false
                    self.lastError = error.localizedDescription
                }
            }
        }.resume()
    }

    /// Extracts the `zot` binary from a downloaded .tar.gz into a temp file.
    private static func extractBinary(from archive: URL) throws -> URL {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zot-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xzf", archive.path, "-C", workDir.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "ZotUpdater", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Extraction failed: \(err)"])
        }

        let binary = workDir.appendingPathComponent("zot")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw NSError(domain: "ZotUpdater", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No zot binary in archive"])
        }
        return binary
    }

    /// Atomically replaces the installed binary and records its version.
    private static func installBinary(at newBinary: URL, version: String) throws {
        let fm = FileManager.default
        let dest = installedBinaryURL
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        let staged = dest.deletingLastPathComponent().appendingPathComponent("zot-bin.new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: newBinary, to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)

        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: dest)
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)

        // Persist the installed version in app userdata.
        storedInstalledVersion = version
    }

    // MARK: - Version compare

    /// Semantic-ish version comparison: returns true if `candidate` > `current`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let c = candidate.split(separator: ".").compactMap { Int($0) }
        let cur = current.split(separator: ".").compactMap { Int($0) }
        guard !c.isEmpty, !cur.isEmpty else { return false }
        let count = max(c.count, cur.count)
        for i in 0..<count {
            let a = i < c.count ? c[i] : 0
            let b = i < cur.count ? cur[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
