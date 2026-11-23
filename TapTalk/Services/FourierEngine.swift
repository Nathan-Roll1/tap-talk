import Foundation
import TranscribeCpp

actor FourierEngine {
    private static let file = OrukeetDownloadManifest.Archive(
        filename: "Fourier-2B-Q8_0.gguf", bytes: 2_185_030_848,
        sha256: "6a7c419bd571f7b0e21da2d5ab1e3a1a3938a83470d622be57427af98f322981"
    )
    private static let revision = "8bcce21695e4ba13569c48de6cedffcb8a7576f5"
    private static let backends = Result { try Transcribe.initBackends() }
    private var model: TranscribeCpp.Model?

    private static var directory: URL {
        URL(fileURLWithPath: AppController.modelsDirectory()).appendingPathComponent("Fourier", isDirectory: true)
    }
    private static var modelFile: URL { directory.appendingPathComponent(file.filename) }

    static func isInstalled() -> Bool {
        let size = try? modelFile.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return size.map(Int64.init) == file.bytes
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isInstalled() { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? fm.removeItem(at: staged) }
        let address = "https://huggingface.co/oruk/oruk-fourier-2b/resolve/" + revision + "/" + file.filename
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        try await ZipDownloader.download(from: url, to: staged, progress: progress)
        guard try file.matches(file: staged) else { throw URLError(.cannotDecodeContentData) }
        try Task.checkCancellation()
        if fm.fileExists(atPath: modelFile.path) {
            _ = try fm.replaceItemAt(modelFile, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: modelFile)
        }
    }

    static func delete() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func ensureLoaded() throws {
        guard model == nil else { return }
        guard Self.isInstalled() else { throw CocoaError(.fileNoSuchFile) }
        try Self.backends.get()
        model = try TranscribeCpp.Model(path: Self.modelFile.path)
    }

    func unload() { model = nil }

    func transcribe(samples: [Float]) throws -> (text: String, processingMs: UInt64) {
        let start = DispatchTime.now().uptimeNanoseconds
        try ensureLoaded()
        guard let model else { throw CocoaError(.fileNoSuchFile) }
        let rate = 16_000
        var offset = 0
        var parts: [String] = []
        while offset < samples.count {
            try Task.checkCancellation()
            var end = min(offset + 30 * rate, samples.count)
            if end < samples.count {
                // Cut long recordings at the quietest 20 ms window near the bound.
                let frame = rate / 50
                let search = (end - 2 * rate)..<end
                var minimum = Float.infinity
                for index in stride(from: search.lowerBound, to: search.upperBound, by: frame) {
                    let power = samples[index..<(index + frame)].reduce(Float(0)) { $0 + $1 * $1 }
                    if power < minimum { minimum = power; end = index + frame }
                }
            }
            let session = try model.session()
            let output = try session.run(Array(samples[offset..<end]),
                                         options: RunOptions(timestamps: .none, language: "en"))
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
            offset = end
        }
        return (parts.joined(separator: " "), (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
}
