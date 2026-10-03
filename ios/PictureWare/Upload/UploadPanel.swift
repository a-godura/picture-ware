import PhotosUI
import SwiftUI

/// The "+" button: picks up to `BulkImporter.maxSelection` photos and queues them.
struct AddPhotosButton: View {
    let uploads: UploadCenter
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $selection, maxSelectionCount: BulkImporter.maxSelection,
                     selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current,
                     photoLibrary: .shared()) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Color.accentColor, in: Circle())
                .shadow(radius: 4, y: 2)
        }
        .disabled(uploads.importing != nil || uploads.queue == nil)
        .accessibilityLabel("Add photos")
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            selection = []
            Task { await uploads.importPicked(items) }
        }
    }
}

/// Compact upload status: "Uploading 3 of 12", failures with retry, done with dismiss.
/// Tapping it opens the per-photo list.
struct UploadPanel: View {
    let uploads: UploadCenter
    @State private var showingDetails = false

    var body: some View {
        if uploads.isVisible {
            HStack(spacing: 10) {
                Button { showingDetails = true } label: { status.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows each photo's upload status")
                trailingAction
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .sheet(isPresented: $showingDetails) { UploadListView(uploads: uploads) }
            .animation(.default, value: uploads.summary)
        }
    }

    private var summary: UploadSummary { uploads.summary }

    @ViewBuilder private var status: some View {
        HStack(spacing: 10) {
            if let importing = uploads.importing {
                ProgressView()
                Text("Adding \(min(importing.done + 1, importing.total)) of \(importing.total)…")
            } else if summary.active > 0 {
                ProgressView(value: summary.fraction)
                    .progressViewStyle(.circular)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uploading \(summary.done) of \(summary.total - summary.failed)")
                        .monospacedDigit()
                    if let note = noteText {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if summary.failed > 0 || !uploads.rejections.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.done > 0 ? "\(summary.done) added" : "Some photos weren't added")
                    if let note = noteText {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(summary.done == 1 ? "1 photo added" : "\(summary.done) photos added")
                if uploads.skippedDuplicates > 0 {
                    Text("· \(uploads.skippedDuplicates) already added").foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "2 failed · 1 no location"
    private var noteText: String? {
        var parts: [String] = []
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if !uploads.rejections.isEmpty { parts.append("\(uploads.rejections.count) skipped") }
        if uploads.skippedDuplicates > 0 { parts.append("\(uploads.skippedDuplicates) already added") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var trailingAction: some View {
        if uploads.importing != nil {
            EmptyView()
        } else if summary.failed > 0 {
            Button("Retry", systemImage: "arrow.clockwise") { uploads.retryAllFailed() }
                .labelStyle(.titleOnly)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else if summary.active == 0 {
            Button("Dismiss", systemImage: "xmark") { uploads.dismissFinished() }
                .labelStyle(.iconOnly)
        }
    }
}

/// Every photo in the current batch, with per-photo retry/remove.
struct UploadListView: View {
    let uploads: UploadCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !uploads.rejections.isEmpty {
                    Section {
                        ForEach(uploads.rejections) { rejection in
                            RejectionRow(rejection: rejection)
                                .swipeActions { Button("Dismiss") { uploads.dismissRejection(rejection) } }
                        }
                    } header: {
                        Text("Not added")
                    } footer: {
                        Text("Photos need a location to be placed on the map.")
                    }
                }
                if !uploads.items.isEmpty {
                    Section("Uploads") {
                        ForEach(uploads.items) { item in UploadRow(item: item, uploads: uploads) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if uploads.summary.failed > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Retry All") { uploads.retryAllFailed() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        let summary = uploads.summary
        return summary.total == 0 ? "Uploads" : "\(summary.done) of \(summary.total) uploaded"
    }
}

private struct UploadRow: View {
    let item: UploadItem
    let uploads: UploadCenter

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.takenAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Photo")
                detail.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if case .failed = item.status {
                Button("Retry", systemImage: "arrow.clockwise") { uploads.retry(item) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        .swipeActions {
            if item.status != .done {
                Button("Remove", role: .destructive) { uploads.remove(item) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch item.status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .uploading: ProgressView(value: item.progress).progressViewStyle(.circular)
        case .creating: ProgressView()
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var detail: some View {
        switch item.status {
        case .done: Text("Uploaded")
        case .failed(let message): Text(message)
        case .uploading: Text("Uploading \(Int(item.progress * 100))%")
        case .creating: Text("Starting…")
        case .waiting:
            if let error = item.lastError, item.nextAttemptAt != nil {
                Text("Will retry: \(error)")
            } else {
                Text("Waiting")
            }
        }
    }
}

private struct RejectionRow: View {
    let rejection: ImportRejection

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let data = rejection.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text("Photo \(rejection.position) of your selection")
                Text(rejection.reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
