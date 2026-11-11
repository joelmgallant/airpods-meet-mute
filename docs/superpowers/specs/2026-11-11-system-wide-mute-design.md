# System-wide AirPods Mute — Design

Date: 2026-11-11
Status: Implemented 2026-11-11; updated after the final review (per-device mute, all-or-nothing, audible mid-call unmute)
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
| Mute mechanism | CoreAudio input-scope `kAudioDevicePropertyMute` on **each input device the call app captures from** (the default input when that is unknown); fallback: input volume scalar → 0 and restore |

## Environment facts (2026-11-11)

- Slack 4.53 (`com.tinyspeck.slackmacgap`) shows no sign of supporting the AirPods mute
  gesture. Teams desktop is not installed; Microsoft announced native AirPods mute for
  Teams on macOS Sonoma in 2024 (MC718244), unverified on current builds.
- Probed (`docs/system-mute-spike-findings.md`): the AirPods Pro 2 mic in headset mode
  exposes a **settable input mute** (main element), and muting it silences a Slack huddle.
  A USB audio interface also has a settable input mute.
- The AirPods only send the mute gesture while a call app records from the AirPods mic; a call
  on another mic (verified with Slack on a USB device) gets no gesture, and our silent input
  hold does not count as a call, so such calls are not stem-controllable.
- No background recorders were seen without a call, so the ignore list starts empty.
- The press only reaches an app that holds microphone input and observes
  `inputMuteStateChangeNotification` (see README, "macOS behaviours").

## Architecture

Core units are pure or sit behind a protocol, so routing and safety are unit-tested with fakes:

| Unit | Responsibility |
|---|---|
| `decideRoute` / `MuteRoute` (`MuteRoute.swift`) | Pure decision from (Meet call present?, recorders): `.meet`, `.standAside(nativeAppNames)`, `.system(appNames)` or `.idle`; `holdsMic` says when to hold the mic. `callRecorders` drops known background recorders. |
| `RouteTracker` | Turns each poll's readings into a route, riding out a Meet script error or a failed/empty recorder listing for 2 polls; remembers `systemRecorders`, the recorders behind the current `.system` route. |
| `targetInputDeviceUIDs` | The devices a system mute must silence: the de-duplicated union of the recorders' input devices, plus the default input if any recorder's devices are unknown. |
| `SystemMicMuter` | `mute`/`unmute(deviceUIDs:)`, `restoreIfWeMuted() -> Bool`, `muteState(deviceUIDs:) -> InputMuteState` (muted / live / mixed). Device mute if settable, else volume 0 with the old level recorded. |
| `MuteRecordStore` (`UserDefaultsMuteRecordStore`) | One `MuteRecord` per device we muted (UID, mechanism, previous volume). |
| CoreAudio adapters | `CoreAudioRecordingProcessSource` (process objects, `kAudioProcessPropertyIsRunningInput`, input-scope `kAudioProcessPropertyDevices`; macOS 14.2+) and `CoreAudioInputDeviceProvider` / `CoreAudioInputDevice`. Thin, smoke-tested. |
| App (`AppDelegate`, `SystemMuteRestore`) | Poll, press dispatch, auto-unmute with its notices, menu. |

Native-handler list (editable constant): Teams desktop (`com.microsoft.teams2`,
`com.microsoft.teams`), FaceTime (`com.apple.FaceTime`). Browser helpers count as their
browser. Our own process is excluded.

## Data flow

**Each poll (3 s):** refresh Meet and list recorders, then `RouteTracker` decides:

- Meet call tab → `.meet`: hold the mic; sync the system mute state to Meet's.
- else a native handler recording → `.standAside`: release the mic so it gets the press.
- else any other call recorder → `.system`: hold the mic; mirror `isMuted` of the target
  devices into `AVAudioApplication` (guarded sync, skipped just after a press).
- else → `.idle`: release the mic.

Any route other than `.system` runs `restoreIfWeMuted()` (a no-op without records).

**Each press:** `.meet` → Meet's button. `.system` → `mute`/`unmute` on
`targetInputDeviceUIDs(systemRecorders)`; success plays the cue and returns true (the
system records the state); failure returns false and shows the error. `.standAside`/`.idle`
→ false. The handler never calls `setInputMuted` (re-entrancy).

## Safety — never silently muted, never silently unmuted mid-call

1. **Per-device records, written before the mute.** A crash in between leaves a record for
   an unmuted device (harmless), never a muted device without one. A failed device write
   rolls the record back. Only recorded mutes are undone automatically; a mute that was
   already there (set by the user or another app) is never claimed.
2. **All-or-nothing mute.** If any target fails, the devices this press muted are unmuted
   again and their records dropped; the error names the failed devices.
3. **Auto-unmute off the `.system` route**, on launch (crash, force-quit, reboot) and on
   quit. SIGTERM is routed through `NSApp.terminate` so quit runs; SIGKILL is covered by
   the launch restore. An unreadable record fails safe by unmuting the default input.
4. **Absent devices keep their records** and are restored when they return (verified live:
   AirPods disconnected while muted reconnect unmuted, so the restore changes nothing).
5. **Unknown is not "nothing recording".** A failed or empty recorder listing after `.system`
   holds the route for 2 polls, so a glitch or an AirPods mode switch can't unmute mid-call.
6. **A mid-call auto-unmute is audible.** If we unmute while an app may still be on a call
   (Meet started, a native handler took over, the listing is unknown), the unmute cue plays
   and a one-shot menu notice says why. A plain call end stays silent.
7. **Switching devices:** a mute press first restores our mutes on devices the call no
   longer uses; an explicit unmute restores all of ours and clears a foreign mute on the targets.

## Feedback and errors

- Same two-note cue and system banner as the Meet path.
- Menu shows `System mic muted — Slack` / `System mic live — Slack`, or
  `Standing aside — Microsoft Teams handles AirPods mute`.
- Errors and one-shot notices appear as ⚠️ rows; the title appends ⚠️ to the mute state
  (`🎧🔇⚠️`) instead of hiding it.

## Testing

- Unit (swift-testing): route decisions, `RouteTracker` tolerance, target devices,
  `SystemMicMuter` safety rules (record-first, rollback, all-or-nothing, absent devices,
  unreadable record, volume fallback) with fake devices and store, menu text.
- CoreAudio adapters: read-only smoke tests plus live checks.
- Live (2026-11-11): Slack mute/unmute, auto-unmute, crash recovery, Meet path,
  AirPods disconnect.
