# AirPods Meet Mute — Design

Date: 2026-11-09
Status: Approved (design), pending spec review

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
- Signing identity: `Apple Development: you@example.com (XXXXXXXXXX)`.

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
| `GestureListener` | Registers the mute-gesture handler; starts/stops the silent input tap when told to (only if the spike requires it); calls `setInputMuted(_:)` to keep the system state in sync. Exposes `onToggle: () -> Bool?` (new muted state, or `nil` = not handled). | AVFAudio |
| `BrowserBridge` | For each running browser in `[Vivaldi, Chrome]`, lists tab URLs via AppleScript, identifies Meet call tabs, and executes JavaScript in a chosen tab. Protocol-backed so tests can use a fake. | NSAppleScript |
| `meet-toggle.js` | Locates Meet's mic button (`button[data-is-muted]`), clicks it, returns `"muted"`, `"unmuted"`, or `"no-button"`. All Meet DOM selectors live only in this file. Also has a read-only mode returning current state without clicking. | Meet's DOM |
| `CallWatcher` | Polls every 3 s for a Meet call tab; starts/stops the input tap; publishes call state (idle / in call muted / in call unmuted / error). | BrowserBridge, GestureListener |
| App shell | `NSStatusItem` menu: status line, error text with fix instructions, Launch at Login toggle (`SMAppService.mainApp`), Quit. | all units |

A Meet tab URL matches `^https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}`.
A tab is a *call tab* when the read-only JS reports a mic button present (excludes
lobbies and landing pages).

## Data flow (one press)

1. macOS invokes the gesture handler.
2. `BrowserBridge` returns the first call tab across running browsers (Vivaldi before
   Chrome; within a browser, window then tab order).
3. No call tab: return `nil` (not handled); macOS behaves as normal.
4. Run `meet-toggle.js` in that tab; parse its result.
5. `"muted"` / `"unmuted"`: call `setInputMuted(...)` with that value so the chime
   matches, update the menu-bar icon, return the new state.
6. `"no-button"` or any AppleScript error: show the error in the menu, return `nil`.

## Error handling

Every failure is visible in the menu; none is swallowed.

| Condition | Detection | Menu shows |
|---|---|---|
| Automation permission denied | AppleScript error -1743 | Which browser, and System Settings › Privacy & Security › Automation |
| JS from Apple Events disabled | Chromium's "Executing JavaScript through AppleScript is turned off" error | Enable View › Developer › Allow JavaScript from Apple Events |
| Meet DOM changed | JS returns `"no-button"` in a call tab | "Meet layout changed — selector needs update" |
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
  and the JS file as a bundle resource.
- Sign with the stable `XXXXXXXXXX` identity (hardened runtime with the
  `com.apple.security.automation.apple-events` and, if needed, `device.audio-input`
  entitlements) so TCC grants survive rebuilds.

## Milestones

1. Gesture-delivery spike — continue or stop, per the decision rule.
2. `BrowserBridge` + `meet-toggle.js`, with tests.
3. `GestureListener` + `CallWatcher` + menu shell wired together.
4. Packaging, signing, Launch at Login, live verification.
