//
//  CapsLock.swift
//  ClaudeTalkCore
//
//  Caps Lock がオンの間だけマイクを入れる (T-0038)。direct/settings.json の "capsLock" ({"capsLock": {"enabled": false}} で今までの動き)。
//
//  状態の知り方: 読みに行く (ポーリング)。macOS の許可 (入力監視・アクセシビリティ) が要らない方法だけを使う。
//    - flags (既定): CGEventSource.flagsState(.combinedSessionState) の maskAlphaShift。WindowServer と共有のメモリを読むだけで、
//      1 回 3ns ほど (M 系の Mac で測った値)。50ms ごとに読んでも CPU は測れないほど小さい
//    - hid: IOHIDGetModifierLockState (IOHIDSystem の Caps Lock の lock)。1 回 0.5µs ほど
//    イベントで知る方法 (NSEvent の global monitor・CGEventTap・IOHIDManager) は、どれも入力監視かアクセシビリティの許可が要る
//    (許可は Claude Code を動かしているアプリ = iTerm2 などに付く)。許可を増やさないため使わない。
//
//  マイクの音の扱い: マイクのリングには今まで通り音を残す (プリロールのため)。オフの区間の音は、聞き取り (listen) と
//  読み上げ中の見張り (割り込み) に送る前に 0 (無音) にする。だからオフの間は聞き取りも割り込みも起きない。
//  オンになった時は、オンを見つける直前の読みの時刻から leadMs 前の音から使う (押してすぐ話しても頭が切れない)。
//

import Foundation
import CoreGraphics
import IOKit

/// direct/settings.json の "capsLock"。全項目省略可。
public struct CapsLockSettings: Codable, Equatable, Sendable {
    /// true: Caps Lock がオンの間だけマイクを入れる。false: 今までの動き (いつでも聞く)
    public var enabled: Bool = true
    /// 状態を読む間隔 (ms)。オン・オフに気付くまでの遅れの上限
    public var pollMs: Int = 50
    /// オンになった時、この ms 前の音から使う (頭切れの保険)
    public var leadMs: Int = 150
    /// オフのままの listen は、この秒数で caps_lock_off を返す (MCP の呼び出しを長く止めすぎないため)。skill はもう一度 listen を呼ぶ
    public var offMaxWaitSeconds: Double = 300
    /// 読み方: `flags` (CGEventSource、既定) / `hid` (IOHIDSystem)。どちらも許可は要らない
    public var source: String = "flags"

    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, pollMs, leadMs, offMaxWaitSeconds, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CapsLockSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        pollMs = try c.decodeIfPresent(Int.self, forKey: .pollMs) ?? d.pollMs
        leadMs = try c.decodeIfPresent(Int.self, forKey: .leadMs) ?? d.leadMs
        offMaxWaitSeconds = try c.decodeIfPresent(Double.self, forKey: .offMaxWaitSeconds) ?? d.offMaxWaitSeconds
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? d.source
    }

    public var pollNs: UInt64 { UInt64(min(max(pollMs, 10), 1000)) * 1_000_000 }
    public var leadNs: UInt64 { UInt64(max(leadMs, 0)) * 1_000_000 }
}

/// Caps Lock の今の状態を読む口 (テストでは差し替える)。
public protocol CapsLockReader: Sendable {
    func isOn() -> Bool
}

/// CGEventSource.flagsState の maskAlphaShift (許可は要らない)。
public struct FlagsCapsLockReader: CapsLockReader {
    public init() {}
    public func isOn() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }
}

/// いつもオン (録音の WAV で数える開発用の eval。本物の Caps Lock を見ない)。
public struct AlwaysOnCapsLockReader: CapsLockReader {
    public init() {}
    public func isOn() -> Bool { true }
}

/// IOHIDSystem の Caps Lock の lock (許可は要らない)。開けなければ flags で読む。
public final class HIDCapsLockReader: CapsLockReader, @unchecked Sendable {
    private var conn: io_connect_t = 0
    private let lock = NSLock()

    public init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        var c: io_connect_t = 0
        if IOServiceOpen(svc, mach_task_self_, UInt32(kIOHIDParamConnectType), &c) == KERN_SUCCESS { conn = c }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    public var available: Bool { conn != 0 }

    public func isOn() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard conn != 0 else { return FlagsCapsLockReader().isOn() }
        var state = false
        guard IOHIDGetModifierLockState(conn, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS else {
            return FlagsCapsLockReader().isOn()
        }
        return state
    }
}

/// 読んだ結果の時系列 (音や時計を持たない部分。テストで確かめる)。
/// オンの区間は [オンを見つける直前の読みの時刻 - lead, オフを見つけた読みの時刻)。
public struct CapsLockTimeline: Sendable {
    public struct Span: Sendable, Equatable {
        public var from: UInt64
        /// nil = 今もオン
        public var to: UInt64?
    }

    public let leadNs: UInt64
    public let retainNs: UInt64
    public private(set) var spans: [Span] = []
    /// 最後に読んだ時刻 (この時刻までの状態は分かっている)
    public private(set) var lastPollAt: UInt64?
    public private(set) var isOn = false
    /// 今のオン・オフになった (見つけた) 時刻
    public private(set) var changedAt: UInt64?

    public init(leadNs: UInt64, retainNs: UInt64 = 30_000_000_000) {
        self.leadNs = leadNs
        self.retainNs = retainNs
    }

    /// 読んだ結果を足す。オン・オフが変わったら true。
    @discardableResult
    public mutating func record(on: Bool, at now: UInt64) -> Bool {
        defer { lastPollAt = now }
        guard let prev = lastPollAt else {
            // 最初の読み: オンなら少し前からオンとみなす (読み始める前の音は分からないので lead だけ)
            isOn = on
            changedAt = now
            if on { spans.append(Span(from: now > leadNs ? now - leadNs : 0, to: nil)) }
            return true
        }
        guard on != isOn else { trim(now: now); return false }
        isOn = on
        changedAt = now
        if on {
            // 前の読み (prev) より後に押された。prev から lead 前の音から使う
            let from = prev > leadNs ? prev - leadNs : 0
            spans.append(Span(from: from, to: nil))
        } else if !spans.isEmpty, spans[spans.count - 1].to == nil {
            spans[spans.count - 1].to = now
        }
        trim(now: now)
        return true
    }

    private mutating func trim(now: UInt64) {
        let cutoff = now > retainNs ? now - retainNs : 0
        spans.removeAll { ($0.to ?? UInt64.max) < cutoff }
    }

    /// `t` の時点でオンか (分かっていない時刻は今の状態)。
    public func isOn(at t: UInt64) -> Bool {
        if let last = lastPollAt, t > last { return isOn }
        return spans.contains { $0.from <= t && t < ($0.to ?? UInt64.max) }
    }

    /// その音の終わりまで状態が分かっているか (分かるまで送るのを待つ)。
    public func covers(_ piece: AudioPiece) -> Bool {
        guard let last = lastPollAt else { return false }
        return piece.end <= last
    }

    /// オフの区間のサンプルを 0 にする。全部オンならそのまま、全部オフなら全部 0 (長さと時刻は変えない: Realtime の時刻がずれないため)。
    public func mask(_ piece: AudioPiece) -> AudioPiece {
        let n = piece.data.count / 2
        guard n > 0 else { return piece }
        // サンプルの区間 [i, j) ごとにオン・オフを決める (境目はオンの区間の端だけ)
        func time(_ i: Int) -> UInt64 { piece.start &+ PCM.nanoseconds(bytes: i * 2) }
        var cuts: [Int] = [0, n]
        for s in spans {
            for edge in [Optional(s.from), s.to].compactMap({ $0 }) where edge > piece.start && edge < piece.end {
                cuts.append(min(n, PCM.bytes(nanoseconds: edge - piece.start) / 2))
            }
        }
        if let last = lastPollAt, last > piece.start, last < piece.end {
            cuts.append(min(n, PCM.bytes(nanoseconds: last - piece.start) / 2))
        }
        cuts = Array(Set(cuts)).sorted()
        var offRanges: [Range<Int>] = []
        for k in 0..<(cuts.count - 1) where cuts[k] < cuts[k + 1] {
            if !isOn(at: time(cuts[k])) { offRanges.append(cuts[k]..<cuts[k + 1]) }
        }
        if offRanges.isEmpty { return piece }
        var data = piece.data
        data.withUnsafeMutableBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for r in offRanges { for i in r { s[i] = 0 } }
        }
        return AudioPiece(start: piece.start, data: data)
    }

    /// `since` 以降で最初にオンになった時刻 (オンの区間の始まり)。今オンで、その区間が since より前から続くなら since。
    public func onStart(since: UInt64) -> UInt64? {
        guard isOn, let cur = spans.last, cur.to == nil else { return nil }
        return max(cur.from, since)
    }
}

/// Caps Lock を pollMs ごとに読み、時系列を持つ。マイクを開けている間だけ動かす (DirectEngine)。
public final class CapsLockGate: @unchecked Sendable {
    public let settings: CapsLockSettings
    private let reader: CapsLockReader
    private let lock = NSLock()
    private var timeline: CapsLockTimeline
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "claude-talk.capslock", qos: .userInitiated)
    /// オン・オフが変わった時 (ログ用)
    public var onChange: (@Sendable (Bool) -> Void)?

    public init(settings: CapsLockSettings, reader: CapsLockReader? = nil) {
        self.settings = settings
        if let reader {
            self.reader = reader
        } else if settings.source.lowercased() == "hid" {
            self.reader = HIDCapsLockReader()
        } else {
            self.reader = FlagsCapsLockReader()
        }
        timeline = CapsLockTimeline(leadNs: settings.leadNs)
    }

    public var enabled: Bool { settings.enabled }

    /// 読み始める (何度呼んでもよい)。最初の読みはその場で行う。
    public func start() {
        guard settings.enabled else { return }
        lock.lock()
        let running = timer != nil
        lock.unlock()
        if running { return }
        poll()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let ns = settings.pollNs
        t.schedule(deadline: .now() + .nanoseconds(Int(ns)), repeating: .nanoseconds(Int(ns)), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.poll() }
        lock.lock()
        timer = t
        lock.unlock()
        t.resume()
    }

    public func stop() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }

    /// 今読む (テストからも呼ぶ)。
    public func poll(at now: UInt64 = PCM.now()) {
        let on = reader.isOn()
        lock.lock()
        let changed = timeline.record(on: on, at: now)
        lock.unlock()
        if changed { onChange?(on) }
    }

    public var snapshot: CapsLockTimeline { lock.lock(); defer { lock.unlock() }; return timeline }

    /// 今オンか (無効なら常に true)。
    public var isOn: Bool {
        guard settings.enabled else { return true }
        return snapshot.isOn
    }

    /// 今のオン・オフになってからの秒数。
    public func secondsInState(now: UInt64 = PCM.now()) -> Double {
        guard let c = snapshot.changedAt, now > c else { return 0 }
        return Double(now - c) / 1e9
    }

    /// 送る前の音: オフの区間を 0 にする。状態がまだ分かっていない所があれば、読みが追いつくまで待つ (最大 pollMs の数倍)。
    public func masked(_ piece: AudioPiece) async -> AudioPiece {
        guard settings.enabled else { return piece }
        let deadline = PCM.now() &+ settings.pollNs * 4 &+ 200_000_000
        while !snapshot.covers(piece), PCM.now() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return snapshot.mask(piece)
    }

    /// 同期版 (待たない。分かっていない所は今の状態)。
    public func maskedNow(_ piece: AudioPiece) -> AudioPiece {
        guard settings.enabled else { return piece }
        return snapshot.mask(piece)
    }

    /// `t` の時点でオンか (無効なら常に true)。
    public func isOn(at t: UInt64) -> Bool {
        guard settings.enabled else { return true }
        return snapshot.isOn(at: t)
    }
}

/// listen の返す文の 1 行目 (Caps Lock がオフのままだった)。
public enum CapsLockListen {
    public static let marker = "caps_lock_off"

    public static func text(waitedSeconds: Double) -> String {
        """
        \(marker)
        Caps Lock がオフのままでした (\(Int(waitedSeconds.rounded())) 秒待ちました)。ユーザーはまだ話していません。何も読み上げずに、もう一度 listen を呼んでください。
        """
    }
}
