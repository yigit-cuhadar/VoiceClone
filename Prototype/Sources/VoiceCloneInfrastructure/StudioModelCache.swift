import AudioCommon
import CryptoKit
import Foundation
import VoiceCloneCore

public actor StudioModelCache {
    private var verified: Set<StudioModel> = []

    public init() {}

    public nonisolated func isReady(_ model: StudioModel) -> Bool {
        guard let directory = try? HuggingFaceDownloader.getCacheDirectory(for: model.repository) else { return false }
        return fileSizes(for: model).allSatisfy { path, expected in
            size(of: directory.appendingPathComponent(path)) == expected
        }
    }

    public func download(_ model: StudioModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = try HuggingFaceDownloader.getCacheDirectory(for: model.repository)
        let expectedSizes = fileSizes(for: model)
        let missingBytes = expectedSizes.reduce(Int64(0)) { total, entry in
            total + (size(of: directory.appendingPathComponent(entry.key)) == entry.value ? 0 : entry.value)
        }
        if missingBytes > 0 {
            if let available = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage,
               available < missingBytes {
                throw StudioCacheError.insufficientStorage
            }
            try await HuggingFaceDownloader.downloadFilesByteWeighted(
                modelId: model.repository, to: directory, files: expectedSizes.keys.sorted(),
                expectedSizes: expectedSizes
            ) { fraction, _, _, _ in progress(fraction) }
            verified.remove(model)
        }
        _ = try verify(model)
    }

    public func verify(_ model: StudioModel) throws -> String {
        guard isReady(model) else { throw StudioError.unavailableModel }
        let expected = model == .int8
            ? "0d701a35df4ad7ed9af47a2c7a17b50d2de7feff6b4ffc9500d5f8587c473ac7"
            : "9f6109e8a72253be1031b2134501593ff9634226db8ba4ae5920e0145dae60f3"
        if !verified.contains(model) {
            let directory = try HuggingFaceDownloader.getCacheDirectory(for: model.repository)
            try verifyFile(directory.appendingPathComponent("model.safetensors"), checksum: expected)
            try verifyFile(directory.appendingPathComponent("audio_tokenizer/model.safetensors"),
                           checksum: "2ccdf29d0f01b504075fc188705458ffa4d1502a196839492bb59a941c1e70d0")
            verified.insert(model)
        }
        return expected
    }

    public func remove(_ model: StudioModel) throws {
        let directory = try HuggingFaceDownloader.getCacheDirectory(for: model.repository)
        try FileManager.default.removeItem(at: directory)
        verified.remove(model)
    }

    private nonisolated func fileSizes(for model: StudioModel) -> [String: Int64] {
        [
            "model.safetensors": model == .int8 ? 689_415_208 : 1_225_189_168,
            "config.json": model == .int8 ? 2_298 : 2_238,
            "tokenizer.json": 11_423_986,
            "tokenizer_config.json": 533,
            "audio_tokenizer/model.safetensors": 402_864_450,
            "audio_tokenizer/config.json": 2_531,
            "audio_tokenizer/preprocessor_config.json": 206
        ]
    }

    private nonisolated func size(of url: URL) -> Int64? {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(bytes)
    }

    private func verifyFile(_ file: URL, checksum: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == checksum else {
            try FileManager.default.removeItem(at: file)
            throw StudioCacheError.invalidWeights
        }
    }
}

private enum StudioCacheError: LocalizedError {
    case insufficientStorage
    case invalidWeights

    var errorDescription: String? {
        switch self {
        case .insufficientStorage: "Free up device storage before downloading this model."
        case .invalidWeights: "The model files did not pass validation. Download the model again."
        }
    }
}
