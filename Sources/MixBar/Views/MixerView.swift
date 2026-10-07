import AppKit
import SwiftUI

struct MixerView: View {
    @EnvironmentObject var mixer: MixerModel
    @EnvironmentObject var nowPlaying: NowPlayingProvider
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TransportSection()
            Divider()
            OutputSection()
            Divider()
            AppsSection()
            Divider()
            FooterSection(onQuit: onQuit)
        }
        .padding(14)
        .frame(width: 340)
    }
}

// MARK: - Transport

private struct TransportSection: View {
    @EnvironmentObject var nowPlaying: NowPlayingProvider

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let info = nowPlaying.info {
                    Text(info.title.isEmpty ? "Nothing playing" : info.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(info.artist.isEmpty ? info.app : "\(info.artist) · \(info.app)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Media")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Controls the active player")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                TransportButton(symbol: "backward.fill") { MediaKey.previous.send() }
                TransportButton(symbol: nowPlaying.info?.isPlaying == true ? "pause.fill" : "play.fill", prominent: true) { MediaKey.playPause.send() }
                TransportButton(symbol: "forward.fill") { MediaKey.next.send() }
            }
        }
    }
}

private struct TransportButton: View {
    let symbol: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 15 : 12, weight: .semibold))
                .frame(width: prominent ? 36 : 30, height: prominent ? 36 : 30)
                .background(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Circle())
                .foregroundStyle(prominent ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Output

private struct OutputSection: View {
    @EnvironmentObject var mixer: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Output")
                Spacer()
                Menu {
                    ForEach(mixer.output.devices) { device in
                        Button {
                            mixer.output.setDefaultDevice(device)
                        } label: {
                            HStack {
                                Image(systemName: device.symbolName)
                                Text(device.name)
                                if device.id == mixer.output.defaultDevice?.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mixer.output.defaultDevice?.symbolName ?? "hifispeaker")
                        Text(mixer.output.defaultDevice?.name ?? "No output")
                            .lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            VolumeRow(
                icon: mixer.output.isMuted ? "speaker.slash.fill" : speakerIcon(mixer.output.volume),
                value: Binding(get: { mixer.output.volume }, set: { mixer.output.setVolume($0) }),
                isMuted: Binding(get: { mixer.output.isMuted }, set: { mixer.output.setMuted($0) }),
                level: nil,
                enabled: mixer.output.canSetVolume
            )
        }
    }
}

// MARK: - Apps

private struct AppsSection: View {
    @EnvironmentObject var mixer: MixerModel

    private var listHeight: CGFloat {
        let rows = CGFloat(min(mixer.apps.count, 6))
        return rows * 46 + max(rows - 1, 0) * 10
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Apps")
                Spacer()
                Text("\(mixer.apps.filter(\.isPlaying).count) playing")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if mixer.apps.isEmpty {
                Text("No apps are using audio right now.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.vertical, showsIndicators: mixer.apps.count > 6) {
                    VStack(spacing: 10) {
                        ForEach(mixer.apps) { app in
                            AppRow(app: app)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(height: listHeight)
            }

            if let error = mixer.tapError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AppRow: View {
    @EnvironmentObject var mixer: MixerModel
    let app: AudioApp

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .opacity(app.isPlaying ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(app.isPlaying ? .primary : .secondary)
                    if app.isPlaying {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                    }
                    Spacer()
                    Text("\(Int((mixer.isMuted(app) ? 0 : mixer.volume(for: app)) * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                VolumeRow(
                    icon: nil,
                    value: Binding(get: { mixer.volume(for: app) }, set: { mixer.setVolume($0, for: app) }),
                    isMuted: Binding(get: { mixer.isMuted(app) }, set: { mixer.setMuted($0, for: app) }),
                    level: mixer.isTapped(app) ? mixer.level(for: app) : nil,
                    enabled: true
                )
            }
        }
    }
}

// MARK: - Shared pieces

private struct VolumeRow: View {
    var icon: String?
    @Binding var value: Float
    @Binding var isMuted: Bool
    var level: Float?
    var enabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            ZStack(alignment: .leading) {
                if let level {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.green.opacity(0.35))
                            .frame(width: max(0, geo.size.width * CGFloat(min(level, 1))), height: 4)
                            .frame(maxHeight: .infinity, alignment: .center)
                            .animation(.linear(duration: 0.05), value: level)
                    }
                    .allowsHitTesting(false)
                }
                Slider(value: $value, in: 0...1)
                    .controlSize(.small)
                    .disabled(!enabled)
                    .opacity(isMuted ? 0.5 : 1)
            }
            Button {
                isMuted.toggle()
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isMuted ? Color.red : Color.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute" : "Mute")
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.6)
    }
}

private struct FooterSection: View {
    @EnvironmentObject var mixer: MixerModel
    var onQuit: () -> Void
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .onChange(of: launchAtLogin) { _, newValue in LaunchAtLogin.set(newValue) }
                Spacer()
                HStack(spacing: 4) {
                    Text("Open with")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(HotKey.displayString)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                .help("Press Control + Option + M anywhere to open the mixer.")
                Button("Quit", action: onQuit)
                    .font(.system(size: 11))
                    .keyboardShortcut("q")
            }
            if !mixer.accessibilityTrusted {
                Button {
                    MediaKey.requestAccessibility()
                } label: {
                    Label("Media buttons need Accessibility access. Click to enable.", systemImage: "key.fill")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.link)
            }
        }
    }
}

func speakerIcon(_ volume: Float) -> String {
    switch volume {
    case ..<0.01: return "speaker.fill"
    case ..<0.34: return "speaker.wave.1.fill"
    case ..<0.67: return "speaker.wave.2.fill"
    default: return "speaker.wave.3.fill"
    }
}
