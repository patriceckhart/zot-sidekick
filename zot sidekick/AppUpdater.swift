//
//  AppUpdater.swift
//  zot sidekick
//
//  Checks the zot-sidekick GitHub releases for a version newer than this
//  running app and exposes the latest release URL for an in-app Update button.
//

import Foundation
import Observation

@Observable
final class AppUpdater {
    /// This app's own version (CFBundleShortVersionString).
    private(set) var currentVersion: String = AppUpdater.readCurrentVersion()
    /// Latest version tag found on GitHub, once fetched (without leading "v").
    private(set) var latestVersion: String?
    /// True when latestVersion is strictly newer than currentVersion.
    private(set) var updateAvailable = false
    /// Release page URL for the latest version, for the Update button.
    private(set) var releaseURL: URL?
    private(set) var isChecking = false

    private let repo = "patriceckhart/zot-sidekick"
    private var timer: Timer?

    private static func readCurrentVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// Checks now and then re-checks every 30 minutes so a release published
    /// while the app is running is picked up without a relaunch.
    func startPeriodicChecks() {
        checkForUpdate()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    /// Queries the GitHub releases API for the latest zot-sidekick release.
    /// Force a re-check even if one ran recently (e.g. when the panel opens).
    func checkForUpdate() {
        guard !isChecking else { return }
        isChecking = true

        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("zot-sidekick", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            Task { @MainActor in
                self.isChecking = false
                guard error == nil, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                self.latestVersion = latest
                if let html = json["html_url"] as? String {
                    self.releaseURL = URL(string: html)
                } else {
                    self.releaseURL = URL(string: "https://github.com/\(self.repo)/releases/tag/\(tag)")
                }
                self.updateAvailable = Self.isNewer(latest, than: self.currentVersion)
            }
        }.resume()
    }

    /// Returns true if `candidate` is a strictly newer dotted version than `current`.
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
