import AppKit
import Combine
import CoreAudio
import Foundation

/// Per-app mixer state. Creates a tap only for apps whose volume differs from 100% or that are muted,
/// so untouched apps keep playing directly to the device with no extra latency.
@MainActor
final class MixerModel: ObservableObject {
    let output = OutputDeviceManager()
    let processes = ProcessAudioManager()

    @Published private(set) var levels: [String: Float] = [:]
    @Published private(set) var appVolumes: [String: Float]
    @Published private(set) var appMuted: [String: Bool]
    @Published private(set) var tapError: String?
    @Published private(set) var accessibilityTrusted = MediaKey.isAccessibilityTrusted

    private var taps: [String: ProcessTap] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var meterTimer: Timer?

    private static let volumesKey = "appVolumes"
    private static let mutedKey = "appMuted"

    init() {
        let defaults = UserDefaults.standard
        appVolumes = defaults.dictionary(forKey: Self.volumesKey) as? [String: Float]
            ?? (defaults.dictionary(forKey: Self.volumesKey) as? [String: Double])?.mapValues(Float.init) ?? [:]
        appMuted = defaults.dictionary(forKey: Self.mutedKey) as? [String: Bool] ?? [:]

        processes.$apps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileTaps() }
            .store(in: &cancellables)

        output.$defaultDevice
            .receive(on: DispatchQueue.main)
            .removeDuplicates { $0?.id == $1?.id }
            .dropFirst()
            .sink { [weak self] _ in self?.rebuildAllTaps() }
            .store(in: &cancellables)

        processes.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        output.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    // MARK: Public API used by views

    var apps: [AudioApp] { processes.apps }

    func volume(for app: AudioApp) -> Float { appVolumes[app.id] ?? 1 }
    func isMuted(_ app: AudioApp) -> Bool { appMuted[app.id] ?? false }
    func level(for app: AudioApp) -> Float { levels[app.id] ?? 0 }
    func isTapped(_ app: AudioApp) -> Bool { taps[app.id] != nil }

    func setVolume(_ value: Float, for app: AudioApp) {
        let clamped = min(max(value, 0), 1)
        if abs(clamped - 1) < 0.001 { appVolumes.removeValue(forKey: app.id) } else { appVolumes[app.id] = clamped }
        if clamped > 0, appMuted[app.id] == true { appMuted[app.id] = false }
        persist()
        reconcileTaps()
    }

    func setMuted(_ muted: Bool, for app: AudioApp) {
        if muted { appMuted[app.id] = true } else { appMuted.removeValue(forKey: app.id) }
        persist()
        reconcileTaps()
    }

    /// Called when the popover opens/closes so the meter timer only runs while visible.
    func setVisible(_ visible: Bool) {
        meterTimer?.invalidate()
        meterTimer = nil
        processes.refresh()
        output.refreshDevices()
        accessibilityTrusted = MediaKey.isAccessibilityTrusted
        guard visible else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleLevels() }
        }
    }

    // MARK: Taps

    private func needsTap(_ app: AudioApp) -> Bool {
        (appVolumes[app.id] ?? 1) < 0.999 || appMuted[app.id] == true
    }

    private func reconcileTaps() {

        let live = apps
        let liveIDs = Set(live.map(\.id))

        for (id, tap) in taps where !liveIDs.contains(id) {
            tap.invalidate()
            taps.removeValue(forKey: id)
            levels.removeValue(forKey: id)
        }

        for app in live {
            let existing = taps[app.id]
            if needsTap(app) {
                if let existing, existing.processObjects == app.processObjects, existing.outputDeviceUID == output.defaultDevice?.uid {
                    existing.gain = volume(for: app)
                    existing.isMuted = isMuted(app)
                } else {
                    existing?.invalidate()
                    taps.removeValue(forKey: app.id)
                    createTap(for: app)
                }
            } else if let existing {
                existing.invalidate()
                taps.removeValue(forKey: app.id)
                levels.removeValue(forKey: app.id)
            }
        }
    }

    private func createTap(for app: AudioApp) {
        guard let uid = output.defaultDevice?.uid, !uid.isEmpty else { return }
        do {
            let tap = try ProcessTap(processObjects: app.processObjects, outputDeviceUID: uid, label: app.name)
            tap.gain = volume(for: app)
            tap.isMuted = isMuted(app)
            taps[app.id] = tap
            tapError = nil
        } catch {
            Log.write("tap failed for \(app.name): \(error)")
            tapError = "Couldn't take control of \(app.name)'s audio. Allow MixBar under System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        }
    }

    private func rebuildAllTaps() {
        for (_, tap) in taps { tap.invalidate() }
        taps.removeAll()
        reconcileTaps()
    }

    private func sampleLevels() {
        var updated: [String: Float] = [:]
        for (id, tap) in taps {
            let peak = tap.takePeak()
            let previous = levels[id] ?? 0
            // Fast attack, slow release.
            updated[id] = peak > previous ? peak : previous * 0.75
        }
        if updated != levels { levels = updated }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(appVolumes.mapValues(Double.init), forKey: Self.volumesKey)
        defaults.set(appMuted, forKey: Self.mutedKey)
    }
}
