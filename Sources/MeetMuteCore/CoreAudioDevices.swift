import CoreAudio
import Foundation

public final class CoreAudioInputDevice: InputMuteDevice {
    let objectID: AudioObjectID
    public let uid: String
    public let name: String
    private let muteAddress = propertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
    private let volumeAddresses: [AudioObjectPropertyAddress]

    init(objectID: AudioObjectID) throws {
        self.objectID = objectID
        uid = try readString(objectID, propertyAddress(kAudioDevicePropertyDeviceUID), operation: "read device UID")
        name = try readString(objectID, propertyAddress(kAudioObjectPropertyName), operation: "read device name")
        let elements = [kAudioObjectPropertyElementMain] + (1...8).map { channel in AudioObjectPropertyElement(channel) }
        let settableVolumes = elements
            .map { element in propertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: element) }
            .filter { address in isSettable(objectID, address) }
        // Prefer the main element; otherwise drive every channel element together.
        if let main = settableVolumes.first, main.mElement == kAudioObjectPropertyElementMain {
            volumeAddresses = [main]
        } else {
            volumeAddresses = settableVolumes
        }
    }

    public var supportsMute: Bool { isSettable(objectID, muteAddress) }
    public var supportsVolume: Bool { !volumeAddresses.isEmpty }

    public func isMuted() throws -> Bool {
        try readValue(objectID, muteAddress, initial: UInt32(0), operation: "read input mute") != 0
    }

    public func setMuted(_ muted: Bool) throws {
        try writeValue(objectID, muteAddress, UInt32(muted ? 1 : 0), operation: "set input mute")
    }

    public func volume() throws -> Float {
        guard let first = volumeAddresses.first else {
            throw CoreAudioError(operation: "read input volume", status: kAudioHardwareUnknownPropertyError)
        }
        return try readValue(objectID, first, initial: Float32(0), operation: "read input volume")
    }

    public func setVolume(_ volume: Float) throws {
        for address in volumeAddresses {
            try writeValue(objectID, address, Float32(volume), operation: "set input volume")
        }
    }
}

public struct CoreAudioInputDeviceProvider: InputDeviceProvider {
    public init() {}

    public func defaultInputDevice() throws -> InputMuteDevice {
        let objectID = try readValue(
            AudioObjectID(kAudioObjectSystemObject),
            propertyAddress(kAudioHardwarePropertyDefaultInputDevice),
            initial: AudioObjectID(kAudioObjectUnknown),
            operation: "read default input device"
        )
        guard objectID != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioError(operation: "find a default input device", status: kAudioHardwareBadDeviceError)
        }
        return try CoreAudioInputDevice(objectID: objectID)
    }

    public func inputDevice(uid: String) throws -> InputMuteDevice? {
        let objectIDs = try readObjectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            propertyAddress(kAudioHardwarePropertyDevices),
            operation: "list audio devices"
        )
        for objectID in objectIDs {
            // A device that cannot report a UID/name (mid-teardown) is simply not the one we want.
            if let device = try? CoreAudioInputDevice(objectID: objectID), device.uid == uid {
                return device
            }
        }
        return nil
    }
}
