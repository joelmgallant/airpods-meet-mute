# Spike findings — AirPods gesture delivery

Date: 2026-11-09 · macOS 15.8.1 · AirPods Pro 2 (USB-C), Product ID 0x2024, firmware 9A348
(device name "ape-odds"; default input and output, Bluetooth, 1-channel headset profile during the call)

Browser: Vivaldi, live Google Meet call, mic unmuted.

## Run A — handler only

- GESTURE callback fired: **no** (log shows registration, then nothing across two presses)
- "can't control mic" banner: **yes**; Meet did nothing

## Run B — handler + input tap

- Input tap: `1 ch, 24000 Hz, Float32` on the AirPods mic; mic access granted
- GESTURE callback fired: **yes**, once per press:
  - `21:15:43Z GESTURE inputShouldBeMuted=true thread=background`
  - `21:15:46Z GESTURE inputShouldBeMuted=false thread=background`
- Each gesture was followed by `inputMuteStateChange` with `AVAudioApplicationMuteStateKey` 1 then 0
- Callback thread: **background** (handler must hop to main before AppleScript)
- Banner: the normal system mic on/off banner, **not** "can't control mic"; Meet did nothing (spike only logs)

## Meet DOM (live call, Vivaldi)

- Tab URL: `https://meet.google.com/meet/qrs-tuvw-xyz` — note the **`/meet/` path segment**
  before the meeting code. The plan's original pattern
  `^https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}` would not have matched.
- Buttons with data-is-muted:
  `[{"label":"Turn off microphone","muted":"false"},{"label":"Turn on camera","muted":"true"}]`
- Mic button aria-label: `Turn off microphone` (no keyboard-shortcut suffix); contains
  "microphone", so the selector `button[data-is-muted][aria-label*="microphone" i]` matches.
- The camera button also carries `data-is-muted`, confirming the aria-label filter is required.

## Decision

- HOLD_INPUT_DURING_CALLS: **true**
- **Continue.** Plan amendments: Meet URL pattern accepts an optional `meet/` segment
  (`^https://meet\.google\.com/(?:meet/)?[a-z]{3}-[a-z]{4}-[a-z]{3}(?:[/?#]|$)`); JS fixture
  labels use the observed text.
