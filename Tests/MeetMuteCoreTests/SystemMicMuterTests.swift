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

    init(uid: String = "airpods", name: String = "AirPods", supportsMute: Bool = true, supportsVolume: Bool = true) {
        self.uid = uid
        self.name = name
        self.supportsMute = supportsMute
        self.supportsVolume = supportsVolume
    }

    func isMuted() throws -> Bool { muted }
    func setMuted(_ newValue: Bool) throws {
        if failNextSet { failNextSet = false; throw FakeDeviceError.setFailed }
        muted = newValue
    }
    func volume() throws -> Float { level }
    func setVolume(_ newValue: Float) throws {
        if failNextSet { failNextSet = false; throw FakeDeviceError.setFailed }
        level = newValue
    }
}

final class FakeInputDevices: InputDeviceProvider {
    var current: FakeInputDevice
    var all: [FakeInputDevice]

    init(_ devices: FakeInputDevice...) {
        current = devices[0]
        all = devices
    }

    func defaultInputDevice() throws -> InputMuteDevice { current }
    func inputDevice(uid: String) throws -> InputMuteDevice? { all.first { device in device.uid == uid } }
}

final class MemoryMuteRecordStore: MuteRecordStore {
    var record: MuteRecord?
    var failNextSave = false
    var unreadable = false
    /// Called with the new record just before it is stored, so a test can observe what else is true at save time.
    var onSave: ((MuteRecord?) -> Void)?

    func load() throws -> MuteRecord? {
        if unreadable { throw MuteRecordStoreError.unreadable }
        return record
    }

    func save(_ newRecord: MuteRecord?) throws {
        if failNextSave { failNextSave = false; throw FakeDeviceError.setFailed }
        onSave?(newRecord)
        record = newRecord
        unreadable = false
    }
}

@Test func muteUsesTheDeviceMuteAndRecordsIt() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    try SystemMicMuter(devices: FakeInputDevices(airpods), store: store).mute()
    #expect(airpods.muted)
    #expect(store.record == MuteRecord(deviceUID: "airpods", mechanism: .deviceMute, previousVolume: nil))
}

@Test func unmuteUndoesOurMuteAndClearsTheRecord() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute()
    try muter.unmute()
    #expect(!airpods.muted)
    #expect(store.record == nil)
}

@Test func aDeviceAlreadyMutedElsewhereIsNotClaimed() throws {
    let airpods = FakeInputDevice()
    airpods.muted = true
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute()
    #expect(store.record == nil)
    try muter.restoreIfWeMuted()
    #expect(airpods.muted)
}

@Test func anExplicitUnmuteClearsAForeignMute() throws {
    let airpods = FakeInputDevice()
    airpods.muted = true
    try SystemMicMuter(devices: FakeInputDevices(airpods), store: MemoryMuteRecordStore()).unmute()
    #expect(!airpods.muted)
}

@Test func theVolumeFallbackRemembersAndRestoresTheLevel() throws {
    let airpods = FakeInputDevice(supportsMute: false)
    airpods.level = 0.6
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute()
    #expect(airpods.level == 0)
    #expect(store.record == MuteRecord(deviceUID: "airpods", mechanism: .volumeZero, previousVolume: 0.6))
    try muter.unmute()
    #expect(airpods.level == 0.6)
    #expect(store.record == nil)
}

@Test func aDeviceWithNoControlsIsReported() {
    let fixed = FakeInputDevice(supportsMute: false, supportsVolume: false)
    let muter = SystemMicMuter(devices: FakeInputDevices(fixed), store: MemoryMuteRecordStore())
    #expect(throws: SystemMuteError.unsupported(deviceName: "AirPods")) { try muter.mute() }
}

@Test func restoreDoesNothingWithoutARecord() throws {
    let airpods = FakeInputDevice()
    airpods.muted = true
    try SystemMicMuter(devices: FakeInputDevices(airpods), store: MemoryMuteRecordStore()).restoreIfWeMuted()
    #expect(airpods.muted)
}

@Test func launchRecoveryUnmutesTheRecordedDevice() throws {
    let airpods = FakeInputDevice()
    airpods.muted = true
    let store = MemoryMuteRecordStore()
    store.record = MuteRecord(deviceUID: "airpods", mechanism: .deviceMute, previousVolume: nil)
    try SystemMicMuter(devices: FakeInputDevices(airpods), store: store).restoreIfWeMuted()
    #expect(!airpods.muted)
    #expect(store.record == nil)
}

@Test func aRecordForADisconnectedDeviceIsDropped() throws {
    let store = MemoryMuteRecordStore()
    store.record = MuteRecord(deviceUID: "gone", mechanism: .deviceMute, previousVolume: nil)
    try SystemMicMuter(devices: FakeInputDevices(FakeInputDevice()), store: store).restoreIfWeMuted()
    #expect(store.record == nil)
}

@Test func aDefaultDeviceChangeRestoresThePreviousDeviceFirst() throws {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    let devices = FakeInputDevices(airpods, usb)
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: devices, store: store)
    try muter.mute()
    devices.current = usb
    try muter.mute()
    #expect(!airpods.muted)
    #expect(usb.muted)
    #expect(store.record?.deviceUID == "usb")
}

@Test func muteReappliesWhenOurMuteWasUndoneElsewhere() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute()
    airpods.muted = false
    try muter.mute()
    #expect(airpods.muted)
    #expect(store.record != nil)
}

@Test func aFailedMuteLeavesNoRecord() {
    let airpods = FakeInputDevice()
    airpods.failNextSet = true
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    #expect(throws: FakeDeviceError.self) { try muter.mute() }
    #expect(store.record == nil)
}

@Test func defaultInputMutedReflectsMuteOrZeroVolume() throws {
    let airpods = FakeInputDevice()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: MemoryMuteRecordStore())
    #expect(try !muter.isDefaultInputMuted())
    airpods.muted = true
    #expect(try muter.isDefaultInputMuted())

    let volumeOnly = FakeInputDevice(supportsMute: false)
    volumeOnly.level = 0
    #expect(try SystemMicMuter(devices: FakeInputDevices(volumeOnly), store: MemoryMuteRecordStore()).isDefaultInputMuted())
}

@Test func userDefaultsStoreRoundTripsAndClears() throws {
    let suiteName = "airpods-meet-mute-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsMuteRecordStore(defaults: defaults)
    let record = MuteRecord(deviceUID: "airpods", mechanism: .volumeZero, previousVolume: 0.5)
    try store.save(record)
    #expect(try UserDefaultsMuteRecordStore(defaults: defaults).load() == record)
    try store.save(nil)
    #expect(try store.load() == nil)
}

@Test func muteWritesTheRecordBeforeTouchingTheDevice() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    var deviceWasMutedWhenRecordSaved: Bool?
    store.onSave = { savedRecord in
        if savedRecord != nil { deviceWasMutedWhenRecordSaved = airpods.muted }
    }
    try SystemMicMuter(devices: FakeInputDevices(airpods), store: store).mute()
    #expect(deviceWasMutedWhenRecordSaved == false)
    #expect(airpods.muted)
}

@Test func aFailedRecordWriteLeavesTheDeviceUntouched() {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    store.failNextSave = true
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    #expect(throws: FakeDeviceError.self) { try muter.mute() }
    #expect(!airpods.muted)
    #expect(store.record == nil)
}

@Test func aFailedVolumeMuteRollsBackTheRecord() {
    let volumeOnly = FakeInputDevice(supportsMute: false)
    volumeOnly.failNextSet = true
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(volumeOnly), store: store)
    #expect(throws: FakeDeviceError.self) { try muter.mute() }
    #expect(volumeOnly.level == 0.8)
    #expect(store.record == nil)
}

@Test func anUnreadableRecordFailsSafeByUnmuting() {
    let airpods = FakeInputDevice()
    airpods.muted = true
    let store = MemoryMuteRecordStore()
    store.unreadable = true
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    #expect(throws: SystemMuteError.recordWasUnreadable) { try muter.restoreIfWeMuted() }
    #expect(!airpods.muted)
    #expect(store.record == nil)
    #expect(!store.unreadable)
}

@Test func aFailedRestoreKeepsTheRecord() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute()
    airpods.failNextSet = true
    #expect(throws: FakeDeviceError.self) { try muter.restoreIfWeMuted() }
    #expect(store.record != nil)
}

@Test func userDefaultsStoreReportsUnreadableData() throws {
    let suiteName = "airpods-meet-mute-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data("not json".utf8), forKey: "systemMuteRecord")
    let store = UserDefaultsMuteRecordStore(defaults: defaults)
    #expect(throws: MuteRecordStoreError.unreadable) { try store.load() }
}
