import Foundation

/// Mutes the input devices a call is using, for every app. Only a mute we applied (recorded per
/// device in the store) is ever undone automatically, so a mic the user muted elsewhere stays muted.
public final class SystemMicMuter {
    private let devices: InputDeviceProvider
    private let store: MuteRecordStore

    public init(devices: InputDeviceProvider, store: MuteRecordStore) {
        self.devices = devices
        self.store = store
    }

    public func targetDeviceUIDs(for recorders: [RecordingProcess]) throws -> [String] {
        try targetInputDeviceUIDs(for: recorders, defaultInputUID: devices.defaultInputUID())
    }

    /// Our mutes on devices the call no longer uses are undone first. All or nothing: if any
    /// target fails, the devices this call muted are unmuted again (records dropped) and every
    /// failure is reported. Mutes that predate the call (ours or foreign) are left alone.
    public func mute(deviceUIDs: [String]) throws {
        let targets = uniqued(deviceUIDs)
        var records = try loadRecords(failSafeDeviceUIDs: { targets })
        var failures = restorePresentRecords(in: &records) { record in !targets.contains(record.deviceUID) }.failures
        var mutedByThisCall: Set<String> = []
        var targetFailed = false
        for deviceUID in targets {
            do {
                if try mute(deviceUID, records: &records) { mutedByThisCall.insert(deviceUID) }
            } catch {
                targetFailed = true
                failures.append(failure(deviceUID, error))
            }
        }
        if targetFailed {
            failures += restorePresentRecords(in: &records) { record in mutedByThisCall.contains(record.deviceUID) }.failures
        }
        try throwIfAny(failures)
    }

    /// An explicit unmute press means "make me heard": undo all our mutes, and clear a device
    /// mute set elsewhere on the target devices.
    public func unmute(deviceUIDs: [String]) throws {
        let targets = uniqued(deviceUIDs)
        var records = try loadRecords(failSafeDeviceUIDs: { targets })
        var failures = restorePresentRecords(in: &records) { _ in true }.failures
        let stillRecorded = Set(records.map(\.deviceUID))  // failed or absent: already handled
        for deviceUID in targets where !stillRecorded.contains(deviceUID) {
            do {
                try clearForeignMute(deviceUID)
            } catch {
                failures.append(failure(deviceUID, error))
            }
        }
        try throwIfAny(failures)
    }

    /// Auto-unmute (call ended, launch after a crash, quit): undoes only mutes we applied, on
    /// devices that are connected. A disconnected device keeps its record until it returns
    /// (verified live 2026-11-11: AirPods disconnected while muted reconnected unmuted, so the kept
    /// record's undo finds nothing to change). Returns whether any device actually changed.
    @discardableResult
    public func restoreIfWeMuted() throws -> Bool {
        var records = try loadRecords(failSafeDeviceUIDs: { [try devices.defaultInputUID()] })
        let outcome = restorePresentRecords(in: &records) { _ in true }
        try throwIfAny(outcome.failures)
        return outcome.changed
    }

    /// True only when every target device is silent (device mute or input volume 0).
    public func isMuted(deviceUIDs: [String]) throws -> Bool {
        guard !deviceUIDs.isEmpty else { return false }
        for deviceUID in deviceUIDs {
            guard let device = try devices.inputDevice(uid: deviceUID), try device.isSilenced() else { return false }
        }
        return true
    }

    // MARK: Records

    /// The single place records are read. An unreadable list fails safe toward being heard:
    /// unmute the given devices if silenced, clear the store, then report it.
    private func loadRecords(failSafeDeviceUIDs: () throws -> [String]) throws -> [MuteRecord] {
        do {
            return try store.load()
        } catch MuteRecordStoreError.unreadable {
            for deviceUID in try failSafeDeviceUIDs() {
                guard let device = try devices.inputDevice(uid: deviceUID) else { continue }
                if device.supportsMute {
                    if try device.isMuted() { try device.setMuted(false) }
                } else if device.supportsVolume, try device.volume() == 0 {
                    try device.setVolume(1)  // the previous level was in the unreadable record
                }
            }
            try store.save([])
            throw SystemMuteError.recordWasUnreadable
        }
    }

    /// Records first, then mutes: a crash in between leaves a record for an unmuted device (harmless),
    /// never a muted device with no record. A failed device write rolls the record back.
    private func applyRecordingFirst(_ record: MuteRecord, records: inout [MuteRecord], _ applyMute: () throws -> Void) throws {
        let previousRecords = records
        try store.save(previousRecords + [record])
        records = previousRecords + [record]
        do {
            try applyMute()
        } catch {
            // A failed rollback leaves a record for an unmuted device: stale but safe (a later
            // restore re-unmutes). The device error is the one the caller needs to see.
            if (try? store.save(previousRecords)) != nil { records = previousRecords }
            throw error
        }
    }

    /// Undoes matching records on connected devices; a failed undo keeps its record for a retry.
    private func restorePresentRecords(
        in records: inout [MuteRecord],
        where shouldRestore: (MuteRecord) -> Bool
    ) -> (changed: Bool, failures: [DeviceMuteFailure]) {
        var changed = false
        var failures: [DeviceMuteFailure] = []
        for record in records where shouldRestore(record) {
            do {
                guard let device = try devices.inputDevice(uid: record.deviceUID) else { continue }
                changed = try device.undo(record) || changed
                let remainingRecords = records.filter { kept in kept.deviceUID != record.deviceUID }
                try store.save(remainingRecords)
                records = remainingRecords
            } catch {
                failures.append(failure(record.deviceUID, error))
            }
        }
        return (changed, failures)
    }

    // MARK: One device

    /// Returns whether this call changed the device (a fresh mute or a reapplied one).
    private func mute(_ deviceUID: String, records: inout [MuteRecord]) throws -> Bool {
        guard let device = try devices.inputDevice(uid: deviceUID) else { throw SystemMuteError.notConnected }
        if let record = records.first(where: { record in record.deviceUID == deviceUID }) {
            return try device.reapply(record)
        } else if device.supportsMute {
            guard try !device.isMuted() else { return false }  // muted by someone else: not ours to undo
            let record = MuteRecord(deviceUID: deviceUID, mechanism: .deviceMute, previousVolume: nil)
            try applyRecordingFirst(record, records: &records) { try device.setMuted(true) }
        } else if device.supportsVolume {
            let currentVolume = try device.volume()
            guard currentVolume > 0 else { return false }
            let record = MuteRecord(deviceUID: deviceUID, mechanism: .volumeZero, previousVolume: currentVolume)
            try applyRecordingFirst(record, records: &records) { try device.setVolume(0) }
        } else {
            throw SystemMuteError.noMuteControls
        }
        return true
    }

    private func clearForeignMute(_ deviceUID: String) throws {
        guard let device = try devices.inputDevice(uid: deviceUID), device.supportsMute, try device.isMuted() else { return }
        try device.setMuted(false)
    }

    private func failure(_ deviceUID: String, _ error: Error) -> DeviceMuteFailure {
        let deviceName = (try? devices.inputDevice(uid: deviceUID))?.name ?? deviceUID
        return DeviceMuteFailure(deviceName: deviceName, reason: String(describing: error))
    }

    private func throwIfAny(_ failures: [DeviceMuteFailure]) throws {
        guard failures.isEmpty else { throw SystemMuteError.devicesFailed(failures) }
    }
}

private func uniqued(_ deviceUIDs: [String]) -> [String] {
    var seen = Set<String>()
    return deviceUIDs.filter { deviceUID in seen.insert(deviceUID).inserted }
}
