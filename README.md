# Meeting Agent

A floating Mac agent that notices when you join a call, records and transcribes it, coaches you live using what was said in earlier conversations, and keeps everything organised by project so you can ask questions about all of it later.

Built by Amith K Shinde. Native macOS app in Swift and SwiftUI. Free and open source (MIT).

On Windows? See **[meeting-agent-windows](https://github.com/amithkshinde/meeting-agent-windows)**.

## Install (no Terminal needed)

1. Download or clone this folder.
2. Double-click **Install Meeting Agent.command**. The first time, right-click it and choose Open.
3. Wait for "Built". The app opens by itself.
4. Follow the checklist on the Home screen (Screen Recording, Microphone, Speech Recognition, AI key).

Needs macOS 15 or later (macOS 26 recommended for the better speech engine and the on-device AI). To build by hand:

```bash
cd path/to/meeting-agent-mac
scripts/build-app.sh
open build/MeetingAgent.app
```

## Download

Ready-made installers are on the **[Releases page](https://github.com/amithkshinde/meeting-agent-mac/releases/latest)**. Pick the file that matches your Mac:

| File | Which Macs it is for |
|---|---|
| `MeetingAgent-0.1.0-arm64.dmg` | **Apple Silicon** Macs (M1, M2, M3, M4). Needs macOS 15 or later. |
| `MeetingAgent-0.1.0-intel.dmg` | **Intel** Macs. Needs macOS 15 or later. |

Not sure which Mac you have? Click the Apple menu, then **About This Mac**. If it says "Chip: Apple M…", it is Apple Silicon. If it says "Processor: Intel…", it is Intel.

### How to install it

1. **Download the right `.dmg`** from the Releases page.
2. **Open it** by double-clicking. A window opens with the app, an Applications folder shortcut and a `READ ME FIRST.txt`.
3. **Drag Meeting Agent onto Applications.**
4. **Open it the first time.** macOS shows a warning because the app is not signed with an Apple Developer ID. Open Meeting Agent from Applications and click Done. Then go to System Settings > Privacy & Security, scroll to the Security section, click Open Anyway, and enter your Mac password. You only do this once. (Shortcut: in the Terminal, run `xattr -dr com.apple.quarantine "/Applications/Meeting Agent.app"` and open the app normally.)
5. **Follow the setup inside the app** (about three minutes): allow Screen Recording, Microphone and Speech Recognition, then connect the AI. The app explains how to get a free Gemini key or a Claude key, or you can use the Mac's built-in AI (Apple Silicon only).

### Making a fresh installer

The installers on the Releases page are snapshots and do not update by themselves. After you change the code, make new ones on your Mac:

1. Double-click **Make Installer.command**. It takes a few minutes and builds both installers.
2. A folder called `dist` opens with `MeetingAgent-<version>-arm64.dmg` and `MeetingAgent-<version>-intel.dmg` inside. This folder stays on your Mac and is not part of the repository.
3. To share them, create a new release on GitHub (**Releases > Draft a new release**) and drag both files into it.

## Run it from the Terminal

Open the Terminal app and go to the project folder (change the path to wherever you saved it):

```bash
cd path/to/meeting-agent-mac
```

If you get "permission denied" on a script, run this once: `chmod +x scripts/*.sh *.command`

| What you want | Command |
|---|---|
| Build and open the app | `scripts/build-app.sh && open build/MeetingAgent.app` |
| Build, copy into Applications and open | `scripts/install.sh` |
| Build the shareable installer (Apple Silicon and Intel), saved in `dist/` | `scripts/make-installer.sh` |
| Build only a universal app, no disk image | `UNIVERSAL=1 scripts/build-app.sh` |
| One-time: create the signing certificate so macOS keeps permissions between builds | `scripts/setup-signing.sh` |
| Run the app with its messages shown in the Terminal | `build/MeetingAgent.app/Contents/MacOS/MeetingAgent` |
| Watch the log while it runs | `tail -f ~/Movies/MeetingAgent/spike-log.txt` |
| Run the tests | `swift test` |
| Quit a running copy | `pkill -x MeetingAgent` |
| Open the recordings folder | `open ~/Movies/MeetingAgent` |
| Clear a macOS "can't be opened" block on a copy you were sent | `xattr -dr com.apple.quarantine "/Applications/Meeting Agent.app"` |

You need Xcode or the Xcode Command Line Tools (`xcode-select --install`) to build. People who only receive the installer do not.

## What it does

**During a call**
- Detects Meet, Teams, Zoom and other calls, including ones that were never on your calendar, and offers to record.
- Records screen, call audio and your microphone to your Mac, with no bot joining the call.
- Live transcript (English, Hindi, Kannada and others), with "You" and "Them" labels.
- Live recap and cards: a question to ask, a point to push back on, or a flag. Each card says where it comes from.
- Catch me up and Last minute buttons, and a chat you can ask anything.
- Quiet mode hides suggestions until you peek.
- Global shortcuts (Control + Option): **M** show or hide the window, **A** ask a question, **S** peek at suggestions, **R** start or stop recording, **B** bookmark this moment.
- **Bookmarks:** press Control + Option + B (or the Mark button) to flag a moment. They appear as a Highlights list after the call, each one jumping to that point in the video.
- **Who is speaking:** when the call is in Google Meet, the app reads the outline Meet draws around the active speaker and the name on that tile, and shows "speaking now" in the floating window.
- **Design review mode:** when the shared screen changes a lot (a new Figma frame, the next slide), a screenshot is saved automatically.

**After a call**
- **Video synced to the transcript:** open a call and click any transcript line to jump the video to that moment. The line being played is highlighted.
- **Real names on the transcript:** "Them" lines are renamed to the person the video showed speaking, where it is confident. The original is kept as `transcript-raw.txt`. You can also rename a speaker by hand (right-click a line).
- **Design review:** the Screens tab groups the talk under each screenshot, and the summary gets a "By screen" section ("Screen 1: these 3 comments"). One AI request can summarise the feedback per screen.
- **Search everything (Command + K):** one box across every call, transcript line, summary, note, file, email, promise and project. A transcript hit opens the video at that moment.
- **Share menu:** export a call as PDF or Markdown (Notion, Obsidian and most editors open the Markdown), add promises to the Reminders app, or send them to a Notion database.
- **Hindi and Hinglish:** choose "Hindi and English mixed" as the spoken language, choose whether the cleaned transcript is written in Roman letters or Devanagari, and translate any call into English from its Transcript tab.
- **Older calls:** a call recorded before these features can be run through "Analyse the video" on its page, to find the speakers and screens after the fact.
- Transcript clean-up pass for Hindi, Hinglish and names (the original is kept too).
- Summary with decisions, action items and open questions.
- Promises are pulled out automatically into one list: what you owe, and what others owe you, with due dates.
- Draft a follow-up email in one click. It opens in your mail app and nothing is sent for you.
- Interrupted calls (crash, restart, sleep) are recovered on the next launch.

**Projects and memory**
- A project holds calls, files, emails and notes, plus an AI-written brief.
- Ask questions across a project. Every answer lists the exact call, file or email it came from, with an Open button.
- Live suggestions use everything in the project, including open promises.

**Calendar**
- Connect the Mac's Calendar (Google Calendar works once your Google account is added in System Settings > Internet Accounts).
- A briefing appears a few minutes before each meeting: last time, open promises, questions to ask.
- The calendar invite names the people on the call and files the call under the right project.

**Privacy**
- Recordings, transcripts and notes stay on your Mac, in Movies > MeetingAgent.
- Only text is ever sent to the AI, never audio or video. The key is kept in the macOS Keychain.
- Choose "On this Mac only" in Settings, or per project, to use Apple's on-device model so nothing leaves the Mac. Projects marked this way are also kept out of cloud searches.
- Tell people on the call that you are recording. Laws on recording differ by place.

## AI key

The cloud AI uses either a free Google Gemini key (https://aistudio.google.com/apikey) or an Anthropic Claude key (https://console.anthropic.com/settings/keys), or the Mac's built-in AI. Settings > AI assistant > Set up AI walks you through getting and pasting a key. Free Gemini keys allow only about 20 requests a day, so live suggestions slow down and stop early to leave room for the call summary. Free Google keys may let Google use what you send to improve its products, so use a paid key or the on-device option for confidential work.

## Feedback

Open **Feedback** in the sidebar (or **Help > Send Feedback…**). Pick a type, write a note, and choose whether to
put your name on it. Giving a name and email is optional but welcome, because it lets me write back if I want to
understand something or talk it through. You can also stay fully anonymous. Nothing from your calls is ever
included: only your note, and optionally the app version, macOS version and chip.

Prefer GitHub? [Open an issue](https://github.com/amithkshinde/meeting-agent-mac/issues/new/choose). If you fork this
project and want feedback delivered to you, see [docs/FEEDBACK-SETUP.md](docs/FEEDBACK-SETUP.md).

## License and contributing

Meeting Agent is open source under the [MIT License](LICENSE). You can use it, fork it, change it and build on it, including in commercial work, as long as you keep the copyright and license notice.

To build on it: fork the repository on GitHub, clone your fork, and build with `Install Meeting Agent.command` (or `scripts/build-app.sh`). Pull requests are welcome. If you fork it and make it better, please let me know as well, so that I can see what you changed and learn from it. If you share a modified build, please use your own name and app icon so people can tell it apart from this one.

The software comes with no warranty. You are responsible for telling people on a call that you are recording, and for following the recording laws where you are.

## Project layout

- `Sources/MeetingAgent`: the app. `AppDelegate` wires everything; `CallDetector`, `CallRecorder`, `LiveTranscriber` and `ModernTranscriber` handle calls, capture and speech; `PostCall` writes notes and promises; `CalendarService` does briefings; `Knowledge` holds projects and retrieval; `MainView`, `ProjectPage`, `PromisesView`, `SettingsView` and `PanelView` are the screens.
- `scripts/`: `build-app.sh`, `install.sh`, `setup-signing.sh` (a stable signing certificate so macOS keeps your permissions between builds).
- `docs/`: [Product requirements](docs/PRD.md) and the [original spike test plan](docs/SPIKE.md).

## Known limits

This is an early version. These are the things that do not work well yet.

**Speed**
- It is slow in places, and speeding it up is in progress. After a call, cleaning the transcript, writing the summary, finding promises and refreshing the project brief are separate AI requests that run one after another. Live suggestions arrive every 30 seconds at best, and every two minutes or slower on a free Gemini key.

**AI limits (Gemini)**
- A free Gemini key allows only about 20 AI requests per 24 hours (seen in practice on `gemini-3.8-flash`). After that, every AI feature stops until the limit resets, roughly 19 hours later: call summaries, cleaned transcripts, promises, project briefs, live suggestions, and chat.
- Transcription keeps working, because it uses Apple's speech engine on your Mac and does not use the AI key.
- To stay inside the limit, live suggestions on a Gemini key slow down and stop after about 10 requests a day, so the call summary still has room. That makes live suggestions of little use on a free key.
- There is no "retry" button yet. If a summary fails, it stays without one, and you cannot re-run it later.
- A Claude key (pay as you go) has no such tight daily limit.

**Who said what**
- Naming speakers works by watching the video, not by recognising voices. It looks for the outline Google Meet draws around the person speaking and reads the name on that tile. It was checked on real Google Meet recordings. It has not been tested with Zoom, Teams or other apps, and it needs the participant tiles to be visible on screen (if the call window is hidden or covered, or Meet shows only the presenter, it has nothing to read).
- When two people talk at once, or one transcript line holds two speakers, the line stays "Them" or gets the more likely name. Expect a few wrong or missing names, and fix them by right-clicking a line.
- People who join by phone, or whose tile is never outlined, stay "Them".
- If you use laptop speakers instead of headphones, the other people's voices leak into your microphone and can be labelled "You". Headphones fix most of this.

**Transcription**
- It uses Apple's on-device speech engine, and accuracy varies. It mishears names and jargon, drops quiet or overlapping speech, and misreads music and TV in the background.
- English works best. Hindi and Hinglish are a first version: the "Hinglish" setting runs Apple's Hindi recogniser, which tends to write English words in Devanagari, and the AI clean-up can turn that into Roman letters. This has not been tested on real Hindi calls. Translation to English is done after the call by the AI (so it uses AI requests), and there is no live translation yet. Kannada support varies by Mac.

**Video and storage**
- Video is about 400 MB per hour at the current setting (HEVC, up to 1080p, 10 fps), plus about 45 MB per hour per audio track. Small text can look soft. Screenshots add roughly 100 to 200 KB each (at most 150 per call).
- There is no video quality setting, audio-only mode, or automatic deletion of old recordings yet.

**On-device AI**
- It needs an Apple Silicon Mac on macOS 26 with Apple Intelligence turned on. It is not available on Intel Macs.
- It has a small context window, so answers are shorter and long calls are trimmed.

**Installing and sharing**
- The installer is not signed with an Apple Developer ID, so macOS shows a one-time warning on another Mac (System Settings > Privacy & Security > Open Anyway).
- The Intel installer may not have been tried on every kind of Intel Mac. Intel Macs without hardware video encoding may run hotter or slower while recording.
- Rebuilding the app with a different signing certificate makes macOS ask for permissions again.
- After allowing Screen Recording, macOS may need you to quit and reopen the app.

**Recording and detection**
- Call detection is a best guess for Meet, Teams, Zoom and similar apps. If it misses a call, press Start recording yourself.
- The Mac going to sleep stops a recording. The app saves what it has and recovers the interrupted call the next time it opens.
- The calendar briefing only reads calendars in macOS Calendar. For Google Calendar, add your Google account in System Settings > Internet Accounts first.

**Privacy and data**
- With a cloud AI key, the text of transcripts, notes and files is sent to Google or Anthropic. Audio and video never leave your Mac. Free Google keys may let Google use what you send to improve its products. Use the on-device option, or mark a project "On this Mac only", for confidential work.
- Everything is stored in plain files on your Mac (in `~/Movies/MeetingAgent`). There is no sync, no backup and no encryption of its own.
- Always tell people on the call that you are recording. Laws on recording differ by place.

**Newer features, not fully tested**
- These were written and checked in pieces, and the speaker outline finder was run on real recordings, but the whole app with all of them has had little real-world use. Expect rough edges.
- Reminders needs you to allow access the first time. Notion needs a free integration secret and a database shared with it (Settings walks through it). Notion rows get a title, a due date (if the database has a date column) and a note, nothing else.
- PDF export is plain text layout without the screenshots. Use Markdown if you want the structure intact.
- Search matches words, not meaning, so "budget" will not find "pricing".
- Bookmarks only exist for calls recorded after this feature was added.

**Not built yet**
- Direct Gmail import. In Gmail, download an email (⋮ > Download message) and drag the .eml file onto a project.
- iPhone and iPad versions. This is a Mac app for macOS 15 or later. A first Windows version lives in [meeting-agent-windows](https://github.com/amithkshinde/meeting-agent-windows).

## Roadmap

Direct Gmail sync, voice-based speaker separation (for calls where the video does not show who is speaking), live translation, video quality setting and automatic deletion of old recordings, a retry button for failed AI steps, notarized distribution.
