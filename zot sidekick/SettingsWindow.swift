//
//  SettingsWindow.swift
//  Zot Sidekick
//
//  Settings window for API key configuration.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var tempApiKey: String = ""
    @State private var tempProvider: String = "anthropic"
    @Environment(\.dismiss) private var dismiss

    private var selectedOption: AppState.ProviderOption? {
        appState.providerOptions.first { $0.id == tempProvider }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Zot Sidekick Settings")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .padding(.top)

            Form {
                Section(header: Text("Provider").font(.system(size: 12, design: .monospaced))) {
                    Picker("Provider", selection: $tempProvider) {
                        ForEach(appState.providerOptions) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: tempProvider) {
                        appState.provider = tempProvider
                        appState.loginStatus = ""
                    }
                }

                authSection

                Section(header: Text("Model").font(.system(size: 12, design: .monospaced))) {
                    TextField("Model ID (optional)", text: $appState.selectedModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                }

                Section(header: Text("Zot Binary").font(.system(size: 12, design: .monospaced))) {
                    HStack {
                        Text("Bundled version")
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Text(appState.updater.installedVersion)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if appState.updater.isChecking {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Checking for updates…")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    } else if appState.updater.updateAvailable, let latest = appState.updater.latestVersion {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.orange)
                            Text("Update available: \(latest)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Open Release") {
                                if let url = appState.updater.releaseURL {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.system(size: 11, design: .monospaced))
                        }
                    } else if let latest = appState.updater.latestVersion {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Up to date (latest \(latest))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Check for Updates") {
                        appState.updater.checkForUpdate()
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") {
                    appState.provider = tempProvider
                    appState.selectedModel = appState.selectedModel
                    appState.saveSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 460, height: 520)
        .onAppear {
            tempProvider = appState.provider
            tempApiKey = ""
        }
    }

    // MARK: - Auth Section

    @ViewBuilder
    private var authSection: some View {
        Section(header: Text("Authentication").font(.system(size: 12, design: .monospaced))) {
            // Current status
            HStack(spacing: 6) {
                switch appState.currentAuthStatus() {
                case .subscription:
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Subscription configured").font(.system(size: 12, design: .monospaced))
                case .apiKey:
                    Image(systemName: "key.fill").foregroundStyle(.blue)
                    Text("API key configured").font(.system(size: 12, design: .monospaced))
                case .none:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Not signed in").font(.system(size: 12, design: .monospaced))
                }
                Spacer()
                if appState.currentAuthStatus() != .none {
                    Button("Sign Out") { appState.signOut() }
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            // Subscription login (only for providers that support it)
            if let option = selectedOption, option.supportsSubscription, let oauth = option.oauthProvider {
                Button {
                    appState.startSubscriptionLogin(oauthProvider: oauth)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                        Text("Log in with \(option.displayName) subscription")
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
            }

            // API key entry
            VStack(alignment: .leading, spacing: 6) {
                Text("Or use an API key")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack {
                    SecureField("Enter API key", text: $tempApiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                    Button("Save Key") {
                        appState.saveAPIKey(tempApiKey)
                        tempApiKey = ""
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(tempApiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            // Live status line
            if !appState.loginStatus.isEmpty {
                Text(appState.loginStatus)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    convenience init(appState: AppState) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false

        let hostingController = NSHostingController(rootView: SettingsView(appState: appState))
        window.contentViewController = hostingController

        self.init(window: window)
    }

    static func show(appState: AppState) {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let controller = SettingsWindowController(appState: appState)
            shared = controller
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
