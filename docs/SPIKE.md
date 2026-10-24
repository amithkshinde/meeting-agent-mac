# Phase 0 spike: test plan

Goal from the PRD: record three real calls cleanly, with no virtual audio driver, across Meet, Teams and Zoom. This build has no transcription or suggestions yet. It only answers whether call detection and capture are reliable on a real Mac.

## Important: this code has not been compiled yet

It was written without access to a Mac or the Swift toolchain, so expect a few compile errors on the first build. Fix them, then run the checks below. If a ScreenCaptureKit name differs in your SDK, that is the likeliest cause.

Requires macOS 15 or later (it uses `SCRecordingOutput` and ScreenCaptureKit microphone capture, which arrived in macOS 15) and Xcode 16 or the matching Swift toolchain.

## Build and run

```bash
scripts/build-app.sh          # builds build/MeetingAgent.app, ad-hoc signed
open build/MeetingAgent.app
swift test                    # runs the call-detection rule tests
```

macOS forgets the Screen Recording permission each time an ad-hoc build changes. To avoid that, create a self-signed code-signing certificate named "Meeting Agent Dev" in Keychain Access and run `scripts/build-app.sh "Meeting Agent Dev"`.

On first record, macOS will ask for Microphone and Screen Recording. After allowing Screen Recording, quit and reopen the app once.

## What you should see

- A small dot in the menu bar and a floating window at the top right of the screen.
- When a call starts: "Looks like a Google Meet call. Record this one?" Tick "Record detected calls automatically" in the menu to skip the prompt (off by default).
- While recording: a red dot, a timer, and a Stop button.
- When the call window closes: recording stops on its own after about 5 seconds.
- Files in `~/Movies/MeetingAgent/<date>_<app>/`: `screen.mp4`, `system.m4a` (other people), `mic.m4a` (you), `meta.json`.
- A running log in `~/Movies/MeetingAgent/spike-log.txt`.

The floating window is hidden from screen sharing and from the recording itself.

## Checks to run for each of Meet, Teams and Zoom

| Check | Pass when |
| --- | --- |
| Unscheduled call is noticed | Prompt appears within about 5 s of joining, with no calendar event |
| Recording starts | Folder appears with all three media files |
| `mic.m4a` has only you | Play it: your voice, not theirs |
| `system.m4a` has only them | Play it: other people, not you, and no echo of your own voice |
| Video plays with sound in sync | Open `screen.mp4` and check lips against audio |
| Recording ends with the call | Stops within about 5 s of leaving, no manual Stop |
| Window is not in the share | Share your screen to a second device or person and confirm the panel is invisible |
| Cost | Activity Monitor shows CPU under 25% on Apple silicon; note fan noise and battery |
| Long call | 45 minutes or more records without a gap or a truncated file |

Also try: headphones versus speakers, a call on a second monitor, the call tab not being the active browser tab, a Teams chat window open next to a Teams call, and a full-screen call.

## Known limits to expect

- A browser only reports its active tab's title. A Meet call in a background tab is not seen yet. Reading the tab URL needs Accessibility permission or a companion extension.
- A minimised call window or one on another Space is not seen.
- Teams is detected from "Teams window plus microphone in use". While we record, the microphone is held by this app, so call end for Teams is judged from the window alone and may not stop on its own. Stop manually and note it in the log.
- Screen recording uses the first display only.
- Audio capture on the display's audio output can miss calls routed to a specific device. Note any call where `system.m4a` is silent.

## What to send back

The contents of `spike-log.txt`, and for each call: app, what happened against the table above, and anything strange. The "Log visible windows" menu item prints every window title during a call and is the fastest way to tune the detection rules.
