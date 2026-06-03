//
//  AppDelegate.swift
//  Zot Sidekick
//
//  Owns the NSStatusItem (menu bar icon) and the floating panel.
//  Long-press Right Option key to summon from anywhere.
//  Click menu bar icon to toggle. Right-click for context menu.
//

import AppKit
import SwiftUI
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    let appState = AppState()
    private var hotkeyMonitor: HotkeyMonitor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request permissions
        requestPermissions()

        // Install screenshot helper
        installScreenshotHelper()

        // Menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let icon = NSImage(named: "MenuBarIcon")
            // Constrain the template image to a compact menu bar glyph size
            // so it renders crisply and leaves padding around it.
            icon?.size = NSSize(width: 14, height: 14)
            icon?.isTemplate = true
            button.image = icon
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Floating panel
        panelController = PanelController(appState: appState)

        // Long-press Right Option toggles the panel from anywhere.
        hotkeyMonitor = HotkeyMonitor { [weak self] in
            self?.panelController.toggle()
        }
        hotkeyMonitor.start()
    }

    // MARK: - Permissions

    private func requestPermissions() {
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                print("[permissions] Screen recording not yet granted: \(error)")
            }
        }

        // The global Right Option hotkey uses a CGEvent tap, which requires
        // Accessibility permission. Prompt for it on first launch.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        print("[permissions] Accessibility: \(trusted ? "granted" : "will prompt")")
    }

    // MARK: - Screenshot Helper

    private func installScreenshotHelper() {
        let binDir = NSHomeDirectory() + "/.zot/bin"
        let helperPath = binDir + "/zot-screenshot"

        if FileManager.default.isExecutableFile(atPath: helperPath) { return }

        let source = """
        import AppKit
        import ScreenCaptureKit

        @main
        struct ScreenshotHelper {
            static func main() async {
                let args = CommandLine.arguments
                let outPath = args.count > 1 ? args[1] : "/tmp/zot-screenshot.png"
                let maxDim = args.count > 2 ? Int(args[2]) ?? 1568 : 1568

                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let display = content.displays.first else {
                        fputs("No display found\\n", stderr)
                        exit(1)
                    }

                    let scale = min(Double(maxDim) / Double(display.width), Double(maxDim) / Double(display.height), 2.0)
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = Int(Double(display.width) * scale)
                    config.height = Int(Double(display.height) * scale)
                    config.capturesAudio = false
                    config.showsCursor = true

                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                        fputs("Failed to encode PNG\\n", stderr)
                        exit(1)
                    }
                    try pngData.write(to: URL(fileURLWithPath: outPath))
                    print("\\(config.width)x\\(config.height)")
                } catch {
                    fputs("Screenshot failed: \\(error)\\n", stderr)
                    exit(1)
                }
            }
        }
        """

        try? FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)

        let srcPath = binDir + "/zot-screenshot.swift"
        try? source.write(toFile: srcPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        process.arguments = ["-parse-as-library", "-O", "-o", helperPath, srcPath,
                             "-framework", "AppKit", "-framework", "ScreenCaptureKit"]
        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                print("[helper] zot-screenshot compiled and installed at \(helperPath)")
                try? FileManager.default.removeItem(atPath: srcPath)
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                print("[helper] compile failed: \(errStr)")
            }
        } catch {
            print("[helper] failed to run swiftc: \(error)")
        }
    }

    // MARK: - Status Item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            panelController.toggle()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "")
            .target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    @objc private func quitApp() {
        appState.bridge?.stop()
        hotkeyMonitor?.stop()
        NSApp.terminate(nil)
    }
}
