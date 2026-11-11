# AirPods Meet Mute

Press an AirPods Pro stem during a call to mute or unmute yourself — in Google Meet
(Vivaldi or Chrome) and in any other call app (Slack huddles, Teams in a browser, Zoom…).
In Meet it presses Meet's own mic button, so Meet's UI stays truthful. Everywhere else it
mutes the microphone device itself, so the app receives silence; that app's own mic icon
will still look unmuted, so trust the menu-bar icon.

## How it works

A menu-bar agent registers for the macOS 14+ AirPods mute gesture
(`AVAudioApplication.setInputMuteStateChangeHandler`). On a press it finds the Meet
call tab through AppleScript and runs a small script in the page that sets the mic
button. A 3-second poll keeps the menu icon and the system mute state in sync with
Meet, so clicking Meet's button with the mouse doesn't leave the next press backwards.

Menu icon: 🎧 no call · 🎧🎙️ unmuted · 🎧🔇 muted · 🎧⚠️ needs attention (open the menu).

### macOS behaviours this depends on (found live, 2026-11-09)

- **The gesture only reaches an app that is recording.** The app holds a silent
  microphone input while a Meet call is open and releases it when the call ends
  (`docs/spike-findings.md`). Outside calls, stem presses behave normally.
- **Registering the handler is not enough to opt in.** The app must also observe
  `AVAudioApplication.inputMuteStateChangeNotification`; that is what sets the
  `PrefersBluetoothAccessoryMutingMacOS` property on the audio server. Without it,
  `audiomxd` logs `no recording audio apps found that are opted in to input muting`
  and every press is silently rejected.
- **`setInputMuted` calls your own mute handler.** Calling it from inside the handler
  stops the system from recording the new state, and calling it while the handler is
  running on the same queue crashes in libdispatch. The handler ignores calls made
  during our own sync, and the press path never calls `setInputMuted`: returning
  `true` already makes the system record the requested state.

Debug the audio server's side of a press with:
`/usr/bin/log show --last 5m --predicate 'process == "audiomxd" AND eventMessage CONTAINS "InputMuteAction"'`

### System-wide mute

- The app takes over the stem only while another app is recording from the mic, and
  stands aside for apps that handle AirPods mute themselves (Teams desktop, FaceTime).
- It mutes the default input device (CoreAudio input mute, or input volume 0 where the
  device has no mute) and never leaves you muted: it unmutes when the call ends, on quit
  (including `kill`), and on the next launch after a crash. A mute you set elsewhere is
  never undone automatically.
- One failed read of which apps are recording doesn't unmute you mid-call; the call
  route is held for two polls first.
- `swift scripts/system-mute-probe.swift status|list` shows the device mute state and
  which apps are recording. Findings: `docs/system-mute-spike-findings.md`.

## Setup

1. Build and install:
   `scripts/build-app.sh AirPodsMeetMute && rm -rf ~/Applications/AirPodsMeetMute.app && ditto build/AirPodsMeetMute.app ~/Applications/AirPodsMeetMute.app`
2. In **every** Vivaldi/Chrome profile you take Meet calls from, enable
   JavaScript from Apple Events. Chrome: View › Developer › Allow JavaScript from
   Apple Events. Vivaldi has no menu item: quit Vivaldi fully, then set
   `"browser": {"allow_javascript_apple_events": true}` in
   `~/Library/Application Support/Vivaldi/<Profile>/Preferences` (it is per profile).
3. Launch the app and approve: Automation for Vivaldi/Chrome, and Microphone.
4. Menu › Launch at Login.

## Development

- `swift test` — unit tests for the core (tab matching, AppleScript bridge, controller)
- `scripts/test-js.sh` — the in-page script against a fixture, in headless Chrome
- `osascript scripts/probe-meet.applescript com.vivaldi.Vivaldi` — live Meet button state
- `scripts/make-icon.sh` / `scripts/make-sounds.sh` — regenerate the app icon and the press sounds (mute = high→low, unmute = low→high)
- `scripts/build-app.sh MeetMuteSpike` — the original gesture-delivery spike (logs to
  `~/Library/Logs/MeetMuteSpike.log`; `open -n build/MeetMuteSpike.app --args tap`)
- Builds are signed with your first Apple Development identity (any free Apple ID
  works via Xcode › Settings › Accounts) so privacy grants survive rebuilds; override
  with `CODESIGN_IDENTITY=...`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Menu: Automation not allowed | System Settings › Privacy & Security › Automation › AirPods Meet Mute |
| Menu: turn on Allow JavaScript from Apple Events | Setup step 2, in the profile that owns the Meet window |
| Menu: no mic button was found | Meet changed its DOM: run the probe, update the selector in `Sources/MeetMuteCore/MeetToggleJS.swift` and the labels in `Tests/js/meet-toggle.test.js` |
| Menu: Microphone access denied | System Settings › Privacy & Security › Microphone |
| Press does nothing, no banner | Check `audiomxd` with the log command above; "not opted in" means the notification observer is missing |
