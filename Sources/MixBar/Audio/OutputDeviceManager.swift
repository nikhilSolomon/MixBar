import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32

    var symbolName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "hifispeaker"
        }
    }
}

/// Enumerates output devices, tracks the default output, and exposes master volume / mute for it.
@MainActor
final class OutputDeviceManager: ObservableObject {
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var defaultDevice: OutputDevice?
    @Published private(set) var volume: Float = 0
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var canSetVolume: Bool = false

    /// UIDs starting with this prefix are our own private aggregates and are hidden from the list.
    static let privateUIDPrefix = "dev.local.MixBar."

    private var systemListeners: [ListenerToken] = []
    private var deviceListeners: [ListenerToken] = []

    init() {
        let sys = CA.systemObject
        systemListeners = [
            CA.listen(sys, CA.address(kAudioHardwarePropertyDevices)) { [weak self] in self?.refreshDevices() },
            CA.listen(sys, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in self?.refreshDefault() },
        ]
        refreshDevices()
    }

    // MARK: Queries

    func refreshDevices() {
        let ids: [AudioDeviceID] = (try? CA.getArray(CA.systemObject, CA.address(kAudioHardwarePropertyDevices))) ?? []
        var list: [OutputDevice] = []
        for id in ids {
            guard Self.outputChannelCount(id) > 0 else { continue }
            let uid = (try? CA.getString(id, CA.address(kAudioDevicePropertyDeviceUID))) ?? ""
            if uid.hasPrefix(Self.privateUIDPrefix) { continue }
            let name = (try? CA.getString(id, CA.address(kAudioObjectPropertyName))) ?? "Device \(id)"
            let transport: UInt32 = (try? CA.get(id, CA.address(kAudioDevicePropertyTransportType), initial: UInt32(0))) ?? 0
            list.append(OutputDevice(id: id, uid: uid, name: name, transportType: transport))
        }
        devices = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        refreshDefault()
    }

    private func refreshDefault() {
        let id: AudioDeviceID = (try? CA.get(CA.systemObject, CA.address(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioDeviceID(0))) ?? 0
        let device = devices.first { $0.id == id } ?? Self.describe(id)
        if device?.id != defaultDevice?.id {
            defaultDevice = device
            installDeviceListeners()
        }
        refreshVolume()
    }

    private static func describe(_ id: AudioDeviceID) -> OutputDevice? {
        guard id != 0 else { return nil }
        let uid = (try? CA.getString(id, CA.address(kAudioDevicePropertyDeviceUID))) ?? ""
        let name = (try? CA.getString(id, CA.address(kAudioObjectPropertyName))) ?? "Device \(id)"
        let transport: UInt32 = (try? CA.get(id, CA.address(kAudioDevicePropertyTransportType), initial: UInt32(0))) ?? 0
        return OutputDevice(id: id, uid: uid, name: name, transportType: transport)
    }

    static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = CA.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func installDeviceListeners() {
        deviceListeners.removeAll()
        guard let id = defaultDevice?.id else { return }
        for element in volumeElements(for: id) {
            deviceListeners.append(CA.listen(id, CA.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)) { [weak self] in self?.refreshVolume() })
        }
        for element in muteElements(for: id) {
            deviceListeners.append(CA.listen(id, CA.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element)) { [weak self] in self?.refreshVolume() })
        }
    }

    /// Elements that carry a volume control: the main element if present, else each channel.
    private func volumeElements(for id: AudioDeviceID) -> [AudioObjectPropertyElement] {
        let main = CA.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        if CA.has(id, main) { return [kAudioObjectPropertyElementMain] }
        let channels = Self.outputChannelCount(id)
        return (1...max(channels, 1)).map { AudioObjectPropertyElement($0) }.filter {
            CA.has(id, CA.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: $0))
        }
    }

    private func muteElements(for id: AudioDeviceID) -> [AudioObjectPropertyElement] {
        let main = CA.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        if CA.has(id, main) { return [kAudioObjectPropertyElementMain] }
        let channels = Self.outputChannelCount(id)
        return (1...max(channels, 1)).map { AudioObjectPropertyElement($0) }.filter {
            CA.has(id, CA.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: $0))
        }
    }

    private func refreshVolume() {
        guard let id = defaultDevice?.id else { volume = 0; isMuted = false; canSetVolume = false; return }
        let vElements = volumeElements(for: id)
        let values: [Float] = vElements.compactMap {
            try? CA.get(id, CA.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: $0), initial: Float(0))
        }
        canSetVolume = vElements.contains { CA.isSettable(id, CA.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: $0)) }
        volume = values.isEmpty ? 1 : values.reduce(0, +) / Float(values.count)
        let mutes: [UInt32] = muteElements(for: id).compactMap {
            try? CA.get(id, CA.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: $0), initial: UInt32(0))
        }
        isMuted = !mutes.isEmpty && mutes.allSatisfy { $0 != 0 }
    }

    // MARK: Actions

    func setDefaultDevice(_ device: OutputDevice) {
        do {
            try CA.set(CA.systemObject, CA.address(kAudioHardwarePropertyDefaultOutputDevice), value: device.id)
        } catch {
            Log.write("failed to switch output: \(error)")
        }
    }

    func setVolume(_ value: Float) {
        guard let id = defaultDevice?.id else { return }
        let clamped = min(max(value, 0), 1)
        for element in volumeElements(for: id) {
            try? CA.set(id, CA.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element), value: clamped)
        }
        volume = clamped
        if clamped > 0 && isMuted { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard let id = defaultDevice?.id else { return }
        for element in muteElements(for: id) {
            try? CA.set(id, CA.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element), value: UInt32(muted ? 1 : 0))
        }
        isMuted = muted
    }
}
