import Testing
@testable import MeetMuteCore

@Test func titleKeepsTheMuteStateAndAppendsAProblem() {
    let route = MuteRoute.system(appNames: ["Slack"])
    #expect(menuTitle(route: route, meetStatus: .idle, systemMuted: true, hasProblem: true) == "🎧🔇⚠️")
    #expect(menuTitle(route: route, meetStatus: .idle, systemMuted: false, hasProblem: true) == "🎧🎙️⚠️")
    #expect(menuTitle(route: route, meetStatus: .idle, systemMuted: nil, hasProblem: true) == "🎧⚠️")
    #expect(menuTitle(route: .meet, meetStatus: .inCall(.muted), systemMuted: nil, hasProblem: true) == "🎧🔇⚠️")
}

@Test func titleWarnsOnAMeetScriptError() {
    #expect(menuTitle(route: .idle, meetStatus: .error("boom"), systemMuted: nil, hasProblem: false) == "🎧⚠️")
    #expect(menuTitle(route: .meet, meetStatus: .error("boom"), systemMuted: nil, hasProblem: false) == "🎧⚠️")
    #expect(menuTitle(route: .system(appNames: ["Slack"]), meetStatus: .error("boom"), systemMuted: true, hasProblem: false)
        == "🎧🔇⚠️")
}

@Test func titleFollowsMeetOnTheMeetRoute() {
    #expect(menuTitle(route: .meet, meetStatus: .inCall(.muted), systemMuted: nil, hasProblem: false) == "🎧🔇")
    #expect(menuTitle(route: .meet, meetStatus: .inCall(.unmuted), systemMuted: nil, hasProblem: false) == "🎧🎙️")
}

@Test func titleFollowsTheDeviceOnTheSystemRoute() {
    let route = MuteRoute.system(appNames: ["Slack"])
    #expect(menuTitle(route: route, meetStatus: .idle, systemMuted: true, hasProblem: false) == "🎧🔇")
    #expect(menuTitle(route: route, meetStatus: .idle, systemMuted: false, hasProblem: false) == "🎧🎙️")
    #expect(menuTitle(route: route, meetStatus: .idle, systemMuted: nil, hasProblem: false) == "🎧")
}

@Test func titleIsPlainWhenStandingAsideOrIdle() {
    #expect(menuTitle(route: .standAside(nativeAppNames: ["Microsoft Teams"]), meetStatus: .idle, systemMuted: nil, hasProblem: false) == "🎧")
    #expect(menuTitle(route: .idle, meetStatus: .idle, systemMuted: nil, hasProblem: false) == "🎧")
}

@Test func statusLineNamesTheRecordingApps() {
    let route = MuteRoute.system(appNames: ["Slack", "Vivaldi"])
    #expect(menuStatusLine(route: route, meetStatus: .idle, systemMuted: true) == "System mic muted — Slack, Vivaldi")
    #expect(menuStatusLine(route: route, meetStatus: .idle, systemMuted: false) == "System mic live — Slack, Vivaldi")
    #expect(menuStatusLine(route: route, meetStatus: .idle, systemMuted: nil) == "System mic — Slack, Vivaldi (state unknown)")
}

@Test func statusLineExplainsStandingAside() {
    #expect(menuStatusLine(route: .standAside(nativeAppNames: ["Microsoft Teams"]), meetStatus: .idle, systemMuted: nil)
        == "Standing aside — Microsoft Teams handles AirPods mute")
}

@Test func statusLineForMeetAndIdle() {
    #expect(menuStatusLine(route: .meet, meetStatus: .inCall(.muted), systemMuted: nil) == "In Meet call — muted")
    #expect(menuStatusLine(route: .meet, meetStatus: .inCall(.unmuted), systemMuted: nil) == "In Meet call — unmuted")
    #expect(menuStatusLine(route: .meet, meetStatus: .error("glitch"), systemMuted: nil) == "glitch")
    #expect(menuStatusLine(route: .idle, meetStatus: .idle, systemMuted: nil) == "No call")
    #expect(menuStatusLine(route: .idle, meetStatus: .error("boom"), systemMuted: nil) == "boom")
}

@Test func anAutoUnmuteIsAnnouncedWhileAnotherAppKeepsTheMic() {
    #expect(autoUnmuteNotice(route: .standAside(nativeAppNames: ["Microsoft Teams"]), recorderNames: ["Microsoft Teams"])
        == "Unmuted the system mic — Microsoft Teams took over")
    #expect(autoUnmuteNotice(route: .meet, recorderNames: []) == "Unmuted the system mic — Meet call started")
    #expect(autoUnmuteNotice(route: .idle, recorderNames: ["Recorder"])
        == "Unmuted the system mic — Recorder is still using the mic")
    #expect(autoUnmuteNotice(route: .idle, recorderNames: nil)
        == "Unmuted the system mic — could not check whether a call is still using the mic")
}

@Test func aPlainCallEndUnmutesSilently() {
    #expect(autoUnmuteNotice(route: .idle, recorderNames: []) == nil)
    #expect(autoUnmuteNotice(route: .system(appNames: ["Slack"]), recorderNames: ["Slack"]) == nil)
}

@Test func restoreFailuresNameTheMoment() {
    let failure = SystemMuteError.devicesFailed([DeviceMuteFailure(deviceName: "USB Mic", reason: "boom")])
    #expect(restoreFailureMessage(failure, moment: "after the call")
        == "Could not unmute the system mic after the call: “USB Mic”: boom")
}

@Test func anUnreadableRecordIsNotReportedAsAFailedUnmute() {
    #expect(restoreFailureMessage(SystemMuteError.recordWasUnreadable, moment: "after the last run")
        == "The saved system-mute record was unreadable (after the last run) — unmuted the default mic to be safe")
}
