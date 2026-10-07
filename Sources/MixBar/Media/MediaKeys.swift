import AppKit
import ApplicationServices

/// Sends the same system media-key events the keyboard's F7/F8/F9 keys produce.
enum MediaKey: Int {
    case playPause = 16   // NX_KEYTYPE_PLAY
    case next = 17        // NX_KEYTYPE_NEXT
    case previous = 18    // NX_KEYTYPE_PREVIOUS

    func send() {
        post(down: true)
        post(down: false)
    }

    private func post(down: Bool) {
        let flags: Int = down ? 0xA00 : 0xB00
        let data1 = (rawValue << 16) | flags
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
