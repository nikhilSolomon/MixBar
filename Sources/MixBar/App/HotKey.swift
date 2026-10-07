import AppKit
import Carbon.HIToolbox

/// Registers one global hotkey (Control + Option + M by default) and calls `onTrigger` on the main thread.
final class HotKey {
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private static var handlerInstalled = false
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 0
    private var id: UInt32 = 0

    static let displayString = "⌃⌥M"

    func register(keyCode: UInt32 = UInt32(kVK_ANSI_M), modifiers: UInt32 = UInt32(controlKey | optionKey)) {
        unregister()
        Self.installHandlerIfNeeded()
        Self.nextID += 1
        id = Self.nextID
        Self.instances[id] = self

        let hotKeyID = EventHotKeyID(signature: 0x564D4958 /* 'VMIX' */, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr { hotKeyRef = ref } else { Log.write("hotkey registration failed: \(status)") }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if id != 0 { Self.instances.removeValue(forKey: id); id = 0 }
    }

    deinit { unregister() }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            if let instance = HotKey.instances[hotKeyID.id] {
                DispatchQueue.main.async { instance.onTrigger?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
