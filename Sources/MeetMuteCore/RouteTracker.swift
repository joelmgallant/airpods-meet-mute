import Foundation

/// Turns each poll's raw readings into a route, riding out transient read failures so a glitch
/// neither drops a held call nor (worse) unmutes the user mid-call.
public struct RouteTracker: Sendable {
    private let meetErrorTolerance: Int
    private let recorderErrorTolerance: Int
    private var previousRoute: MuteRoute = .idle
    private var wasInMeetCall = false
    private var consecutiveMeetErrorPolls = 0
    private var consecutiveRecorderErrorPolls = 0

    public init(meetErrorTolerance: Int = 2, recorderErrorTolerance: Int = 2) {
        self.meetErrorTolerance = meetErrorTolerance
        self.recorderErrorTolerance = recorderErrorTolerance
    }

    public mutating func nextRoute(meetStatus: MeetStatus, recorders: Result<[RecordingProcess], Error>) -> MuteRoute {
        let route = decide(meetCallPresent: meetCallPresent(meetStatus), recorders: recorders)
        previousRoute = route
        return route
    }

    private mutating func decide(meetCallPresent: Bool, recorders: Result<[RecordingProcess], Error>) -> MuteRoute {
        if meetCallPresent { return .meet }
        switch recorders {
        case .success(let processes):
            consecutiveRecorderErrorPolls = 0
            return decideRoute(meetCallPresent: false, recording: processes)
        case .failure:
            // Unknown is not "nothing recording": letting go would unmute a user who is still on a call.
            if previousRoute.isSystem, consecutiveRecorderErrorPolls < recorderErrorTolerance {
                consecutiveRecorderErrorPolls += 1
                return previousRoute
            }
            return decideRoute(meetCallPresent: false, recording: [])
        }
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
