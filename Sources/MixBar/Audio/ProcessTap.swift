import CoreAudio
import Foundation
import os

/// Routes one app's audio through a private aggregate device so its gain can be changed.
///
/// The process tap mutes the app's direct output; the IO proc below replays the tapped
/// audio into the real output device after applying the per-app gain.

final class ProcessTap {
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private struct State { var gain: Float = 1; var muted = false; var peak: Float = 0 }

    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "dev.local.MixBar.tap", qos: .userInteractive)
    private var inputIsFloat = true
    private var outputIsFloat = true

    let processObjects: [AudioObjectID]
    let outputDeviceUID: String

    var gain: Float {
        get { lock.withLock { $0.gain } }
        set { lock.withLock { $0.gain = min(max(newValue, 0), 1) } }
    }
    var isMuted: Bool {
        get { lock.withLock { $0.muted } }
        set { lock.withLock { $0.muted = newValue } }
    }
    /// Peak sample level since the last read, 0…1.
    func takePeak() -> Float { lock.withLock { let p = $0.peak; $0.peak = 0; return p } }

    init(processObjects: [AudioObjectID], outputDeviceUID: String, label: String) throws {
        self.processObjects = processObjects
        self.outputDeviceUID = outputDeviceUID

        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "MixBar – \(label)"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw CoreAudioError(status: status, context: "AudioHardwareCreateProcessTap") }
        tapID = tap

        let aggregateUID = OutputDeviceManagerUIDs.aggregate(for: description.uuid)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MixBar – \(label)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw CoreAudioError(status: status, context: "AudioHardwareCreateAggregateDevice")
        }
        aggregateID = aggregate

        if let format: AudioStreamBasicDescription = try? CA.get(tap, CA.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription()) {
            inputIsFloat = format.mFormatID == kAudioFormatLinearPCM && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && format.mBitsPerChannel == 32
        }
        if let format: AudioStreamBasicDescription = try? CA.get(aggregate, CA.address(kAudioStreamPropertyVirtualFormat, scope: kAudioDevicePropertyScopeOutput), initial: AudioStreamBasicDescription()) {
            outputIsFloat = format.mFormatID == kAudioFormatLinearPCM && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && format.mBitsPerChannel == 32
        }

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { [weak self] _, inputData, _, outputData, _ in
            self?.render(input: inputData, output: outputData)
        }
        guard status == noErr, let proc else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw CoreAudioError(status: status, context: "AudioDeviceCreateIOProcIDWithBlock")
        }
        procID = proc

        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else {
            invalidate()
            throw CoreAudioError(status: status, context: "AudioDeviceStart")
        }
    }

    deinit { invalidate() }

    func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Rendering (real-time thread)

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let (gain, muted) = lock.withLock { ($0.gain, $0.muted) }
        guard inputIsFloat, outputIsFloat, !muted, gain > 0 else { return }

        // Flatten tap input channels into (buffer, channelOffset, stride) descriptors.
        var inChannels: [(ptr: UnsafeMutablePointer<Float>, stride: Int, frames: Int)] = []
        inChannels.reserveCapacity(4)
        for buffer in inList {
            guard let raw = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let ptr = raw.assumingMemoryBound(to: Float.self)
            let channels = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (4 * channels)
            for c in 0..<channels {
                inChannels.append((ptr + c, channels, frames))
            }
        }
        guard !inChannels.isEmpty else { return }

        var peak: Float = 0
        var outChannelIndex = 0
        for buffer in outList {
            guard let raw = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let out = raw.assumingMemoryBound(to: Float.self)
            let channels = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (4 * channels)
            for c in 0..<channels {
                let src = inChannels[outChannelIndex % inChannels.count]
                let count = min(frames, src.frames)
                var i = 0
                while i < count {
                    let sample = src.ptr[i * src.stride] * gain
                    out[i * channels + c] = sample
                    let magnitude = abs(sample)
                    if magnitude > peak { peak = magnitude }
                    i += 1
                }
                outChannelIndex += 1
            }
        }
        let framePeak = peak
        lock.withLock { if framePeak > $0.peak { $0.peak = framePeak } }
    }
}

enum OutputDeviceManagerUIDs {
    static func aggregate(for uuid: UUID) -> String { "dev.local.MixBar.aggregate.\(uuid.uuidString)" }
}
