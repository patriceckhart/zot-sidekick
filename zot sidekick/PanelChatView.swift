//
//  PanelChatView.swift
//  Zot Sidekick
//
//  The SwiftUI view inside the floating panel.
//  Dark pill input bar with model selector, chat area, and drag-drop
//  for images/PDFs.
//

import SwiftUI
import UniformTypeIdentifiers

private let mono: Font = .system(size: 13, design: .monospaced)
private let monoSmall: Font = .system(size: 11, design: .monospaced)
private let monoInput: Font = .system(size: 14, design: .monospaced)

struct PanelChatView: View {
    var appState: AppState
    var onClose: () -> Void

    @State private var inputText = ""
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var isInputFocused: Bool
    @State private var attachedImages: [ImageAttachment] = []
    @State private var isDragOver = false
    @State private var showSessions = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 4)

            if appState.messages.isEmpty {
                Spacer(minLength: 0)
                emptyState
                Spacer(minLength: 0)
            } else {
                chatArea
                Spacer(minLength: 0)
            }

            if !attachedImages.isEmpty {
                attachmentBar
            }

            inputPill
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 32)
                .fill(.ultraThinMaterial)
                // Solid dark tint on top of the blur so text stays legible
                // over bright/colorful backgrounds, in light and dark mode.
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .fill(Color.black.opacity(0.35))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .stroke(isDragOver ? Color.blue.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .overlay {
            if showSettings {
                InlineSettingsView(appState: appState) {
                    withAnimation(.easeInOut(duration: 0.18)) { showSettings = false }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .overlay {
            if showSessions {
                SessionBrowserView(
                    appState: appState,
                    onSelect: { session in
                        appState.loadSession(session)
                        withAnimation(.easeInOut(duration: 0.18)) { showSessions = false }
                    },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.18)) { showSessions = false }
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .environment(\.colorScheme, .dark)
        .onAppear {
            isInputFocused = true
        }
        .onDrop(of: [.image, .pdf, .fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button {
                appState.loginStatus = ""
                withAnimation(.easeInOut(duration: 0.18)) { showSettings = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, design: .monospaced))
                    Text("Settings")
                        .font(monoSmall)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")

            Button {
                appState.reloadSavedSessions()
                withAnimation(.easeInOut(duration: 0.18)) { showSessions = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, design: .monospaced))
                    Text("Sessions")
                        .font(monoSmall)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Browse saved sessions")

            // Small primary Update button when a newer app release exists.
            if appState.appUpdater.updateAvailable, let latest = appState.appUpdater.latestVersion {
                Button {
                    if let url = appState.appUpdater.releaseURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10, design: .monospaced))
                        Text("Update")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.85))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("zot sidekick \(latest) is available. Click to open the release.")
            }

            if appState.updater.updateAvailable, let latest = appState.updater.latestVersion {
                Button {
                    if let url = appState.updater.releaseURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10, design: .monospaced))
                        Text("zot \(latest) available")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("A newer zot release is available on GitHub. Click to open.")
            }

            Spacer()

            Button {
                appState.newSession()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, design: .monospaced))
                    Text("New")
                        .font(monoSmall)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New session")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image("ZotAvatar")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)

            Text("Drop images here or type below")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// Hide empty, non-streaming assistant/system bubbles (e.g. the
    /// placeholder created before tool calls). Tool bubbles always show.
    private var visibleMessages: [ChatMessage] {
        appState.messages.filter { m in
            switch m.role {
            case .tool:
                return true
            case .assistant, .system:
                return m.isStreaming || !m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !m.images.isEmpty
            case .user:
                return true
            }
        }
    }

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleMessages) { message in
                        if message.role == .tool {
                            ToolBubble(message: message)
                                .id(message.id)
                        } else {
                            MessageBubble(
                                message: message,
                                onCopy: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(message.content, forType: .string)
                                },
                                onPaste: {
                                    // Hide the panel first so it releases key
                                    // focus, then activate the target app and
                                    // paste into it.
                                    onClose()
                                    appState.pasteResultIntoApp()
                                }
                            )
                            .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onAppear {
                scrollProxy = proxy
                scrollToBottom(proxy)
            }
            // New message added.
            .onChange(of: appState.messages.count) {
                scrollToBottom(proxy)
            }
            // Last message growing while the agent streams its reply.
            .onChange(of: appState.messages.last?.content) {
                scrollToBottom(proxy)
            }
            // Streaming finished: settle at the very bottom.
            .onChange(of: appState.isStreaming) { _, streaming in
                if !streaming { scrollToBottom(proxy) }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = appState.messages.last else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var inputPill: some View {
        HStack(spacing: 10) {
            modelSelector

            Button {
                pickWorkingDirectory()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, design: .monospaced))
                    if !appState.workingDirectory.isEmpty {
                        Text(cwdDisplayName)
                            .font(.system(size: 9, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(appState.workingDirectory.isEmpty ? "Set working directory" : appState.workingDirectory)

            TextField("Ask anything ...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(monoInput)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .onSubmit {
                    send()
                }

            if appState.isStreaming {
                Button {
                    appState.abort()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22, design: .monospaced))
                        .foregroundStyle(canSend ? .white : .gray.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var modelSelector: some View {
        Menu {
            // Group models by provider so all logged-in providers are shown.
            ForEach(appState.providerOptions) { option in
                let models = appState.availableModels.filter { $0.provider == option.id }
                if !models.isEmpty {
                    Section(option.displayName) {
                        ForEach(models) { model in
                            Button {
                                appState.selectModel(model)
                            } label: {
                                HStack {
                                    Text(model.displayName)
                                    if model.id == appState.selectedModel && model.provider == appState.provider {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, design: .monospaced))
                Text(selectedModelDisplayName)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var selectedModelDisplayName: String {
        appState.availableModels.first(where: { $0.id == appState.selectedModel && $0.provider == appState.provider })?.displayName
            ?? (appState.selectedModel.isEmpty ? "Loading..." : appState.selectedModel)
    }

    private var cwdDisplayName: String {
        let path = appState.workingDirectory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let short = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let components = short.split(separator: "/")
        if components.count <= 2 { return String(short) }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    private var attachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachedImages) { img in
                    HStack(spacing: 4) {
                        if let nsImage = NSImage(data: img.data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: "doc.fill")
                                .frame(width: 32, height: 32)
                        }
                        Text(img.name)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)

                        Button {
                            attachedImages.removeAll { $0.id == img.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a directory or file for zot to work in"
        panel.prompt = "Select"
        panel.level = .floating

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            var isDir: ObjCBool = false
            let path: String
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                path = url.path
            } else {
                path = url.deletingLastPathComponent().path
            }
            appState.setWorkingDirectory(path)
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty || !attachedImages.isEmpty
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty else { return }

        let prompt = text.isEmpty ? "Analyse these attachments." : text
        let images = attachedImages
        inputText = ""
        attachedImages = []
        appState.sendPrompt(prompt, images: images)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    guard let data = data else { return }
                    if let image = NSImage(data: data),
                       let tiff = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiff),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        DispatchQueue.main.async {
                            self.attachedImages.append(ImageAttachment(data: pngData, mimeType: "image/png", name: "dropped.png"))
                        }
                    }
                }
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async {
                        self.loadFileAsAttachment(url)
                    }
                }
            }
        }
    }

    private func loadFileAsAttachment(_ url: URL) {
        let ext = url.pathExtension.lowercased()

        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) {
            if let data = try? Data(contentsOf: url) {
                if let image = NSImage(data: data),
                   let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    attachedImages.append(ImageAttachment(data: pngData, mimeType: "image/png", name: url.lastPathComponent))
                }
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var onCopy: () -> Void = {}
    var onPaste: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            if message.role == .assistant {
                Image("ZotAvatar")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .padding(.top, 2)
            }

            if message.role == .tool {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.orange)
                    .frame(width: 22, height: 22)
                    .padding(.top, 2)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if !message.images.isEmpty {
                    ForEach(message.images) { img in
                        if let nsImage = NSImage(data: img.data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 200, maxHeight: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }

                if message.content.isEmpty && message.isStreaming {
                    TypingIndicator()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(bubbleBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    Text(message.content)
                        .font(mono)
                        .foregroundStyle(foregroundColor)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubbleBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                if message.role == .assistant && !message.isStreaming {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Button { onCopy() } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        Button { onPaste() } label: {
                            Label("Paste into …", systemImage: "doc.on.clipboard.fill")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 12)
                    .padding(.top, 2)
                }

            }

            if message.role != .user {
                Spacer(minLength: 40)
            }
        }
    }

    private var foregroundColor: Color {
        switch message.role {
        case .user: .white
        case .assistant: .white.opacity(0.95)
        case .tool: .white.opacity(0.7)
        case .system: .secondary
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        switch message.role {
        case .user:
            Color.blue.opacity(0.5)
        case .assistant:
            Color.white.opacity(0.1)
        case .tool:
            Color.orange.opacity(0.12)
        case .system:
            Color.gray.opacity(0.1)
        }
    }
}

// MARK: - Session Browser

struct SessionBrowserView: View {
    var appState: AppState
    let onSelect: (SavedSession) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""

    private var filtered: [SavedSession] {
        guard !searchText.isEmpty else { return appState.savedSessions }
        let q = searchText.lowercased()
        return appState.savedSessions.filter {
            $0.title.lowercased().contains(q)
            || $0.workingDirectory.lowercased().contains(q)
            || $0.model.lowercased().contains(q)
        }
    }

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header (matches the inline settings view)
            HStack {
                Text("Sessions")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(appState.savedSessions.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.8))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider().overlay(Color.white.opacity(0.08))

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("Search sessions…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.2))
                    Text(appState.savedSessions.isEmpty ? "No saved sessions yet" : "No matches")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { session in
                            sessionRow(session)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 32)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 32).fill(Color.black.opacity(0.7)))
        )
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .environment(\.colorScheme, .dark)
    }

    private func sessionRow(_ session: SavedSession) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(cwdShort(session.workingDirectory))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                    Text("|").foregroundStyle(.white.opacity(0.15))
                    Text("\(session.messages.count) msgs")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                    if !session.model.isEmpty {
                        Text("|").foregroundStyle(.white.opacity(0.15))
                        Text(session.model)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Text(Self.dateFormatter.localizedString(for: session.updatedAt, relativeTo: Date()))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.25))

            Button {
                appState.deleteSession(session)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
            .help("Delete session")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(session) }
    }

    private func cwdShort(_ cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }
}

// MARK: - Inline Settings (rendered inside the overlay panel)

struct InlineSettingsView: View {
    var appState: AppState
    var onClose: () -> Void

    @State private var apiKeyDraft = ""
    @State private var modelDraft = ""

    private var selectedOption: AppState.ProviderOption? {
        appState.providerOptions.first { $0.id == appState.provider }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button {
                    appState.selectedModel = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    appState.saveSettings()
                    onClose()
                } label: {
                    Text("Done")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.8))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    providerSection
                    authSection
                    modelSection
                    binarySection
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 32)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 32).fill(Color.black.opacity(0.7)))
        )
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .onAppear {
            apiKeyDraft = ""
            modelDraft = appState.selectedModel
        }
    }

    // MARK: Sections

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Provider")
            Menu {
                ForEach(appState.providerOptions) { option in
                    Button {
                        appState.provider = option.id
                        appState.loginStatus = ""
                    } label: {
                        HStack {
                            Text(option.displayName)
                            if option.id == appState.provider { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(selectedOption?.displayName ?? appState.provider)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }

    private var authSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Authentication")

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
                        .buttonStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.white.opacity(0.85))

            if let option = selectedOption, option.supportsSubscription, let oauth = option.oauthProvider {
                Button {
                    appState.startSubscriptionLogin(oauthProvider: oauth)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                        Text("Log in with \(option.displayName) subscription")
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Or use an API key")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    SecureField("Enter API key", text: $apiKeyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Button("Save") {
                        appState.saveAPIKey(apiKeyDraft)
                        apiKeyDraft = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.white.opacity(0.06) : Color.blue.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !appState.loginStatus.isEmpty {
                Text(appState.loginStatus)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Model")
            TextField("Model ID (optional)", text: $modelDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var binarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("zot binary")
            HStack(spacing: 8) {
                Text("Installed")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(appState.updater.installedVersion)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                if appState.updater.updateAvailable, let latest = appState.updater.latestVersion {
                    Text("(\(latest) available)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange)
                }

                Spacer()

                // Primary action button, aligned right on the same row.
                Button {
                    if appState.updater.updateAvailable {
                        appState.updater.downloadAndInstall()
                    } else {
                        appState.updater.checkForUpdate()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if appState.updater.isUpdating || appState.updater.isChecking {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: appState.updater.updateAvailable ? "arrow.down.circle.fill" : "arrow.clockwise")
                        }
                        Text(primaryUpdateLabel)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.blue.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(appState.updater.isUpdating || appState.updater.isChecking)
            }

            if let error = appState.updater.lastError {
                Text(error)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var primaryUpdateLabel: String {
        if appState.updater.isUpdating { return "Updating…" }
        if appState.updater.isChecking { return "Checking…" }
        if appState.updater.updateAvailable { return "Update zot" }
        return "Check for Updates"
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.35))
            .tracking(1)
    }
}

// MARK: - Typing Indicator

/// Three dots that bounce in sequence while the agent is preparing a reply.
struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .opacity(animating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever()
                            .delay(Double(i) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

// MARK: - Tool Bubble (collapsible read/write/edit/bash preview)

struct ToolBubble: View {
    let message: ChatMessage
    @State private var expanded = false

    private var toolName: String { message.toolName ?? "tool" }
    private var isError: Bool { message.toolIsError == true }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName(for: toolName))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isError ? Color.red : Color.cyan)
                .frame(width: 22, height: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                        Text(toolName)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(summary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if message.isStreaming {
                            ProgressView().controlSize(.mini).scaleEffect(0.7)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if let args = message.toolArgs, !args.isEmpty, args != "{}" {
                            ToolCodeBlock(title: "arguments", text: args)
                        }
                        if let result = message.toolResult, !result.isEmpty {
                            ToolCodeBlock(title: isError ? "error" : "result", text: result)
                        } else if message.isStreaming {
                            Text("running…")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.top, 6)
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isError ? Color.red.opacity(0.35) : Color.cyan.opacity(0.18))
            )

            Spacer(minLength: 40)
        }
    }

    private var summary: String {
        if message.isStreaming { return "running" }
        if isError { return "failed" }
        return "completed"
    }

    private func iconName(for tool: String) -> String {
        switch tool {
        case "read": return "doc.text.magnifyingglass"
        case "write": return "square.and.pencil"
        case "edit": return "pencil.line"
        case "bash": return "terminal"
        default: return "wrench.and.screwdriver"
        }
    }
}

private struct ToolCodeBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(0.5)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.07)))
        }
    }
}
