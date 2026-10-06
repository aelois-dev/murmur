# Murmur

A private, on-device voice dictation app for macOS, modelled closely on Wispr Flow. Hold a key, talk, release: your words appear, cleaned up, wherever your cursor is.

Everything runs on your Mac. Speech recognition uses Whisper Large v3 Turbo on the Neural Engine (via WhisperKit), and text editing uses a local Qwen3 language model (via llama.cpp). No audio or text leaves your computer.

## ⬇️ Download the app

**[Download Murmur.zip (latest version)](https://github.com/aelois-dev/murmur/releases/latest/download/Murmur.zip)**. You need to be signed in to GitHub, because this repo is private.

The app isn't in the file list above: it's attached to each [release](https://github.com/aelois-dev/murmur/releases). Unzip it, drag **Murmur** into **Applications**, and see [Install on another Mac](#install-on-another-mac) for the first-launch steps.

## First launch (about 2 minutes)

**You need a microphone.** A Mac mini has no built-in mic, and the only input on your Mac right now is "Microsoft Teams Audio", a virtual device. Connect AirPods, a headset, a webcam or a USB mic first. Onboarding includes a live mic test with a device picker.

1. Open **Murmur** from `/Applications` (or Spotlight). The onboarding window appears.
2. **Microphone**: click *Allow*.
3. **Accessibility**: click *Allow*. System Settings opens; switch **Murmur** on. This lets Murmur hear your shortcut in every app and paste text.
4. **The 🌐/fn key**: your Mac currently has *Press 🌐 key to → Change Input Source*. You have two options:
   - In **System Settings → Keyboard**, set *Press 🌐 key to* **Do Nothing**, then switch input sources with ⌃Space; or
   - Keep your setting. Murmur puts your keyboard layout back after each dictation, and a quick tap of fn still switches input source. If fn still misbehaves, pick another key (for example Right ⌥) in onboarding or Settings.
5. Click into any text box, **hold fn**, speak, release.

The models are already downloaded and prepared, so dictation works straight away.

## Install on another Mac

1. Download `Murmur-<version>.zip` from this repo's **Releases** page, unzip it, and drag **Murmur.app** into **Applications**.
2. First launch: macOS blocks apps that aren't notarized, so do one of these:
   - Double-click Murmur, click **Done**, then go to **System Settings → Privacy & Security** and click **Open Anyway** (you'll confirm with your password); or
   - Run `xattr -dr com.apple.quarantine /Applications/Murmur.app` in Terminal, then open it normally.
3. Follow the onboarding: allow **Microphone** and **Accessibility**, and check the mic test (you need a microphone; AirPods are fine).
4. The speech model (632 MB) downloads automatically. The first time on each Mac, macOS then prepares it for the Neural Engine, which takes several minutes (about 15 on an M1, less on newer chips). For AI editing and Command Mode, click **Download** for the AI model (2.5 GB) in onboarding or Settings → AI editing.

Updates: download the newer release and replace the app. It's signed with the same certificate, so the permissions carry over.

## Shortcuts (same as Wispr Flow)

| Action | Keys |
|---|---|
| Push to talk | Hold **fn**, release to insert |
| Hands-free | **Double-tap fn**, or **fn + Space**, or click the Flow bar. Tap fn again (or click ■) to finish |
| Command Mode | Select text, hold **fn + ⌃**, say an instruction ("make this more formal", "translate to Spanish"), release |
| Cancel | **Esc** while recording, or click ✕. The notice offers *Undo* |
| Paste last transcript | **⌃⌘V** |

## What it does

- **Flow bar**: a small pill at the bottom of the screen. It shows a live waveform while you talk, dots while it works, and ✕/■ buttons in hands-free mode. Hover over it for a hint, click it to start.
- **Smart formatting**: removes filler words (um, uh, you know) and stutters, handles punctuation by name ("comma", "question mark", "new paragraph"), and turns spoken lists into numbered lists.
- **Backtrack**: "at 2, actually 3" becomes "at 3". "Scratch that" removes the previous sentence.
- **AI auto-edits**: a local model applies the fuzzier fixes ("as a gift… as a present" becomes "as a present"). Guardrails stop it from answering questions or obeying instructions in your dictation.
- **Styles**: formatting per app type (Personal messages, Work messages, Email, Other), with Formal, Casual, very casual and Excited!
- **Dictionary**: names and jargon you add are passed to the speech model as hints and corrected automatically.
- **Snippets**: say a cue ("my calendar link") and get the full text.
- **History and stats**: every transcript, grouped by day, plus your streak, total words and words per minute.
- **Smart spacing and continuation**: a space is added when you continue after existing text, and a sentence you're continuing doesn't get a stray capital.
- **Context awareness**: the app you're in and the text just before your cursor help spell names correctly. If "Siobhan" is already in the email, you get "Siobhan", not "Shivon".
- **Learns from corrections**: if you fix a name or term Murmur typed, it's added to your Dictionary automatically. Ordinary words are never added.
- **Fast**: Murmur starts transcribing during your natural pause before you release the key, so text usually appears about 0.2 s after you let go (about 0.6–1.3 s if you release mid-sentence).
- **Clipboard**: text is inserted via a brief paste, and your clipboard is restored half a second later.
- **Languages**: 100+ with auto-detect. Chinese is tested: it gets full-width punctuation and AI cleanup that keeps it in Chinese. Long dictations (30 s and up) are chunked automatically.
- Microphone picker, quiet/whisper boost, sound effects, optional mute-while-dictating, launch at login.

## Test results from the overnight build

- **Unit tests**: 46/46 (`swift test`), covering text cleanup, styles, snippets, dictionary, correction learning, stats, audio analysis and the shortcut state machine.
- **Speech accuracy**: 2% word error rate on synthetic test recordings, about 0.9 s per clip.
- **AI cleanup**: 22/24 tricky cases exact with Qwen3 4B (all 20 base cases, plus 2 of 4 context cases), about 0.48 s each. The 1.7B model scores 17/20 on the base cases at 0.22 s. Guardrails catch prompt-injection attempts and echoed context.
- **In-app pipeline**: 11/11 recordings exact (about 1.3 s without the pause trick). A 34-second multi-paragraph update came out word-perfect, and a Chinese sentence was correct with full-width punctuation.
- **End-to-end** (real system key events, real paste into a live text field): 19/19. Covers hold-to-talk, about 0.2 s release-to-text after a pause, smart spacing, backtrack, double-tap hands-free, ⌃⌘V, quick-tap dismissal, Esc cancel, context spelling, auto-learning, Command Mode, clipboard restore, mic format conversion and sounds.
- **Idle CPU**: about 0.6% in the background.

## Good to know

- **AirPods/Bluetooth mics** take about 1.5 s to switch on. The start chime plays when the mic is actually listening (the Flow bar shows a pulsing mic until then), so wait for it. Afterwards the mic stays ready for 1 minute so back-to-back dictations start instantly (Settings → Keep microphone ready).
- **Your words are never reworded.** The AI may only drop fillers, fix punctuation and apply real self-corrections; anything else it changed is put back.

- The app is signed with your **Apple Development** certificate (team YJTAS82KYW), so macOS keeps its Accessibility and Microphone permissions across rebuilds. The certificate expires on 1 Oct 2027; renew it in Xcode → Settings → Accounts → Manage Certificates. The build script falls back to ad-hoc signing if no certificate is found, and then permissions must be re-granted after every rebuild.
- If you switch to a speech model that hasn't been used before, the first load takes several minutes while macOS prepares it for the Neural Engine. After that it loads in about 5 s.
- **Choosing models:** pick them during setup, in Settings, or from the menu bar (Speech Model / AI Model). Only models that fit the Mac's memory are listed, and the best fit is marked *Recommended* and preselected on a fresh install:
  - **16 GB Macs:** Large v3 Turbo speech plus the Qwen3 4B editor (about 4–5 GB of memory in use). Qwen3 1.7B is lighter and faster. A bigger Qwen3 8B tested slower and no better, so it isn't offered.
  - **32 GB+ Macs (e.g. 48 GB):** full-precision Large v3 Turbo plus the **Qwen3 30B-A3B** editor (18.6 GB download): best quality, and still fast.
  - Downloads resume if interrupted and check free disk space first. Settings → AI editing → *Downloaded models* lets you remove ones you don't use.
- Logs: `~/Library/Application Support/Murmur/murmur.log`. Data (history, dictionary, snippets, settings) lives in the same folder.

## Building

```bash
cd ~/Murmur
scripts/build-app.sh release --install     # build, sign, copy to /Applications
swift test                                  # unit tests
```

Evaluation and test harnesses:

```bash
.build/release/murmur-eval stt  openai_whisper-large-v3-v20240930_turbo_632MB TestAudio/cases.json
.build/release/murmur-eval text Qwen3-4B-Instruct-2507-Q4_K_M TestAudio/text-cases.json
MURMUR_SUPPORT_DIR=/tmp/murmur-test .build/app/Murmur.app/Contents/MacOS/Murmur --selftest TestAudio/cases.json
MURMUR_SUPPORT_DIR=/tmp/murmur-test .build/app/Murmur.app/Contents/MacOS/Murmur --e2e TestAudio   # needs Accessibility for the launching app
.build/app/Murmur.app/Contents/MacOS/Murmur --snapshot /tmp/murmur-snaps                         # renders every screen to PNG
```

## Layout

- `Sources/MurmurCore`: pure logic (text cleanup, styles, snippets, dictionary, stats, shortcut state machine, settings)
- `Sources/MurmurEngine`: WhisperKit transcriber, llama.cpp runner (KV-cache reuse and prompt-lookup speculative decoding), AI editor with guardrails, text pipeline
- `Sources/Murmur`: the app (hotkeys, audio, paste, Flow bar, hub window, onboarding, menu bar, self-tests)
- `Sources/MurmurEval`: command-line benchmark harness
- `Vendor/llama.xcframework`: prebuilt llama.cpp (b11292)
