# WhisperKey

> Hold a key. Speak. Paste anywhere.

[![build](https://github.com/DzimitryB/whisperkey/actions/workflows/build.yml/badge.svg)](https://github.com/DzimitryB/whisperkey/actions/workflows/build.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)

Push-to-talk dictation for macOS. Hold a hotkey, speak, release — your speech is
transcribed and lands in the clipboard, ready to paste into any app. Runs **100%
offline** with whisper.cpp by default, or through the cloud engine of your choice.

| Recording | Transcribing | Done |
|---|---|---|
| ![Recording](docs/hud-recording.png) | ![Transcribing](docs/hud-processing.png) | ![Done](docs/hud-done.png) |

## Features

- **Push-to-talk** — hold ⌥ Space (or right ⌘, F13, F19…), release to transcribe; Esc cancels
- **Offline by default** — whisper.cpp on Metal, models run entirely on your Mac
- **Cloud engines, if you want them** — OpenAI, Groq, Google Gemini, ElevenLabs Scribe, Mistral Voxtral; automatic fallback to the local model when the network is down
- **Tiny HUD** — live mic levels while you speak, a spinner while it thinks, a checkmark when your text is ready
- **Model manager** — download and switch Whisper models right from the menu bar
- **Any language** — auto-detect or pin one
- **No noise** — menu bar only, no Dock icon, no telemetry, no accounts, a single ~200 KB binary

## Install

**Prebuilt:** grab `WhisperKey.zip` from [Releases](https://github.com/DzimitryB/whisperkey/releases),
unzip into `/Applications`, then right-click → Open on first launch (the app is not notarized).

**From source:**

```bash
git clone https://github.com/DzimitryB/whisperkey.git && cd whisperkey && ./build.sh
```

For the local engine, install [whisper.cpp](https://github.com/ggml-org/whisper.cpp) —
`brew install whisper-cpp` — and download a model from the app's menu
(large-v3-turbo quantized, ~574 MB, is a good default). Cloud engines need no local model:
just paste your API key in the menu.

## Usage

1. **Hold** the hotkey (default ⌥ Space) and speak.
2. **Release.** The HUD shows progress and a checkmark when the text is in your clipboard.
3. **⌘V** wherever you want it.

Everything is configurable from the menu bar icon: engine, model, language, hotkey,
toggle vs push-to-talk mode, optional auto-paste into the focused field, sounds.

## Engines

| Engine | Runs | Notes |
|---|---|---|
| whisper.cpp | on-device | free, private, offline |
| Groq — whisper-large-v3-turbo | cloud | fastest, ~$0.04/h |
| OpenAI — gpt-4o-transcribe / mini / whisper-1 | cloud | high accuracy |
| Google — Gemini 2.5 Flash / Flash-Lite | cloud | free tier, great punctuation |
| ElevenLabs — Scribe v2 | cloud | top benchmark accuracy, ~$0.22/h |
| Mistral — Voxtral Mini Transcribe 2 | cloud | ~$0.18/h |

API keys are stored in a user-only file (`chmod 600`), never leave your machine except
to the provider you picked, and cloud audio goes only to that provider. Local mode
sends nothing anywhere.

## Permissions

- **Microphone** — required to record.
- **Accessibility** — optional; only if you enable auto-paste or the right-⌘ hotkey.

## License

[MIT](LICENSE)
