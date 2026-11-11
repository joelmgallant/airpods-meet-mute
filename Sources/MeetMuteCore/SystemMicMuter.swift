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
    func load() throws -> MuteRecord?
    func save(_ record: MuteRecord?) throws
}

public enum MuteRecordStoreError: Error, Equatable { case unreadable }

public final class UserDefaultsMuteRecordStore: MuteRecordStore {
    private let defaults: UserDefaults
    private let key = "systemMuteRecord"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() throws -> MuteRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(MuteRecord.self, from: data)
        } catch {
            throw MuteRecordStoreError.unreadable
        }
    }

    /// Never deletes on an encoding failure — losing the record would strand a mute we applied.
    public func save(_ record: MuteRecord?) throws {
        guard let record else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(try JSONEncoder().encode(record), forKey: key)
    }
}

public enum SystemMuteError: Error, Equatable, CustomStringConvertible {
    case unsupported(deviceName: String)
    case recordWasUnreadable

    public var description: String {
        switch self {
        case .recordWasUnreadable:
            "The saved mute record was unreadable — unmuted the mic to be safe"
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

    public func mute() throws {
        let device = try devices.defaultInputDevice()
        try restoreRecordForAnotherDevice(than: device)
        if let record = try loadRecord() {
            try reapply(record, on: device)
            return
        }
        if device.supportsMute {
            guard try !device.isMuted() else { return }  // muted by someone else: not ours to undo
            let record = MuteRecord(deviceUID: device.uid, mechanism: .deviceMute, previousVolume: nil)
            try applyRecordingFirst(record) { try device.setMuted(true) }
        } else if device.supportsVolume {
            let currentVolume = try device.volume()
            guard currentVolume > 0 else { return }
            let record = MuteRecord(deviceUID: device.uid, mechanism: .volumeZero, previousVolume: currentVolume)
            try applyRecordingFirst(record) { try device.setVolume(0) }
        } else {
            throw SystemMuteError.unsupported(deviceName: device.name)
        }
    }

    /// An explicit unmute press means "make me heard": undo our mute, or clear a device mute set elsewhere.
    public func unmute() throws {
        let device = try devices.defaultInputDevice()
        try restoreRecordForAnotherDevice(than: device)
        if let record = try loadRecord() {
            try restore(record, on: device)
            return
        }
        if device.supportsMute, try device.isMuted() {
            try device.setMuted(false)
        }
    }

    /// Auto-unmute (call ended, launch after a crash, quit): undoes only a mute we applied.
    public func restoreIfWeMuted() throws {
        guard let record = try loadRecord() else { return }
        guard let device = try devices.inputDevice(uid: record.deviceUID) else {
            try store.save(nil)  // device disconnected; checked live in Task 7 Step 6
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

    /// The single place the record is read. An unreadable record fails safe toward being heard:
    /// unmute the default input if device-muted, clear the record, then report it.
    private func loadRecord() throws -> MuteRecord? {
        do {
            return try store.load()
        } catch MuteRecordStoreError.unreadable {
            let device = try devices.defaultInputDevice()
            if device.supportsMute, try device.isMuted() {
                try device.setMuted(false)
            }
            try store.save(nil)
            throw SystemMuteError.recordWasUnreadable
        }
    }

    /// Records first, then mutes: a crash in between leaves a record for an unmuted device (harmless),
    /// never a muted device with no record. A failed device write rolls the record back.
    private func applyRecordingFirst(_ record: MuteRecord, _ applyMute: () throws -> Void) throws {
        try store.save(record)
        do {
            try applyMute()
        } catch {
            try? store.save(nil)
            throw error
        }
    }

    private func restore(_ record: MuteRecord, on device: InputMuteDevice) throws {
        switch record.mechanism {
        case .deviceMute: try device.setMuted(false)
        case .volumeZero: try device.setVolume(record.previousVolume ?? 1)
        }
        try store.save(nil)
    }

    private func reapply(_ record: MuteRecord, on device: InputMuteDevice) throws {
        switch record.mechanism {
        case .deviceMute: if try !device.isMuted() { try device.setMuted(true) }
        case .volumeZero: if try device.volume() > 0 { try device.setVolume(0) }
        }
    }

    private func restoreRecordForAnotherDevice(than device: InputMuteDevice) throws {
        if let record = try loadRecord(), record.deviceUID != device.uid {
            try restoreIfWeMuted()
        }
    }
}
