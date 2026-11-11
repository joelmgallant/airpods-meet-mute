import Testing
@testable import MeetMuteCore

private struct ListingFailure: Error {}

private let slack = RecordingProcess(pid: 10, bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")
private let systemForSlack = MuteRoute.system(appNames: ["Slack"])

private func recorders(_ processes: [RecordingProcess]) -> Result<[RecordingProcess], Error> { .success(processes) }
private let failedListing: Result<[RecordingProcess], Error> = .failure(ListingFailure())

@Test func aMeetCallSurvivesTwoErrorPollsAndTheThirdLeaves() {
    var tracker = RouteTracker()
    #expect(tracker.nextRoute(meetStatus: .inCall(.unmuted), recorders: recorders([])) == .meet)
    #expect(tracker.nextRoute(meetStatus: .error("x"), recorders: recorders([])) == .meet)
    #expect(tracker.nextRoute(meetStatus: .error("x"), recorders: recorders([])) == .meet)
    #expect(tracker.nextRoute(meetStatus: .error("x"), recorders: recorders([])) == .idle)
}

@Test func aMeetErrorWithoutAPriorCallIsNotACall() {
    var tracker = RouteTracker()
    #expect(tracker.nextRoute(meetStatus: .error("x"), recorders: recorders([])) == .idle)
}

@Test func aRecorderFailureAfterSystemKeepsSystemForTwoPollsThenIdle() {
    var tracker = RouteTracker()
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([slack])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: failedListing) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: failedListing) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: failedListing) == .idle)
}

@Test func aSuccessfulReadResetsTheRecorderFailureCounter() {
    var tracker = RouteTracker()
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([slack])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: failedListing) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: failedListing) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([slack])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: failedListing) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: failedListing) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: failedListing) == .idle)
}

@Test func aRecorderFailureWhenPreviouslyIdleStaysIdle() {
    var tracker = RouteTracker()
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: failedListing) == .idle)
}

@Test func meetWinsOverAHeldSystemRoute() {
    var tracker = RouteTracker()
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([slack])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .inCall(.muted), recorders: failedListing) == .meet)
}
