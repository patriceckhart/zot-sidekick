//
//  Zot_SidekickApp.swift
//  Zot Sidekick
//
//  Menu-bar-only AI assistant. Lives in the menu bar.
//  Long-press Right Option key to summon from anywhere.
//

import SwiftUI

@main
struct Zot_SidekickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
