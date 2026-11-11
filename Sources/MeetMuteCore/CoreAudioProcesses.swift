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
        return processObjects.compactMap { processObject in
            // A process can exit between the list and these reads; it is then simply not recording.
            guard let recording = try? readValue(processObject, propertyAddress(kAudioProcessPropertyIsRunningInput),
                                                 initial: UInt32(0), operation: "read process input state"),
                  recording != 0,
                  let pid = try? readValue(processObject, propertyAddress(kAudioProcessPropertyPID),
                                           initial: pid_t(0), operation: "read process PID"),
                  pid != excludedPID
            else { return nil }
            let bundleID = (try? readString(processObject, propertyAddress(kAudioProcessPropertyBundleID),
                                            operation: "read process bundle ID")) ?? ""
            return RecordingProcess(pid: pid, bundleID: bundleID, displayName: displayName(pid: pid, bundleID: bundleID))
        }
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
