# System-wide AirPods Mute — Design

Date: 2026-11-11
Status: Approved (design), pending spec review
Builds on: `2026-11-09-airpods-meet-mute-design.md` (Meet path, unchanged)

## Goal

An AirPods Pro stem press mutes and unmutes the microphone in any call app — Slack
huddles, Teams in a browser, Zoom, Discord — not only Google Meet. Meet keeps its
truthful in-page toggle; every other app gets a system-level microphone mute.

## Non-goals

- Driving other apps' own mute buttons (no keystroke injection, no Accessibility
  permission). Their mic icons will still show "unmuted" while they receive silence.
- Taking over the stem from apps that already handle the AirPods mute gesture natively.
- A virtual audio device or HAL plug-in.
- Windows/iOS, or non-AirPods headsets' buttons.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Mute model | **Hybrid**: Meet tab → press Meet's button (existing path); otherwise → system-level mic mute |
| When to take over the stem | **Any other app recording from the mic**, except apps with native AirPods mute |
| Mute mechanism | CoreAudio input-scope `kAudioDevicePropertyMute` on the default input device; fallback: input volume scalar → 0 and restore |

## Environment facts (2026-11-11)

- Slack 4.53 installed (`com.tinyspeck.slackmacgap`); no evidence it supports the AirPods
  mute gesture. Teams desktop is not installed; Microsoft announced native AirPods mute
  for Teams on macOS Sonoma in 2024 (MC718244), unverified on current builds.
- The current default input (a USB audio device) exposes a settable input mute on
  element 0 and a settable volume scalar on element 1. The AirPods Pro 2 mic in headset
  mode is **not yet probed** — Milestone 1.
- The press only reaches an app that holds microphone input and observes
  `inputMuteStateChangeNotification` (see README, "macOS behaviours").

## Architecture

New units, each behind a protocol so the routing logic is unit-testable:

| Unit | Responsibility | Depends on |
|---|---|---|
| `MicUsageMonitor` (core, protocol `RecordingProcessSource`) | Lists processes other than ours that are currently recording, as bundle IDs, via the CoreAudio process objects (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyBundleID`; macOS 14.2+). Classifies each as `native` (on the native-handler list) or `handled-by-us`. | CoreAudio (adapter) |
| `SystemMicMute` (core, protocol `InputMuteDevice`) | Mutes/unmutes the current default input device: device mute property if settable, else volume scalar 0 with the previous volume remembered and restored. Reports which mechanism it used. | CoreAudio (adapter) |
| `MuteRouter` (core) | Pure decision: given (Meet call present?, recording processes), returns `meet`, `system(appNames)`, or `standAside`. Also decides whether the app should hold the mic. | — |
| `MuteSafety` (core, protocol `MuteFlagStore`) | Persists "we muted the device" (UserDefaults in the app); drives auto-unmute rules. | — |
| `AppDelegate` (app) | Poll asks the router each tick; holds/releases input accordingly; press handler dispatches to `MuteController` (Meet) or `SystemMicMute`; renders the menu. | all |

Native-handler list (bundle IDs, editable constant): Microsoft Teams desktop
(`com.microsoft.teams2`, `com.microsoft.teams`), FaceTime (`com.apple.FaceTime`).
Our own process is always excluded.

## Data flow

**Each poll (3 s):**

1. `MuteController.refresh()` (Meet tab, as today) and `MicUsageMonitor.recordingProcesses()`.
2. `MuteRouter` decides:
   - Meet call tab present → `meet`: hold the mic; sync the system mute state to Meet's (existing).
   - else any recording process not on the native list → `system`: hold the mic; mirror
     the device mute state into `AVAudioApplication` (guarded `syncSystemMute`).
   - else → `standAside`: release the mic, so native apps (or play/pause) get the press.
3. Leaving `system` (no non-native app recording any more) while we muted the device →
   auto-unmute (see Safety).

**Each press:**

- Route `meet` → existing Meet path.
- Route `system` → `SystemMicMute.setMuted(requested)`; on success play the cue, return
  true (the system records the state and plays the banner); on failure return false and
  surface the error.
- The handler never calls `setInputMuted` (re-entrancy rule from the Meet work).

## Safety — never leave the user silently muted

A stuck system mute silences the user in every app, so:

1. **Auto-unmute when the call ends**: when no non-native app is recording and no Meet
   call is present, undo a mute we applied.
2. **Unmute on launch** if the persisted flag says we left the device muted (crash,
   force-quit, reboot mid-call).
3. **Unmute on quit** (`applicationWillTerminate`).
4. **Only undo our own mute**: if the device was already muted when we started, or the
   user muted it elsewhere, leave it alone (flag is set only when *we* muted it).
5. **Default device changes** (AirPods disconnect mid-call): unmute the device we muted
   before acting on the new default; the flag records the device UID.

## Feedback and errors

- Same two-note cue and system banner as the Meet path.
- Menu shows `System mic muted — Slack` / `System mic live — Slack` (the recording apps'
  names), or `Standing aside — Teams handles AirPods mute`.
- Errors (device mute failed, process list unavailable on < 14.2, volume restore failed)
  appear as ⚠️ rows, like every other failure.

## Testing

- Unit (swift-testing): `MuteRouter` decisions for every combination (Meet ± recording
  apps ± native apps ± only us); `MuteSafety` rules (launch-unmute only with the flag,
  never undo a pre-existing mute, device-change handling) with fake device and store;
  `SystemMicMute` mechanism choice and volume restore with a fake device.
- Adapters (CoreAudio) stay thin and are exercised in the spike and live tests.
- Live: Slack huddle mute/unmute heard as silence by the other side (or loopback);
  Meet still uses its own button; Teams-in-browser takes the system path; kill -9 while
  muted → relaunch → device unmuted.

## Milestones

1. **Spike (needs Joel, AirPods connected)**: (a) does the AirPods headset-mode mic
   expose a settable input mute; (b) does a muted device send silence to a Slack huddle;
   (c) does a browser call show up as a recording process with the browser's bundle ID.
   (a) fails → volume fallback; (b) fails → stop and rethink.
2. Core: `MuteRouter`, `MuteSafety`, `SystemMicMute` logic with fakes, TDD.
3. CoreAudio adapters: process list and device mute/volume.
4. App wiring: routing in poll and press, safety hooks, menu text.
5. Live verification and README update.
