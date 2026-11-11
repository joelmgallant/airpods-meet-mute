import Foundation

/// The mute state, with ⚠️ appended (never replacing it) when something needs attention.
public func menuTitle(route: MuteRoute, meetStatus: MeetStatus, systemMuted: Bool?, hasProblem: Bool) -> String {
    let warning: String
    if case .error = meetStatus { warning = "⚠️" } else { warning = hasProblem ? "⚠️" : "" }
    return "🎧" + micStateSymbol(route: route, meetStatus: meetStatus, systemMuted: systemMuted) + warning
}

private func micStateSymbol(route: MuteRoute, meetStatus: MeetStatus, systemMuted: Bool?) -> String {
    let muted: Bool?
    switch route {
    case .meet:
        guard case .inCall(let mic) = meetStatus else { return "" }
        muted = mic == .muted
    case .system:
        muted = systemMuted
    case .standAside, .idle:
        muted = nil
    }
    guard let muted else { return "" }
    return muted ? "🔇" : "🎙️"
}

/// Said (with an unmute cue) when we undo our system mute while an app may still be on a call;
/// nil for a plain call end, which is expected and stays silent. `recorderNames` nil = unknown.
public func autoUnmuteNotice(route: MuteRoute, recorderNames: [String]?) -> String? {
    let reason: String
    switch route {
    case .meet:
        reason = "Meet call started"
    case .standAside(let nativeAppNames):
        reason = "\(nativeAppNames.joined(separator: ", ")) took over"
    case .system:
        return nil
    case .idle:
        guard let recorderNames else { reason = "could not check whether a call is still using the mic"; break }
        guard !recorderNames.isEmpty else { return nil }
        reason = "\(recorderNames.joined(separator: ", ")) \(recorderNames.count == 1 ? "is" : "are") still using the mic"
    }
    return "Unmuted the system mic — \(reason)"
}

/// An unreadable record is not a failed unmute: the fail-safe already unmuted the default input.
public func restoreFailureMessage(_ error: Error, moment: String) -> String {
    if case SystemMuteError.recordWasUnreadable = error {
        return "The saved system-mute record was unreadable (\(moment)) — unmuted the default mic to be safe"
    }
    return "Could not unmute the system mic \(moment): \(error)"
}

public func menuStatusLine(route: MuteRoute, meetStatus: MeetStatus, systemMuted: Bool?) -> String {
    switch route {
    case .meet:
        switch meetStatus {
        case .inCall(.muted): return "In Meet call — muted"
        case .inCall(.unmuted): return "In Meet call — unmuted"
        case .error(let message): return message
        case .idle: return "In Meet call"
        }
    case .system(let appNames):
        let apps = appNames.joined(separator: ", ")
        switch systemMuted {
        case true?: return "System mic muted — \(apps)"
        case false?: return "System mic live — \(apps)"
        case nil: return "System mic — \(apps) (state unknown)"
        }
    case .standAside(let nativeAppNames):
        return "Standing aside — \(nativeAppNames.joined(separator: ", ")) handles AirPods mute"
    case .idle:
        if case .error(let message) = meetStatus { return message }
        return "No call"
    }
}
