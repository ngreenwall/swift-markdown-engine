//
//  PerfTrace.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 07.07.26.
//
//  TEMP diagnostics (typing performance). Prints one compact line per keystroke
//  with a per-phase breakdown plus the current document length, so we can see
//  which costs grow with file size instead of staying constant. The whole point:
//  type in a short file, then a long one, and compare `total` for the same edit.
//
//  Toggle: set the env var MD_PERF=0 in the run scheme to silence.
//  Debug-only — the whole thing compiles out in Release.
//  Remove before shipping (this file + the `PerfTrace.` call sites).
//

import Foundation

enum PerfTrace {
#if DEBUG
    static var enabled = ProcessInfo.processInfo.environment["MD_PERF"] != "0"
    /// Opt-in for the sampled full-rebuild verifier asserts (wiki splice,
    /// backtick census, parse buffer). They run 3× O(doc) work synchronously
    /// on every 64th keystroke — periodic spikes that pollute the PERF
    /// numbers — so they stay off unless explicitly requested.
    static let verifyEnabled = ProcessInfo.processInfo.environment["MD_PERF_VERIFY"] == "1"
#else
    static let enabled = false
    static let verifyEnabled = false
#endif

    // All call sites run on the main thread (the coordinator + text view are
    // main-actor), so plain static state is safe under the package's Swift 5 mode.
    private static var active = false
    private static var frameStart: UInt64 = 0
    private static var docLength = 0
    private static var phases: [(String, Double)] = []
    private static var notes: [String] = []
    /// Summed costs for code that runs MANY times per frame or from inside
    /// AppKit callbacks (caret reveal, spell-checker callbacks) — printed as
    /// `+label=…(×n)` after the sequential phases.
    private static var accumulated: [(String, Double, Int)] = []

    private static func nowMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }

    /// Open a per-keystroke frame. Every `measure`/`note` until `end()` attaches to it.
    /// A frame already opened this keystroke is CONTINUED, not reset:
    /// shouldChangeTextIn opens the frame (so the pre-edit parse and the
    /// smart-input interceptors are counted — they used to run before the
    /// frame and were invisible), the mid-edit selection change and
    /// textDidChange attach to it. A frame left open by an edit that never
    /// reached textDidChange is considered stale after 1s and reset.
    static func begin(docLength len: Int) {
        guard enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        docLength = len
        if active, Double(now - frameStart) / 1_000_000 < 1_000 { return }
        active = true
        phases.removeAll(keepingCapacity: true)
        notes.removeAll(keepingCapacity: true)
        accumulated.removeAll(keepingCapacity: true)
        frameStart = now
    }

    /// Like `measure`, but SUMS repeated calls under one label instead of
    /// appending a phase per call — for work triggered from inside AppKit
    /// (caret reveal, spell-checker callbacks) that can fire several times
    /// per keystroke and would otherwise stay invisible in the frame.
    @discardableResult
    static func accumulate<T>(_ label: String, _ body: () -> T) -> T {
        // Feeds whichever frame is open. These are the per-item AppKit callbacks
        // (layout-fragment provider, spell-check, caret reveal) — they fire during
        // a document switch just as much as during typing, and until the switch
        // frame existed they were invisible there.
        guard enabled, active || swActive else { return body() }
        let t0 = nowMs()
        let result = body()
        let dt = nowMs() - t0
        if active {
            if let i = accumulated.firstIndex(where: { $0.0 == label }) {
                accumulated[i].1 += dt
                accumulated[i].2 += 1
            } else {
                accumulated.append((label, dt, 1))
            }
        }
        if swActive { switchAdd(label, ms: dt) }
        return result
    }

    /// Time one sequential top-level phase of the current frame.
    @discardableResult
    static func measure<T>(_ label: String, _ body: () -> T) -> T {
        guard enabled, active else { return body() }
        let t0 = nowMs()
        let result = body()
        phases.append((label, nowMs() - t0))
        return result
    }

    /// Attach a free-form detail line (e.g. how many tables were re-rendered).
    /// The closure only runs when tracing is active, so it costs nothing when off.
    static func note(_ make: () -> String) {
        guard enabled, active else { return }
        notes.append(make())
    }

    /// Record a named timestamp (offset from frame start) inline in the
    /// breakdown, printed as `@label=12.34`. The gaps BETWEEN checkpoints and
    /// the measured spans locate work the spans don't cover (AppKit edit
    /// application, layout, notification dispatch between our callbacks).
    static func checkpoint(_ label: String) {
        guard enabled, active else { return }
        phases.append(("@" + label, Double(DispatchTime.now().uptimeNanoseconds - frameStart) / 1_000_000))
    }

    /// Close the frame and print total + per-phase breakdown + notes.
    /// `other` = total − Σ(phases + accumulated): time inside the frame that
    /// no span covers (AppKit edit processing, layout, unmeasured code).
    static func end() {
        guard enabled, active else { return }
        active = false
        let total = Double(DispatchTime.now().uptimeNanoseconds - frameStart) / 1_000_000
        var breakdown = phases.map { String(format: "%@=%.2f", $0.0, $0.1) }.joined(separator: " ")
        if !accumulated.isEmpty {
            breakdown += " " + accumulated.map { String(format: "+%@=%.2f(×%d)", $0.0, $0.1, $0.2) }.joined(separator: " ")
        }
        let covered = phases.filter { !$0.0.hasPrefix("@") }.reduce(0) { $0 + $1.1 }
            + accumulated.reduce(0) { $0 + $1.1 }
        print(String(format: "⌨️ PERF doc=%dch total=%.2fms | %@ other=%.2f", docLength, total, breakdown, total - covered))
        for note in notes { print("    └─ \(note)") }
    }

    /// Standalone timing print for a cost that runs *outside* the keystroke frame
    /// (e.g. the async wide-table overlay reconcile fired after the edit settles).
    static func stamp(_ label: String, _ ms: Double, _ detail: @autoclosure () -> String = "") {
        guard enabled else { return }
        print(String(format: "⏱️ PERF %@ %.2fms %@", label, ms, detail()))
    }

    // MARK: - Node-switch frame
    //
    // The keystroke frame above is gated on `active`, which ONLY `begin(docLength:)`
    // sets — and only the typing path calls it. So the document-switch path has
    // never been traced at all, which is why opening a large note looked like it
    // cost nothing. This is a SECOND frame with its own independent state, opened
    // by `NativeTextViewWrapper.updateNSView` once per node switch / initial load:
    //
    //   🔀 PERF switch doc=345998ch total=1234.56ms | outFont=0.01 outOverscroll=5.21 …
    //       └─ latex ×221 = 537.20ms
    //
    // Read it like this:
    //  · `out*` phases run while the OUTGOING document is still in the text storage,
    //    i.e. time spent on a document that is about to be thrown away — should be
    //    ~0 once the font assignment is guarded.
    //  · The `└─` counters are per-element bridge costs summed across the switch.
    //    They are a breakdown WITHIN `style`, not time on top of it.
    //  · Warm vs cold: switch away and back. Counters that collapse to ~0 were
    //    cache misses the first time; counters that stay are genuine per-pass work.

    private static var swActive = false
    private static var swStart: UInt64 = 0
    private static var swDocLength = 0
    private static var swPhases: [(String, Double)] = []
    private static var swCounters: [(String, Double, Int)] = []

    // MARK: Runloop timeline
    //
    // ~296 ms of a switch elapse AFTER `updateNSView` returns, and neither the
    // engine's own counters nor the app's SwiftUI body timings account for it.
    // This observer stamps the main runloop's own phase transitions into the
    // frame, which splits that window without needing to know whose code runs:
    //
    //   @updateEnd=768  …  @rl.beforeWaiting=1060  @rl.afterWaiting=1061  total=1064
    //     → the turn itself is the cost: AppKit deferred layout + CA commit.
    //
    //   @updateEnd=768  …  @rl.beforeWaiting=775   @rl.afterWaiting=1060  total=1064
    //     → the turn ended immediately and the time is spent asleep/elsewhere,
    //       i.e. NOT this runloop turn's work.

    private static var swRunLoopObserver: CFRunLoopObserver?
    /// Second observer at a very high order so it runs AFTER AppKit's own
    /// display/CA-commit observer (order 2_000_000). The pair brackets the
    /// commit: `rl.beforeWaiting` before it, `rl.beforeWaiting.late` after.
    private static var swRunLoopObserverLate: CFRunLoopObserver?

    private static func installRunLoopObserver() {
        guard swRunLoopObserver == nil else { return }
        let activities: CFOptionFlags =
            CFRunLoopActivity.beforeTimers.rawValue |
            CFRunLoopActivity.beforeSources.rawValue |
            CFRunLoopActivity.beforeWaiting.rawValue |
            CFRunLoopActivity.afterWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            switch activity {
            case .beforeTimers: switchCheckpoint("rl.beforeTimers")
            case .beforeSources: switchCheckpoint("rl.beforeSources")
            case .beforeWaiting: switchCheckpoint("rl.beforeWaiting")
            case .afterWaiting: switchCheckpoint("rl.afterWaiting")
            default: break
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        swRunLoopObserver = observer

        let late = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 3_000_000
        ) { _, _ in switchCheckpoint("rl.beforeWaiting.late") }
        CFRunLoopAddObserver(CFRunLoopGetMain(), late, .commonModes)
        swRunLoopObserverLate = late
    }

    private static func removeRunLoopObserver() {
        if let observer = swRunLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            swRunLoopObserver = nil
        }
        if let late = swRunLoopObserverLate {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), late, .commonModes)
            swRunLoopObserverLate = nil
        }
    }

    /// Bare counter for the layout-fragment provider.
    ///
    /// Deliberately NOT `accumulate`: that helper does two clock reads plus a
    /// linear String scan over ~40 counter labels, and the provider fires 15,000+
    /// times per switch — the measurement would be a meaningful share of what it
    /// measures. Here only the COUNT is the answer (how many full document passes
    /// ran, and on which side of `@updateEnd`), so one integer increment suffices.
    static var fragProvCount: Int = 0

    @inline(__always)
    static func fragProvTick() {
        if enabled { fragProvCount &+= 1 }
    }

    /// Open the switch frame. `len` is the INCOMING document's length.
    /// A frame that is still open is CONTINUED, not restarted — the frame now
    /// stays open past the end of `updateNSView` (see `switchEndAfterRunloop`).
    static func switchBegin(docLength len: Int) {
        guard enabled, !swActive else { return }
        swActive = true
        fragProvCount = 0
        installRunLoopObserver()
        swDocLength = len
        swPhases.removeAll(keepingCapacity: true)
        swCounters.removeAll(keepingCapacity: true)
        swStart = DispatchTime.now().uptimeNanoseconds
    }

    /// Time one sequential phase of the switch. Do not nest these in each other.
    @discardableResult
    static func switchMeasure<T>(_ label: String, _ body: () -> T) -> T {
        guard enabled, swActive else { return body() }
        let t0 = nowMs()
        let result = body()
        swPhases.append((label, nowMs() - t0))
        return result
    }

    /// Sum a per-element bridge cost (LaTeX render, syntax highlight, table
    /// render) over the whole switch. Call count + total ms distinguishes a cache
    /// hit from a miss without having to reach into the bridges' own modules.
    @discardableResult
    static func switchCount<T>(_ label: String, _ body: () -> T) -> T {
        guard enabled, swActive else { return body() }
        let t0 = nowMs()
        let result = body()
        let dt = nowMs() - t0
        if let i = swCounters.firstIndex(where: { $0.0 == label }) {
            swCounters[i].1 += dt
            swCounters[i].2 += 1
        } else {
            swCounters.append((label, dt, 1))
        }
        return result
    }

    /// Add an already-measured duration to a switch counter.
    ///
    /// For costs inside a tight per-token loop, where wrapping every iteration in
    /// `switchCount` would itself distort the number (its label lookup is linear
    /// over the counter list). Accumulate into a local `Double` in the loop and
    /// hand the total over once afterwards.
    static func switchAdd(_ label: String, ms: Double, count: Int = 1) {
        guard enabled, swActive, ms > 0 || count > 0 else { return }
        if let i = swCounters.firstIndex(where: { $0.0 == label }) {
            swCounters[i].1 += ms
            swCounters[i].2 += count
        } else {
            swCounters.append((label, ms, count))
        }
    }

    /// Milliseconds since an `uptimeNanoseconds` stamp — for `switchAdd` callers.
    static func elapsedMs(since start: UInt64) -> Double {
        guard enabled, swActive else { return 0 }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// Record a named timestamp (offset from frame start), printed as `@label`.
    /// Marks a boundary — e.g. where `updateNSView` returned — so the phases
    /// before it can be told apart from whatever the runloop does afterwards.
    static func switchCheckpoint(_ label: String) {
        guard enabled, swActive else { return }
        swPhases.append(("@" + label, Double(DispatchTime.now().uptimeNanoseconds - swStart) / 1_000_000))
    }

    /// Close the frame one runloop turn later instead of immediately.
    ///
    /// `updateNSView` returning is NOT the end of the user-visible stall: SwiftUI
    /// finishes its pass and AppKit runs the first display cycle afterwards, and
    /// on a large document that draw is substantial. Closing async makes the
    /// frame span the same window the app-side `mainBlock` measures, so the two
    /// numbers are comparable and the drawing counters land inside it.
    static func switchEndAfterRunloop() {
        guard enabled, swActive else { return }
        DispatchQueue.main.async { switchEnd() }
    }

    /// Close the switch frame and print. `other` = total − Σphases: time inside
    /// the switch that no phase covers (AppKit, SwiftUI, notification dispatch).
    static func switchEnd() {
        guard enabled, swActive else { return }
        swActive = false
        removeRunLoopObserver()
        let total = Double(DispatchTime.now().uptimeNanoseconds - swStart) / 1_000_000
        let breakdown = swPhases.map { String(format: "%@=%.2f", $0.0, $0.1) }.joined(separator: " ")
        let covered = swPhases.filter { !$0.0.hasPrefix("@") }.reduce(0) { $0 + $1.1 }
        print(String(format: "🔀 PERF switch doc=%dch total=%.2fms fragProv=%d | %@ other=%.2f",
                     swDocLength, total, fragProvCount, breakdown, total - covered))
        for counter in swCounters.sorted(by: { $0.1 > $1.1 }) {
            print(String(format: "    └─ %@ ×%d = %.2fms", counter.0, counter.2, counter.1))
        }
    }
}
