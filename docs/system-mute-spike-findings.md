# System-wide mute spike findings

Date: 2026-11-11 · macOS 15.8.1 · input: AirPods Pro 2 ("ape-odds", UID `<bt-mac>:input`)

## AirPods input controls (headset mode)

- Input mute settable: **yes** (`kAudioDevicePropertyMute`, input scope, main element)
- Volume scalar settable: main element (not needed)
- A USB audio interface tested earlier also has a settable input mute (plus volume on elements 1–2)
- **MUTE_MECHANISM: deviceMute**

## Silence check (probe `level`, 5 s each, with a Slack huddle holding the headset link open)

| Device mute | Samples | Peak | RMS |
|---|---|---|---|
| off (user not yet talking) | 118,784 | 0.00157 | -81.4 dBFS |
| **on** | 118,784 | **0.00000** | **digital silence** |
| off (talking) | 118,784 | 0.17218 | -32.0 dBFS |

Samples flowed in every window, so the muted window is the driver zeroing the input, not a
dead link.

- **Slack huddle while device-muted: speaking ring stayed dark; Slack heard nothing.**
- Pitfall: with no other app holding the mic, the first recording after the AirPods switch
  into headset mode can deliver **0 samples even when unmuted** (link still coming up).
  "0 samples" is not evidence of muting; test with a call holding the link open.
- `say` once hung for two minutes on the Bluetooth route right after a mute/unmute while
  the AirPods were switching modes; unrelated to the mute itself (device state was correct).

## Recorders

- **BACKGROUND_RECORDERS (no call): none** (checked with both the USB mic and the AirPods as input)
- Slack huddle recorder: `com.tinyspeck.slackmacgap.helper`
- **BROWSER_RECORDER_BUNDLE_ID** (Vivaldi Meet): `com.vivaldi.Vivaldi.helper`
- Our own app appears in the list while it holds the mic (`com.joelmgallant.AirPodsMeetMute`)
  — the adapter must exclude our PID.
- `NSRunningApplication(processIdentifier:)` has no name for helper PIDs (`name=?`) —
  display names must come from the owning app's bundle ID.

## Decision

- **Continue.** Device mute works on the AirPods and silences Slack.
- `ignoredRecorderBundleIDs` starts empty.
