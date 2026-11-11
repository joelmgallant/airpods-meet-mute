import Testing
@testable import MeetMuteCore

@Test func titleShowsAProblemFirst() {
    #expect(menuTitle(route: .system(appNames: ["Slack"]), meetStatus: .idle, systemMuted: true, hasProblem: true) == "🎧⚠️")
}

@Test func titleWarnsOnAMeetScriptError() {
    #expect(menuTitle(route: .idle, meetStatus: .error("boom"), systemMuted: nil, hasProblem: false) == "🎧⚠️")
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
