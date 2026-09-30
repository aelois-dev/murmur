# Murmur

A private, on-device voice dictation app for macOS, modelled closely on Wispr Flow. Hold a key, talk, release: your words appear, cleaned up, wherever your cursor is.

Everything runs on your Mac. Speech recognition uses Whisper Large v3 Turbo on the Neural Engine (via WhisperKit), and text editing uses a local Qwen3 language model (via llama.cpp). No audio or text leaves your computer.

## First launch (about 2 minutes)

1. Open **Murmur** from `/Applications` (or Spotlight). The onboarding window appears.
2. **Microphone**: click *Allow*.
3. **Accessibility**: click *Allow*. System Settings opens; switch **Murmur** on. This lets Murmur hear your shortcut in every app and paste text.
4. **The 🌐/fn key**: your Mac currently has *Press 🌐 key to → Change Input Source*. You have two options:
   - In **System Settings → Keyboard**, set *Press 🌐 key to* **Do Nothing**, then switch input sources with ⌃Space; or
   - Keep your setting. Murmur puts your keyboard layout back after each dictation, and a quick tap of fn still switches input source. If fn still misbehaves, pick another key (for example Right ⌥) in onboarding or Settings.
5. Click into any text box, **hold fn**, speak, release.

The models are already downloaded and prepared, so dictation works straight away.

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
- Microphone picker, 100+ languages (auto-detect), quiet/whisper boost, sound effects, optional mute-while-dictating, launch at login.

## Test results from the overnight build

- **Unit tests**: 43/43 (`swift test`), covering text cleanup, styles, snippets, dictionary, correction learning, stats, audio analysis and the shortcut state machine.
- **Speech accuracy**: 2% word error rate on synthetic test recordings, about 0.9 s per clip.
- **AI cleanup**: 22/24 tricky cases exact with Qwen3 4B (all 20 base cases, plus 2 of 4 context cases), about 0.48 s each. The 1.7B model scores 17/20 on the base cases at 0.22 s. Guardrails catch prompt-injection attempts and echoed context.
- **In-app pipeline**: 11/11 recordings exact, about 1.35 s from key release to text.
- **End-to-end** (real system key events, real paste into a live text field): 19/19. Covers hold-to-talk, about 0.2 s release-to-text after a pause, smart spacing, backtrack, double-tap hands-free, ⌃⌘V, quick-tap dismissal, Esc cancel, context spelling, auto-learning, Command Mode, clipboard restore, mic format conversion and sounds.
- **Idle CPU**: about 0.6% in the background.

## Good to know

- The app is signed "ad-hoc" (no Apple developer account). macOS ties Accessibility permission to the exact build, so **after rebuilding, remove Murmur from System Settings → Privacy & Security → Accessibility and add it again**. To avoid this, sign into Xcode with your Apple ID; the build script then uses your free *Apple Development* certificate automatically.
- If you switch to a speech model that hasn't been used before, the first load takes several minutes while macOS prepares it for the Neural Engine. After that it loads in about 5 s.
- Memory use is about 4–5 GB with the 4B AI model. Pick *Qwen3 1.7B* in Settings → AI editing for a lighter, faster (slightly less clever) editor.
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
MURMUR_SUPPORT_DIR=/tmp/murmur-test build/Murmur.app/Contents/MacOS/Murmur --selftest TestAudio/cases.json
MURMUR_SUPPORT_DIR=/tmp/murmur-test build/Murmur.app/Contents/MacOS/Murmur --e2e TestAudio   # needs Accessibility for the launching app
build/Murmur.app/Contents/MacOS/Murmur --snapshot /tmp/murmur-snaps                         # renders every screen to PNG
```

## Layout

- `Sources/MurmurCore`: pure logic (text cleanup, styles, snippets, dictionary, stats, shortcut state machine, settings)
- `Sources/MurmurEngine`: WhisperKit transcriber, llama.cpp runner (KV-cache reuse and prompt-lookup speculative decoding), AI editor with guardrails, text pipeline
- `Sources/Murmur`: the app (hotkeys, audio, paste, Flow bar, hub window, onboarding, menu bar, self-tests)
- `Sources/MurmurEval`: command-line benchmark harness
- `Vendor/llama.xcframework`: prebuilt llama.cpp (b11292)
