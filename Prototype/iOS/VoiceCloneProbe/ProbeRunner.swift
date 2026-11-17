import Darwin
import Foundation
import VoiceCloneCore
import VoiceCloneInfrastructure

struct ProbeReport: Codable, Sendable {
    let loadSeconds: Double
    let generationSeconds: Double
    let audioSeconds: Double
    let peakResidentMiB: Double?
    let peakFootprintMiB: Double?
    let initialThermalState: String
    let finalThermalState: String
}

enum ProbeRunner {
    static func run(
        _ request: SynthesisRequest,
        variant: OmniVoiceSynthesizer.Variant,
        offline: Bool,
        outputURL: URL
    ) async throws -> ProbeReport {
        let duration = try AudioFiles.duration(of: request.referenceAudio)
        guard (1...15).contains(duration) else {
            throw ProbeFailure(message: "Choose a reference recording between 1 and 15 seconds.")
        }

        let process = ProcessInfo.processInfo
        let initialThermalState = thermalState(process.thermalState)
        let start = process.systemUptime
        let synthesizer = try await OmniVoiceSynthesizer.load(variant, offline: offline)
        let loaded = process.systemUptime
        let audio = try SynthesizeSpeech(synthesizer: synthesizer)(request)
        let generated = process.systemUptime
        try AudioFiles.writeWAV(audio, to: outputURL)

        var resources = rusage()
        let peakResident = getrusage(RUSAGE_SELF, &resources) == 0
            ? Double(resources.ru_maxrss) / 1_048_576 : nil
        return ProbeReport(
            loadSeconds: loaded - start,
            generationSeconds: generated - loaded,
            audioSeconds: audio.duration,
            peakResidentMiB: peakResident,
            peakFootprintMiB: peakFootprintMiB(),
            initialThermalState: initialThermalState,
            finalThermalState: thermalState(process.thermalState)
        )
    }

    private static func peakFootprintMiB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), words, &count)
            }
        }
        guard result == KERN_SUCCESS, info.ledger_phys_footprint_peak > 0 else { return nil }
        return Double(info.ledger_phys_footprint_peak) / 1_048_576
    }

    private static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
