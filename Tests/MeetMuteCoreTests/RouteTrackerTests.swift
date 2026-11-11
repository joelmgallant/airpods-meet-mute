import XCTest
@testable import MeetMuteCore

final class RouteTrackerTests: XCTestCase {
    private struct ListingFailure: Error {}

    private let slack = RecordingProcess(pid: 10, bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")

    private func recorders(_ processes: [RecordingProcess]) -> Result<[RecordingProcess], Error> { .success(processes) }
    private var failedListing: Result<[RecordingProcess], Error> { .failure(ListingFailure()) }

    func testMeetCallSurvivesTwoErrorPollsAndThirdLeaves() {
        var tracker = RouteTracker()
        XCTAssertEqual(tracker.nextRoute(meetStatus: .inCall(.unmuted), recorders: recorders([])), .meet)
        XCTAssertEqual(tracker.nextRoute(meetStatus: .error("x"), recorders: recorders([])), .meet)
        XCTAssertEqual(tracker.nextRoute(meetStatus: .error("x"), recorders: recorders([])), .meet)
        XCTAssertEqual(tracker.nextRoute(meetStatus: .error("x"), recorders: recorders([])), .idle)
    }

    func testMeetErrorWithoutPriorCallIsNotACall() {
        var tracker = RouteTracker()
        XCTAssertEqual(tracker.nextRoute(meetStatus: .error("x"), recorders: recorders([])), .idle)
    }

    func testRecorderFailureAfterSystemKeepsSystemForTwoPollsThenIdle() {
        var tracker = RouteTracker()
        let system = MuteRoute.system(appNames: ["Slack"])
        XCTAssertEqual(tracker.nextRoute(meetStatus: .idle, recorders: recorders([slack])), system)
        XCTAssertEqual(tracker.nextRoute(meetStatus: .idle, recorders: failedListing), system)
        XCTAssertEqual(tracker.nextRoute(meetStatus: .idle, recorders: failedListing), system)
        XCTAssertEqual(tracker.nextRoute(meetStatus: .idle, recorders: failedListing), .idle)
    }

    func testSuccessfulReadResetsRecorderFailureCounter() {
        var tracker = RouteTracker()
        let system = MuteRoute.system(appNames: ["Slack"])
        _ = tracker.nextRoute(meetStatus: .idle, recorders: recorders([slack]))
        _ = tracker.nextRoute(meetStatus: .idle, recorders: failedListing)
        _ = tracker.nextRoute(meetStatus: .idle, recorders: failedListing)
        XCTAssertEqual(tracker.nextRoute(meetStatus: .idle, recorders: recorders([slack])), system)
        XCTAssertEqual(tracker.nextRoute(meetStatus: .idle, recorders: failedListing), system)
        XCTAssertEqual(tracker.nextRoute(meetStatus: .idle, recorders: failedListing), system)
        XCTAssertEqual(tracker.nextRoute(meetStatus: .idle, recorders: failedListing), .idle)
    }

    func testRecorderFailureWhenPreviouslyIdleStaysIdleImmediately() {
        var tracker = RouteTracker()
        XCTAssertEqual(tracker.nextRoute(meetStatus: .idle, recorders: failedListing), .idle)
    }

    func testMeetWinsOverHeldSystemRoute() {
        var tracker = RouteTracker()
        _ = tracker.nextRoute(meetStatus: .idle, recorders: recorders([slack]))
        XCTAssertEqual(tracker.nextRoute(meetStatus: .inCall(.muted), recorders: failedListing), .meet)
    }
}
