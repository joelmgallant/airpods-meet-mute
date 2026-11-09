# AirPods Meet Mute — Design

Date: 2026-11-09
Status: Implemented 2026-11-09 (see README for the macOS behaviours found during live testing)

## Goal

Pressing an AirPods Pro stem during a Google Meet call in Vivaldi or Google Chrome
toggles Meet's own microphone button, so Meet's UI, the other participants' view,
and the AirPods mute chime all agree.

## Non-goals

- System-wide input muting, or muting any app other than Google Meet.
- Firefox, Safari, or Meet installed as a PWA.
- Push-to-talk, keyboard shortcuts, or any trigger other than the AirPods gesture.
- Distribution to other people (personal tool; no notarization, no App Store).

## Environment

- macOS 15.8.1 (Sequoia), Apple Silicon, Swift 6.2, full Xcode installed.
- Primary browser Vivaldi; Chrome also supported. Both expose the identical Chromium
  AppleScript dictionary (`tab` / `URL` / `execute ... javascript`), so one code path
  serves both.
- Signing identity: the builder's own Apple Development identity (auto-detected by `scripts/build-app.sh`).

## Key risk and Milestone 1 (spike)

The API is `AVAudioApplication.setInputMuteStateChangeHandler` (macOS 14+). On macOS
the system delivers the mute gesture to an app that is using audio input, and that app
must perform the mute itself. During a call the input-using app is the browser, which
does not adopt the API, so macOS shows "can't control mic".

Hypothesis: if our agent also holds an active audio input (a silent `AVAudioEngine`
input tap) while a call is running, the system delivers the gesture to us.

The spike is a throwaway command-line app that registers the handler, optionally
starts an input tap, and logs every gesture callback. Run it during a live Meet call
with AirPods Pro connected, in two configurations: handler only, and handler plus
input tap.

Decision rule:

- Callback fires in either configuration: continue; record which configuration is
  required. The input tap is built into `GestureListener` only if required.
- Callback fires in neither: stop the project and buy Mutify. Record the finding.

## Architecture

| Unit | Responsibility | Depends on |
|---|---|---|
| `GestureListener` | Registers the mute-gesture handler and observes the mute-state notification (the opt-in, see below); starts/stops the silent input tap when told to; `syncSystemMute(_:)` calls `setInputMuted(_:)` to keep the system state equal to Meet's, guarded against re-entering its own handler. Exposes `onMuteRequest: (Bool) -> Bool` (receives the requested mute state; returns true if handled). | AVFAudio |
| `BrowserBridge` | For each running browser in `[Vivaldi, Chrome]`, lists tab URLs via AppleScript (one Apple Event per window) and executes JavaScript in a chosen tab. Every script runs under a 3 s AppleScript timeout so a hung browser cannot freeze the menu. Protocol-backed so tests can use a fake. | NSAppleScript |
| `MeetToggleJS` | The in-page script, embedded as a Swift raw string (not a bundle resource). Locates Meet's mic button (`button[data-is-muted][aria-label*="microphone" i]` — the camera button also carries `data-is-muted`), clicks it, returns `"muted"`, `"unmuted"`, or `"no-button"`. All Meet DOM selectors live only here. Also has a read-only query mode that returns the current state without clicking. | Meet's DOM |
| `MuteController` (in `MeetMuteCore`) | Polling and press logic: finds the call tab (`refresh()`), reads its mic state, and handles a press by running mute/unmute on the cached call tab, falling back to one refresh and retry if that fails. Publishes status (idle / in call muted / in call unmuted / error) and the last press error. | BrowserBridge, MeetToggleJS |
| `AppDelegate` (app shell) | 3 s poll timer, the held-input tap lifecycle, and the `NSStatusItem` menu: status line, error text with fix instructions, Launch at Login toggle (`SMAppService.mainApp`), Quit. | all units |

A Meet tab URL matches `^https://meet\.google\.com/(?:meet/)?[a-z]{3}-[a-z]{4}-[a-z]{3}(?:[/?#]|$)`.
A tab is a *call tab* when the read-only JS reports a mic button present (excludes
lobbies and landing pages).

Two macOS requirements found live (details in the README):

- The gesture only reaches an app that holds an active audio input, so the app holds a
  silent input tap while a call is open and releases it when the call ends.
- Registering the handler is not enough: the app must also observe
  `AVAudioApplication.inputMuteStateChangeNotification`, which is what opts it into
  Bluetooth accessory muting. Without the observer every press is silently rejected.

## Data flow (one press)

1. macOS invokes the gesture handler.
2. `MuteController` uses the cached call tab from the last poll; if there is none, or
   running the script on it fails, it refreshes (first call tab across running browsers,
   Vivaldi before Chrome, then window and tab order) and retries once.
3. No call tab: return `false` (not handled); macOS behaves as normal.
4. Run the mute/unmute script in that tab; parse its result.
5. `"muted"` / `"unmuted"`: update the menu-bar icon and return `true`. Returning `true`
   makes the system record the requested state and play the chime. The press path must
   not call `setInputMuted`: it synchronously re-enters our own handler, which stopped
   the state being recorded and caused a libdispatch crash. Only the 3 s poll calls it,
   and only when Meet and the system disagree, guarded by a flag that makes the handler
   accept the re-entrant call without acting.
6. `"no-button"` or any AppleScript error: show the error in the menu, return `false`.

## Error handling

Every failure is visible in the menu; none is swallowed.

| Condition | Detection | Menu shows |
|---|---|---|
| Automation permission denied | AppleScript error -1743 | Which browser, and System Settings › Privacy & Security › Automation |
| JS from Apple Events disabled | Chromium's "Executing JavaScript through AppleScript is turned off" error | Enable View › Developer › Allow JavaScript from Apple Events |
| Meet DOM changed | JS returns `"no-button"` in a call tab | "Meet layout changed — selector needs update" |
| Browser hung or unresponsive | AppleScript error -1712 (3 s timeout) | Which browser is not responding |
| Microphone permission denied (input tap only) | `AVCaptureDevice.authorizationStatus(for: .audio)` | System Settings › Privacy & Security › Microphone |

## Testing

- Unit tests (swift-testing, `swift test`): Meet URL matching; parsing the AppleScript
  tab listing; mapping JS results to state; the press flow end to end against a fake
  `BrowserBridge` (call tab present, absent, `no-button`, AppleScript error).
- JS: headless Chrome against a fixture page with a `button[data-is-muted]`, checking
  click, returned state, read-only mode, and `"no-button"`. This proves the logic, not
  Meet's live DOM.
- Live verification (manual, real Meet call): after a stem press, read the tab's
  `data-is-muted` independently via AppleScript and confirm it flipped. Do not accept
  the handler's own return value as proof.

## Packaging

- SwiftPM package; executable target plus a library target holding the testable units.
- `scripts/build-app.sh` assembles `AirPodsMeetMute.app`: binary, `Info.plist` with
  `LSUIElement=true`, `NSMicrophoneUsageDescription`, `NSAppleEventsUsageDescription`,
  (the in-page JS is compiled in, not shipped as a resource).
- Sign with a stable Apple Development identity (hardened runtime with the
  `com.apple.security.automation.apple-events` and, if needed, `device.audio-input`
  entitlements) so TCC grants survive rebuilds.

## Milestones

1. Gesture-delivery spike — continue or stop, per the decision rule.
2. `BrowserBridge` + `MeetToggleJS`, with tests.
3. `GestureListener` + `MuteController` + `AppDelegate` menu shell wired together.
4. Packaging, signing, Launch at Login, live verification.
