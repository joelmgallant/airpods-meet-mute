import Foundation
import Testing
@testable import MeetMuteCore

enum FakeDeviceError: Error { case setFailed }

final class FakeInputDevice: InputMuteDevice {
    let uid: String
    let name: String
    let supportsMute: Bool
    let supportsVolume: Bool
    var muted = false
    var level: Float = 0.8
    var failNextSet = false
    var failEverySet = false

    init(uid: String = "airpods", name: String = "AirPods", supportsMute: Bool = true, supportsVolume: Bool = true) {
        self.uid = uid
        self.name = name
        self.supportsMute = supportsMute
        self.supportsVolume = supportsVolume
    }

    func isMuted() throws -> Bool { muted }
    func setMuted(_ newValue: Bool) throws {
        try failIfAsked()
        muted = newValue
    }
    func volume() throws -> Float { level }
    func setVolume(_ newValue: Float) throws {
        try failIfAsked()
        level = newValue
    }

    private func failIfAsked() throws {
        if failEverySet { throw FakeDeviceError.setFailed }
        if failNextSet { failNextSet = false; throw FakeDeviceError.setFailed }
    }
}

final class FakeInputDevices: InputDeviceProvider {
    /// The system default input.
    var current: FakeInputDevice
    /// Connected devices; remove one to simulate unplugging it.
    var all: [FakeInputDevice]

    init(_ devices: FakeInputDevice...) {
        current = devices[0]
        all = devices
    }

    func defaultInputUID() throws -> String { current.uid }
    func inputDevice(uid: String) throws -> InputMuteDevice? { all.first { device in device.uid == uid } }
}

final class MemoryMuteRecordStore: MuteRecordStore {
    var records: [MuteRecord] = []
    var failNextSave = false
    var unreadable = false
    /// Called with the new records just before they are stored, so a test can observe what else is true at save time.
    var onSave: (([MuteRecord]) -> Void)?

    func load() throws -> [MuteRecord] {
        if unreadable { throw MuteRecordStoreError.unreadable }
        return records
    }

    func save(_ newRecords: [MuteRecord]) throws {
        if failNextSave { failNextSave = false; throw FakeDeviceError.setFailed }
        onSave?(newRecords)
        records = newRecords
        unreadable = false
    }
}

private func deviceMuteRecord(_ deviceUID: String) -> MuteRecord {
    MuteRecord(deviceUID: deviceUID, mechanism: .deviceMute, previousVolume: nil)
}

private func failedDeviceNames(_ body: () throws -> Void) -> [String]? {
    do {
        try body()
        return nil
    } catch let SystemMuteError.devicesFailed(failures) {
        return failures.map(\.deviceName)
    } catch {
        return ["unexpected: \(error)"]
    }
}

// MARK: Single device (the behaviour before per-device muting)

@Test func muteUsesTheDeviceMuteAndRecordsIt() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    try SystemMicMuter(devices: FakeInputDevices(airpods), store: store).mute(deviceUIDs: ["airpods"])
    #expect(airpods.muted)
    #expect(store.records == [deviceMuteRecord("airpods")])
}

@Test func unmuteUndoesOurMuteAndClearsTheRecord() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute(deviceUIDs: ["airpods"])
    try muter.unmute(deviceUIDs: ["airpods"])
    #expect(!airpods.muted)
    #expect(store.records.isEmpty)
}

@Test func aDeviceAlreadyMutedElsewhereIsNotClaimed() throws {
    let airpods = FakeInputDevice()
    airpods.muted = true
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute(deviceUIDs: ["airpods"])
    #expect(store.records.isEmpty)
    #expect(try !muter.restoreIfWeMuted())
    #expect(airpods.muted)
}

@Test func anExplicitUnmuteClearsAForeignMute() throws {
    let airpods = FakeInputDevice()
    airpods.muted = true
    try SystemMicMuter(devices: FakeInputDevices(airpods), store: MemoryMuteRecordStore()).unmute(deviceUIDs: ["airpods"])
    #expect(!airpods.muted)
}

@Test func theVolumeFallbackRemembersAndRestoresTheLevel() throws {
    let airpods = FakeInputDevice(supportsMute: false)
    airpods.level = 0.6
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute(deviceUIDs: ["airpods"])
    #expect(airpods.level == 0)
    #expect(store.records == [MuteRecord(deviceUID: "airpods", mechanism: .volumeZero, previousVolume: 0.6)])
    try muter.unmute(deviceUIDs: ["airpods"])
    #expect(airpods.level == 0.6)
    #expect(store.records.isEmpty)
}

@Test func aDeviceWithNoControlsIsReportedByName() {
    let fixed = FakeInputDevice(supportsMute: false, supportsVolume: false)
    let muter = SystemMicMuter(devices: FakeInputDevices(fixed), store: MemoryMuteRecordStore())
    #expect(failedDeviceNames { try muter.mute(deviceUIDs: ["airpods"]) } == ["AirPods"])
}

@Test func restoreDoesNothingWithoutARecord() throws {
    let airpods = FakeInputDevice()
    airpods.muted = true
    #expect(try !SystemMicMuter(devices: FakeInputDevices(airpods), store: MemoryMuteRecordStore()).restoreIfWeMuted())
    #expect(airpods.muted)
}

@Test func launchRecoveryUnmutesTheRecordedDevice() throws {
    let airpods = FakeInputDevice()
    airpods.muted = true
    let store = MemoryMuteRecordStore()
    store.records = [deviceMuteRecord("airpods")]
    #expect(try SystemMicMuter(devices: FakeInputDevices(airpods), store: store).restoreIfWeMuted())
    #expect(!airpods.muted)
    #expect(store.records.isEmpty)
}

@Test func restoreReportsNoChangeWhenOurMuteWasAlreadyUndone() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute(deviceUIDs: ["airpods"])
    airpods.muted = false  // the user unmuted in System Settings
    #expect(try !muter.restoreIfWeMuted())
    #expect(store.records.isEmpty)
}

@Test func muteReappliesWhenOurMuteWasUndoneElsewhere() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute(deviceUIDs: ["airpods"])
    airpods.muted = false
    try muter.mute(deviceUIDs: ["airpods"])
    #expect(airpods.muted)
    #expect(store.records == [deviceMuteRecord("airpods")])
}

@Test func aFailedMuteLeavesNoRecord() {
    let airpods = FakeInputDevice()
    airpods.failNextSet = true
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    #expect(failedDeviceNames { try muter.mute(deviceUIDs: ["airpods"]) } == ["AirPods"])
    #expect(store.records.isEmpty)
}

@Test func muteWritesTheRecordBeforeTouchingTheDevice() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    var deviceWasMutedWhenRecordSaved: Bool?
    store.onSave = { savedRecords in
        if !savedRecords.isEmpty { deviceWasMutedWhenRecordSaved = airpods.muted }
    }
    try SystemMicMuter(devices: FakeInputDevices(airpods), store: store).mute(deviceUIDs: ["airpods"])
    #expect(deviceWasMutedWhenRecordSaved == false)
    #expect(airpods.muted)
}

@Test func aFailedRecordWriteLeavesTheDeviceUntouched() {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    store.failNextSave = true
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    #expect(failedDeviceNames { try muter.mute(deviceUIDs: ["airpods"]) } == ["AirPods"])
    #expect(!airpods.muted)
    #expect(store.records.isEmpty)
}

@Test func aFailedVolumeMuteRollsBackTheRecord() {
    let volumeOnly = FakeInputDevice(supportsMute: false)
    volumeOnly.failNextSet = true
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(volumeOnly), store: store)
    #expect(failedDeviceNames { try muter.mute(deviceUIDs: ["airpods"]) } == ["AirPods"])
    #expect(volumeOnly.level == 0.8)
    #expect(store.records.isEmpty)
}

@Test func aFailedRestoreKeepsTheRecord() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute(deviceUIDs: ["airpods"])
    airpods.failNextSet = true
    #expect(failedDeviceNames { try muter.restoreIfWeMuted() } == ["AirPods"])
    #expect(store.records == [deviceMuteRecord("airpods")])
}

// MARK: Several devices

@Test func muteSilencesEveryTargetDeviceWithOneRecordEach() throws {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods, usb), store: store)
    try muter.mute(deviceUIDs: ["airpods", "usb"])
    try muter.mute(deviceUIDs: ["airpods", "usb"])
    #expect(airpods.muted && usb.muted)
    #expect(store.records == [deviceMuteRecord("airpods"), deviceMuteRecord("usb")])
    #expect(try muter.muteState(deviceUIDs: ["airpods", "usb"]) == .muted)
    try muter.unmute(deviceUIDs: ["airpods", "usb"])
    #expect(!airpods.muted && !usb.muted)
    #expect(store.records.isEmpty)
}

@Test func oneFailingDeviceLeavesNoTargetMutedByUsAndIsNamed() {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    usb.failEverySet = true
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods, usb), store: store)
    #expect(failedDeviceNames { try muter.mute(deviceUIDs: ["airpods", "usb"]) } == ["USB Mic"])
    #expect(!airpods.muted && !usb.muted)
    #expect(store.records.isEmpty)
}

@Test func aMissingTargetDeviceIsReportedAndNothingIsLeftMuted() {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    #expect(failedDeviceNames { try muter.mute(deviceUIDs: ["airpods", "gone"]) } == ["gone"])
    #expect(!airpods.muted)
    #expect(store.records.isEmpty)
}

@Test func aFailedMuteRollsBackAVolumeMuteToItsLevel() {
    let volumeOnly = FakeInputDevice(uid: "usb", name: "USB Mic", supportsMute: false)
    volumeOnly.level = 0.6
    let broken = FakeInputDevice(uid: "studio", name: "Studio Mic")
    broken.failEverySet = true
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(volumeOnly, broken), store: store)
    #expect(failedDeviceNames { try muter.mute(deviceUIDs: ["usb", "studio"]) } == ["Studio Mic"])
    #expect(volumeOnly.level == 0.6)
    #expect(store.records.isEmpty)
}

@Test func aFailedMuteLeavesMutesThatPredateThePressAlone() throws {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let foreign = FakeInputDevice(uid: "foreign", name: "Foreign Mic")
    foreign.muted = true  // muted elsewhere
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods, foreign, usb), store: store)
    try muter.mute(deviceUIDs: ["airpods"])
    usb.failEverySet = true
    #expect(failedDeviceNames { try muter.mute(deviceUIDs: ["airpods", "foreign", "usb"]) } == ["USB Mic"])
    #expect(airpods.muted && foreign.muted)
    #expect(store.records == [deviceMuteRecord("airpods")])
}

@Test func aFailedMuteUndoesAMuteItReappliedAfterItWasUndoneElsewhere() throws {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods, usb), store: store)
    try muter.mute(deviceUIDs: ["airpods"])
    airpods.muted = false  // unmuted elsewhere; this press reapplies it
    usb.failEverySet = true
    #expect(failedDeviceNames { try muter.mute(deviceUIDs: ["airpods", "usb"]) } == ["USB Mic"])
    #expect(!airpods.muted)
    #expect(store.records.isEmpty)
}

@Test func aPreExistingMuteOnOneTargetIsNotClaimed() throws {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    usb.muted = true
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods, usb), store: store)
    try muter.mute(deviceUIDs: ["airpods", "usb"])
    #expect(store.records == [deviceMuteRecord("airpods")])
    #expect(try muter.restoreIfWeMuted())
    #expect(!airpods.muted)
    #expect(usb.muted)
}

@Test func switchingTargetDevicesRestoresTheOldOne() throws {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods, usb), store: store)
    try muter.mute(deviceUIDs: ["airpods"])
    try muter.mute(deviceUIDs: ["usb"])
    #expect(!airpods.muted)
    #expect(usb.muted)
    #expect(store.records == [deviceMuteRecord("usb")])
}

@Test func unmuteAlsoRestoresOurMuteOnOtherDevices() throws {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods, usb), store: store)
    try muter.mute(deviceUIDs: ["airpods"])
    try muter.unmute(deviceUIDs: ["usb"])
    #expect(!airpods.muted)
    #expect(store.records.isEmpty)
}

@Test func anAbsentDeviceKeepsItsRecordUntilItReappears() throws {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    let devices = FakeInputDevices(airpods, usb)
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: devices, store: store)
    try muter.mute(deviceUIDs: ["airpods", "usb"])
    devices.all = [airpods]  // USB mic unplugged while muted

    #expect(try muter.restoreIfWeMuted())
    #expect(!airpods.muted)
    #expect(store.records == [deviceMuteRecord("usb")])
    #expect(try !muter.restoreIfWeMuted())

    devices.all = [airpods, usb]  // replugged, still muted by us
    #expect(try muter.restoreIfWeMuted())
    #expect(!usb.muted)
    #expect(store.records.isEmpty)
}

@Test func muteStateIsMutedOnlyWhenEveryTargetIsSilent() throws {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods, usb), store: MemoryMuteRecordStore())
    airpods.muted = true
    usb.muted = true
    #expect(try muter.muteState(deviceUIDs: ["airpods", "usb"]) == .muted)
}

@Test func muteStateIsLiveWhenNoTargetIsSilent() throws {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods, usb), store: MemoryMuteRecordStore())
    #expect(try muter.muteState(deviceUIDs: ["airpods", "usb"]) == .live)
    #expect(try muter.muteState(deviceUIDs: []) == .live)
}

@Test func muteStateIsMixedWhenOnlySomeTargetsAreSilent() throws {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods, usb), store: MemoryMuteRecordStore())
    airpods.muted = true
    #expect(try muter.muteState(deviceUIDs: ["airpods", "usb"]) == .mixed)
    #expect(try muter.muteState(deviceUIDs: ["airpods", "gone"]) == .mixed)
}

@Test func muteStateCountsInputVolumeZeroAsSilent() throws {
    let volumeOnly = FakeInputDevice(uid: "usb", name: "USB Mic", supportsMute: false)
    let muter = SystemMicMuter(devices: FakeInputDevices(volumeOnly), store: MemoryMuteRecordStore())
    #expect(try muter.muteState(deviceUIDs: ["usb"]) == .live)
    volumeOnly.level = 0
    #expect(try muter.muteState(deviceUIDs: ["usb"]) == .muted)
}

@Test func targetDevicesUseTheDefaultInputOnlyWhenRecordersReportNone() throws {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: MemoryMuteRecordStore())
    let slack = RecordingProcess(pid: 1, bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")
    #expect(try muter.targetDeviceUIDs(for: [slack]) == ["airpods"])
    let slackOnUSB = RecordingProcess(pid: 1, bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack",
                                      inputDeviceUIDs: ["usb"])
    #expect(try muter.targetDeviceUIDs(for: [slackOnUSB]) == ["usb"])
}

// MARK: Unreadable record list

@Test func anUnreadableRecordFailsSafeByUnmutingTheDefaultInputOnRestore() {
    let airpods = FakeInputDevice()
    airpods.muted = true
    let store = MemoryMuteRecordStore()
    store.unreadable = true
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    #expect(throws: SystemMuteError.recordWasUnreadable) { try muter.restoreIfWeMuted() }
    #expect(!airpods.muted)
    #expect(store.records.isEmpty)
    #expect(!store.unreadable)
}

@Test func anUnreadableRecordRestoresAVolumeOnlyMicSilencedAtZero() {
    let volumeOnly = FakeInputDevice(supportsMute: false)
    volumeOnly.level = 0
    let store = MemoryMuteRecordStore()
    store.unreadable = true
    let muter = SystemMicMuter(devices: FakeInputDevices(volumeOnly), store: store)
    #expect(throws: SystemMuteError.recordWasUnreadable) { try muter.restoreIfWeMuted() }
    #expect(volumeOnly.level == 1)
    #expect(store.records.isEmpty)
}

@Test func anUnreadableRecordStopsAMutePressAfterUnmutingTheTargets() {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    let bystander = FakeInputDevice(uid: "other", name: "Other Mic")
    airpods.muted = true
    usb.muted = true
    bystander.muted = true
    let store = MemoryMuteRecordStore()
    store.unreadable = true
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods, usb, bystander), store: store)
    #expect(throws: SystemMuteError.recordWasUnreadable) { try muter.mute(deviceUIDs: ["airpods", "usb"]) }
    #expect(!airpods.muted && !usb.muted)
    #expect(bystander.muted)  // bounded: only the devices we were asked about
    #expect(store.records.isEmpty)
}

// MARK: UserDefaults store

@Test func userDefaultsStoreRoundTripsAndClears() throws {
    let suiteName = "airpods-meet-mute-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsMuteRecordStore(defaults: defaults)
    let records = [MuteRecord(deviceUID: "airpods", mechanism: .volumeZero, previousVolume: 0.5), deviceMuteRecord("usb")]
    try store.save(records)
    #expect(try UserDefaultsMuteRecordStore(defaults: defaults).load() == records)
    try store.save([])
    #expect(try store.load().isEmpty)
    #expect(defaults.object(forKey: "systemMuteRecord") == nil)
}

@Test func userDefaultsStoreReadsTheSingleRecordWrittenByTheOldApp() throws {
    let suiteName = "airpods-meet-mute-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let oldFormat = #"{"deviceUID":"airpods","mechanism":"volumeZero","previousVolume":0.5}"#
    defaults.set(Data(oldFormat.utf8), forKey: "systemMuteRecord")
    let store = UserDefaultsMuteRecordStore(defaults: defaults)
    #expect(try store.load() == [MuteRecord(deviceUID: "airpods", mechanism: .volumeZero, previousVolume: 0.5)])

    let airpods = FakeInputDevice(supportsMute: false)
    airpods.level = 0
    #expect(try SystemMicMuter(devices: FakeInputDevices(airpods), store: store).restoreIfWeMuted())
    #expect(airpods.level == 0.5)
    #expect(try store.load().isEmpty)
}

@Test func userDefaultsStoreReportsUnreadableData() throws {
    let suiteName = "airpods-meet-mute-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data("not json".utf8), forKey: "systemMuteRecord")
    let store = UserDefaultsMuteRecordStore(defaults: defaults)
    #expect(throws: MuteRecordStoreError.unreadable) { try store.load() }
}
