# apple-wyoming

A [Wyoming](https://github.com/rhasspy/wyoming) speech-to-text server for Home Assistant, backed by Apple's
on-device dictation (`SpeechAnalyzer` + `DictationTranscriber`, macOS 26+).

Audio comes from your Assist satellites over the network; the Mac's microphone is never used. Recognition runs
fully on-device: nothing leaves the machine.

## Why

On a French benchmark of 25 short voice commands (synthesized, 600 ms of trailing silence, real-time pacing),
on a Mac mini M4:

| Engine                                     | WER  | Median latency¹ | p90    |
|--------------------------------------------|------|-----------------|--------|
| apple-wyoming, `--engine dictation`        | 2.4% | ~50 ms          | ~65 ms |
| apple-wyoming, `--engine speech`           | 3.4% | ~90 ms          | —      |
| Vosk (Wyoming add-on, Intel N100)          | 6.6% | 165 ms          | 245 ms |

¹ From the end of the audio (`audio-stop`) to the transcript.

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon
- Xcode 26 or later to build
- A logged-in user session: the Speech framework does not run from a LaunchDaemon

The language model is downloaded on first start if it is not installed yet.

## Install

### Homebrew

```sh
brew tap juliendeveaux/tap
brew install apple-wyoming
brew services start apple-wyoming
```

The service listens on `0.0.0.0:10300` and logs to `$(brew --prefix)/var/log/apple-wyoming.log`.

### From source

```sh
swift build -c release
sudo install -m 755 .build/release/apple-wyoming /usr/local/bin/
cp contrib/io.github.juliendeveaux.apple-wyoming.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.juliendeveaux.apple-wyoming.plist
```

## Home Assistant

1. **Settings → Devices & services → Add integration → Wyoming Protocol**
2. Host: the Mac's IP address, port: `10300`
3. **Settings → Voice assistants** → pick your assistant → **Speech-to-text**: `apple-dictation`

If the macOS firewall is on, allow incoming connections for `apple-wyoming` when asked.

## Usage

```
usage: apple-wyoming [--host ADDR] [--port N] [--engine dictation|speech] [--locale ID]
  --host    IPv4 address to listen on (default 0.0.0.0)
  --port    TCP port (default 10300)
  --engine  dictation: Apple's dictation model, punctuation and digits (default)
            speech:    SpeechTranscriber, the general transcription model (better on long monologues)
  --locale  language, e.g. fr-FR, en-US (default fr-FR)
  --version print the version
```

With Homebrew, change the arguments in the formula's service or run the binary yourself.

### Which engine

- `dictation` (default): fastest and most accurate on voice commands. On long, multi-sentence monologues it can
  drop a segment.
- `speech`: slightly slower, keeps everything on long dictation.

## Notes

- Input: 16-bit PCM, 8–96 kHz, 1–8 channels (downmixed and resampled internally). Invalid audio gets an empty
  transcript instead of a dropped connection.
- Connections idle for 30 s are closed; at most 32 concurrent connections.
- The Mac must stay awake: a sleeping Mac answers no satellite.

## Benchmark

`bench/` holds the corpus phrases and a Wyoming client that measures WER and latency against any Wyoming STT
server:

```sh
bench/make-corpus.sh                       # synthesizes bench/corpus/*.wav with the French macOS voices
cd bench && PAD_MS=600 python3 wyobench.py HOST PORT [LABEL]
```

`PAD_MS` appends trailing silence, as a real satellite does after you stop speaking.
