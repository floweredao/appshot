import AppKit
import AppshotCore
import Carbon.HIToolbox

@MainActor
final class HotkeyMonitor {
    var onTrigger: () -> Void = {}
    var onRegistrationFailed: () -> Void = {}
    private var monitors: [Any] = []
    private var dual: DualModifierDetector?
    private var tap: DoubleTapDetector?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    nonisolated(unsafe) private static weak var current: HotkeyMonitor?

    func apply(_ shortcut: Shortcut) {
        stop()
        Self.current = self
        switch shortcut {
        case .bothSides(let side):
            dual = DualModifierDetector(side: side)
            installMonitors()
        case .doubleTap(let side):
            tap = DoubleTapDetector(side: side)
            installMonitors()
        case .combo(let keyCode, let modifiers, _):
            registerCarbon(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)))
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        dual = nil
        tap = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { self.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { self.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        var fired = false
        switch event.type {
        case .keyDown:
            dual?.keyDown()
            tap?.keyDown()
        case .flagsChanged:
            let flags = UInt64(event.modifierFlags.rawValue)
            if dual?.flagsChanged(flags) == true { fired = true }
            if tap?.flagsChanged(flags, at: event.timestamp) == true { fired = true }
        default:
            break
        }
        if fired { DispatchQueue.main.async { self.onTrigger() } }
    }

    private func registerCarbon(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyMonitor.current?.onTrigger() } }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4150_5348), id: 1)
        let status = RegisterEventHotKey(UInt32(keyCode), carbon, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            hotKey = nil
            onRegistrationFailed()
        }
    }
}
