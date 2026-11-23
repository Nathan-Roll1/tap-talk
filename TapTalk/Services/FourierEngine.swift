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
        try await fetchWeights(from: url, to: staged, progress: progress)
        guard try file.matches(file: staged) else { throw URLError(.cannotDecodeContentData) }
        try Task.checkCancellation()
        if fm.fileExists(atPath: modelFile.path) {
            _ = try fm.replaceItemAt(modelFile, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: modelFile)
        }
    }

    private static func fetchWeights(from url: URL, to target: URL,
                                     progress: @escaping @Sendable (Double) -> Void) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let fm = FileManager.default
        guard fm.createFile(atPath: target.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var offset: Int64 = 0
        while offset < file.bytes {
            try Task.checkCancellation()
            let end = min(offset + 16 * 1024 * 1024, file.bytes) - 1
            // A range-specific URL keeps CDN redirects for different ranges independent.
            let partURL = url.appending(queryItems: [URLQueryItem(name: "part", value: String(offset))])
            var request = URLRequest(url: partURL)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (temp, response) = try await session.download(for: request)
            defer { try? fm.removeItem(at: temp) }
            guard let http = response as? HTTPURLResponse,
                  let size = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                throw URLError(.badServerResponse)
            }
            let whole = offset == 0 && http.statusCode == 200 && Int64(size) == file.bytes
            let range = "bytes \(offset)-\(end)/\(file.bytes)"
            guard whole || (http.statusCode == 206 && http.value(forHTTPHeaderField: "Content-Range") == range
                            && Int64(size) == end - offset + 1) else { throw URLError(.badServerResponse) }
            let input = try FileHandle(forReadingFrom: temp)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            offset += Int64(size)
            progress(Double(offset) / Double(file.bytes))
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
