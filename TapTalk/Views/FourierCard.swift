import SwiftUI

@MainActor
private final class FourierInstaller: ObservableObject {
    static let shared = FourierInstaller()
    enum State { case idle, downloading(Double), ready, failed(String) }
    @Published private(set) var state: State = FourierEngine.isInstalled() ? .ready : .idle
    private var task: Task<Void, Never>?

    func install() {
        guard task == nil else { return }
        AppController.shared.fetchVoiceDetectorIfMissing()
        state = .downloading(0)
        task = Task {
            defer { task = nil }
            do {
                try await FourierEngine.download { value in
                    Task { @MainActor in
                        guard case .downloading(let previous) = self.state, value > previous else { return }
                        self.state = .downloading(min(value, 1))
                    }
                }
                state = .ready
                AppController.shared.adoptDownloadedEngine(.fourier)
            } catch {
                state = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel() }

    func remove() {
        do {
            try FourierEngine.delete()
            state = .idle
            AppController.shared.handleEngineRemoved(.fourier)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct FourierCard: View {
    @ObservedObject private var installer = FourierInstaller.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var removing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(LocalEngine.fourier.displayName).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("2.19 GB").foregroundStyle(AppTheme.secondary)
            }
            HStack {
                Text("English dictation on this Mac. For noncommercial use.")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.tertiary)
                Spacer()
                switch installer.state {
                case .ready:
                    UseEngineControl(isInUse: settings.isInUse(.fourier)) { settings.use(.fourier) }
                    Button("Remove") { removing = true }
                case .downloading(let progress):
                    ProgressView(value: progress).frame(width: 62)
                    Button("Cancel") { installer.cancel() }
                case .idle, .failed:
                    CardButton(title: "Download", prominent: false) { installer.install() }
                }
            }
            if case .failed(let message) = installer.state {
                Text(message).font(.caption).foregroundStyle(AppTheme.danger)
            }
            if let terms = URL(string: "https://huggingface.co/oruk/oruk-fourier-2b#license") {
                Link("Model license", destination: terms).font(.caption)
            }
        }
        .padding(12)
        .confirmationDialog("Remove the Fourier model from this Mac?", isPresented: $removing) {
            Button("Remove", role: .destructive) { installer.remove() }
        }
    }
}
