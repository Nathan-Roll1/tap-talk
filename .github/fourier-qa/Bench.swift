import AppKit
import AVFoundation
import ApplicationServices
import TapTalkAudio

// Runs only in the benchmark build on an ephemeral macOS runner.
final class FixtureCapture: AudioCapture, @unchecked Sendable {
    let ring = SampleRing(capacity: 16_000 * 20)
    func prepare() throws {}
    func start() throws -> CaptureSession {
        CaptureSession(ring: ring, sampleRate: 16_000, startMark: ring.writtenCount)
    }
    func pause() {}
    func shutdown() {}
}

@MainActor
final class ReceivingEditor: NSTextView {
    var released: UInt64 = 0
    var inserted: UInt64 = 0
    override func keyUp(with event: NSEvent) {
        released = DispatchTime.now().uptimeNanoseconds
        AppController.shared.stopAndTranscribe()
    }
    override func didChangeText() {
        super.didChangeText()
        if released > 0 && inserted == 0 && !string.isEmpty {
            inserted = DispatchTime.now().uptimeNanoseconds
        }
    }
}

@MainActor
enum FourierComparison {
    nonisolated static let capture = FixtureCapture()
    static let editor = ReceivingEditor()
    static let outputURL = URL(fileURLWithPath: "/tmp/taptalk-result.json")
    static var window: NSWindow?
    static let physicalPaste = AXIsProcessTrusted()
    struct Row: Codable {
        let model: String
        let iteration: Int
        let releaseToVisibleMS: Double
        let text: String
    }

    static func prepareEditor() {
        NSApp.setActivationPolicy(.regular)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 160),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window = w
        w.title = "TapTalk test editor"
        w.contentView = editor
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(editor)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func deliverInAppPaste() {
        // Used only where the runner has no global event permission.
        guard NSApp.sendAction(#selector(NSText.paste(_:)), to: editor, from: nil) else {
            fatalError("AppKit did not route Paste")
        }
    }

    static func stage(_ name: String) {
        FileHandle.standardError.write(Data(("STAGE " + name + "\n").utf8))
    }

    static func run() async {
        stage("entered benchmark")
        do {
            let c = AppController.shared
            stage("controller initialized")
            prepareEditor()
            stage("editor initialized")
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: "/tmp/taptalk-speech.wav"),
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                  let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)) else { throw CocoaError(.fileReadCorruptFile) }
            try file.read(into: b)
            guard let first = b.floatChannelData?.pointee else { throw CocoaError(.fileReadCorruptFile) }
            let samples = Array(UnsafeBufferPointer(start: first, count: Int(b.frameLength)))
            let store = VadModelStore(modelsDirectory: URL(fileURLWithPath: AppController.modelsDirectory()))
            stage("installing VAD")
            try await store.install()
            try await c.recorder.loadVoiceActivity(modelURL: store.modelURL)
            stage("downloading Fourier")
            try await FourierEngine.download { value in FileHandle.standardError.write(Data(("Fourier downloaded " + String(Int(value * 100)) + "%\n").utf8)) }
            stage("Fourier verified")
            if !OrukeetEngine.isInstalled() {
                try await OrukeetEngine.download { _ in }
                stage("compiling Orukeet")
                try await Task.detached { try OrukeetEngine.compile() }.value
            }
            stage("both models ready")
            let settings = SettingsStore.shared
            settings.streamingEnabled = false
            settings.llmEnabled = false
            settings.learnCorrections = false
            settings.transcriptionEngine = .local
            var rows = [Row]()
            for model: LocalEngine in [.orukeet, .fourier] {
                await c.fourier.unload()
                await c.orukeet.unload()
                settings.localEngine = model
                c.state.setModel(.ready)
                for i in 0...10 {
                    stage(model.rawValue + " take " + String(i))
                    editor.released = 0; editor.inserted = 0; editor.string = ""
                    c.startRecording(hotkey: true, smart: false)
                    try await Task.sleep(nanoseconds: 220_000_000)
                    for off in stride(from: 0, to: samples.count, by: 320) {
                        let end = min(off + 320, samples.count)
                        samples.withUnsafeBufferPointer { ptr in
                            capture.ring.writer.write(UnsafeBufferPointer(rebasing: ptr[off..<end]))
                        }
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                    guard let w = window, let ev = NSEvent.keyEvent(with: .keyUp, location: .zero,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: w.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                        isARepeat: false, keyCode: 49) else { throw CocoaError(.coderInvalidValue) }
                    w.makeKeyAndOrderFront(nil)
                    w.makeFirstResponder(editor)
                    w.sendEvent(ev)
                    guard editor.released > 0 else { throw NSError(domain: "AppKit failed to deliver key release", code: 1) }
                    let deadline = Date().addingTimeInterval(75)
                    while editor.inserted == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
                    guard editor.inserted > editor.released else { throw NSError(domain: "No editor insertion, " + c.state.status, code: 2) }
                    let ms = Double(editor.inserted - editor.released) / 1_000_000
                    rows.append(Row(model: model.rawValue, iteration: i, releaseToVisibleMS: ms, text: editor.string))
                    print("MEASURE", model.rawValue, i, ms, editor.string)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(rows).write(to: outputURL, options: .atomic)
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            print("PASTE_TRANSPORT",physicalPaste ? "system Cmd-V" : "in-process AppKit paste action")
            exit(0)
        } catch {
            print("BENCH_ERROR",error)
            exit(1)
        }
    }
}
