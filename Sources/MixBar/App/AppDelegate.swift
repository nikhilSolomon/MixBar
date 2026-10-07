import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mixer: MixerModel!
    private var nowPlaying: NowPlayingProvider!
    private var hotKey: HotKey!
    /// Used when the status item is hidden (full menu bar / notch): a floating panel at the top-right instead.
    private var fallbackPanel: NSPanel?
    private var panelObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        mixer = MixerModel()
        nowPlaying = NowPlayingProvider()

        let root = MixerView(onQuit: { NSApp.terminate(nil) })
            .environmentObject(mixer!)
            .environmentObject(nowPlaying!)

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: root)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "MixBar")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        hotKey = HotKey()
        hotKey.onTrigger = { [weak self] in self?.toggleMixer() }
        hotKey.register()

        installDebugHooks()
    }

    /// Relaunching the app (Finder double-click, `open`) while it is running shows the mixer.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.write("reopen; statusItemVisible=\(isStatusItemVisible)")
        showMixer()
        return false
    }

    private var isStatusItemVisible: Bool {
        guard let window = statusItem.button?.window else { return false }
        guard window.occlusionState.contains(.visible) else { return false }
        let frame = window.frame
        return NSScreen.screens.contains { screen in
            guard screen.frame.intersects(frame) else { return false }
            // On a notched display the hidden items sit under the notch; the visible areas are the auxiliary ones.
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                return left.intersects(frame) || right.intersects(frame)
            }
            return true
        }
    }

    private func toggleMixer() {
        if popover.isShown { popover.performClose(nil); return }
        if let panel = fallbackPanel, panel.isVisible { closeFallbackPanel(); return }
        showMixer()
    }

    private func showMixer() {
        if isStatusItemVisible {
            closeFallbackPanel()
            if !popover.isShown { togglePopover(nil) }
        } else {
            showFallbackPanel()
        }
    }

    private func showFallbackPanel() {
        if fallbackPanel == nil {
            let root = MixerView(onQuit: { NSApp.terminate(nil) })
                .environmentObject(mixer!)
                .environmentObject(nowPlaying!)
            let hosting = NSHostingController(rootView: root)
            let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.contentViewController = hosting
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.isMovableByWindowBackground = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.becomesKeyOnlyIfNeeded = false
            fallbackPanel = panel
            // Dismiss when the user switches to another app (clicking elsewhere), like a popover would.
            panelObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.closeFallbackPanel() }
            }
        }
        guard let panel = fallbackPanel, let content = panel.contentViewController?.view else { return }
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = panel.frame.size
        let area = screen.visibleFrame
        let origin = NSPoint(x: max(area.minX, area.maxX - size.width - 12),
                             y: max(area.minY, area.maxY - size.height - 8))
        panel.setFrameOrigin(origin)
        Log.write("fallback panel on \(screen.localizedName) visible=\(screen.visibleFrame) size=\(size) origin=\(origin) mouse=\(mouse) screens=\(NSScreen.screens.map { "\($0.localizedName) \($0.frame)" })")
        mixer.setVisible(true)
        nowPlaying.setVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeFallbackPanel() {
        guard let panel = fallbackPanel, panel.isVisible else { return }
        Log.write("closing fallback panel (appActive=\(NSApp.isActive))")
        panel.orderOut(nil)
        if !popover.isShown {
            mixer.setVisible(false)
            nowPlaying.setVisible(false)
        }
    }

    /// Developer aid: `MIXBAR_SNAPSHOT=/path/out.png` opens the popover, writes a PNG of it
    /// plus a text dump of the audio state next to it, then quits.
    private func installDebugHooks() {
        guard let path = ProcessInfo.processInfo.environment["MIXBAR_SNAPSHOT"], !path.isEmpty else { return }
        let tapTarget = ProcessInfo.processInfo.environment["MIXBAR_TAP"]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            togglePopover(nil)
            if let tapTarget, let app = mixer.apps.first(where: { $0.id == tapTarget || $0.name == tapTarget }) {
                mixer.setVolume(0.5, for: app)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [self] in
            var dump = "Output devices:\n"
            for d in mixer.output.devices {
                dump += "  \(d.id == mixer.output.defaultDevice?.id ? "*" : " ") [\(d.id)] \(d.name) uid=\(d.uid)\n"
            }
            dump += "Master volume: \(mixer.output.volume) muted=\(mixer.output.isMuted) settable=\(mixer.output.canSetVolume)\n"
            dump += "Apps:\n"
            for a in mixer.apps {
                dump += "  \(a.isPlaying ? "▶" : " ") \(a.name) pid=\(a.pid) bundle=\(a.bundleID ?? "-") objs=\(a.processObjects) vol=\(mixer.volume(for: a)) tapped=\(mixer.isTapped(a)) level=\(mixer.level(for: a))\n"
            }
            dump += "Tap error: \(mixer.tapError ?? "none")\n"
            dump += "Now playing: \(String(describing: nowPlaying.info))\n"
            dump += "Accessibility trusted: \(MediaKey.isAccessibilityTrusted)\n"
            if let frame = popover.contentViewController?.view.window?.frame, let screen = NSScreen.main {
                dump += "Popover frame (top-left origin): \(Int(frame.minX)),\(Int(screen.frame.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))\n"
            }
            try? dump.write(toFile: path + ".txt", atomically: true, encoding: .utf8)

            if let view = popover.contentViewController?.view,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
            NSApp.terminate(nil)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if !isStatusItemVisible, sender == nil {
            showFallbackPanel()
        } else if let button = statusItem.button {
            closeFallbackPanel()
            popover.contentViewController?.view.window?.makeKey()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        mixer.setVisible(true)
        nowPlaying.setVisible(true)
    }

    func popoverDidClose(_ notification: Notification) {
        mixer.setVisible(false)
        nowPlaying.setVisible(false)
    }
}
