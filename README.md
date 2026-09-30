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

## What it does

- **Flow bar**: a small pill at the bottom of the screen. It shows a live waveform while you talk, dots while it works, and ✕/■ buttons in hands-free mode. Hover over it for a hint, click it to start.
- **Smart formatting**: removes filler words (um, uh, you know) and stutters, handles punctuation by name ("comma", "question mark", "new paragraph"), and turns spoken lists into numbered lists.
- **Backtrack**: "at 2, actually 3" becomes "at 3". "Scratch that" removes the previous sentence.
- **AI auto-edits**: a local model applies the fuzzier fixes ("as a gift… as a present" becomes "as a present"). Guardrails stop it from answering questions or obeying instructions in your dictation.
- **Styles**: formatting per app type (Personal messages, Work messages, Email, Other), with Formal, Casual, very casual and Excited!
- **Dictionary**: names and jargon you add are passed to the speech model as hints and corrected automatically.
- **Snippets**: say a cue ("my calendar link") and get the full text.
- **History and stats**: every transcript, grouped by day, plus your streak, total words and words per minute.
- **Smart spacing**: a space is added automatically when you continue after existing text.
- **Clipboard**: text is inserted via a brief paste, and your clipboard is restored half a second later.
- Microphone picker, 100+ languages (auto-detect), quiet/whisper boost, sound effects, optional mute-while-dictating, launch at login.

## Test results from the overnight build

- **Unit tests**: 33/33 (`swift test`), covering text cleanup, styles, snippets, dictionary, stats and the shortcut state machine.
- **Speech accuracy**: 2% word error rate on synthetic test recordings, about 0.9 s per clip.
- **AI cleanup**: 20/20 tricky cases exact with Qwen3 4B, about 0.47 s each. The 1.7B model scores 17/20 at 0.22 s.
- **In-app pipeline**: 11/11 recordings exact, about 1.35 s from key release to text.
- **End-to-end** (real system key events, real paste into a live text field): 15/15. Covers hold-to-talk, smart spacing, backtrack, double-tap hands-free, quick-tap dismissal, Esc cancel, Command Mode, clipboard restore, mic format conversion and sounds.

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
