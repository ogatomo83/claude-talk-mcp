//
//  ContentView.swift
//  claude-talk-mcp
//
//  メニューバーから開くポップオーバーの中身。
//

import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            statusSection

            Divider()

            Toggle("ログイン時に自動起動", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)

            Divider()

            logSection

            Divider()

            HStack {
                Spacer()
                Button("終了") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Claude Talk")
                .font(.headline)
            Spacer()
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = state.socketError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else {
                Label("待受中", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                    .font(.callout)
            }

            HStack {
                Text("状態")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(state.activity.rawValue)
                    .fontWeight(.medium)
            }
            .font(.callout)

            Text(state.socketPath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("最近のやりとり")
                .font(.caption)
                .foregroundStyle(.secondary)

            if state.logs.isEmpty {
                Text("まだありません")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(state.logs.suffix(8).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(2)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }
}
