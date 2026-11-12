import Foundation
import Testing
@testable import MeetMuteCore

@Test func listingRecordersWorksAndNeverIncludesUs() throws {
    let ourPID = ProcessInfo.processInfo.processIdentifier
    let recorders = try CoreAudioRecordingProcessSource(excludingPID: ourPID).recordingProcesses()
    #expect(!recorders.contains { process in process.pid == ourPID })
}

@Test func theDefaultInputDeviceHasAnIdentityAndCanBeFoundByUID() throws {
    let provider = CoreAudioInputDeviceProvider()
    let device = try provider.defaultInputDevice()
    #expect(!device.uid.isEmpty)
    #expect(!device.name.isEmpty)
    let found = try #require(try provider.inputDevice(uid: device.uid))
    #expect(found.uid == device.uid)
    #expect(try provider.inputDevice(uid: "no-such-device-\(UUID().uuidString)") == nil)
}

@Test func coreAudioErrorsReadAsFourCharacterCodes() {
    let error = CoreAudioError(operation: "set input mute", status: 0x21646576)  // '!dev'
    #expect(error.description == "CoreAudio set input mute failed ('!dev')")
}

@Test func everyReportedRecorderInputDeviceResolvesToAnInputDevice() throws {
    let provider = CoreAudioInputDeviceProvider()
    for recorder in try CoreAudioRecordingProcessSource().recordingProcesses() {
        for deviceUID in recorder.inputDeviceUIDs {
            #expect(try provider.inputDevice(uid: deviceUID) != nil, "\(recorder.displayName) → \(deviceUID)")
        }
    }
}

@Test func aProcessWithoutABundleIsIdentifiedByItsCodeSignature() {
    #expect(signingIdentifier(pid: 1) == "com.apple.xpc.launchd")
    #expect(signingIdentifier(pid: -1) == nil)
}

@Test func anEmptyCoreAudioBundleIDFallsBackToTheSigningIdentifier() {
    #expect(recorderIdentifier(coreAudioBundleID: "", pid: 1) == "com.apple.xpc.launchd")
    #expect(recorderIdentifier(coreAudioBundleID: "com.tinyspeck.slackmacgap.helper", pid: 1) == "com.tinyspeck.slackmacgap.helper")
}
