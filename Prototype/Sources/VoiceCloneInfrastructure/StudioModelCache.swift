import AudioCommon
import CryptoKit
import Foundation
import VoiceCloneCore

public actor StudioModelCache {
    private var verified: Set<StudioModel> = []

    public init() {}

    public nonisolated func isReady(_ model: StudioModel) -> Bool {
        guard let directory = try? directory(for: model) else { return false }
        return fileSizes(for: model).allSatisfy { path, expected in
            size(of: directory.appendingPathComponent(path)) == expected
        }
    }

    public func download(_ model: StudioModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = try directory(for: model)
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
        let checksums = weightsChecksums(for: model)
        let directory = try directory(for: model)
        if !verified.contains(model) {
            for (path, checksum) in checksums {
                try verifyFile(directory.appendingPathComponent(path), checksum: checksum)
            }
            verified.insert(model)
        }
        switch model {
        case .int8, .fp16: return checksums[0].checksum
        case .chatterbox:
            let fingerprint = checksums.map(\.checksum).joined()
            return SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    public func remove(_ model: StudioModel) throws {
        try FileManager.default.removeItem(at: directory(for: model))
        verified.remove(model)
    }

    nonisolated func directory(for model: StudioModel) throws -> URL {
        try HuggingFaceDownloader.getCacheDirectory(for: model.repository)
    }

    private nonisolated func fileSizes(for model: StudioModel) -> [String: Int64] {
        if model == .chatterbox {
            return [
                "model.safetensors": 1_286_967_446,
                "conformer.safetensors": 68_333_080,
                "s3_tokenizer.safetensors": 494_868_984,
                "config.json": 121,
                "tokenizer.json": 69_989,
                "Cangjie5_TC.json": 1_920_163
            ]
        }
        return [
            "model.safetensors": model == .int8 ? 689_415_208 : 1_225_189_168,
            "config.json": model == .int8 ? 2_298 : 2_238,
            "tokenizer.json": 11_423_986,
            "tokenizer_config.json": 533,
            "audio_tokenizer/model.safetensors": 402_864_450,
            "audio_tokenizer/config.json": 2_531,
            "audio_tokenizer/preprocessor_config.json": 206
        ]
    }

    private func weightsChecksums(for model: StudioModel) -> [(path: String, checksum: String)] {
        if model == .chatterbox {
            return [
                ("model.safetensors", "13f152e36e19539a633571fd38db40af1ba42001fc3876eb2c46c158bc69c3f0"),
                ("conformer.safetensors", "fc89fabf9bfedc33acf9acd52cfd32aa4c94d5bf8c2835325c9ed2c351219913"),
                ("s3_tokenizer.safetensors", "928726bc1f206a613d36b8f49e297eae9c5593a21bf9b92ddfe2c23f85eb92cc"),
                ("config.json", "022fb7f8158c59ee2947459404621a1ddf026f2cb300087db03e0f630b4ca299"),
                ("tokenizer.json", "69632f47220a788a52ce2661d096453c5655e9bf25289d89a8d832c46ee07dbf"),
                ("Cangjie5_TC.json", "7073fd9de919443ae88e0bd2449917a65fe54898a4413ed1edcc4b67f28bce8c")
            ]
        }
        return [
            ("model.safetensors", model == .int8
                ? "0d701a35df4ad7ed9af47a2c7a17b50d2de7feff6b4ffc9500d5f8587c473ac7"
                : "9f6109e8a72253be1031b2134501593ff9634226db8ba4ae5920e0145dae60f3"),
            ("audio_tokenizer/model.safetensors", "2ccdf29d0f01b504075fc188705458ffa4d1502a196839492bb59a941c1e70d0")
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
