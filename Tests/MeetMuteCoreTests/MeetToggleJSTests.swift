import Testing
@testable import MeetMuteCore

@Test func invocationAppliesTheFunctionToTheMode() {
    let call = MeetToggleJS.invocation(.mute)
    #expect(call.hasPrefix("(function (mode) {"))
    #expect(call.hasSuffix(#"})("mute")"#))
    #expect(MeetToggleJS.invocation(.query).hasSuffix(#"})("query")"#))
}

@Test func parseRecognisesEveryResult() {
    #expect(MeetToggleJS.parse("muted") == .state(.muted))
    #expect(MeetToggleJS.parse("unmuted\n") == .state(.unmuted))
    #expect(MeetToggleJS.parse("no-button") == .noButton)
    #expect(MeetToggleJS.parse("") == .unexpected(""))
    #expect(MeetToggleJS.parse("missing value") == .unexpected("missing value"))
}
