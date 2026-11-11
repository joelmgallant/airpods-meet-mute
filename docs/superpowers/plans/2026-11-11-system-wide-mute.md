# System-wide AirPods Mute Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An AirPods Pro stem press mutes and unmutes the mic in any call app (Slack, Teams in a browser, Zoom…), keeping the existing Meet in-page toggle and adding a device-level mic mute for everything else.

**Architecture:** Three pure, tested core units decide and act — `decideRoute` (Meet / system / stand aside / idle), `SystemMicMuter` (device mute with volume fallback and crash-safe bookkeeping) and `menuTitle`/`menuStatusLine` — over thin CoreAudio adapters (process list, input device). `AppDelegate` polls every 3 s, routes presses, holds the mic only when a route needs it, and applies the safety rules.

**Tech Stack:** Swift 6.2 toolchain (Swift 5 language mode), SwiftPM, swift-testing, CoreAudio (process objects, macOS 14.2+), AVFAudio, AppKit.

**Spec:** `docs/superpowers/specs/2026-11-11-system-wide-mute-design.md`

## Global Constraints

- Platform: package floor stays macOS 14.0; process-list code guards `#available(macOS 14.2, *)` and reports an error below it. Developed on macOS 15.8.1.
- Swift tools 6.0, `swiftLanguageModes: [.v5]`. No third-party dependencies. Build must be warning-free.
- Route order: Meet call present → `.meet`; else any recording app on the native list → `.standAside`; else any other recorder → `.system`; else `.idle`. (Refinement of the spec: a native handler wins even if another app also records, so we never steal its presses.)
- Native-handler list: `com.microsoft.teams2`, `com.microsoft.teams`, `com.apple.FaceTime`. Matching is on the owning app's bundle ID (helper suffix `.helper…` stripped), equal or `listed + "."` prefix — never substring.
- Our own process is never a "recorder".
- Mute mechanism: input-scope `kAudioDevicePropertyMute` on the default input device if settable; else input volume scalar → 0 with the previous level remembered and restored.
- Safety: auto-unmute when the route leaves `.system`; unmute on launch if a persisted record says we muted; unmute on quit; only undo a mute we applied (no record = not ours); a default-device change restores the previously muted device first.
- The press handler never calls `setInputMuted` (it re-enters the handler — README "macOS behaviours"); `isSyncingSystemMute` stays.
- Every failure surfaces as a ⚠️ menu row; none is silently swallowed.
- Commits end with a `Co-Authored-By:` trailer naming the model that wrote them. Never `--no-verify`, never amend. Branch: `system-wide-mute` (already checked out). Repo-local `user.email` is the GitHub noreply address — don't change it.
- Shell is zsh: never `pkill -f`; use `/usr/bin/log`.

## File Structure

```
scripts/system-mute-probe.swift                 Task 1: standalone CoreAudio probe (status/list/mute/unmute/level)
docs/system-mute-spike-findings.md              Task 1: results + go/no-go
Sources/MeetMuteCore/MuteRoute.swift            RecordingProcess, native/ignored lists, owningAppBundleID, MuteRoute, decideRoute
Sources/MeetMuteCore/SystemMicMuter.swift       InputMuteDevice/InputDeviceProvider/MuteRecordStore protocols, MuteRecord, UserDefaultsMuteRecordStore, SystemMicMuter
Sources/MeetMuteCore/StatusText.swift           menuTitle, menuStatusLine (pure)
Sources/MeetMuteCore/CoreAudioSupport.swift     CoreAudioError + property read/write helpers
Sources/MeetMuteCore/CoreAudioDevices.swift     CoreAudioInputDevice, CoreAudioInputDeviceProvider
Sources/MeetMuteCore/CoreAudioProcesses.swift   RecordingProcessSource, CoreAudioRecordingProcessSource
Sources/AirPodsMeetMute/StatusMenu.swift        NSMenu builder (split out of AppDelegate to keep it < 200 lines)
Sources/AirPodsMeetMute/AppDelegate.swift       rewritten: routing, press dispatch, safety hooks
Tests/MeetMuteCoreTests/MuteRouteTests.swift
Tests/MeetMuteCoreTests/SystemMicMuterTests.swift
Tests/MeetMuteCoreTests/StatusTextTests.swift
Tests/MeetMuteCoreTests/CoreAudioSmokeTests.swift   read-only; never mutates a device
```

---

### Task 1: Spike — AirPods mic mute, real silence, browser recorders (go / no-go)

**Requires Joel:** AirPods Pro connected as input, a Slack huddle, a Meet tab call.

**Files:**
- Create: `scripts/system-mute-probe.swift`
- Create: `docs/system-mute-spike-findings.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `swift scripts/system-mute-probe.swift status|list|mute|unmute|level`; findings file with `MUTE_MECHANISM: deviceMute|volumeZero`, `BACKGROUND_RECORDERS: <bundle IDs seen with no call>`, `BROWSER_RECORDER_BUNDLE_ID: <id>`.

- [ ] **Step 1: Write the probe**

`scripts/system-mute-probe.swift`:

```swift
// Standalone CoreAudio probe for the system-wide mute spike.
// Usage: swift scripts/system-mute-probe.swift status|list|mute|unmute|level
import AVFoundation
import AppKit
import CoreAudio

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var propertyAddress = address(selector)
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, &unmanaged) == noErr else { return "?" }
    return (unmanaged?.takeRetainedValue() as String?) ?? "?"
}

func readUInt32(_ object: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress) -> UInt32? {
    var propertyAddress = propertyAddress
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, &value) == noErr ? value : nil
}

func settable(_ object: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress) -> Bool {
    var propertyAddress = propertyAddress
    guard AudioObjectHasProperty(object, &propertyAddress) else { return false }
    var isSettable = DarwinBoolean(false)
    return AudioObjectIsPropertySettable(object, &propertyAddress, &isSettable) == noErr && isSettable.boolValue
}

func defaultInput() -> AudioObjectID {
    var propertyAddress = address(kAudioHardwarePropertyDefaultInputDevice)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(systemObject, &propertyAddress, 0, nil, &size, &device)
    return device
}

let muteAddress = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)

func status() {
    let device = defaultInput()
    print("default input: \(readString(device, kAudioObjectPropertyName)) uid=\(readString(device, kAudioDevicePropertyDeviceUID))")
    print("  input mute settable=\(settable(device, muteAddress)) value=\(readUInt32(device, muteAddress).map(String.init) ?? "n/a")")
    for element in [kAudioObjectPropertyElementMain] + (1...4).map({ AudioObjectPropertyElement($0) }) {
        var volumeAddress = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, element)
        guard settable(device, volumeAddress) else { continue }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume)
        print("  input volume element \(element) settable=true value=\(volume)")
    }
}

func list() {
    guard #available(macOS 14.2, *) else { print("needs macOS 14.2"); return }
    var listAddress = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(systemObject, &listAddress, 0, nil, &size)
    var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(systemObject, &listAddress, 0, nil, &size, &processes)
    var found = 0
    for process in processes where readUInt32(process, address(kAudioProcessPropertyIsRunningInput)) == 1 {
        let pid = Int32(bitPattern: readUInt32(process, address(kAudioProcessPropertyPID)) ?? 0)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        print("recording: pid=\(pid) bundle=\(readString(process, kAudioProcessPropertyBundleID)) name=\(name)")
        found += 1
    }
    print("\(found) recording process(es); probe pid=\(ProcessInfo.processInfo.processIdentifier)")
}

func setMute(_ muted: Bool) {
    let device = defaultInput()
    var propertyAddress = muteAddress
    var value: UInt32 = muted ? 1 : 0
    let result = AudioObjectSetPropertyData(device, &propertyAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    print("set input mute=\(muted) on \(readString(device, kAudioObjectPropertyName)): status=\(result) now=\(readUInt32(device, muteAddress).map(String.init) ?? "n/a")")
}

func level() {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    var peak: Float = 0
    var sumSquares: Double = 0
    var samples = 0
    input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in
        guard let channel = buffer.floatChannelData?[0] else { return }
        for index in 0..<Int(buffer.frameLength) {
            let sample = channel[index]
            peak = max(peak, abs(sample))
            sumSquares += Double(sample * sample)
        }
        samples += Int(buffer.frameLength)
    }
    do { try engine.start() } catch { print("engine start failed: \(error)"); return }
    print("recording 3 s from \(readString(defaultInput(), kAudioObjectPropertyName)) — talk now")
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    engine.stop()
    let rms = samples > 0 ? sqrt(sumSquares / Double(samples)) : 0
    print(String(format: "samples=%d peak=%.5f rms=%.6f (%.1f dBFS)", samples, peak, rms, 20 * log10(max(rms, 1e-9))))
}

switch CommandLine.arguments.dropFirst().first {
case "status": status()
case "list": list()
case "mute": setMute(true)
case "unmute": setMute(false)
case "level": level()
default: print("usage: swift scripts/system-mute-probe.swift status|list|mute|unmute|level")
}
```

- [ ] **Step 2: Baseline with no call (finds background recorders)**

Joel: AirPods connected and selected as input; no call running. Then:

Run: `swift scripts/system-mute-probe.swift status && swift scripts/system-mute-probe.swift list`
Expected: default input is the AirPods; mute/volume support printed; the `list` output names any process that records with no call (e.g. Siri's `corespeechd`) — these become `BACKGROUND_RECORDERS`.

- [ ] **Step 3: Device mute → real silence (Joel speaks during each `level`)**

```bash
swift scripts/system-mute-probe.swift level
swift scripts/system-mute-probe.swift mute
swift scripts/system-mute-probe.swift level
swift scripts/system-mute-probe.swift unmute
swift scripts/system-mute-probe.swift level
```

Expected: first and last `level` show speech (rms well above the floor, e.g. > -50 dBFS); the middle one is digital silence or near it (peak ≈ 0). If `mute` prints a non-zero status or `now=n/a`, the device has no settable mute → record `MUTE_MECHANISM: volumeZero` and re-test silence with the volume element printed by `status` (set via a one-off: edit `setMute` to write `kAudioDevicePropertyVolumeScalar` 0.0, then restore the printed value).

- [ ] **Step 4: Slack huddle hears silence**

Joel: start a Slack huddle (solo is fine). With the probe: `mute`, speak — Slack's own speaking indicator (your avatar ring) must stay dark; `unmute`, speak — it lights. While the huddle runs: `swift scripts/system-mute-probe.swift list` → Slack (or its helper) is listed; record its bundle ID. Always finish with `unmute`.

- [ ] **Step 5: Browser call shows up as its browser**

Joel: join a Meet call in Vivaldi. Run `list`. Record the browser's recording bundle ID (expected `com.vivaldi.Vivaldi.helper` — audiomxd logged the "Vivaldi Helper" session earlier). Leave the call.

- [ ] **Step 6: Write findings**

`docs/system-mute-spike-findings.md`:

```markdown
# System-wide mute spike findings

Date: <date> · macOS <version> · input: <AirPods name/model>

## AirPods input controls (headset mode)
- Input mute settable: yes/no · Volume scalar elements settable: <list>
- MUTE_MECHANISM: deviceMute / volumeZero

## Silence check (probe `level`)
- unmuted: rms <x> dBFS · muted: rms <y> dBFS, peak <z> · unmuted again: <x2>
- Slack huddle speaking indicator while muted: dark / lit

## Recorders
- BACKGROUND_RECORDERS (no call): <bundle IDs or "none">
- Slack huddle recorder bundle ID: <id>
- BROWSER_RECORDER_BUNDLE_ID (Vivaldi Meet): <id>

## Decision
- Continue / Stop
```

- [ ] **Step 7: Commit**

```bash
git add scripts/system-mute-probe.swift docs/system-mute-spike-findings.md
git commit -m "Add system-mute probe and spike findings

Co-Authored-By: <model> <noreply@anthropic.com>"
```

- [ ] **Step 8: GATE**

- Muted `level` still carries speech (and Slack's indicator lights) with both mechanisms → **STOP**, report to Joel.
- Otherwise continue. Task 2 uses `BACKGROUND_RECORDERS`; Task 5 has no mechanism-specific code (the muter picks at runtime).

---

### Task 2: Route decision

**Files:**
- Create: `Sources/MeetMuteCore/MuteRoute.swift`
- Test: `Tests/MeetMuteCoreTests/MuteRouteTests.swift`

**Interfaces:**
- Consumes: `docs/system-mute-spike-findings.md` `BACKGROUND_RECORDERS`.
- Produces:
  - `public struct RecordingProcess: Equatable` — `pid: Int32`, `bundleID: String`, `displayName: String`; `public init(pid:bundleID:displayName:)`.
  - `public let nativeAirPodsMuteBundleIDs: Set<String>`; `public let ignoredRecorderBundleIDs: Set<String>`.
  - `public func owningAppBundleID(_ bundleID: String) -> String`
  - `public enum MuteRoute: Equatable` — `.meet`, `.system(appNames: [String])`, `.standAside(nativeAppNames: [String])`, `.idle`; `var holdsMic: Bool`; `var isSystem: Bool`.
  - `public func decideRoute(meetCallPresent: Bool, recording: [RecordingProcess], nativeBundleIDs: Set<String> = nativeAirPodsMuteBundleIDs, ignoredBundleIDs: Set<String> = ignoredRecorderBundleIDs) -> MuteRoute`

- [ ] **Step 1: Write the failing tests**

`Tests/MeetMuteCoreTests/MuteRouteTests.swift`:

```swift
import Testing
@testable import MeetMuteCore

private func recorder(_ bundleID: String, _ name: String, pid: Int32 = 100) -> RecordingProcess {
    RecordingProcess(pid: pid, bundleID: bundleID, displayName: name)
}

@Test func aMeetCallWinsOverEveryRecorder() {
    let recording = [recorder("com.microsoft.teams2", "Microsoft Teams"), recorder("com.tinyspeck.slackmacgap", "Slack")]
    #expect(decideRoute(meetCallPresent: true, recording: recording) == .meet)
}

@Test func idleWhenNothingIsRecording() {
    #expect(decideRoute(meetCallPresent: false, recording: []) == .idle)
}

@Test func aNonNativeRecorderGetsTheSystemPath() {
    #expect(decideRoute(meetCallPresent: false, recording: [recorder("com.tinyspeck.slackmacgap", "Slack")])
        == .system(appNames: ["Slack"]))
}

@Test func aBrowserHelperCountsAsItsBrowser() {
    #expect(decideRoute(meetCallPresent: false, recording: [recorder("com.vivaldi.Vivaldi.helper", "Vivaldi")])
        == .system(appNames: ["Vivaldi"]))
}

@Test func standAsideForAnAppWithNativeAirPodsMute() {
    #expect(decideRoute(meetCallPresent: false, recording: [recorder("com.microsoft.teams2", "Microsoft Teams")])
        == .standAside(nativeAppNames: ["Microsoft Teams"]))
}

@Test func aNativeHandlerWinsOverOtherRecorders() {
    let recording = [recorder("com.tinyspeck.slackmacgap", "Slack"), recorder("com.microsoft.teams2", "Microsoft Teams")]
    #expect(decideRoute(meetCallPresent: false, recording: recording) == .standAside(nativeAppNames: ["Microsoft Teams"]))
}

@Test func nativeMatchingCoversHelperProcesses() {
    #expect(decideRoute(meetCallPresent: false, recording: [recorder("com.microsoft.teams2.helper", "Microsoft Teams")])
        == .standAside(nativeAppNames: ["Microsoft Teams"]))
}

@Test func nativeMatchingIsByBundleComponentNotSubstring() {
    #expect(decideRoute(meetCallPresent: false, recording: [recorder("com.apple.FaceTimeX", "Impostor")])
        == .system(appNames: ["Impostor"]))
}

@Test func ignoredBackgroundRecordersAreNotCalls() {
    let recording = [recorder("com.apple.corespeechd", "corespeechd")]
    #expect(decideRoute(meetCallPresent: false, recording: recording, ignoredBundleIDs: ["com.apple.corespeechd"]) == .idle)
}

@Test func appNamesAreDeduplicatedInOrder() {
    let recording = [
        recorder("com.vivaldi.Vivaldi.helper", "Vivaldi", pid: 1),
        recorder("com.vivaldi.Vivaldi.helper", "Vivaldi", pid: 2),
        recorder("com.tinyspeck.slackmacgap", "Slack", pid: 3),
    ]
    #expect(decideRoute(meetCallPresent: false, recording: recording) == .system(appNames: ["Vivaldi", "Slack"]))
}

@Test func processesWithoutABundleIDStillCount() {
    #expect(decideRoute(meetCallPresent: false, recording: [recorder("", "process 42")]) == .system(appNames: ["process 42"]))
}

@Test func owningAppBundleIDStripsHelperSuffixes() {
    #expect(owningAppBundleID("com.vivaldi.Vivaldi.helper") == "com.vivaldi.Vivaldi")
    #expect(owningAppBundleID("com.google.Chrome.helper.Renderer") == "com.google.Chrome")
    #expect(owningAppBundleID("com.example.App.Helper") == "com.example.App")
    #expect(owningAppBundleID("com.tinyspeck.slackmacgap") == "com.tinyspeck.slackmacgap")
    #expect(owningAppBundleID("com.helperapp.Tool") == "com.helperapp.Tool")
    #expect(owningAppBundleID("") == "")
}

@Test func onlyTheMeetAndSystemRoutesHoldTheMic() {
    #expect(MuteRoute.meet.holdsMic)
    #expect(MuteRoute.system(appNames: ["Slack"]).holdsMic)
    #expect(!MuteRoute.standAside(nativeAppNames: ["Microsoft Teams"]).holdsMic)
    #expect(!MuteRoute.idle.holdsMic)
}

@Test func isSystemIgnoresTheAppNames() {
    #expect(MuteRoute.system(appNames: []).isSystem)
    #expect(MuteRoute.system(appNames: ["Slack"]).isSystem)
    #expect(!MuteRoute.meet.isSystem)
    #expect(!MuteRoute.idle.isSystem)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MuteRouteTests`
Expected: build failure — `cannot find 'decideRoute' in scope`.

- [ ] **Step 3: Implement**

`Sources/MeetMuteCore/MuteRoute.swift` — set `ignoredRecorderBundleIDs` to the bundle IDs listed under `BACKGROUND_RECORDERS` in `docs/system-mute-spike-findings.md` (use an empty set if it says "none"):

```swift
import Foundation

/// A process other than ours that is currently capturing microphone input.
public struct RecordingProcess: Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String
    public let displayName: String

    public init(pid: Int32, bundleID: String, displayName: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.displayName = displayName
    }
}

/// Apps that handle the AirPods mute gesture themselves; we never take the press from them.
public let nativeAirPodsMuteBundleIDs: Set<String> = [
    "com.microsoft.teams2",
    "com.microsoft.teams",
    "com.apple.FaceTime",
]

/// Processes that capture input in the background with no call (from the spike's
/// no-call `list`, docs/system-mute-spike-findings.md).
public let ignoredRecorderBundleIDs: Set<String> = [
    // BACKGROUND_RECORDERS from the spike findings go here.
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
    let calls = recording.filter { process in !isListed(process.bundleID, in: ignoredBundleIDs) }
    let nativeHandlers = calls.filter { process in isListed(process.bundleID, in: nativeBundleIDs) }
    if !nativeHandlers.isEmpty { return .standAside(nativeAppNames: uniqueNames(nativeHandlers)) }
    if !calls.isEmpty { return .system(appNames: uniqueNames(calls)) }
    return .idle
}

private func uniqueNames(_ processes: [RecordingProcess]) -> [String] {
    var seen = Set<String>()
    return processes.map(\.displayName).filter { name in seen.insert(name).inserted }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MuteRouteTests`
Expected: `Test run with 14 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetMuteCore/MuteRoute.swift Tests/MeetMuteCoreTests/MuteRouteTests.swift
git commit -m "Add the press route decision for system-wide mute

Co-Authored-By: <model> <noreply@anthropic.com>"
```

---

### Task 3: System mic muter with crash-safe bookkeeping

**Files:**
- Create: `Sources/MeetMuteCore/SystemMicMuter.swift`
- Test: `Tests/MeetMuteCoreTests/SystemMicMuterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public protocol InputMuteDevice: AnyObject` — `uid: String`, `name: String`, `supportsMute: Bool`, `supportsVolume: Bool`, `isMuted() throws -> Bool`, `setMuted(_:) throws`, `volume() throws -> Float`, `setVolume(_:) throws`.
  - `public protocol InputDeviceProvider` — `defaultInputDevice() throws -> InputMuteDevice`, `inputDevice(uid: String) throws -> InputMuteDevice?`.
  - `public enum MuteMechanism: String, Codable` (`.deviceMute`, `.volumeZero`); `public struct MuteRecord: Codable, Equatable` (`deviceUID`, `mechanism`, `previousVolume: Float?`).
  - `public protocol MuteRecordStore: AnyObject` — `load() -> MuteRecord?`, `save(_: MuteRecord?)`; `public final class UserDefaultsMuteRecordStore: MuteRecordStore` — `init(defaults: UserDefaults = .standard)`.
  - `public enum SystemMuteError: Error, Equatable, CustomStringConvertible` — `.unsupported(deviceName: String)`.
  - `public final class SystemMicMuter` — `init(devices: InputDeviceProvider, store: MuteRecordStore)`, `mute() throws`, `unmute() throws`, `restoreIfWeMuted() throws`, `isDefaultInputMuted() throws -> Bool`, `var hasOwnedMute: Bool`.

- [ ] **Step 1: Write the failing tests**

`Tests/MeetMuteCoreTests/SystemMicMuterTests.swift`:

```swift
import Foundation
import Testing
@testable import MeetMuteCore

enum FakeDeviceError: Error { case setFailed }

final class FakeInputDevice: InputMuteDevice {
    let uid: String
    let name: String
    let supportsMute: Bool
    let supportsVolume: Bool
    var muted = false
    var level: Float = 0.8
    var failNextSet = false

    init(uid: String = "airpods", name: String = "AirPods", supportsMute: Bool = true, supportsVolume: Bool = true) {
        self.uid = uid
        self.name = name
        self.supportsMute = supportsMute
        self.supportsVolume = supportsVolume
    }

    func isMuted() throws -> Bool { muted }
    func setMuted(_ newValue: Bool) throws {
        if failNextSet { failNextSet = false; throw FakeDeviceError.setFailed }
        muted = newValue
    }
    func volume() throws -> Float { level }
    func setVolume(_ newValue: Float) throws {
        if failNextSet { failNextSet = false; throw FakeDeviceError.setFailed }
        level = newValue
    }
}

final class FakeInputDevices: InputDeviceProvider {
    var current: FakeInputDevice
    var all: [FakeInputDevice]

    init(_ devices: FakeInputDevice...) {
        current = devices[0]
        all = devices
    }

    func defaultInputDevice() throws -> InputMuteDevice { current }
    func inputDevice(uid: String) throws -> InputMuteDevice? { all.first { device in device.uid == uid } }
}

final class MemoryMuteRecordStore: MuteRecordStore {
    var record: MuteRecord?
    func load() -> MuteRecord? { record }
    func save(_ newRecord: MuteRecord?) { record = newRecord }
}

@Test func muteUsesTheDeviceMuteAndRecordsIt() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    try SystemMicMuter(devices: FakeInputDevices(airpods), store: store).mute()
    #expect(airpods.muted)
    #expect(store.record == MuteRecord(deviceUID: "airpods", mechanism: .deviceMute, previousVolume: nil))
}

@Test func unmuteUndoesOurMuteAndClearsTheRecord() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute()
    try muter.unmute()
    #expect(!airpods.muted)
    #expect(store.record == nil)
}

@Test func aDeviceAlreadyMutedElsewhereIsNotClaimed() throws {
    let airpods = FakeInputDevice()
    airpods.muted = true
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute()
    #expect(store.record == nil)
    try muter.restoreIfWeMuted()
    #expect(airpods.muted)
}

@Test func anExplicitUnmuteClearsAForeignMute() throws {
    let airpods = FakeInputDevice()
    airpods.muted = true
    try SystemMicMuter(devices: FakeInputDevices(airpods), store: MemoryMuteRecordStore()).unmute()
    #expect(!airpods.muted)
}

@Test func theVolumeFallbackRemembersAndRestoresTheLevel() throws {
    let airpods = FakeInputDevice(supportsMute: false)
    airpods.level = 0.6
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute()
    #expect(airpods.level == 0)
    #expect(store.record == MuteRecord(deviceUID: "airpods", mechanism: .volumeZero, previousVolume: 0.6))
    try muter.unmute()
    #expect(airpods.level == 0.6)
    #expect(store.record == nil)
}

@Test func aDeviceWithNoControlsIsReported() {
    let fixed = FakeInputDevice(supportsMute: false, supportsVolume: false)
    let muter = SystemMicMuter(devices: FakeInputDevices(fixed), store: MemoryMuteRecordStore())
    #expect(throws: SystemMuteError.unsupported(deviceName: "AirPods")) { try muter.mute() }
}

@Test func restoreDoesNothingWithoutARecord() throws {
    let airpods = FakeInputDevice()
    airpods.muted = true
    try SystemMicMuter(devices: FakeInputDevices(airpods), store: MemoryMuteRecordStore()).restoreIfWeMuted()
    #expect(airpods.muted)
}

@Test func launchRecoveryUnmutesTheRecordedDevice() throws {
    let airpods = FakeInputDevice()
    airpods.muted = true
    let store = MemoryMuteRecordStore()
    store.record = MuteRecord(deviceUID: "airpods", mechanism: .deviceMute, previousVolume: nil)
    try SystemMicMuter(devices: FakeInputDevices(airpods), store: store).restoreIfWeMuted()
    #expect(!airpods.muted)
    #expect(store.record == nil)
}

@Test func aRecordForADisconnectedDeviceIsDropped() throws {
    let store = MemoryMuteRecordStore()
    store.record = MuteRecord(deviceUID: "gone", mechanism: .deviceMute, previousVolume: nil)
    try SystemMicMuter(devices: FakeInputDevices(FakeInputDevice()), store: store).restoreIfWeMuted()
    #expect(store.record == nil)
}

@Test func aDefaultDeviceChangeRestoresThePreviousDeviceFirst() throws {
    let airpods = FakeInputDevice(uid: "airpods", name: "AirPods")
    let usb = FakeInputDevice(uid: "usb", name: "USB Mic")
    let devices = FakeInputDevices(airpods, usb)
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: devices, store: store)
    try muter.mute()
    devices.current = usb
    try muter.mute()
    #expect(!airpods.muted)
    #expect(usb.muted)
    #expect(store.record?.deviceUID == "usb")
}

@Test func muteReappliesWhenOurMuteWasUndoneElsewhere() throws {
    let airpods = FakeInputDevice()
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    try muter.mute()
    airpods.muted = false
    try muter.mute()
    #expect(airpods.muted)
    #expect(store.record != nil)
}

@Test func aFailedMuteLeavesNoRecord() {
    let airpods = FakeInputDevice()
    airpods.failNextSet = true
    let store = MemoryMuteRecordStore()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: store)
    #expect(throws: FakeDeviceError.self) { try muter.mute() }
    #expect(store.record == nil)
}

@Test func defaultInputMutedReflectsMuteOrZeroVolume() throws {
    let airpods = FakeInputDevice()
    let muter = SystemMicMuter(devices: FakeInputDevices(airpods), store: MemoryMuteRecordStore())
    #expect(try !muter.isDefaultInputMuted())
    airpods.muted = true
    #expect(try muter.isDefaultInputMuted())

    let volumeOnly = FakeInputDevice(supportsMute: false)
    volumeOnly.level = 0
    #expect(try SystemMicMuter(devices: FakeInputDevices(volumeOnly), store: MemoryMuteRecordStore()).isDefaultInputMuted())
}

@Test func userDefaultsStoreRoundTripsAndClears() throws {
    let suiteName = "airpods-meet-mute-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsMuteRecordStore(defaults: defaults)
    let record = MuteRecord(deviceUID: "airpods", mechanism: .volumeZero, previousVolume: 0.5)
    store.save(record)
    #expect(UserDefaultsMuteRecordStore(defaults: defaults).load() == record)
    store.save(nil)
    #expect(store.load() == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SystemMicMuterTests`
Expected: build failure — `cannot find type 'InputMuteDevice' in scope`.

- [ ] **Step 3: Implement**

`Sources/MeetMuteCore/SystemMicMuter.swift`:

```swift
import Foundation

/// The default input device's software controls (CoreAudio adapter in production, fake in tests).
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
    func defaultInputDevice() throws -> InputMuteDevice
    func inputDevice(uid: String) throws -> InputMuteDevice?
}

public enum MuteMechanism: String, Codable, Sendable {
    case deviceMute
    case volumeZero
}

/// Proof that *we* muted a device, persisted so a crash can be undone on the next launch.
public struct MuteRecord: Codable, Equatable, Sendable {
    public let deviceUID: String
    public let mechanism: MuteMechanism
    public let previousVolume: Float?

    public init(deviceUID: String, mechanism: MuteMechanism, previousVolume: Float?) {
        self.deviceUID = deviceUID
        self.mechanism = mechanism
        self.previousVolume = previousVolume
    }
}

public protocol MuteRecordStore: AnyObject {
    func load() -> MuteRecord?
    func save(_ record: MuteRecord?)
}

public final class UserDefaultsMuteRecordStore: MuteRecordStore {
    private let defaults: UserDefaults
    private let key = "systemMuteRecord"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> MuteRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        // Our own JSON; an undecodable record (format change) is treated as no record.
        return try? JSONDecoder().decode(MuteRecord.self, from: data)
    }

    public func save(_ record: MuteRecord?) {
        if let record, let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

public enum SystemMuteError: Error, Equatable, CustomStringConvertible {
    case unsupported(deviceName: String)

    public var description: String {
        switch self {
        case .unsupported(let deviceName):
            "“\(deviceName)” has no software mute or input volume — choose another input device"
        }
    }
}

/// Mutes the default input device for every app. Only a mute we applied (recorded in the store)
/// is ever undone automatically, so a mic the user muted elsewhere stays muted.
public final class SystemMicMuter {
    private let devices: InputDeviceProvider
    private let store: MuteRecordStore

    public init(devices: InputDeviceProvider, store: MuteRecordStore) {
        self.devices = devices
        self.store = store
    }

    public var hasOwnedMute: Bool { store.load() != nil }

    public func mute() throws {
        let device = try devices.defaultInputDevice()
        try restoreRecordForAnotherDevice(than: device)
        if let record = store.load() {
            try reapply(record, on: device)
            return
        }
        if device.supportsMute {
            guard try !device.isMuted() else { return }  // muted by someone else: not ours to undo
            try device.setMuted(true)
            store.save(MuteRecord(deviceUID: device.uid, mechanism: .deviceMute, previousVolume: nil))
        } else if device.supportsVolume {
            let currentVolume = try device.volume()
            guard currentVolume > 0 else { return }
            try device.setVolume(0)
            store.save(MuteRecord(deviceUID: device.uid, mechanism: .volumeZero, previousVolume: currentVolume))
        } else {
            throw SystemMuteError.unsupported(deviceName: device.name)
        }
    }

    /// An explicit unmute press means "make me heard": undo our mute, or clear a device mute set elsewhere.
    public func unmute() throws {
        let device = try devices.defaultInputDevice()
        try restoreRecordForAnotherDevice(than: device)
        if let record = store.load() {
            try restore(record, on: device)
            return
        }
        if device.supportsMute, try device.isMuted() {
            try device.setMuted(false)
        }
    }

    /// Auto-unmute (call ended, launch after a crash, quit): undoes only a mute we applied.
    public func restoreIfWeMuted() throws {
        guard let record = store.load() else { return }
        guard let device = try devices.inputDevice(uid: record.deviceUID) else {
            store.save(nil)  // superseded: AirPods reconnected unmuted live (2026-11-11); records for absent devices are now kept and restored on return
            return
        }
        try restore(record, on: device)
    }

    public func isDefaultInputMuted() throws -> Bool {
        let device = try devices.defaultInputDevice()
        if device.supportsMute { return try device.isMuted() }
        if device.supportsVolume { return try device.volume() == 0 }
        return false
    }

    private func restore(_ record: MuteRecord, on device: InputMuteDevice) throws {
        switch record.mechanism {
        case .deviceMute: try device.setMuted(false)
        case .volumeZero: try device.setVolume(record.previousVolume ?? 1)
        }
        store.save(nil)
    }

    private func reapply(_ record: MuteRecord, on device: InputMuteDevice) throws {
        switch record.mechanism {
        case .deviceMute: if try !device.isMuted() { try device.setMuted(true) }
        case .volumeZero: if try device.volume() > 0 { try device.setVolume(0) }
        }
    }

    private func restoreRecordForAnotherDevice(than device: InputMuteDevice) throws {
        if let record = store.load(), record.deviceUID != device.uid {
            try restoreIfWeMuted()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SystemMicMuterTests`
Expected: `Test run with 14 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetMuteCore/SystemMicMuter.swift Tests/MeetMuteCoreTests/SystemMicMuterTests.swift
git commit -m "Add the system mic muter with crash-safe mute records

Co-Authored-By: <model> <noreply@anthropic.com>"
```

---

### Task 4: Menu title and status line

**Files:**
- Create: `Sources/MeetMuteCore/StatusText.swift`
- Test: `Tests/MeetMuteCoreTests/StatusTextTests.swift`

**Interfaces:**
- Consumes: `MuteRoute` (Task 2); existing `MeetStatus`, `MicState`.
- Produces: `public func menuTitle(route: MuteRoute, meetStatus: MeetStatus, systemMuted: Bool?, hasProblem: Bool) -> String`; `public func menuStatusLine(route: MuteRoute, meetStatus: MeetStatus, systemMuted: Bool?) -> String`.

- [ ] **Step 1: Write the failing tests**

`Tests/MeetMuteCoreTests/StatusTextTests.swift`:

```swift
import Testing
@testable import MeetMuteCore

@Test func titleShowsAProblemFirst() {
    #expect(menuTitle(route: .system(appNames: ["Slack"]), meetStatus: .idle, systemMuted: true, hasProblem: true) == "🎧⚠️")
}

@Test func titleWarnsOnAMeetScriptError() {
    #expect(menuTitle(route: .idle, meetStatus: .error("boom"), systemMuted: nil, hasProblem: false) == "🎧⚠️")
}

@Test func titleFollowsMeetOnTheMeetRoute() {
    #expect(menuTitle(route: .meet, meetStatus: .inCall(.muted), systemMuted: nil, hasProblem: false) == "🎧🔇")
    #expect(menuTitle(route: .meet, meetStatus: .inCall(.unmuted), systemMuted: nil, hasProblem: false) == "🎧🎙️")
}

@Test func titleFollowsTheDeviceOnTheSystemRoute() {
    let route = MuteRoute.system(appNames: ["Slack"])
    #expect(menuTitle(route: route, meetStatus: .idle, systemMuted: true, hasProblem: false) == "🎧🔇")
    #expect(menuTitle(route: route, meetStatus: .idle, systemMuted: false, hasProblem: false) == "🎧🎙️")
    #expect(menuTitle(route: route, meetStatus: .idle, systemMuted: nil, hasProblem: false) == "🎧")
}

@Test func titleIsPlainWhenStandingAsideOrIdle() {
    #expect(menuTitle(route: .standAside(nativeAppNames: ["Microsoft Teams"]), meetStatus: .idle, systemMuted: nil, hasProblem: false) == "🎧")
    #expect(menuTitle(route: .idle, meetStatus: .idle, systemMuted: nil, hasProblem: false) == "🎧")
}

@Test func statusLineNamesTheRecordingApps() {
    let route = MuteRoute.system(appNames: ["Slack", "Vivaldi"])
    #expect(menuStatusLine(route: route, meetStatus: .idle, systemMuted: true) == "System mic muted — Slack, Vivaldi")
    #expect(menuStatusLine(route: route, meetStatus: .idle, systemMuted: false) == "System mic live — Slack, Vivaldi")
    #expect(menuStatusLine(route: route, meetStatus: .idle, systemMuted: nil) == "System mic — Slack, Vivaldi (state unknown)")
}

@Test func statusLineExplainsStandingAside() {
    #expect(menuStatusLine(route: .standAside(nativeAppNames: ["Microsoft Teams"]), meetStatus: .idle, systemMuted: nil)
        == "Standing aside — Microsoft Teams handles AirPods mute")
}

@Test func statusLineForMeetAndIdle() {
    #expect(menuStatusLine(route: .meet, meetStatus: .inCall(.muted), systemMuted: nil) == "In Meet call — muted")
    #expect(menuStatusLine(route: .meet, meetStatus: .inCall(.unmuted), systemMuted: nil) == "In Meet call — unmuted")
    #expect(menuStatusLine(route: .meet, meetStatus: .error("glitch"), systemMuted: nil) == "glitch")
    #expect(menuStatusLine(route: .idle, meetStatus: .idle, systemMuted: nil) == "No call")
    #expect(menuStatusLine(route: .idle, meetStatus: .error("boom"), systemMuted: nil) == "boom")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StatusTextTests`
Expected: build failure — `cannot find 'menuTitle' in scope`.

- [ ] **Step 3: Implement**

`Sources/MeetMuteCore/StatusText.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StatusTextTests`
Expected: `Test run with 8 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeetMuteCore/StatusText.swift Tests/MeetMuteCoreTests/StatusTextTests.swift
git commit -m "Add route-aware menu title and status line

Co-Authored-By: <model> <noreply@anthropic.com>"
```

---

### Task 5: CoreAudio adapters

**Files:**
- Create: `Sources/MeetMuteCore/CoreAudioSupport.swift`
- Create: `Sources/MeetMuteCore/CoreAudioDevices.swift`
- Create: `Sources/MeetMuteCore/CoreAudioProcesses.swift`
- Test: `Tests/MeetMuteCoreTests/CoreAudioSmokeTests.swift`

**Interfaces:**
- Consumes: `InputMuteDevice`, `InputDeviceProvider` (Task 3); `RecordingProcess`, `owningAppBundleID` (Task 2).
- Produces: `public struct CoreAudioError: Error, CustomStringConvertible`; `public final class CoreAudioInputDevice: InputMuteDevice`; `public struct CoreAudioInputDeviceProvider: InputDeviceProvider` (`init()`); `public protocol RecordingProcessSource { func recordingProcesses() throws -> [RecordingProcess] }`; `public struct CoreAudioRecordingProcessSource: RecordingProcessSource` (`init(excludingPID: Int32 = ProcessInfo.processInfo.processIdentifier)`).

- [ ] **Step 1: Write the smoke tests (read-only — they must never set a device property)**

`Tests/MeetMuteCoreTests/CoreAudioSmokeTests.swift`:

```swift
import Foundation
import Testing
@testable import MeetMuteCore

@Test func listingRecordersWorksAndNeverIncludesUs() throws {
    let ourPID = ProcessInfo.processInfo.processIdentifier
    let recorders = try CoreAudioRecordingProcessSource(excludingPID: ourPID).recordingProcesses()
    #expect(!recorders.contains { process in process.pid == ourPID })
}

@Test func theDefaultInputDeviceHasAnIdentityAndCanBeFoundByUID() throws {
    let provider = CoreAudioInputDeviceProvider()
    let device = try provider.defaultInputDevice()
    #expect(!device.uid.isEmpty)
    #expect(!device.name.isEmpty)
    let found = try #require(try provider.inputDevice(uid: device.uid))
    #expect(found.uid == device.uid)
    #expect(try provider.inputDevice(uid: "no-such-device-\(UUID().uuidString)") == nil)
}

@Test func coreAudioErrorsReadAsFourCharacterCodes() {
    let error = CoreAudioError(operation: "set input mute", status: 0x21646576)  // '!dev'
    #expect(error.description == "CoreAudio set input mute failed ('!dev')")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CoreAudioSmokeTests`
Expected: build failure — `cannot find 'CoreAudioRecordingProcessSource' in scope`.

- [ ] **Step 3: Implement the property helpers**

`Sources/MeetMuteCore/CoreAudioSupport.swift`:

```swift
import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let operation: String
    public let status: OSStatus

    public init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var description: String { "CoreAudio \(operation) failed (\(fourCharacterCode(status)))" }
}

/// CoreAudio statuses are usually four ASCII characters ('!dev'); fall back to the number.
func fourCharacterCode(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { shift in UInt8((value >> UInt32(shift)) & 0xFF) }
    guard bytes.allSatisfy({ byte in byte >= 32 && byte < 127 }) else { return "\(status)" }
    return "'" + String(decoding: bytes, as: UTF8.self) + "'"
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

/// For plain value types only (UInt32, Float32, AudioObjectID, pid_t) — never CFString.
func readValue<Value>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: Value, operation: String) throws -> Value {
    var address = address
    var value = initial
    var size = UInt32(MemoryLayout<Value>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
    return value
}

func writeValue<Value>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ newValue: Value, operation: String) throws {
    var address = address
    var value = newValue
    let status = AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Value>.size), &value)
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
}

func readString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, operation: String) throws -> String {
    var address = address
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &unmanaged)
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
    return (unmanaged?.takeRetainedValue() as String?) ?? ""
}

func readObjectIDs(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, operation: String) throws -> [AudioObjectID] {
    var address = address
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
    var objectIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objectIDs)
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
    return Array(objectIDs.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
    var address = address
    guard AudioObjectHasProperty(object, &address) else { return false }
    var settable = DarwinBoolean(false)
    return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
}
```

- [ ] **Step 4: Implement the input device adapter**

`Sources/MeetMuteCore/CoreAudioDevices.swift`:

```swift
import CoreAudio
import Foundation

public final class CoreAudioInputDevice: InputMuteDevice {
    let objectID: AudioObjectID
    public let uid: String
    public let name: String
    private let muteAddress = propertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
    private let volumeAddresses: [AudioObjectPropertyAddress]

    init(objectID: AudioObjectID) throws {
        self.objectID = objectID
        uid = try readString(objectID, propertyAddress(kAudioDevicePropertyDeviceUID), operation: "read device UID")
        name = try readString(objectID, propertyAddress(kAudioObjectPropertyName), operation: "read device name")
        let elements = [kAudioObjectPropertyElementMain] + (1...8).map { channel in AudioObjectPropertyElement(channel) }
        let settableVolumes = elements
            .map { element in propertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: element) }
            .filter { address in isSettable(objectID, address) }
        // Prefer the main element; otherwise drive every channel element together.
        if let main = settableVolumes.first, main.mElement == kAudioObjectPropertyElementMain {
            volumeAddresses = [main]
        } else {
            volumeAddresses = settableVolumes
        }
    }

    public var supportsMute: Bool { isSettable(objectID, muteAddress) }
    public var supportsVolume: Bool { !volumeAddresses.isEmpty }

    public func isMuted() throws -> Bool {
        try readValue(objectID, muteAddress, initial: UInt32(0), operation: "read input mute") != 0
    }

    public func setMuted(_ muted: Bool) throws {
        try writeValue(objectID, muteAddress, UInt32(muted ? 1 : 0), operation: "set input mute")
    }

    public func volume() throws -> Float {
        guard let first = volumeAddresses.first else {
            throw CoreAudioError(operation: "read input volume", status: kAudioHardwareUnknownPropertyError)
        }
        return try readValue(objectID, first, initial: Float32(0), operation: "read input volume")
    }

    public func setVolume(_ volume: Float) throws {
        for address in volumeAddresses {
            try writeValue(objectID, address, Float32(volume), operation: "set input volume")
        }
    }
}

public struct CoreAudioInputDeviceProvider: InputDeviceProvider {
    public init() {}

    public func defaultInputDevice() throws -> InputMuteDevice {
        let objectID = try readValue(
            AudioObjectID(kAudioObjectSystemObject),
            propertyAddress(kAudioHardwarePropertyDefaultInputDevice),
            initial: AudioObjectID(kAudioObjectUnknown),
            operation: "read default input device"
        )
        guard objectID != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioError(operation: "find a default input device", status: kAudioHardwareBadDeviceError)
        }
        return try CoreAudioInputDevice(objectID: objectID)
    }

    public func inputDevice(uid: String) throws -> InputMuteDevice? {
        let objectIDs = try readObjectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            propertyAddress(kAudioHardwarePropertyDevices),
            operation: "list audio devices"
        )
        for objectID in objectIDs {
            // A device that cannot report a UID/name (mid-teardown) is simply not the one we want.
            if let device = try? CoreAudioInputDevice(objectID: objectID), device.uid == uid {
                return device
            }
        }
        return nil
    }
}
```

- [ ] **Step 5: Implement the recording-process adapter**

`Sources/MeetMuteCore/CoreAudioProcesses.swift`:

```swift
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
```

- [ ] **Step 6: Run tests to verify they pass, then the full suite**

Run: `swift test --filter CoreAudioSmokeTests`
Expected: `Test run with 3 tests passed`.

Run: `swift test`
Expected: `Test run with 81 tests passed` (42 existing + 14 + 14 + 8 + 3), no warnings.

- [ ] **Step 7: Live read-only check against the real system**

Run: `swift scripts/system-mute-probe.swift list` while a Slack huddle is running (Joel), and compare with what the app adapter returns by temporarily running the smoke test with output: `swift test --filter listingRecordersWorksAndNeverIncludesUs` passes. (The probe is the reference; no adapter code is changed by this step.)

- [ ] **Step 8: Commit**

```bash
git add Sources/MeetMuteCore/CoreAudioSupport.swift Sources/MeetMuteCore/CoreAudioDevices.swift Sources/MeetMuteCore/CoreAudioProcesses.swift Tests/MeetMuteCoreTests/CoreAudioSmokeTests.swift
git commit -m "Add CoreAudio adapters for input devices and recording apps

Co-Authored-By: <model> <noreply@anthropic.com>"
```

---

### Task 6: App wiring — routing, press dispatch, safety hooks

**Files:**
- Create: `Sources/AirPodsMeetMute/StatusMenu.swift`
- Modify (full rewrite): `Sources/AirPodsMeetMute/AppDelegate.swift`

**Interfaces:**
- Consumes: `decideRoute`, `MuteRoute` (Task 2); `SystemMicMuter`, `UserDefaultsMuteRecordStore` (Task 3); `menuTitle`, `menuStatusLine` (Task 4); `CoreAudioInputDeviceProvider`, `CoreAudioRecordingProcessSource`, `RecordingProcessSource` (Task 5); existing `MuteController`, `GestureListener` (`onMuteRequest`, `start()`, `syncSystemMute(_:) -> String?`, `setHoldingInput(_:) -> String?`), `PressFeedbackSound.play(for:) -> String?`.
- Produces: `build/AirPodsMeetMute.app` with system-wide mute.

- [ ] **Step 1: Split the menu builder out**

`Sources/AirPodsMeetMute/StatusMenu.swift`:

```swift
import AppKit

/// Builds the status-item menu. AppDelegate owns the state and the actions.
enum StatusMenu {
    static func build(
        statusLine: String,
        problems: [String],
        launchAtLoginEnabled: Bool,
        actionTarget: AnyObject,
        toggleLaunchAtLogin: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(disabledItem(statusLine))
        for problem in problems {
            menu.addItem(disabledItem("⚠️ " + problem))
        }
        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "Launch at Login", action: toggleLaunchAtLogin, keyEquivalent: "")
        loginItem.target = actionTarget
        loginItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit AirPods Meet Mute", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
```

- [ ] **Step 2: Rewrite AppDelegate**

`Sources/AirPodsMeetMute/AppDelegate.swift` (complete file):

```swift
import AppKit
import MeetMuteCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let pollInterval: TimeInterval = 3
    /// A poll this soon after a handled press skips the system-mute sync: the press already
    /// made the system record the requested state, and a sync from a stale read could undo it.
    private let syncQuietPeriodAfterPress: TimeInterval = 1.5
    /// Consecutive AppleScript error polls a Meet call survives before it counts as ended.
    private let errorPollsBeforeLeavingMeet = 2

    private let controller = MuteController(browsers: Browser.allCases.map { ChromiumBridge(browser: $0) })
    private let recorders: RecordingProcessSource = CoreAudioRecordingProcessSource()
    private let systemMute = SystemMicMuter(devices: CoreAudioInputDeviceProvider(), store: UserDefaultsMuteRecordStore())
    private let listener = GestureListener()
    private let pressSound = PressFeedbackSound()
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?

    private var route: MuteRoute = .idle
    private var systemMuted: Bool?
    private var lastHandledPress: Date?
    private var wasInMeetCall = false
    private var consecutiveMeetErrorPolls = 0

    private var listenerError: String?
    private var inputError: String?
    private var syncError: String?
    private var systemError: String?
    private var recorderError: String?
    private var loginItemError: String?
    private var soundError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        restoreSystemMute(when: "after the last run")  // a crash or force-quit may have left the mic muted
        listener.onMuteRequest = { [weak self] shouldMute in
            guard let self else { return false }
            let handled = self.handlePress(shouldMute: shouldMute)
            self.render()
            return handled
        }
        do {
            try listener.start()
        } catch {
            listenerError = "Could not register for the AirPods mute gesture: \(error.localizedDescription)"
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreSystemMute(when: "on quit")
    }

    // MARK: Press

    /// Never calls setInputMuted (it re-enters this handler); returning true records the state.
    private func handlePress(shouldMute: Bool) -> Bool {
        let newState: MicState?
        switch route {
        case .meet:
            newState = controller.handleMuteRequest(shouldMute: shouldMute)
        case .system:
            do {
                if shouldMute { try systemMute.mute() } else { try systemMute.unmute() }
                systemError = nil
                systemMuted = shouldMute
                newState = shouldMute ? .muted : .unmuted
            } catch {
                systemError = "Could not \(shouldMute ? "mute" : "unmute") the system mic: \(error)"
                newState = nil
            }
        case .standAside, .idle:
            newState = nil
        }
        guard let newState else { return false }
        lastHandledPress = Date()
        soundError = pressSound.play(for: newState)
        return true
    }

    // MARK: Poll

    private func poll() {
        let meetStatus = controller.refresh()
        route = decideRoute(meetCallPresent: meetCallPresent(meetStatus), recording: currentRecorders())
        if !route.isSystem {
            restoreSystemMute(when: "after the call")  // no-op unless we muted the device
        }
        switch route {
        case .meet:
            systemMuted = nil
            if case .inCall(let mic) = meetStatus, !inQuietPeriodAfterPress {
                syncError = listener.syncSystemMute(mic == .muted)
            }
        case .system:
            do {
                let muted = try systemMute.isDefaultInputMuted()
                systemMuted = muted
                if !inQuietPeriodAfterPress { syncError = listener.syncSystemMute(muted) }
            } catch {
                systemMuted = nil
                systemError = "Could not read the system mic state: \(error)"
            }
        case .standAside, .idle:
            systemMuted = nil
            syncError = nil
        }
        if route.holdsMic {
            inputError = listener.setHoldingInput(true)
        } else {
            listener.setHoldingInput(false)
            inputError = nil
        }
        render()
    }

    private var inQuietPeriodAfterPress: Bool {
        guard let lastHandledPress else { return false }
        return Date().timeIntervalSince(lastHandledPress) < syncQuietPeriodAfterPress
    }

    /// A Meet call survives a couple of transient AppleScript errors, so one glitch neither
    /// drops the held mic nor reroutes presses to the system path mid-call.
    private func meetCallPresent(_ status: MeetStatus) -> Bool {
        switch status {
        case .inCall:
            consecutiveMeetErrorPolls = 0
            wasInMeetCall = true
            return true
        case .error where wasInMeetCall && consecutiveMeetErrorPolls < errorPollsBeforeLeavingMeet:
            consecutiveMeetErrorPolls += 1
            return true
        case .error, .idle:
            consecutiveMeetErrorPolls = 0
            wasInMeetCall = false
            return false
        }
    }

    private func currentRecorders() -> [RecordingProcess] {
        do {
            let found = try recorders.recordingProcesses()
            recorderError = nil
            return found
        } catch {
            recorderError = "Could not list apps using the mic: \(error)"
            return []
        }
    }

    private func restoreSystemMute(when moment: String) {
        do {
            try systemMute.restoreIfWeMuted()
            if !route.isSystem { systemError = nil }
        } catch {
            systemError = "Could not unmute the system mic \(moment): \(error)"
        }
    }

    // MARK: Menu

    private func render() {
        let meetStatus = controller.status
        var problems = [listenerError, inputError, syncError, systemError, recorderError,
                        loginItemError, soundError, controller.lastPressError].compactMap { $0 }
        if case .error(let message) = meetStatus, route != .meet, route != .idle {
            problems.insert(message, at: 0)  // the status line is about another app; keep the Meet error visible
        }
        statusItem.button?.title = menuTitle(route: route, meetStatus: meetStatus, systemMuted: systemMuted,
                                             hasProblem: !problems.isEmpty)
        statusItem.menu = StatusMenu.build(
            statusLine: menuStatusLine(route: route, meetStatus: meetStatus, systemMuted: systemMuted),
            problems: problems,
            launchAtLoginEnabled: SMAppService.mainApp.status == .enabled,
            actionTarget: self,
            toggleLaunchAtLogin: #selector(toggleLaunchAtLogin)
        )
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Launch at Login failed: \(error.localizedDescription)"
        }
        render()
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `scripts/build-app.sh AirPodsMeetMute 2>&1 | grep -E 'warning|error|satisfies|Built'`
Expected: `satisfies its Designated Requirement` and `Built build/AirPodsMeetMute.app`, no warnings.

Run: `swift test`
Expected: `Test run with 81 tests passed`.

Run: `wc -l Sources/AirPodsMeetMute/AppDelegate.swift`
Expected: under 200 lines.

- [ ] **Step 4: Commit**

```bash
git add Sources/AirPodsMeetMute/StatusMenu.swift Sources/AirPodsMeetMute/AppDelegate.swift
git commit -m "Route presses to Meet or a system-wide mic mute, with auto-unmute safety

Co-Authored-By: <model> <noreply@anthropic.com>"
```

---

### Task 7: Install, live verification, README

**Requires Joel:** AirPods, a Slack huddle, a Meet call.

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-11-11-system-wide-mute-design.md` (Status line)

**Interfaces:**
- Consumes: `build/AirPodsMeetMute.app` (Task 6); `scripts/system-mute-probe.swift` (Task 1).

- [ ] **Step 1: Install, keeping existing privacy grants**

Sign with the certificate of the installed copy so Microphone/Automation grants survive:

```bash
installed_cert="$(codesign -dvv ~/Applications/AirPodsMeetMute.app 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)$/\1/p')"
CODESIGN_IDENTITY="$installed_cert" scripts/build-app.sh AirPodsMeetMute
pkill -x AirPodsMeetMute; sleep 1
rm -rf ~/Applications/AirPodsMeetMute.app && ditto build/AirPodsMeetMute.app ~/Applications/AirPodsMeetMute.app
open ~/Applications/AirPodsMeetMute.app
```

Expected: 🎧 with "No call".

- [ ] **Step 2: Slack huddle — system path**

Joel starts a Slack huddle. Within 3 s the menu reads `System mic live — Slack` and 🎧🎙️. Press: cue (high→low), banner, 🎧🔇, and `swift scripts/system-mute-probe.swift status` shows input mute `value=1` (or volume 0); speaking does not light Slack's indicator. Press again: low→high cue, 🎧🎙️, mute `value=0`, indicator lights.

- [ ] **Step 3: Auto-unmute when the call ends**

While muted, Joel leaves the huddle. Within 3 s: 🎧, "No call", and `status` shows input mute `value=0`.

- [ ] **Step 4: Crash recovery**

Join a huddle, press to mute, then `pkill -9 -x AirPodsMeetMute`. `status` → mute `value=1` (stuck, expected). Relaunch with `open ~/Applications/AirPodsMeetMute.app`; `status` → `value=0` within a second.

- [ ] **Step 5: Meet still uses its own button**

Joel joins a Meet call: menu shows `In Meet call — …`; a press flips Meet's button (`osascript scripts/probe-meet.applescript com.vivaldi.Vivaldi`) and the probe `status` shows the device mute untouched (`value=0`).

- [ ] **Step 6: Device disconnect while muted**

In a huddle, press to mute, then put the AirPods in their case. Reconnect, rejoin: `status` shows the AirPods input mute `value=0`. If it shows `1`, report it — `restoreIfWeMuted` drops records for disconnected devices on the assumption the mute does not persist, and that assumption is then wrong.

- [ ] **Step 7: README**

In `README.md`, replace the first paragraph of the file (the one beginning "Press an AirPods Pro stem during a Google Meet call") with:

```markdown
Press an AirPods Pro stem during a call to mute or unmute yourself — in Google Meet
(Vivaldi or Chrome) and in any other call app (Slack huddles, Teams in a browser, Zoom…).
In Meet it presses Meet's own mic button, so Meet's UI stays truthful. Everywhere else it
mutes the microphone device itself, so the app receives silence; that app's own mic icon
will still look unmuted, so trust the menu-bar icon.
```

and add this section before `## Setup`:

```markdown
### System-wide mute

- The app takes over the stem only while another app is recording from the mic, and
  stands aside for apps that handle AirPods mute themselves (Teams desktop, FaceTime).
- It mutes the default input device (CoreAudio input mute, or input volume 0 where the
  device has no mute) and never leaves you muted: it unmutes when the call ends, on quit,
  and on the next launch after a crash. A mute you set elsewhere is never undone by it.
- `swift scripts/system-mute-probe.swift status|list` shows the device mute state and
  which apps are recording.
```

- [ ] **Step 8: Mark the spec implemented and commit**

In `docs/superpowers/specs/2026-11-11-system-wide-mute-design.md` change `Status: Approved (design), pending spec review` to `Status: Implemented <date>`.

```bash
git add README.md docs/superpowers/specs/2026-11-11-system-wide-mute-design.md
git commit -m "Document system-wide mute and mark the design implemented

Co-Authored-By: <model> <noreply@anthropic.com>"
```
