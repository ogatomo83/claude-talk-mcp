//
//  TimingLog.swift
//  ClaudeTalkCore
//
//  1 往復の各段の時刻を ~/.claude-talk-mcp/logs/timing.jsonl に 1 行 1 イベントで残す (app / direct 共通)。
//  集計は tools/timing-report.py。
//
//  共通のキー: ev / mode / pid / turn / t (ISO8601) / at_ms (書いた時刻、epoch ms)。
//  "ms" は各イベントの経過時間 (fields で渡した時だけ)。2026-11-25 より前の行は "ms" が書いた時刻 (epoch ms) で、
//  at_ms はない (timing-report.py は at_ms が無ければ ms を時刻として読む)。
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

    /// 1 往復の番号を外から決める (claude-talk-voice は自分で数える)。
    public func setTurn(_ t: Int) {
        lock.lock(); turn = t; lock.unlock()
    }

    /// 1 行の中身を作る (pid・t・turn は event が足す)。書いた時刻は at_ms (epoch ms)。
    /// fields の "ms" (経過時間) は上書きしない (以前は epoch ms で上書きしていた)。
    public func encode(_ ev: String, modeName: String, fields: [String: Any], at date: Date) -> [String: Any] {
        var obj: [String: Any] = fields
        obj["ev"] = ev
        obj["mode"] = modeName
        obj["at_ms"] = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return obj
    }

    public var currentTurn: Int {
        lock.lock(); defer { lock.unlock() }
        return turn
    }

    /// 1 行書く。fields の値は JSON にできるもの (String / Int / Double / Bool)。
    public func event(_ ev: String, mode: TalkMode, fields: [String: Any] = [:], at date: Date = Date()) {
        event(ev, modeName: mode.rawValue, fields: fields, at: date)
    }

    /// mode が TalkMode に無いもの (claude-talk-voice の "voice") 用。
    public func event(_ ev: String, modeName: String, fields: [String: Any] = [:], at date: Date = Date()) {
        guard enabled else { return }
        var obj = encode(ev, modeName: modeName, fields: fields, at: date)
        obj["pid"] = Int(pid)
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
