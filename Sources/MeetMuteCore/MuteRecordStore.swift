import Foundation

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

/// Our mute records, at most one per device (the muter keeps that invariant).
public protocol MuteRecordStore: AnyObject {
    func load() throws -> [MuteRecord]
    /// An empty list removes the stored value.
    func save(_ records: [MuteRecord]) throws
}

public enum MuteRecordStoreError: Error, Equatable { case unreadable }

public final class UserDefaultsMuteRecordStore: MuteRecordStore {
    private let defaults: UserDefaults
    private let key = "systemMuteRecord"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Reads the list format and the single record written by earlier versions, so a mute left
    /// pending by the previously installed app is still recovered after an upgrade.
    public func load() throws -> [MuteRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        if let records = try? decoder.decode([MuteRecord].self, from: data) { return records }
        if let legacyRecord = try? decoder.decode(MuteRecord.self, from: data) { return [legacyRecord] }
        throw MuteRecordStoreError.unreadable
    }

    /// Never deletes on an encoding failure — losing a record would strand a mute we applied.
    public func save(_ records: [MuteRecord]) throws {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(try JSONEncoder().encode(records), forKey: key)
    }
}
