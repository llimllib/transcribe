# transcribe

A small command-line transcription tool built on Apple's new
`SpeechAnalyzer` / `SpeechTranscriber` APIs (macOS 26+, the replacement for
`SFSpeechRecognizer`). Runs fully on-device.

## Requirements

- macOS 26 or later
- On-device dictation model installed (see [troubleshooting](#troubleshooting) if missing)
- `ffmpeg` **only** for opus/ogg files (see [audio formats](#audio-formats) below)

## Install

`brew install llimllib/tap/transcribe`

## Usage

```sh
transcribe [-v] <audio-file> [locale]
```

- `-v` / `--verbose` prints diagnostics to stderr.
- `locale` defaults to `en-US`.

Examples:

```sh
transcribe recording.wav
transcribe -v speech.m4a en-US
```

## Quality

Apple's transcription quality on my sample file (an abridged recording of the "I Have a Dream" speech) comes in somewhere between whisper-large and whisper-tiny models, and very similar to the parakeet model:

| tool               |   WER | substitutions | deletions | insertions |
| ------------------ | ----: | ------------: | --------: | ---------: |
| cpp-large-v3-turbo |  3.0% |            13 |         2 |          7 |
| mlx-large-v3-turbo |  3.2% |            14 |         3 |          6 |
| parakeet-v2        |  6.1% |            15 |        21 |          8 |
| transcribe         |  7.5% |            37 |        13 |          4 |
| cpp-tiny           | 20.2% |            93 |        42 |         11 |
| mlx-tiny           | 26.1% |           128 |        34 |         27 |

WER means "word error rate"

You can see example outputs in the `quality` folder, and the comparison script

## Speed

On my computer, `transcript` is about equal to `mlx_whisper` and slightly slower than `whisper.cpp` when using `tiny` models. It's about 4x faster when using `large-v3-turbo` models:

```
Benchmark 1: apple transcribe
  Time (mean ± σ):      3.916 s ±  0.072 s    [User: 0.158 s, System: 0.039 s]
  Range (min … max):    3.838 s …  4.071 s    10 runs

Benchmark 2: mlx_whisper tiny
  Time (mean ± σ):      2.402 s ±  0.068 s    [User: 1.420 s, System: 0.452 s]
  Range (min … max):    2.293 s …  2.475 s    10 runs

Benchmark 3: mlx_whisper large-v3-turbo
  Time (mean ± σ):     10.305 s ±  0.053 s    [User: 1.708 s, System: 0.907 s]
  Range (min … max):   10.208 s … 10.398 s    10 runs

Benchmark 4: whisper.cpp tiny
  Time (mean ± σ):      2.808 s ±  0.051 s    [User: 2.733 s, System: 0.319 s]
  Range (min … max):    2.706 s …  2.887 s    10 runs

Benchmark 5: whisper.cpp large-v3-turbo
  Time (mean ± σ):     13.666 s ±  0.213 s    [User: 3.008 s, System: 0.732 s]
  Range (min … max):   13.461 s … 14.183 s    10 runs

Benchmark 6: parakeet-mlx parakeet-tdt-0.6b-v2
  Time (mean ± σ):      4.833 s ±  0.252 s    [User: 0.936 s, System: 1.299 s]
  Range (min … max):    4.546 s …  5.438 s    10 runs

Summary
  mlx_whisper tiny ran
    1.17 ± 0.04 times faster than whisper.cpp tiny
    1.63 ± 0.06 times faster than apple transcribe
    2.01 ± 0.12 times faster than parakeet-mlx parakeet-tdt-0.6b-v2
    4.29 ± 0.12 times faster than mlx_whisper large-v3-turbo
    5.69 ± 0.18 times faster than whisper.cpp large-v3-turbo
```

Run `benchmark.sh` to reproduce on your own machine

## Build

requires a swift compilation toolchain

```sh
make            # produces ./transcribe
make install    # installs to /usr/local/bin (override with PREFIX=...)
```

## Audio formats

The tool opens files directly with `AVAudioFile`, which uses Core Audio's
`ExtAudioFile`. These formats work with no conversion:

- `.wav`, `.aiff`, `.caf` (PCM)
- `.m4a` / AAC
- `.mp3`
- `.flac`

Just pass any of them straight to `transcribe` — no pre-processing needed.

### Opus / Ogg — the one exception

macOS has **no working decoder** for raw `.opus` / `.ogg` files: neither
`AVAudioFile`, `afconvert`, nor `AVAsset` can open them (they fail with
`'fmt?'` / `kAudioFileUnsupportedDataFormatError`). Despite `afconvert
--help-formats` _listing_ Ogg as readable, the decoder is not actually wired
in.

For these files, transcode with `ffmpeg` first:

```sh
ffmpeg -i input.opus out.wav
transcribe out.wav en-US
```

(`afconvert`, the built-in macOS converter, does not help here since it shares
the same non-functional Ogg path.)

## How it works

1. Create a `SpeechTranscriber(locale:)` module.
2. Ensure the on-device model assets for the locale are installed
   (`AssetInventory.assetInstallationRequest`).
3. Wrap it in a `SpeechAnalyzer(modules:)`.
4. Feed the file with `analyzeSequence(from:)`, which returns the last sample
   time, then call `finalizeAndFinish(through: lastSampleTime)`.
5. Drain the `transcriber.results` async stream concurrently.

### Gotchas worth knowing

- `@main` in a single-file program requires `swiftc -parse-as-library`.
- **Do not** use `finalizeAndFinishThroughEndOfInput()` with a file source — it
  never terminates the results stream and the program hangs. Capture
  `lastSampleTime` from `analyzeSequence(from:)` and use
  `finalizeAndFinish(through:)` instead. (A timeout guard is included as a
  safety net regardless.)

## Troubleshooting

### `locale ... not supported`, empty `supportedLocales`, or Dictation won't enable

If `transcribe` reports the locale isn't supported, or macOS **Settings →
Keyboard → Dictation** silently refuses to turn on (you click Enable and
nothing happens), the on-device speech model was never able to install.

A common root cause is a **root-owned preferences file** that the per-user
`assistantd` can't write to, so the `Dictation Enabled` flag never persists.

**Diagnose** — stream the log while toggling Dictation:

```sh
log stream --predicate 'process == "assistantd"'
```

Look for:

```
Couldn't write values for keys ("Dictation Enabled")
  in ... Domain: com.apple.assistant.support ...: Path not accessible
```

**Fix** — check ownership and reclaim the file if it's owned by `root`:

```sh
ls -la ~/Library/Preferences/com.apple.assistant.support.plist
# if owned by root:
sudo chown "$(whoami):staff" ~/Library/Preferences/com.apple.assistant.support.plist
```

Then re-enable Dictation in System Settings. The on-device model downloads
afterward, and `transcribe` will work. If the daemon is caching stale prefs,
`killall cfprefsd` and try again.

(This is a local-machine issue, not an MDM policy block — coworkers on the same
management profile are unaffected.)
