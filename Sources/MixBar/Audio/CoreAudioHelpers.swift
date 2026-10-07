import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String
    var description: String {
        let code = UInt32(bitPattern: status)
        var fourcc = ""
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8((code >> UInt32(shift)) & 0xFF)
            if byte >= 32 && byte < 127 { fourcc.append(Character(UnicodeScalar(byte))) } else { fourcc = ""; break }
        }
        let codeText = fourcc.isEmpty ? "\(status)" : "'\(fourcc)' (\(status))"
        return "\(context): \(codeText)"
    }
}

/// Thin wrappers over AudioObjectGetPropertyData / SetPropertyData.
enum CA {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        return AudioObjectHasProperty(object, &addr)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) throws -> T {
        var addr = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { throw CoreAudioError(status: status, context: "get \(describe(address)) on \(object)") }
        return value
    }

    static func getArray<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [T] {
        var addr = address
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(status: status, context: "size \(describe(address)) on \(object)") }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let result = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer.baseAddress!)
            initialized = status == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
        guard status == noErr else { throw CoreAudioError(status: status, context: "get \(describe(address)) on \(object)") }
        return result
    }

    static func getString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        var addr = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { throw CoreAudioError(status: status, context: "get \(describe(address)) on \(object)") }
        guard let cf = value?.takeRetainedValue() else { return "" }
        return cf as String
    }

    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, value: T) throws {
        var addr = address
        var v = value
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafePointer(to: &v) { ptr in
            AudioObjectSetPropertyData(object, &addr, 0, nil, size, ptr)
        }
        guard status == noErr else { throw CoreAudioError(status: status, context: "set \(describe(address)) on \(object)") }
    }

    /// Registers a listener block; returns a token that removes it when deallocated.
    static func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                       queue: DispatchQueue = .main, handler: @escaping () -> Void) -> ListenerToken {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var addr = address
        AudioObjectAddPropertyListenerBlock(object, &addr, queue, block)
        return ListenerToken(object: object, address: address, queue: queue, block: block)
    }

    static func describe(_ a: AudioObjectPropertyAddress) -> String {
        func fourcc(_ v: UInt32) -> String {
            var s = ""
            for shift in stride(from: 24, through: 0, by: -8) {
                let byte = UInt8((v >> UInt32(shift)) & 0xFF)
                s.append(byte >= 32 && byte < 127 ? Character(UnicodeScalar(byte)) : "?")
            }
            return s
        }
        return "\(fourcc(a.mSelector))/\(fourcc(a.mScope))/\(a.mElement)"
    }
}

final class ListenerToken {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = block
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
