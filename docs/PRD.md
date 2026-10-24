# Meeting Agent: PRD

Oct 16, 2026 · Amith K Shinde

A floating Mac agent that notices when you join a call, records and transcribes it, and coaches you live using what was said in earlier conversations with the same client.

## Problem and vision

You forget what was said in earlier calls, and you can't take notes and think on your feet at the same time. Existing note-takers (bots that join the call, or cloud tools you have to start by hand) record the call but don't help you in the moment, and they're visible to the other side.

Meeting Agent is a small floating window on your Mac. It notices when a call starts in Google Meet, Teams, Zoom or any other app, records screen and audio, transcribes in real time, and while the other person talks it shows you a question to ask or a point to push back on, drawn from your earlier conversations with that person. After the call it leaves you a summary, action items and the full recording.

**Primary user:** Amith, a product designer who runs client calls (requirements, reviews, negotiation) and needs to carry context from one call to the next. The same need applies to anyone who sits in many calls: consultants, sales, founders, freelancers.

**Why on-device, not a bot:** no "Notetaker has joined" tile, no meeting-admin permission needed, works on any call app, and client audio can stay on your machine.

## Goals, non-goals and success metrics

**Goals**

- Start recording on its own within 10 seconds of you joining a call, with no manual step.
- Capture screen, your mic and the other participants' audio, and produce a full transcript with speaker labels.
- Show a useful suggestion within 3 seconds of the other person finishing a point.
- Remember every client across calls, so suggestions use real history instead of generic advice.
- Keep everything on your Mac by default.

**Non-goals (v1)**

- Windows, Linux, iOS or Android.
- Joining calls as a bot or sending anything to other participants.
- Team workspaces, sharing, or CRM sync.
- Speaking on your behalf or auto-replying.

| Metric | Target for v1 |
| --- | --- |
| Calls auto-detected without manual start | 95% or more |
| Missed or truncated recordings | Under 2% of calls |
| Transcript word error rate (clear English audio) | Under 10% |
| Suggestion latency (end of client speech to card shown) | Under 3 s median |
| Suggestions you rate useful or use | 40% or more |
| CPU use during a call on Apple silicon | Under 25% average |

## Key user scenarios

**Before the call.** The agent sees an upcoming calendar event with a client you've spoken to before. Five minutes ahead, the floating window shows a short brief: what was agreed last time, what is still open, and two questions worth raising.

**You click a Meet link.** The window wakes up, shows "Recording Client X, Google Meet", and starts capturing. You do nothing.

**An unscheduled call.** A client pings you on Teams and you pick up. There is no calendar event, but the agent sees the call window and live mic and starts as if it had been planned, asking you to confirm who it is.

**The client raises a concern.** While they speak, the live transcript scrolls. When they finish, a card appears: "They said the timeline is too long. On Sept 12 they accepted a two-phase rollout. Ask: which phase is non-negotiable?"

**The client contradicts an earlier statement.** The agent flags it: "Last call they said budget was fixed at X. Now they're asking for more scope." You can use it as a rebuttal.

**You zone out for a minute.** The recap strip already shows the last few points. You tap "Catch me up" and see: pricing was raised, they asked for a revised timeline by Friday, and they asked you about the second option. You re-join the conversation without asking them to repeat it.

**You leave the call.** Recording stops, a summary, decisions and action items are ready in about a minute, and everything is filed under that client.

**You open it a week later** and ask, "What did Client X say about pricing across all calls?"

## Functional requirements

P0 = needed for the first usable build, P1 = v1, P2 = later.

| ID | Requirement | Priority |
| --- | --- | --- |
| **Call detection** | | |
| F1 | Detect an active call in Google Meet, Microsoft Teams, Zoom and Slack huddles, by watching for apps and browser tabs that hold the mic and camera and have a call window open | P0 |
| F1a | Catch calls that were never scheduled: watch the screen for a call starting (a join or leave button, a participant grid, a call window opening, the mic going live) and treat it as a new call even with no calendar event or known link | P0 |
| F2 | Detect call end and stop recording within 5 s | P0 |
| F3 | Read the calendar event for the call to get title, attendees and client name | P1 |
| F4 | Ask once per new client or domain: record always, ask each time, or never | P0 |
| **Capture** | | |
| F5 | Record the screen (the call window or full display, user's choice) at 1080p max | P0 |
| F6 | Record system audio (other participants) and microphone (you) as separate tracks | P0 |
| F7 | Save locally in an open format (MP4 plus separate audio) and survive a crash without losing the file | P0 |
| F8 | Pause and resume, and a one-click "stop and delete this call" | P0 |
| **Transcription** | | |
| F9 | Live transcript with a delay under 2 s | P0 |
| F10 | Speaker labels: you versus others at minimum, individual names where the call app shows them | P1 |
| F11 | English and Hindi, including mixed-language speech | P1 |
| **Live copilot** | | |
| F12 | After each client turn, show up to one suggestion card: a question, a rebuttal, or a contradiction flag | P0 |
| F13 | Each card cites the earlier call and moment it came from, with one click to play that clip | P1 |
| F14 | Thumbs up or down on each card, used to tune future suggestions | P1 |
| F15 | Quiet mode: only show cards when you press a key | P1 |
| **Memory** | | |
| F16 | Store transcripts, summaries and facts per client, searchable | P0 |
| F17 | Pre-call brief generated from history | P1 |
| F18 | Post-call summary, decisions, action items and open questions | P0 |
| F19 | Ask questions across all past calls in plain language | P2 |
| **Control and data** | | |
| F20 | Edit or delete any transcript, memory item or recording | P0 |
| F21 | Export to Markdown, PDF and the Notion or Google Docs of your choice | P2 |
| **Catch-up (when you drift off)** | | |
| F22 | Rolling recap: a live strip of the last 3 to 5 points discussed, each one line, with who said it, refreshed whenever the topic shifts | P0 |
| F23 | "Catch me up" button and hotkey: instantly shows what was said in the last 1, 3 or 5 minutes as three short bullets, ready in under 1 s because recaps are prepared in the background | P0 |
| F24 | "You were asked" alert: when someone says your name or asks you a direct question and you have not replied, show the question and how many seconds ago it was asked | P1 |
| F25 | Pin a point: tap any recap line to keep it on screen until you dismiss it, for something you want to come back to | P1 |

## Live copilot

The copilot is the part that makes this more than a recorder, and the part most likely to annoy you if it talks too much. It should feel like a quiet colleague who only taps your shoulder when it has something worth saying.

**What triggers a card.** The client finishes a turn (a pause of about 1 s after speech) and that turn contains a claim, an objection, a number, a commitment or a question. Small talk and filler never trigger one.

**Three card types**

1. **Ask:** a follow-up question that digs into what they just said or fills a gap from earlier calls.
2. **Push back:** a rebuttal or counterpoint, grounded in something they or you said before.
3. **Flag:** a contradiction, a changed number, or a commitment they made that they are now stepping away from.

**Rules for cards**

- At most one card at a time, and at most one every 20 seconds. A new card replaces the old one if you haven't acted on it.
- Every card is under 25 words and says where it came from ("Call of Sept 12, 14:03").
- No card without a source in your history or the current call. If the agent has nothing grounded to say, it says nothing.
- Cards are only ever visible to you, never shared on screen if you present (the window hides itself during screen share).
- You can set a stance per client (collaborative, firm, exploratory) which changes how rebuttals are worded.

**How it works, in short.** Each finished client turn is sent with the last few minutes of transcript and the top matching memory items for that client to a language model. The model returns either "no card" or one card in a fixed format. See the technical section for latency and on-device options.

**Catch-up, the second job of the window.** Alongside suggestions, the agent keeps you oriented. It summarises the call in small chunks every 20 to 30 seconds, so a recap is ready before you ask. The recap strip always shows the last few points; "Catch me up" expands the last 1, 3 or 5 minutes; and "You were asked" appears if someone addresses you while you have been quiet. Catch-up never competes with a suggestion card: if both are due, the "you were asked" alert goes first.

## Floating agent UX

The agent lives in the menu bar and as a small always-on-top window that you can drag anywhere. It never takes keyboard focus unless you ask it to, so it won't interrupt typing in the call.

| State | What you see | Trigger |
| --- | --- | --- |
| Idle | A tiny dot or pill, dimmed | No call detected |
| Call found | Pill expands: "Looks like a Meet call with Client X. Record?" (auto-starts after 5 s if the client is set to always) | Call detected |
| Recording | Red dot, timer, live transcript lines, current suggestion card | Recording active |
| Suggesting | Card slides in under the transcript with Ask, Push back or Flag label | Client turn ends |
| Paused | Grey dot, "Paused" | You pause |
| Wrapping up | "Writing your summary" with progress | Call ends |
| Done | Summary card with Open and Delete buttons | Summary ready |

**Recap strip.** A pinned area at the top of the window, above the live transcript, showing the last 3 to 5 points as one-liners with timestamps. It updates quietly with no animation that pulls your eye. A "Catch me up" button (default hotkey Cmd+Shift+R) expands it to the last 1, 3 or 5 minutes. A "You were asked" alert is the only element that pulses, once.

**Controls.** Pause, stop, delete this call, quiet mode, and a hotkey to show or hide the window (default Cmd+Shift+M). While you share your screen, the window hides itself so the other side never sees it.

**Visual feel.** Compact, translucent, and readable at a glance, roughly 320 by 420 px. Card text is large enough to read in half a second. Detailed design (layouts, motion, dark and light) is a separate design pass, and is the natural place for your own design work.

## Technical approach on macOS

A native Swift and SwiftUI app, running as a menu bar agent, is the recommended base. It gets the best access to the system capture APIs, uses little power, and installs as one app. The names below are my best understanding of the Apple APIs and should be confirmed in a short technical spike before any build commitment.

| Layer | Recommended approach | Alternative or note |
| --- | --- | --- |
| Call detection | Watch running apps and which ones hold the microphone, then confirm with the call app's window title, the browser tab URL (meet.google.com, teams.microsoft.com, zoom.us) and on-screen call cues (join or leave button, participant grid, mute control) read from the screen, so unscheduled calls are caught too | Browser tab URLs need either Accessibility permission or a small companion browser extension |
| Screen capture | ScreenCaptureKit, capturing the call window or a display | Needs the Screen Recording permission |
| Other participants' audio | ScreenCaptureKit app audio, or a Core Audio process tap on the call app | Avoids a virtual audio driver such as BlackHole, which users find hard to set up |
| Your microphone | AVAudioEngine input, kept as its own track | Separate tracks give you free "you versus them" speaker labels |
| Live transcription | On-device Whisper-family model (WhisperKit or whisper.cpp) running on the Neural Engine, or Apple's own on-device speech APIs | Cloud ASR (Deepgram, AssemblyAI) is faster to build and better on Hindi and accents, but sends audio off the Mac |
| Speaker names | Diarization model for multi-person calls; call app's active-speaker highlight as a hint | Hardest part to get right on group calls |
| Memory | Local SQLite with a vector index; chunks of transcript, summaries and extracted facts, tagged by client | Embeddings can run on-device |
| Suggestion model | Claude via API with only the relevant transcript snippets sent, never the video | A small on-device model for an offline mode, with lower quality |
| Storage | Files in the user's chosen folder, encrypted at rest with a Keychain key | Auto-delete rules per client |

**Latency budget for a suggestion (target under 3 s).** Transcription finalises the turn: about 0.5 to 1 s. Memory lookup: under 0.2 s. Model call: about 1.5 s with a fast model and a short prompt. Rendering: instant.

**Permissions the app will ask for.** Microphone, Screen Recording, Accessibility (for window titles), Calendar (optional), and Notifications. The onboarding flow has to walk through these one at a time, because macOS makes this clumsy and it is the biggest drop-off risk.

**Distribution.** Direct download, signed and notarized, outside the Mac App Store, because the App Store sandbox makes system audio capture difficult. Requires macOS 14.2 or later at minimum.

## Privacy, consent and legal

This is the area where a silent recorder can hurt you, so it is a product requirement, not an afterthought. I'm not a lawyer; the points below need review by one before you record real client calls.

- **Consent rules differ by place.** Some US states and some countries require every participant to agree to a recording, and the rules follow the participants' locations, not only yours. The EU's GDPR and India's Digital Personal Data Protection Act also treat voice and transcripts as personal data, which brings notice and purpose requirements. Your clients' contracts and NDAs may add their own limits, especially in defence and finance work.
- **So the product has a consent mode.** Per client you choose: announce at the start (the agent can show a one-line reminder for you to say, "I'm recording this for notes, is that okay?"), ask first, or record silently where you've confirmed it's lawful. The default is announce.
- **Never record without a visible local indicator for you.** The red dot and menu bar icon are always on while capturing.
- **Local by default.** Video and audio never leave the Mac. Only short text snippets go to the language model, and only when copilot is on. A fully offline mode turns the cloud model and cloud transcription off.
- **Control.** One click deletes any call, and a per-client retention setting (for example, delete recordings after 30 days, keep summaries).
- **No training on your data**, and a plain-language data-flow screen in settings showing exactly what leaves the device.
- **Sensitive clients.** A "never record" list, and an automatic pause when a call app shows a confidentiality banner or when the calendar event title contains words you choose.

## Phasing

Build the risky, unglamorous parts first (capture and detection). The copilot is only as good as the transcript under it.

| Phase | Scope | Exit gate |
| --- | --- | --- |
| 0. Spike (about 1 week) | Prove call detection, system audio plus mic capture, and screen capture on your own Mac across Meet, Teams and Zoom | Three real calls recorded cleanly with no virtual audio driver |
| 1. Recorder MVP (about 3 weeks) | Floating window, auto-start and stop (including unscheduled calls spotted from the screen), rolling recap and Catch me up, local files, live transcript, you-versus-them labels, post-call summary, delete controls, consent mode | You use it on every call for two weeks without a missed recording |
| 2. Memory (about 2 weeks) | Per-client store, calendar link, pre-call brief, search across calls | Brief for a repeat client is judged accurate on 8 of 10 calls |
| 3. Live copilot (about 3 weeks) | Ask, Push back and Flag cards with sources, rating, quiet mode, hide-on-share | 40% of cards rated useful over 20 calls, and no card shown that you felt was wrong or noisy more than 1 in 10 |
| 4. Polish for others | Onboarding for permissions, signed installer, Hindi support, export, auto-update | Five outside testers complete setup unaided |

Estimates assume one builder working with AI coding help and are rough.

## Risks and open questions

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Recording-consent law and client contracts | A recorded call can breach a law or an NDA | Consent mode on by default, never-record list, lawyer review before real use |
| macOS permissions are clumsy and change between releases | Users give up at setup, or capture silently breaks after an OS update | Guided onboarding, a health check that tests capture before each call, a quick OS-update test pass |
| Wrong or noisy suggestions | One bad rebuttal in front of a client costs trust | Sources on every card, "say nothing" as the default, rate-limit, quiet mode |
| Transcript quality on accents, Hindi and crosstalk | Bad transcript means bad suggestions | Benchmark on your own call audio in the spike; allow a cloud ASR option |
| Latency | A late suggestion arrives after the moment has passed | Short prompts, fast model, stream the card as it is generated |
| Window visible on screen share | Embarrassing and possibly damaging | Auto-hide when sharing, tested per call app |
| Battery and heat during long calls | Fans spinning during a call | Run ASR on the Neural Engine, cap frame rate for screen capture |

**Open questions**

- [ ] Is this for your own use first, or do you plan to sell it? It changes how much to invest in onboarding and compliance.
- [ ] Which call apps matter most? Meet and Teams are assumed; is Zoom needed from day one?
- [ ] Which languages are on your client calls (English only, or Hindi and others)?
- [ ] Are any clients under NDA or in defence work where cloud processing of snippets isn't allowed?
- [ ] Do you want the silent-recording option at all, or consent announcement always on?
- [ ] Where does the prior-conversation history live today: past recordings, TwinMind, notes, email? An import step could seed the memory on day one.
- [ ] Which macOS version and chip do you and your clients' machines run?
