import AppKit
import CoreAudio

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
        let bundleID = (try? readString(processObject, propertyAddress(kAudioProcessPropertyBundleID),
                                        operation: "read process bundle ID")) ?? ""
        return RecordingProcess(pid: pid, bundleID: bundleID, displayName: displayName(pid: pid, bundleID: bundleID))
    }
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
