import Foundation

/// An input device's software controls (CoreAudio adapter in production, fake in tests).
public protocol InputMuteDevice: AnyObject {
    var uid: String { get }
    var name: String { get }
    var supportsMute: Bool { get }
    var supportsVolume: Bool { get }
    func isMuted() throws -> Bool
    func setMuted(_ muted: Bool) throws
    func volume() throws -> Float
    func setVolume(_ volume: Float) throws
}

public protocol InputDeviceProvider {
    func defaultInputUID() throws -> String
    /// nil when no connected device has this UID.
    func inputDevice(uid: String) throws -> InputMuteDevice?
}

public struct DeviceMuteFailure: Equatable, Sendable {
    public let deviceName: String
    public let reason: String

    public init(deviceName: String, reason: String) {
        self.deviceName = deviceName
        self.reason = reason
    }
}

public enum SystemMuteError: Error, Equatable, CustomStringConvertible {
    case noMuteControls
    case notConnected
    case recordWasUnreadable
    /// Every other device was still handled; these were not.
    case devicesFailed([DeviceMuteFailure])

    public var description: String {
        switch self {
        case .noMuteControls: "no software mute or input volume — choose another input device"
        case .notConnected: "not connected"
        case .recordWasUnreadable: "The saved mute record was unreadable — unmuted the mic to be safe"
        case .devicesFailed(let failures):
            failures.map { failure in "“\(failure.deviceName)”: \(failure.reason)" }.joined(separator: "; ")
        }
    }
}
