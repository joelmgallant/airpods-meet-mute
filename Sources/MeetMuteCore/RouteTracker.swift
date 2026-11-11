import Foundation

/// Turns each poll's raw readings into a route, riding out transient read failures so a glitch
/// neither drops a held call nor (worse) unmutes the user mid-call.
public struct RouteTracker: Sendable {
    private let meetErrorTolerance: Int
    private let recorderErrorTolerance: Int
    private var previousRoute: MuteRoute = .idle
    private var wasInMeetCall = false
    private var consecutiveMeetErrorPolls = 0
    /// Polls in a row that held `.system` without seeing a recorder (failed or empty listing).
    private var consecutiveUnconfirmedSystemPolls = 0
    /// The recorders behind the current `.system` route (kept while it is held); empty otherwise.
    /// Their input devices are the ones a press must mute.
    public private(set) var systemRecorders: [RecordingProcess] = []

    public init(meetErrorTolerance: Int = 2, recorderErrorTolerance: Int = 2) {
        self.meetErrorTolerance = meetErrorTolerance
        self.recorderErrorTolerance = recorderErrorTolerance
    }

    public mutating func nextRoute(meetStatus: MeetStatus, recorders: Result<[RecordingProcess], Error>) -> MuteRoute {
        let route = decide(meetCallPresent: meetCallPresent(meetStatus), recorders: recorders)
        if !route.isSystem { systemRecorders = [] }
        previousRoute = route
        return route
    }

    private mutating func decide(meetCallPresent: Bool, recorders: Result<[RecordingProcess], Error>) -> MuteRoute {
        if meetCallPresent { return .meet }
        guard case .success(let processes) = recorders else {
            // Unknown is not "nothing recording": letting go would unmute a user who is still on a call.
            return holdSystemRoute() ?? .idle
        }
        let route = decideRoute(meetCallPresent: false, recording: processes)
        if route == .idle {
            // A call app can drop out of one listing (audio restart, AirPods mode switch) while the
            // call goes on; unmuting then would be a hot mic. A native handler or Meet still wins at once.
            return holdSystemRoute() ?? .idle
        }
        consecutiveUnconfirmedSystemPolls = 0
        if route.isSystem { systemRecorders = callRecorders(processes) }
        return route
    }

    /// The previous `.system` route while the shared budget of unconfirmed polls lasts; nil otherwise.
    private mutating func holdSystemRoute() -> MuteRoute? {
        guard previousRoute.isSystem, consecutiveUnconfirmedSystemPolls < recorderErrorTolerance else {
            consecutiveUnconfirmedSystemPolls = 0
            return nil
        }
        consecutiveUnconfirmedSystemPolls += 1
        return previousRoute
    }

    private mutating func meetCallPresent(_ status: MeetStatus) -> Bool {
        switch status {
        case .inCall:
            consecutiveMeetErrorPolls = 0
            wasInMeetCall = true
            return true
        case .error where wasInMeetCall && consecutiveMeetErrorPolls < meetErrorTolerance:
            consecutiveMeetErrorPolls += 1
            return true
        case .error, .idle:
            consecutiveMeetErrorPolls = 0
            wasInMeetCall = false
            return false
        }
    }
}
