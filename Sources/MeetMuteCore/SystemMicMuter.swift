import Foundation

/// The default input device's software controls (CoreAudio adapter in production, fake in tests).
public protocol InputMuteDevice: AnyObject {
    var uid: String { get }
    var name: String { get }
    var supportsMute: Bool { get }
    var supportsVolume: Bool { get }
    func isMuted() throws -> Bool
    func setMuted(_ muted: Bool) throws
    func volume() throws -> Float
    func setVolume(_ volume: Float) throws
}

public protocol InputDeviceProvider {
    func defaultInputDevice() throws -> InputMuteDevice
    func inputDevice(uid: String) throws -> InputMuteDevice?
}

public enum MuteMechanism: String, Codable, Sendable {
    case deviceMute
    case volumeZero
}

/// Proof that *we* muted a device, persisted so a crash can be undone on the next launch.
public struct MuteRecord: Codable, Equatable, Sendable {
    public let deviceUID: String
    public let mechanism: MuteMechanism
    public let previousVolume: Float?

    public init(deviceUID: String, mechanism: MuteMechanism, previousVolume: Float?) {
        self.deviceUID = deviceUID
        self.mechanism = mechanism
        self.previousVolume = previousVolume
    }
}

public protocol MuteRecordStore: AnyObject {
    func load() -> MuteRecord?
    func save(_ record: MuteRecord?)
}

public final class UserDefaultsMuteRecordStore: MuteRecordStore {
    private let defaults: UserDefaults
    private let key = "systemMuteRecord"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> MuteRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        // Our own JSON; an undecodable record (format change) is treated as no record.
        return try? JSONDecoder().decode(MuteRecord.self, from: data)
    }

    public func save(_ record: MuteRecord?) {
        if let record, let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

public enum SystemMuteError: Error, Equatable, CustomStringConvertible {
    case unsupported(deviceName: String)

    public var description: String {
        switch self {
        case .unsupported(let deviceName):
            "“\(deviceName)” has no software mute or input volume — choose another input device"
        }
    }
}

/// Mutes the default input device for every app. Only a mute we applied (recorded in the store)
/// is ever undone automatically, so a mic the user muted elsewhere stays muted.
public final class SystemMicMuter {
    private let devices: InputDeviceProvider
    private let store: MuteRecordStore

    public init(devices: InputDeviceProvider, store: MuteRecordStore) {
        self.devices = devices
        self.store = store
    }

    public var hasOwnedMute: Bool { store.load() != nil }

    public func mute() throws {
        let device = try devices.defaultInputDevice()
        try restoreRecordForAnotherDevice(than: device)
        if let record = store.load() {
            try reapply(record, on: device)
            return
        }
        if device.supportsMute {
            guard try !device.isMuted() else { return }  // muted by someone else: not ours to undo
            try device.setMuted(true)
            store.save(MuteRecord(deviceUID: device.uid, mechanism: .deviceMute, previousVolume: nil))
        } else if device.supportsVolume {
            let currentVolume = try device.volume()
            guard currentVolume > 0 else { return }
            try device.setVolume(0)
            store.save(MuteRecord(deviceUID: device.uid, mechanism: .volumeZero, previousVolume: currentVolume))
        } else {
            throw SystemMuteError.unsupported(deviceName: device.name)
        }
    }

    /// An explicit unmute press means "make me heard": undo our mute, or clear a device mute set elsewhere.
    public func unmute() throws {
        let device = try devices.defaultInputDevice()
        try restoreRecordForAnotherDevice(than: device)
        if let record = store.load() {
            try restore(record, on: device)
            return
        }
        if device.supportsMute, try device.isMuted() {
            try device.setMuted(false)
        }
    }

    /// Auto-unmute (call ended, launch after a crash, quit): undoes only a mute we applied.
    public func restoreIfWeMuted() throws {
        guard let record = store.load() else { return }
        guard let device = try devices.inputDevice(uid: record.deviceUID) else {
            store.save(nil)  // device disconnected; checked live in Task 7 Step 6
            return
        }
        try restore(record, on: device)
    }

    public func isDefaultInputMuted() throws -> Bool {
        let device = try devices.defaultInputDevice()
        if device.supportsMute { return try device.isMuted() }
        if device.supportsVolume { return try device.volume() == 0 }
        return false
    }

    private func restore(_ record: MuteRecord, on device: InputMuteDevice) throws {
        switch record.mechanism {
        case .deviceMute: try device.setMuted(false)
        case .volumeZero: try device.setVolume(record.previousVolume ?? 1)
        }
        store.save(nil)
    }

    private func reapply(_ record: MuteRecord, on device: InputMuteDevice) throws {
        switch record.mechanism {
        case .deviceMute: if try !device.isMuted() { try device.setMuted(true) }
        case .volumeZero: if try device.volume() > 0 { try device.setVolume(0) }
        }
    }

    private func restoreRecordForAnotherDevice(than device: InputMuteDevice) throws {
        if let record = store.load(), record.deviceUID != device.uid {
            try restoreIfWeMuted()
        }
    }
}
