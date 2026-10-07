import AppKit
import Foundation

struct NowPlayingInfo: Equatable {
    var app: String
    var title: String
    var artist: String
    var isPlaying: Bool
}

/// Polls Music and Spotify via Apple Events while the popover is visible.
@MainActor
final class NowPlayingProvider: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?

    private var timer: Timer?
    private let queue = DispatchQueue(label: "dev.local.MixBar.nowplaying", qos: .utility)

    private struct Player { let bundleID: String; let name: String }
    private let players = [
        Player(bundleID: "com.spotify.client", name: "Spotify"),
        Player(bundleID: "com.apple.Music", name: "Music"),
    ]

    func setVisible(_ visible: Bool) {
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        guard let player = players.first(where: { running.contains($0.bundleID) }) else {
            info = nil
            return
        }
        let script = """
        tell application "\(player.name)"
            set st to player state as string
            if st is "stopped" then return "||" & st
            return (name of current track) & "|" & (artist of current track) & "|" & st
        end tell
        """
        queue.async { [weak self] in
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
            let parsed: NowPlayingInfo? = result.flatMap { text in
                let parts = text.components(separatedBy: "|")
                guard parts.count == 3 else { return nil }
                return NowPlayingInfo(app: player.name, title: parts[0], artist: parts[1], isPlaying: parts[2] == "playing")
            }
            Task { @MainActor in
                if self?.info != parsed { self?.info = parsed }
            }
        }
    }
}
