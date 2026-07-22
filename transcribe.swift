import Foundation
import AVFoundation
import Speech

// Usage: transcribe [-v] <audio-file> [locale]
// e.g.   transcribe recording.m4a en-US
//        transcribe -v speech.wav en-US   (verbose diagnostics on stderr)

@main
struct Transcribe {
    static var verbose = false

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        if let i = args.firstIndex(of: "-v") ?? args.firstIndex(of: "--verbose") {
            verbose = true
            args.remove(at: i)
        }
        // Allow output redirection to a file via TRANSCRIBE_OUT (useful when
        // launched as an .app bundle where stdout is not a terminal).
        let outPath = ProcessInfo.processInfo.environment["TRANSCRIBE_OUT"]
        guard args.count >= 1 else {
            FileHandle.standardError.write(Data("usage: transcribe [-v] <audio-file> [locale]\n".utf8))
            exit(2)
        }

        let url = URL(fileURLWithPath: args[0])
        let localeID = args.count >= 2 ? args[1] : "en-US"
        let locale = Locale(identifier: localeID)

        do {
            try await run(url: url, locale: locale, outPath: outPath)
        } catch {
            let msg = "error: \(error)\n"
            if let outPath { try? msg.write(toFile: outPath, atomically: true, encoding: .utf8) }
            FileHandle.standardError.write(Data(msg.utf8))
            exit(1)
        }
    }

    static func log(_ s: String) {
        guard verbose else { return }
        FileHandle.standardError.write(Data("[transcribe] \(s)\n".utf8))
    }

    static func run(url: URL, locale: Locale, outPath: String?) async throws {
        log("creating transcriber for \(locale.identifier)")
        // 1. Create the transcriber module.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],           // add .volatileResults for partials
            attributeOptions: [.audioTimeRange]
        )

        // 2. Make sure the on-device model assets are installed.
        log("ensuring model...")
        try await ensureModel(transcriber: transcriber, locale: locale)
        log("model ready")

        // 3. Build the analyzer and open the file.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        log("opened \(url.lastPathComponent); format=\(file.processingFormat); frames=\(file.length); dur=\(String(format: "%.1f", duration))s")

        // 5. Consume results concurrently.
        let resultsTask = Task<String, Error> {
            var full = ""
            log("results loop started")
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                log("got result (\(text.count) chars, isFinal=\(result.isFinal))")
                full += text
                print(text, terminator: "")
            }
            log("results loop ended")
            return full
        }

        // 6. Feed the whole file, then finalize THROUGH the last sample time.
        //    (finalizeAndFinishThroughEndOfInput never terminates for a file source.)
        log("analyzeSequence starting")
        do {
            let lastSampleTime = try await analyzer.analyzeSequence(from: file)
            log("analyzeSequence returned lastSampleTime=\(String(describing: lastSampleTime))")
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                resultsTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw NSError(domain: "transcribe", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "no audio samples received"])
            }
        } catch {
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        log("finalized; awaiting results (with timeout)")

        // 7. Wait for the results stream to drain, with a safety timeout.
        let timeout = max(20.0, duration * 4.0 + 10.0)
        let full = try await withThrowingTaskGroup(of: String.self) { group -> String in
            group.addTask { try await resultsTask.value }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(domain: "transcribe", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "result stream timed out"])
            }
            defer { group.cancelAll() }
            guard let r = try await group.next() else { return "" }
            return r
        }

        print("")
        if let outPath { try? full.write(toFile: outPath, atomically: true, encoding: .utf8) }
        log("done")
    }

    static func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let target = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == target }) else {
            throw NSError(domain: "transcribe", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "locale \(locale.identifier) not supported"])
        }

        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == target }) {
            return
        }

        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            FileHandle.standardError.write(Data("downloading model assets...\n".utf8))
            try await request.downloadAndInstall()
        }
    }
}
