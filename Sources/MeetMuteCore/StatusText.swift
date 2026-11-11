import Foundation

public func menuTitle(route: MuteRoute, meetStatus: MeetStatus, systemMuted: Bool?, hasProblem: Bool) -> String {
    if hasProblem { return "🎧⚠️" }
    if case .error = meetStatus { return "🎧⚠️" }
    switch route {
    case .meet:
        guard case .inCall(let mic) = meetStatus else { return "🎧" }
        return mic == .muted ? "🎧🔇" : "🎧🎙️"
    case .system:
        guard let systemMuted else { return "🎧" }
        return systemMuted ? "🎧🔇" : "🎧🎙️"
    case .standAside, .idle:
        return "🎧"
    }
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
