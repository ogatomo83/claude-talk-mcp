//
//  claude_talk_mcpApp.swift
//  claude-talk-mcp
//
//  メニューバー常駐アプリのエントリポイント。
//

import SwiftUI

@main
struct claude_talk_mcpApp: App {
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra("Claude Talk", systemImage: "waveform") {
            ContentView()
                .environment(state)
        }
        .menuBarExtraStyle(.window)
    }
}
