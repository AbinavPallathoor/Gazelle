import Carbon.HIToolbox
import CoreGraphics
import Foundation
import GazeKit
import os

private let log = Logger(subsystem: "dev.gazelle.Gazelle", category: "tap")

/// Keyboard interception while Active: a `CGEventTap` that swallows only the navigation and
/// action keys from `KeyMap` and passes everything else through untouched.
///
/// Safety (ADR 0003, PLAN.md §8):
/// - The tap runs on its own thread with its own run loop, so a stalled main thread cannot
///   hold keyboard input; the swallow decision needs only `KeyMap` and an atomic flag.
/// - ⌃⌥K is recognised here as well as by the Carbon hotkey: the tap disables itself
///   immediately and then tells the app, regardless of how hotkey delivery resolves.
/// - If macOS disables the tap (timeout or user input), it is re-enabled only while still wanted.
/// - When disabled, the tap is removed entirely, so nothing is ever swallowed while Inactive.
@MainActor
final class KeyboardTap: InputInterceptor {
    /// Called on the main thread with each command.
    var onCommand: ((NavCommand) -> Void)?
    /// Called on the main thread when ⌃⌥K was pressed while the tap was active.
    var onKill: (() -> Void)?

    private(set) var isEnabled = false
    private let state = TapState()
    private var thread: Thread?

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled { start() } else { stop() }
    }

    private func start() {
        state.wanted.store(true)
        let state = state
        state.onCommand = { [weak self] cmd in DispatchQueue.main.async { self?.onCommand?(cmd) } }
        state.onKill = { [weak self] in DispatchQueue.main.async { self?.onKill?() } }
        let t = Thread { KeyboardTap.runTap(state) }
        t.name = "gazelle.keyboard-tap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func stop() {
        state.wanted.store(false)
        state.shutdown()
        thread = nil
    }

    /// Body of the tap thread: create the tap, run its run loop until stopped.
    nonisolated private static func runTap(_ state: TapState) {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(state).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: tapCallback, userInfo: refcon) else {
            log.error("could not create keyboard event tap (Accessibility permission missing?)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let loop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(loop, source, .commonModes)
        state.attach(tap: tap, loop: loop)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.info("keyboard tap enabled")
        if state.wanted.load() { CFRunLoopRun() }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        log.info("keyboard tap removed")
    }
}

/// State shared between the main thread and the tap thread.
private final class TapState: @unchecked Sendable {
    let wanted = AtomicBool()
    var onCommand: ((NavCommand) -> Void)?
    var onKill: (() -> Void)?
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    /// Key codes whose keyDown was swallowed; their keyUp is swallowed too.
    var swallowedDown = Set<Int64>()

    func attach(tap: CFMachPort, loop: CFRunLoop) {
        lock.lock(); defer { lock.unlock() }
        self.tap = tap
        self.loop = loop
        if !wanted.load() { CFRunLoopStop(loop) }
    }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
        tap = nil
        loop = nil
    }

    func reenable() {
        lock.lock(); defer { lock.unlock() }
        if wanted.load(), let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func disableNow() {
        lock.lock(); defer { lock.unlock() }
        wanted.store(false)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
    }
}

private final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func load() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func store(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

private func modifiers(_ flags: CGEventFlags) -> GazeKit.KeyMap.Modifiers {
    var m: GazeKit.KeyMap.Modifiers = []
    if flags.contains(.maskShift) { m.insert(.shift) }
    if flags.contains(.maskControl) { m.insert(.control) }
    if flags.contains(.maskAlternate) { m.insert(.option) }
    if flags.contains(.maskCommand) { m.insert(.command) }
    return m
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<TapState>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        state.reenable()
        return Unmanaged.passUnretained(event)
    }
    guard state.wanted.load() else { return Unmanaged.passUnretained(event) }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let mods = modifiers(event.flags)

    if type == .keyUp {
        // Swallow the release of any key whose press we swallowed, so apps never see half a keystroke.
        if state.swallowedDown.remove(keyCode) != nil { return nil }
        return Unmanaged.passUnretained(event)
    }

    if GazeKit.KeyMap.isKillSwitch(keyCode: Int(keyCode), modifiers: mods) {
        state.disableNow()
        state.onKill?()
        return Unmanaged.passUnretained(event) // let the Carbon hotkey see it too
    }
    guard let command = GazeKit.KeyMap.command(keyCode: Int(keyCode), modifiers: mods) else {
        return Unmanaged.passUnretained(event)
    }
    state.swallowedDown.insert(keyCode)
    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 || isRepeatable(command) {
        state.onCommand?(command)
    }
    return nil
}

/// Holding an arrow or Tab repeats the move; holding Return must not click repeatedly.
private func isRepeatable(_ c: NavCommand) -> Bool {
    switch c {
    case .move, .next, .previous: return true
    case .act, .exit: return false
    }
}
