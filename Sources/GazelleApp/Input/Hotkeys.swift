import Carbon.HIToolbox
import Foundation
import os

let hotkeyLog = Logger(subsystem: "dev.gazelle.Gazelle", category: "hotkeys")

/// A global key combination.
struct Hotkey: Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (`controlKey | optionKey | cmdKey | shiftKey`).
    var modifiers: UInt32
    var display: String

    /// ⌃⌥G toggles Active.
    static let toggleActive = Hotkey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥G")
    /// ⌃⌥K is the kill switch (same modifiers as the toggle, so both are easy to reach).
    static let killSwitch = Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥K")
}

/// Registers system-wide hotkeys. Behind a protocol so tests can simulate registration failure.
@MainActor
protocol HotkeyRegistering: AnyObject {
    /// Returns false if the combination could not be registered (e.g. another app owns it).
    func register(_ hotkey: Hotkey, handler: @escaping @MainActor () -> Void) -> Bool
    func unregisterAll()
}

/// Carbon `RegisterEventHotKey` hotkeys. They need no Accessibility or Input Monitoring permission,
/// fire from any app, and report registration failure, which the kill switch relies on.
/// Limitation: they do not fire while another app has Secure Event Input enabled (password fields).
@MainActor
final class CarbonHotkeys: HotkeyRegistering {
    private static let signature: OSType = 0x475A_4B59 // 'GZKY'
    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == CarbonHotkeys.signature else { return OSStatus(eventNotHandledErr) }
            hotkeyLog.info("hotkey pressed: id \(id.id)")
            let hotkeys = Unmanaged<CarbonHotkeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotkeys.handlers[id.id]?() }
            return noErr
        }, 1, &spec, me, &eventHandler)
        hotkeyLog.info("installed hotkey event handler: \(status)")
    }

    func register(_ hotkey: Hotkey, handler: @escaping @MainActor () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetEventDispatcherTarget(), 0, &ref)
        hotkeyLog.info("register \(hotkey.display, privacy: .public) as id \(id): status \(status)")
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }
}
