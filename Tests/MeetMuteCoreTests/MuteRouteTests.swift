import Testing
@testable import MeetMuteCore

private func recorder(_ bundleID: String, _ name: String, pid: Int32 = 100) -> RecordingProcess {
    RecordingProcess(pid: pid, bundleID: bundleID, displayName: name)
}

@Test func aMeetCallWinsOverEveryRecorder() {
    let recording = [recorder("com.microsoft.teams2", "Microsoft Teams"), recorder("com.tinyspeck.slackmacgap", "Slack")]
    #expect(decideRoute(meetCallPresent: true, recording: recording) == .meet)
}

@Test func idleWhenNothingIsRecording() {
    #expect(decideRoute(meetCallPresent: false, recording: []) == .idle)
}

@Test func aNonNativeRecorderGetsTheSystemPath() {
    #expect(decideRoute(meetCallPresent: false, recording: [recorder("com.tinyspeck.slackmacgap", "Slack")])
        == .system(appNames: ["Slack"]))
}

@Test func aBrowserHelperCountsAsItsBrowser() {
    #expect(decideRoute(meetCallPresent: false, recording: [recorder("com.vivaldi.Vivaldi.helper", "Vivaldi")])
        == .system(appNames: ["Vivaldi"]))
}

@Test func standAsideForAnAppWithNativeAirPodsMute() {
    #expect(decideRoute(meetCallPresent: false, recording: [recorder("com.microsoft.teams2", "Microsoft Teams")])
        == .standAside(nativeAppNames: ["Microsoft Teams"]))
}

@Test func aNativeHandlerWinsOverOtherRecorders() {
    let recording = [recorder("com.tinyspeck.slackmacgap", "Slack"), recorder("com.microsoft.teams2", "Microsoft Teams")]
    #expect(decideRoute(meetCallPresent: false, recording: recording) == .standAside(nativeAppNames: ["Microsoft Teams"]))
}

@Test func nativeMatchingCoversHelperProcesses() {
    #expect(decideRoute(meetCallPresent: false, recording: [recorder("com.microsoft.teams2.helper", "Microsoft Teams")])
        == .standAside(nativeAppNames: ["Microsoft Teams"]))
}

@Test func nativeMatchingIsByBundleComponentNotSubstring() {
    #expect(decideRoute(meetCallPresent: false, recording: [recorder("com.apple.FaceTimeX", "Impostor")])
        == .system(appNames: ["Impostor"]))
}

@Test func ignoredBackgroundRecordersAreNotCalls() {
    let recording = [recorder("com.apple.corespeechd", "corespeechd")]
    #expect(decideRoute(meetCallPresent: false, recording: recording, ignoredBundleIDs: ["com.apple.corespeechd"]) == .idle)
}

@Test func appNamesAreDeduplicatedInOrder() {
    let recording = [
        recorder("com.vivaldi.Vivaldi.helper", "Vivaldi", pid: 1),
        recorder("com.vivaldi.Vivaldi.helper", "Vivaldi", pid: 2),
        recorder("com.tinyspeck.slackmacgap", "Slack", pid: 3),
    ]
    #expect(decideRoute(meetCallPresent: false, recording: recording) == .system(appNames: ["Vivaldi", "Slack"]))
}

@Test func processesWithoutABundleIDStillCount() {
    #expect(decideRoute(meetCallPresent: false, recording: [recorder("", "process 42")]) == .system(appNames: ["process 42"]))
}

@Test func owningAppBundleIDStripsHelperSuffixes() {
    #expect(owningAppBundleID("com.vivaldi.Vivaldi.helper") == "com.vivaldi.Vivaldi")
    #expect(owningAppBundleID("com.google.Chrome.helper.Renderer") == "com.google.Chrome")
    #expect(owningAppBundleID("com.example.App.Helper") == "com.example.App")
    #expect(owningAppBundleID("com.tinyspeck.slackmacgap") == "com.tinyspeck.slackmacgap")
    #expect(owningAppBundleID("com.helperapp.Tool") == "com.helperapp.Tool")
    #expect(owningAppBundleID("") == "")
}

@Test func onlyTheMeetAndSystemRoutesHoldTheMic() {
    #expect(MuteRoute.meet.holdsMic)
    #expect(MuteRoute.system(appNames: ["Slack"]).holdsMic)
    #expect(!MuteRoute.standAside(nativeAppNames: ["Microsoft Teams"]).holdsMic)
    #expect(!MuteRoute.idle.holdsMic)
}

@Test func isSystemIgnoresTheAppNames() {
    #expect(MuteRoute.system(appNames: []).isSystem)
    #expect(MuteRoute.system(appNames: ["Slack"]).isSystem)
    #expect(!MuteRoute.meet.isSystem)
    #expect(!MuteRoute.idle.isSystem)
}

@Test func targetDevicesAreTheDeduplicatedUnionOfRecorderInputsInOrder() {
    let slackOnUSB = RecordingProcess(pid: 1, bundleID: "com.tinyspeck.slackmacgap.helper", displayName: "Slack",
                                      inputDeviceUIDs: ["usb", "airpods"])
    let zoomOnAirPods = RecordingProcess(pid: 2, bundleID: "us.zoom.xos", displayName: "Zoom",
                                         inputDeviceUIDs: ["airpods", "studio"])
    #expect(targetInputDeviceUIDs(for: [slackOnUSB, zoomOnAirPods], defaultInputUID: "builtin")
            == ["usb", "airpods", "studio"])
}

@Test func aRecorderWithUnknownDevicesAddsTheDefaultInputToTheUnion() {
    let slackOnUSB = RecordingProcess(pid: 1, bundleID: "com.tinyspeck.slackmacgap.helper", displayName: "Slack",
                                      inputDeviceUIDs: ["usb", "airpods"])
    let unknownDevices = RecordingProcess(pid: 3, bundleID: "com.example.app", displayName: "Example")
    #expect(targetInputDeviceUIDs(for: [unknownDevices, slackOnUSB], defaultInputUID: "builtin")
            == ["usb", "airpods", "builtin"])
    #expect(targetInputDeviceUIDs(for: [slackOnUSB, unknownDevices], defaultInputUID: "airpods")
            == ["usb", "airpods"])
}

@Test func targetDevicesFallBackToTheDefaultInputWhenNoRecorderReportsOne() {
    let unknownDevices = RecordingProcess(pid: 3, bundleID: "com.example.app", displayName: "Example")
    #expect(targetInputDeviceUIDs(for: [unknownDevices], defaultInputUID: "builtin") == ["builtin"])
    #expect(targetInputDeviceUIDs(for: [], defaultInputUID: "builtin") == ["builtin"])
}
