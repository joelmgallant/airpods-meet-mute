import MeetMuteCore

/// Undoes our system mute (at launch, after a call, on quit) and keeps the one-shot notices about
/// it. An unmute while an app may still be on a call is never silent: it plays the unmute cue and
/// leaves a notice. A plain call end stays quiet.
final class SystemMuteRestore {
    private let muter: SystemMicMuter
    private let pressSound: PressFeedbackSound
    /// Both are kept until the user opens the menu (rendered there at least once), so a later
    /// poll cannot erase them unseen. The first failure wins; retries only repeat it.
    private var failure: String?
    private var notice: String?

    init(muter: SystemMicMuter, pressSound: PressFeedbackSound) {
        self.muter = muter
        self.pressSound = pressSound
    }

    var problems: [String] { [notice, failure].compactMap { $0 } }

    /// `route`/`recorderNames` say who may still hold the mic (nil names = listing failed).
    /// Returns a sound error when the cue could not play.
    @discardableResult
    func restore(when moment: String, route: MuteRoute = .idle, recorderNames: [String]? = []) -> String? {
        do {
            guard try muter.restoreIfWeMuted(),
                  let message = autoUnmuteNotice(route: route, recorderNames: recorderNames) else { return nil }
            notice = message
            return pressSound.play(for: .unmuted)
        } catch {
            failure = failure ?? restoreFailureMessage(error, moment: moment)
            return nil
        }
    }

    func markSeen() {
        failure = nil
        notice = nil
    }
}
