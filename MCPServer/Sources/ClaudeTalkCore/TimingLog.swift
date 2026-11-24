//
//  TimingLog.swift
//  ClaudeTalkCore
//
//  1 往復の各段の時刻を ~/.claude-talk-mcp/logs/timing.jsonl に 1 行 1 イベントで残す (app / direct 共通)。
//  集計は tools/timing-report.py。
//
//  主なイベント (ev):
//    speak.recv / speak.audio_start (direct) / speak.done
//    listen.recv / listen.server_ready / listen.mic_ready / listen.ws_ready (direct)
//    asr.speech_started / asr.speech_stopped / asr.completed (direct)
//    listen.return
//  app モードは音声アプリの中が見えないので recv / done / return と所要時間だけ。
//

import Foundation

public final class TimingLog: @unchecked Sendable {
    public static let shared = TimingLog()

    private let lock = NSLock()
    private var handle: FileHandle?
    private var openedPath: String?
    private let pid = ProcessInfo.processInfo.processIdentifier
    /// listen を受けるたびに 1 増やす (1 往復の番号)。
    private var turn = 0
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone.current
        return f
    }()

    /// 書き込みを止める (テスト用)。
    public var enabled = ProcessInfo.processInfo.environment["CLAUDE_TALK_TIMING_LOG"] != "0"

    public init() {}

    public func nextTurn() -> Int {
        lock.lock(); defer { lock.unlock() }
        turn += 1
        return turn
    }

    public var currentTurn: Int {
        lock.lock(); defer { lock.unlock() }
        return turn
    }

    /// 1 行書く。fields の値は JSON にできるもの (String / Int / Double / Bool)。
    public func event(_ ev: String, mode: TalkMode, fields: [String: Any] = [:], at date: Date = Date()) {
        guard enabled else { return }
        var obj: [String: Any] = fields
        obj["ev"] = ev
        obj["mode"] = mode.rawValue
        obj["pid"] = Int(pid)
        obj["ms"] = Int64((date.timeIntervalSince1970 * 1000).rounded())
        lock.lock(); defer { lock.unlock() }
        obj["t"] = iso.string(from: date)
        if obj["turn"] == nil { obj["turn"] = turn }
        guard let line = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        write(line + Data([0x0A]))
    }

    private func write(_ data: Data) {
        let url = TalkPaths.timingLog
        if handle == nil || openedPath != url.path {
            try? handle?.close()
            TalkPaths.ensureDir(url.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            openedPath = url.path
        }
        guard let handle else { return }
        // O_APPEND 相当: 複数セッションの MCP サーバーが同じファイルに書くので毎回末尾へ。
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

/// 経過ミリ秒 (単調時計)。
public struct Stopwatch: Sendable {
    public let start: UInt64 = DispatchTime.now().uptimeNanoseconds
    public init() {}
    public var ms: Int { Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000) }
}
