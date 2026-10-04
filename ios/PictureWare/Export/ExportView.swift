import SwiftUI
import UIKit

/// "Save All Photos" sheet: pick Photos or Files, then progress, cancel, failures and retry.
struct ExportView: View {
    let model: ExportModel
    let photoCount: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showingFilesExporter = false
    @State private var confirmingForget = false

    var body: some View {
        NavigationStack {
            List {
                switch model.phase {
                case .idle:
                    chooser
                case .preparing, .running:
                    progressSection
                case .finished, .cancelled:
                    summarySection
                    failuresSection
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.primary, .orange)
                        Button("Try Again") { model.start(model.destination) }
                        if message == ExportError.photosAccessDenied.errorDescription {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                        Button("Back") { model.reset() }
                    }
                }
            }
            .navigationTitle("Save All Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if model.isRunning {
                        Button("Stop", role: .cancel) { model.cancel() }
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showingFilesExporter) {
                if let folder = model.exportFolder {
                    FolderExportPicker(folder: folder).ignoresSafeArea()
                }
            }
            .confirmationDialog("Forget which photos were saved?", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { model.forgetSavedHistory() }
            } message: {
                Text("The next “Save to Photos” will save every photo again, which can create duplicates.")
            }
        }
        .interactiveDismissDisabled(model.isRunning)
    }

    // MARK: - Sections

    @ViewBuilder private var chooser: some View {
        Section {
            Button { model.start(.photos) } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save to Photos").font(.headline)
                        Text(model.rememberedCount > 0
                             ? "Photos you already saved on this iPhone (\(model.rememberedCount)) are skipped."
                             : "Adds the originals to your library.")
                            .font(.footnote).foregroundStyle(Color.secondary)
                    }
                } icon: { Image(systemName: "photo.on.rectangle.angled") }
            }
            Button { model.start(.files) } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save as Files").font(.headline)
                        Text("Downloads a folder of originals you can save to Files, iCloud Drive or a USB drive.")
                            .font(.footnote).foregroundStyle(Color.secondary)
                    }
                } icon: { Image(systemName: "folder") }
            }
        } header: {
            Text("^[\(photoCount) photo](inflect: true)")
        } footer: {
            Text("Original files are saved unchanged, so each photo keeps its date, location and camera details.")
        }
        .disabled(photoCount == 0)

        if model.rememberedCount > 0 {
            Section {
                Button("Forget Which Photos Were Saved", role: .destructive) { confirmingForget = true }
            }
        }
    }

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                if model.phase == .preparing {
                    ProgressView().frame(maxWidth: .infinity)
                    Text("Getting ready…").foregroundStyle(.secondary)
                } else {
                    ProgressView(value: model.fractionComplete)
                    Text("\(verb) \(model.completed) of \(model.total)…")
                        .monospacedDigit()
                    counts
                }
            }
            .padding(.vertical, 6)
            Button("Stop", role: .destructive) { model.cancel() }
        } footer: {
            Text("Keep Picture Ware open until it finishes.")
        }
    }

    @ViewBuilder private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(summaryTitle, systemImage: summaryIcon)
                    .font(.headline)
                    .foregroundStyle(.primary, summaryTint)
                counts
            }
            .padding(.vertical, 4)
            if model.destination == .files, model.exportFolder != nil {
                Button("Save to Files…", systemImage: "folder.badge.plus") { showingFilesExporter = true }
            }
            if model.phase == .cancelled {
                Button(model.destination == .photos ? "Save the Rest" : "Start Over") { model.start(model.destination) }
            }
            if model.phase == .finished {
                Button("Back") { model.reset() }
            }
        }
    }

    @ViewBuilder private var failuresSection: some View {
        if !model.failures.isEmpty {
            Section {
                ForEach(model.failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photo \(failure.id.prefix(8))").font(.subheadline.monospaced())
                        Text(failure.message).font(.footnote).foregroundStyle(Color.secondary)
                    }
                }
                Button("Retry Failed", systemImage: "arrow.clockwise") { model.retryFailed() }
            } header: {
                Text("^[\(model.failures.count) photo](inflect: true) couldn't be saved")
            }
        }
    }

    private var counts: some View {
        HStack(spacing: 14) {
            Label("\(model.saved)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if model.alreadySaved > 0 {
                Label("\(model.alreadySaved) already saved", systemImage: "equal.circle").foregroundStyle(.secondary)
            }
            if !model.failures.isEmpty {
                Label("\(model.failures.count)", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
        }
        .font(.footnote)
        .monospacedDigit()
    }

    private var verb: String { model.destination == .photos ? "Saving" : "Downloading" }

    private var summaryTitle: String {
        if model.phase == .cancelled { return "Stopped" }
        if !model.failures.isEmpty { return "Finished with problems" }
        if model.saved == 0, model.alreadySaved > 0 { return "Everything was already saved" }
        return model.destination == .photos ? "Saved to Photos" : "Ready to save to Files"
    }

    private var summaryIcon: String {
        if model.phase == .cancelled { return "pause.circle.fill" }
        return model.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var summaryTint: Color {
        if model.phase == .cancelled { return .secondary }
        return model.failures.isEmpty ? .green : .orange
    }
}

/// The system "Save to Files" picker for one folder (copied, so we can delete our temp copy).
struct FolderExportPicker: UIViewControllerRepresentable {
    let folder: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [folder], asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

/// The export model for the current screen, so the photo viewer (Map/PhotoBrowser -> PhotoDetailView)
/// can offer "Save to Photos" without threading a closure through the map views. nil hides the button.
extension EnvironmentValues {
    @Entry var exportModel: ExportModel? = nil
}

/// "Save to Photos" for the photo detail sheet. A photo this device already saved shows
/// "Already in Photos" with a "Save Again" option instead of silently creating a duplicate.
struct SaveToPhotosButton: View {
    let model: ExportModel
    let photo: Photo
    @State private var state: SaveState = .idle

    private enum SaveState: Equatable {
        case idle, saving, saved
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state == .idle, model.isSavedToPhotos(photo.id) {
                HStack {
                    Label("Already in Photos", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Again") { Task { await run() } }
                        .buttonStyle(.bordered)
                }
                .font(.subheadline)
            } else {
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        switch state {
                        case .saving: ProgressView()
                        case .saved: Image(systemName: "checkmark.circle.fill")
                        default: Image(systemName: "square.and.arrow.down")
                        }
                        Text(state == .saved ? "Saved to Photos" : "Save to Photos")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(state == .saving || state == .saved)
            }
            if case .failed(let message) = state {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func run() async {
        state = .saving
        do {
            try await model.saveToPhotos(photo)
            state = .saved
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
