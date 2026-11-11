import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let operation: String
    public let status: OSStatus

    public init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var description: String { "CoreAudio \(operation) failed (\(fourCharacterCode(status)))" }
}

/// CoreAudio statuses are usually four ASCII characters ('!dev'); fall back to the number.
func fourCharacterCode(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { shift in UInt8((value >> UInt32(shift)) & 0xFF) }
    guard bytes.allSatisfy({ byte in byte >= 32 && byte < 127 }) else { return "\(status)" }
    return "'" + String(decoding: bytes, as: UTF8.self) + "'"
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

/// For plain value types only (UInt32, Float32, AudioObjectID, pid_t) — never CFString.
func readValue<Value>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: Value, operation: String) throws -> Value {
    var address = address
    var value = initial
    var size = UInt32(MemoryLayout<Value>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
    return value
}

func writeValue<Value>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ newValue: Value, operation: String) throws {
    var address = address
    var value = newValue
    let status = withUnsafePointer(to: &value) { pointer in
        AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Value>.size), pointer)
    }
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
}

func readString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, operation: String) throws -> String {
    var address = address
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &unmanaged)
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
    return (unmanaged?.takeRetainedValue() as String?) ?? ""
}

func readObjectIDs(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, operation: String) throws -> [AudioObjectID] {
    var address = address
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
    var objectIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objectIDs)
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
    return Array(objectIDs.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
    var address = address
    guard AudioObjectHasProperty(object, &address) else { return false }
    var settable = DarwinBoolean(false)
    return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
}
