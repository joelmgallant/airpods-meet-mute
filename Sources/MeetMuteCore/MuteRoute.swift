import Foundation

/// A process other than ours that is currently capturing microphone input.
public struct RecordingProcess: Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String
    public let displayName: String
    /// UIDs of the input devices the process captures from; empty when unknown.
    public let inputDeviceUIDs: [String]

    public init(pid: Int32, bundleID: String, displayName: String, inputDeviceUIDs: [String] = []) {
        self.pid = pid
        self.bundleID = bundleID
        self.displayName = displayName
        self.inputDeviceUIDs = inputDeviceUIDs
    }
}

/// The input devices a system mute must silence: every device the recorders capture from, plus
/// the default input when any recorder's devices are unknown (it may be on the default; muting
/// one extra device is harmless and restored later, while leaving it live would be a hot mic).
public func targetInputDeviceUIDs(for recorders: [RecordingProcess], defaultInputUID: String) -> [String] {
    var seen = Set<String>()
    var targets = recorders
        .flatMap(\.inputDeviceUIDs)
        .filter { deviceUID in seen.insert(deviceUID).inserted }
    let anyUnknown = recorders.isEmpty || recorders.contains { recorder in recorder.inputDeviceUIDs.isEmpty }
    if anyUnknown, !seen.contains(defaultInputUID) { targets.append(defaultInputUID) }
    return targets
}

/// Apps that handle the AirPods mute gesture themselves; we never take the press from them.
public let nativeAirPodsMuteBundleIDs: Set<String> = [
    "com.microsoft.teams2",
    "com.microsoft.teams",
    "com.apple.FaceTime",
]

/// Processes that capture input in the background with no call. The spike's one-off check found
/// none, but Siri's speech service (corespeechd) records intermittently — 24 times on 2026-11-12 —
/// and once we held the AirPods mic for it, it kept recording, trapping the AirPods in headset
/// mode until the app quit. The audio server attributes it to `com.apple.CoreSpeech`; its code
/// signature says `com.apple.corespeechd`; both are listed because CoreAudio's choice is unverified.
public let ignoredRecorderBundleIDs: Set<String> = [
    "com.apple.CoreSpeech",
    "com.apple.corespeechd",
]

/// "com.vivaldi.Vivaldi.helper" and "com.google.Chrome.helper.Renderer" → the owning app's ID.
public func owningAppBundleID(_ bundleID: String) -> String {
    guard let helperRange = bundleID.range(of: #"\.helper(\..*)?$"#, options: [.regularExpression, .caseInsensitive]) else {
        return bundleID
    }
    return String(bundleID[..<helperRange.lowerBound])
}

private func isListed(_ bundleID: String, in list: Set<String>) -> Bool {
    let owner = owningAppBundleID(bundleID)
    return list.contains { listed in owner == listed || owner.hasPrefix(listed + ".") }
}

public enum MuteRoute: Equatable, Sendable {
    /// A Meet call tab: press Meet's own button.
    case meet
    /// Other apps are recording: mute the input device for everyone.
    case system(appNames: [String])
    /// An app with native AirPods mute is recording: let it have the press.
    case standAside(nativeAppNames: [String])
    case idle

    /// The press only reaches an app holding mic input, so hold it only where we handle presses.
    public var holdsMic: Bool {
        switch self {
        case .meet, .system: true
        case .standAside, .idle: false
        }
    }

    /// `route != .system` doesn't compile (associated values); use this instead.
    public var isSystem: Bool {
        if case .system = self { return true }
        return false
    }
}

/// Meet first (truthful in-page toggle); then stand aside for native handlers so we never steal
/// their presses; then any other recorder gets the device-level mute.
public func decideRoute(
    meetCallPresent: Bool,
    recording: [RecordingProcess],
    nativeBundleIDs: Set<String> = nativeAirPodsMuteBundleIDs,
    ignoredBundleIDs: Set<String> = ignoredRecorderBundleIDs
) -> MuteRoute {
    if meetCallPresent { return .meet }
    let calls = callRecorders(recording, ignoredBundleIDs: ignoredBundleIDs)
    let nativeHandlers = calls.filter { process in isListed(process.bundleID, in: nativeBundleIDs) }
    if !nativeHandlers.isEmpty { return .standAside(nativeAppNames: uniqueNames(nativeHandlers)) }
    if !calls.isEmpty { return .system(appNames: uniqueNames(calls)) }
    return .idle
}

/// Recorders that may be a call: everything except known background recorders.
public func callRecorders(
    _ recording: [RecordingProcess],
    ignoredBundleIDs: Set<String> = ignoredRecorderBundleIDs
) -> [RecordingProcess] {
    recording.filter { process in !isListed(process.bundleID, in: ignoredBundleIDs) }
}

private func uniqueNames(_ processes: [RecordingProcess]) -> [String] {
    var seen = Set<String>()
    return processes.map(\.displayName).filter { name in seen.insert(name).inserted }
}
