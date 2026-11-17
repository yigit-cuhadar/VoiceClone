import Darwin
import Foundation
import VoiceCloneCore
import VoiceCloneInfrastructure

@main
struct VoiceCloneProbe {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run(arguments: [String]) async throws {
        let usage = "Usage: VoiceCloneProbe [--offline] <int8|fp16> <en|tr> <reference-audio> <reference-transcript> <text> <output.wav>"
        if arguments == ["--help"] {
            print(usage)
            return
        }

        let offline = arguments.first == "--offline"
        let parameters = offline ? Array(arguments.dropFirst()) : arguments
        guard parameters.count == 6,
              let variant = OmniVoiceSynthesizer.Variant(rawValue: parameters[0]),
              let language = SpeechLanguage(rawValue: parameters[1]) else {
            throw ProbeError(usage)
        }

        let request = try SynthesisRequest(
            text: parameters[4],
            referenceAudio: URL(fileURLWithPath: parameters[2]).standardizedFileURL,
            referenceText: parameters[3],
            language: language
        )
        let outputURL = URL(fileURLWithPath: parameters[5]).standardizedFileURL
        guard outputURL.pathExtension.lowercased() == "wav",
              !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ProbeError("Specify a new output path with a .wav extension.")
        }
        let referenceSeconds = try AudioFiles.duration(of: request.referenceAudio)
        guard (1...15).contains(referenceSeconds) else {
            throw ProbeError("The prototype supports reference clips between 1 and 15 seconds.")
        }

        let start = ProcessInfo.processInfo.systemUptime
        let synthesizer = try await OmniVoiceSynthesizer.load(variant, offline: offline)
        let loaded = ProcessInfo.processInfo.systemUptime
        let synthesizeSpeech = SynthesizeSpeech(synthesizer: synthesizer)
        let audio = try synthesizeSpeech(request)
        let generated = ProcessInfo.processInfo.systemUptime

        try AudioFiles.writeWAV(audio, to: outputURL)
        var resources = rusage()
        let peakMiB = getrusage(RUSAGE_SELF, &resources) == 0
            ? Double(resources.ru_maxrss) / 1_048_576 : .nan
        print(String(format: "Model load %.2f s | Generation %.2f s | Audio %.2f s | Peak RSS %.0f MiB",
                     loaded - start, generated - loaded, audio.duration, peakMiB))
        print(outputURL.path)
    }
}

private struct ProbeError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
