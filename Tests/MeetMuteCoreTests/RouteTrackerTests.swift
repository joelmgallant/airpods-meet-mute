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

private let teams = RecordingProcess(pid: 20, bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")

@Test func anEmptyListingAfterSystemKeepsSystemForTwoPollsThenIdle() {
    var tracker = RouteTracker()
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([slack])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([])) == .idle)
}

@Test func failedAndEmptyListingsShareOneBudget() {
    var tracker = RouteTracker()
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([slack])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: failedListing) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: failedListing) == .idle)

    var emptyFirst = RouteTracker()
    #expect(emptyFirst.nextRoute(meetStatus: .idle, recorders: recorders([slack])) == systemForSlack)
    #expect(emptyFirst.nextRoute(meetStatus: .idle, recorders: recorders([])) == systemForSlack)
    #expect(emptyFirst.nextRoute(meetStatus: .idle, recorders: failedListing) == systemForSlack)
    #expect(emptyFirst.nextRoute(meetStatus: .idle, recorders: recorders([])) == .idle)
}

@Test func aRecorderReappearingResetsTheEmptyListingBudget() {
    var tracker = RouteTracker()
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([slack])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([slack])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([])) == systemForSlack)
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([])) == .idle)
}

@Test func anEmptyListingWhenPreviouslyIdleStaysIdle() {
    var tracker = RouteTracker()
    #expect(tracker.nextRoute(meetStatus: .idle, recorders: recorders([])) == .idle)
}

@Test func meetAndNativeHandlersWinOverAHeldSystemRouteImmediately() {
    var meetTracker = RouteTracker()
    #expect(meetTracker.nextRoute(meetStatus: .idle, recorders: recorders([slack])) == systemForSlack)
    #expect(meetTracker.nextRoute(meetStatus: .inCall(.unmuted), recorders: recorders([])) == .meet)

    var nativeTracker = RouteTracker()
    #expect(nativeTracker.nextRoute(meetStatus: .idle, recorders: recorders([slack])) == systemForSlack)
    #expect(nativeTracker.nextRoute(meetStatus: .idle, recorders: recorders([])) == systemForSlack)
    #expect(nativeTracker.nextRoute(meetStatus: .idle, recorders: recorders([teams]))
            == .standAside(nativeAppNames: ["Microsoft Teams"]))
}

@Test func theTrackerRemembersTheRecordersBehindAHeldSystemRoute() {
    var tracker = RouteTracker()
    _ = tracker.nextRoute(meetStatus: .idle, recorders: recorders([slack]))
    #expect(tracker.systemRecorders == [slack])
    _ = tracker.nextRoute(meetStatus: .idle, recorders: recorders([]))
    #expect(tracker.systemRecorders == [slack])
    _ = tracker.nextRoute(meetStatus: .idle, recorders: failedListing)
    #expect(tracker.systemRecorders == [slack])
    _ = tracker.nextRoute(meetStatus: .idle, recorders: recorders([]))
    #expect(tracker.systemRecorders == [])
}
