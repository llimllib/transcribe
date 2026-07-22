# transcribe

A small command-line transcription tool built on Apple's new
`SpeechAnalyzer` / `SpeechTranscriber` APIs (macOS 26+, the replacement for
`SFSpeechRecognizer`). Runs fully on-device.

## Requirements

- macOS 26 or later
- A Swift 6 toolchain (`swiftc`)
- On-device dictation model installed (see Troubleshooting if missing)
- `ffmpeg` **only** for opus/ogg files (see Audio formats below)

## Build

```sh
make            # produces ./transcribe
make install    # installs to /usr/local/bin (override with PREFIX=...)
```

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
make run FILE=speech.wav LOCALE=en-US V=1
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
--help-formats` *listing* Ogg as readable, the decoder is not actually wired
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
