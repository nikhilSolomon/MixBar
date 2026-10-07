import AppKit
import CoreAudio
import Foundation

/// One row in the mixer: an application that owns one or more Core Audio process objects.
struct AudioApp: Identifiable, Hashable {
    /// Stable key across process restarts: bundle identifier when known, otherwise the responsible PID.
    let id: String
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?
    let processObjects: [AudioObjectID]
    let isPlaying: Bool

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.pid == rhs.pid && lhs.processObjects == rhs.processObjects && lhs.isPlaying == rhs.isPlaying && lhs.name == rhs.name
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Watches Core Audio's process object list and groups processes by the app responsible for them.
@MainActor
final class ProcessAudioManager: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []

    private var listListener: ListenerToken?
    private var processListeners: [AudioObjectID: ListenerToken] = [:]
    private var refreshScheduled = false

    init() {
        listListener = CA.listen(CA.systemObject, CA.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            self?.scheduleRefresh()
        }
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        let objects: [AudioObjectID] = (try? CA.getArray(CA.systemObject, CA.address(kAudioHardwarePropertyProcessObjectList))) ?? []

        // Keep listeners in sync with the object list.
        let current = Set(objects)
        processListeners = processListeners.filter { current.contains($0.key) }
        for obj in objects where processListeners[obj] == nil {
            processListeners[obj] = CA.listen(obj, CA.address(kAudioProcessPropertyIsRunningOutput)) { [weak self] in
                self?.scheduleRefresh()
            }
        }

        struct Group { var pid: pid_t; var bundleID: String?; var objects: [AudioObjectID] = []; var playing = false }
        var groups: [pid_t: Group] = [:]
        let myPID = ProcessInfo.processInfo.processIdentifier

        for obj in objects {
            let pid: pid_t = (try? CA.get(obj, CA.address(kAudioProcessPropertyPID), initial: pid_t(0))) ?? 0
            guard pid > 0, pid != myPID else { continue }
            let running: UInt32 = (try? CA.get(obj, CA.address(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0))) ?? 0
            let bundle = try? CA.getString(obj, CA.address(kAudioProcessPropertyBundleID))

            let owner = ResponsibleProcess.responsiblePID(for: pid)
            var group = groups[owner] ?? Group(pid: owner, bundleID: nil)
            group.objects.append(obj)
            group.playing = group.playing || running != 0
            if owner == pid, let bundle, !bundle.isEmpty { group.bundleID = bundle }
            groups[owner] = group
        }

        var result: [AudioApp] = []
        for group in groups.values {
            let running = NSRunningApplication(processIdentifier: group.pid)
            let bundleID = running?.bundleIdentifier ?? group.bundleID
            // Hide background daemons that never show in the Dock, unless they are actually making sound.
            let isRegularApp = running?.activationPolicy == .regular
            guard isRegularApp || group.playing else { continue }

            let name = running?.localizedName
                ?? bundleID.flatMap { Self.appName(forBundleID: $0) }
                ?? ResponsibleProcess.processName(for: group.pid)
                ?? "PID \(group.pid)"
            let icon = running?.icon ?? bundleID.flatMap { Self.appIcon(forBundleID: $0) }
            result.append(AudioApp(id: bundleID ?? "pid:\(group.pid)", pid: group.pid, bundleID: bundleID,
                                   name: name, icon: icon, processObjects: group.objects.sorted(), isPlaying: group.playing))
        }

        result.sort {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if result != apps { apps = result }
    }

    private static func appName(forBundleID id: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func appIcon(forBundleID id: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Resolves helper processes (e.g. Safari's WebKit GPU process) to the app that owns them.
enum ResponsibleProcess {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let fn = responsibleFn else { return pid }
        let owner = fn(pid)
        return owner > 0 ? owner : pid
    }

    static func processName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
