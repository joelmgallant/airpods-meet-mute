import AppKit
import CoreAudio
import Security

public protocol RecordingProcessSource {
    func recordingProcesses() throws -> [RecordingProcess]
}

/// Processes currently capturing microphone input, from CoreAudio's per-process objects (macOS 14.2+).
public struct CoreAudioRecordingProcessSource: RecordingProcessSource {
    private let excludedPID: Int32

    public init(excludingPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        excludedPID = excludingPID
    }

    public func recordingProcesses() throws -> [RecordingProcess] {
        guard #available(macOS 14.2, *) else {
            throw CoreAudioError(operation: "list recording apps (needs macOS 14.2)", status: kAudioHardwareUnsupportedOperationError)
        }
        let processObjects = try readObjectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            propertyAddress(kAudioHardwarePropertyProcessObjectList),
            operation: "list audio processes"
        )
        return try processObjects.compactMap { processObject in try recordingProcess(processObject) }
    }

    /// nil when the process is not recording, is us, or vanished between the list and the reads
    /// (the only skippable failure). Any other read error throws, so it reaches the caller's
    /// tolerance and warning instead of silently dropping a recorder such as Slack.
    @available(macOS 14.2, *)
    private func recordingProcess(_ processObject: AudioObjectID) throws -> RecordingProcess? {
        let recording: UInt32
        let pid: pid_t
        do {
            recording = try readValue(processObject, propertyAddress(kAudioProcessPropertyIsRunningInput),
                                      initial: UInt32(0), operation: "read process input state")
            guard recording != 0 else { return nil }
            pid = try readValue(processObject, propertyAddress(kAudioProcessPropertyPID),
                                initial: pid_t(0), operation: "read process PID")
        } catch let error as CoreAudioError where error.status == kAudioHardwareBadObjectError {
            return nil
        }
        guard pid != excludedPID else { return nil }
        let coreAudioBundleID = (try? readString(processObject, propertyAddress(kAudioProcessPropertyBundleID),
                                                 operation: "read process bundle ID")) ?? ""
        let bundleID = recorderIdentifier(coreAudioBundleID: coreAudioBundleID, pid: pid)
        if coreAudioBundleID.isEmpty {
            // Unverified which ID CoreAudio gives bundle-less daemons (corespeechd); log what we used.
            NSLog("AirPodsMeetMute: recorder pid \(pid) has no CoreAudio bundle ID; using \"\(bundleID)\"")
        }
        return RecordingProcess(pid: pid, bundleID: bundleID, displayName: displayName(pid: pid, bundleID: bundleID),
                                inputDeviceUIDs: inputDeviceUIDs(processObject))
    }

    /// The input devices the process captures from (`kAudioProcessPropertyDevices`, input scope),
    /// keeping only devices with input streams. Any read failure yields [] (or drops that device):
    /// the caller then falls back to the default input, which is what this app muted before.
    @available(macOS 14.2, *)
    private func inputDeviceUIDs(_ processObject: AudioObjectID) -> [String] {
        let deviceObjects = (try? readObjectIDs(
            processObject,
            propertyAddress(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput),
            operation: "list process input devices"
        )) ?? []
        return deviceObjects.compactMap { deviceObject in
            guard hasInputStreams(deviceObject) else { return nil }
            return try? readString(deviceObject, propertyAddress(kAudioDevicePropertyDeviceUID), operation: "read device UID")
        }
    }
}

func hasInputStreams(_ deviceObject: AudioObjectID) -> Bool {
    let streams = try? readObjectIDs(
        deviceObject,
        propertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput),
        operation: "list device input streams"
    )
    return !(streams ?? []).isEmpty
}

/// "Vivaldi", not "Vivaldi Helper": name the owning app when the recorder is a helper process.
func displayName(pid: Int32, bundleID: String) -> String {
    let owner = owningAppBundleID(bundleID)
    if !owner.isEmpty,
       let name = NSRunningApplication.runningApplications(withBundleIdentifier: owner).first?.localizedName {
        return name
    }
    if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
    return bundleID.isEmpty ? "process \(pid)" : bundleID
}

/// CoreAudio's bundle ID, or — for bundle-less processes such as system daemons — the code-signing
/// identifier, so they can still be matched against the ignore and native lists.
func recorderIdentifier(coreAudioBundleID: String, pid: Int32) -> String {
    guard coreAudioBundleID.isEmpty else { return coreAudioBundleID }
    return signingIdentifier(pid: pid) ?? ""
}

/// The code-signing identifier of a running process (e.g. "com.apple.corespeechd"), or nil.
func signingIdentifier(pid: Int32) -> String? {
    guard pid > 0 else { return nil }
    var guestCode: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
          let guestCode else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(guestCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
          let signing = information as? [String: Any] else { return nil }
    return signing[kSecCodeInfoIdentifier as String] as? String
}
