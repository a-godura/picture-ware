import Foundation
import Observation

/// State behind "Save All Photos": progress, cancel, per-photo failures and retry.
@MainActor
@Observable
final class ExportModel {
    enum Destination: Sendable, Equatable {
        /// Into this device's Photos library (deduplicated across runs).
        case photos
        /// Into a temporary folder that the user then saves to Files.
        case files
    }

    enum Phase: Equatable {
        case idle
        case preparing
        case running
        case finished
        case cancelled
        case failed(String)
    }

    struct Failure: Identifiable, Equatable {
        let id: String
        let message: String
    }

    private(set) var phase: Phase = .idle
    private(set) var destination: Destination = .photos
    private(set) var total = 0
    private(set) var saved = 0
    private(set) var alreadySaved = 0
    private(set) var failures: [Failure] = []
    /// For `.files`: the folder of originals, ready to hand to the Files exporter.
    private(set) var exportFolder: URL?

    var completed: Int { saved + alreadySaved + failures.count }
    var fractionComplete: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    var isRunning: Bool { phase == .preparing || phase == .running }
    /// How many photos this device remembers saving to Photos.
    var rememberedCount: Int { ledgerCount }

    @ObservationIgnored private let fetchPhotos: @Sendable () async throws -> [Photo]
    @ObservationIgnored private let downloader: any PhotoDownloading
    @ObservationIgnored private let library: any PhotoDestination
    @ObservationIgnored private let ledger: any SavedPhotoLedger
    @ObservationIgnored private let filesRoot: URL
    @ObservationIgnored private let maxConcurrent: Int
    @ObservationIgnored private var task: Task<Void, Never>?
    private var ledgerCount: Int

    /// - Parameter fetchPhotos: returns the current photo list. Called at the start of every run
    ///   (and retry) so the presigned image URLs are fresh.
    init(
        fetchPhotos: @escaping @Sendable () async throws -> [Photo],
        downloader: any PhotoDownloading = URLSessionPhotoDownloader(),
        library: any PhotoDestination = PhotoLibraryDestination(),
        ledger: any SavedPhotoLedger = UserDefaultsSavedPhotoLedger(),
        filesRoot: URL = FileManager.default.temporaryDirectory.appending(path: "PictureWareFiles", directoryHint: .isDirectory),
        maxConcurrent: Int = 3
    ) {
        self.fetchPhotos = fetchPhotos
        self.downloader = downloader
        self.library = library
        self.ledger = ledger
        self.filesRoot = filesRoot
        self.maxConcurrent = maxConcurrent
        self.ledgerCount = ledger.count
    }

    // MARK: - Batch

    func start(_ destination: Destination) {
        guard !isRunning else { return }
        task = Task { await run(destination) }
    }

    /// Re-runs only the photos that failed last time, with a freshly fetched list.
    func retryFailed() {
        guard !isRunning, !failures.isEmpty else { return }
        let ids = Set(failures.map(\.id))
        task = Task { await run(destination, only: ids) }
    }

    /// Stops starting new photos; in-flight downloads are cancelled. Already-saved photos stay
    /// saved and are remembered, so "Save to Photos" again resumes where this stopped.
    func cancel() {
        task?.cancel()
    }

    func waitUntilIdle() async {
        await task?.value
    }

    /// Clears the "already saved" memory so the next run saves everything again.
    func forgetSavedHistory() {
        ledger.forgetAll()
        ledgerCount = ledger.count
    }

    func reset() {
        guard !isRunning else { return }
        phase = .idle
        total = 0
        saved = 0
        alreadySaved = 0
        failures = []
        exportFolder = nil
        try? FileManager.default.removeItem(at: filesRoot)
    }

    func run(_ destination: Destination, only retryIDs: Set<String>? = nil) async {
        phase = .preparing
        if let retryIDs {
            failures.removeAll { retryIDs.contains($0.id) }
        } else {
            self.destination = destination
            total = 0
            saved = 0
            alreadySaved = 0
            failures = []
            exportFolder = nil
            if destination == .files { try? FileManager.default.removeItem(at: filesRoot) }
        }

        let photos: [Photo]
        do {
            photos = try await fetchPhotos()
        } catch {
            if let retryIDs { failures += retryIDs.sorted().map { Failure(id: $0, message: error.localizedDescription) } }
            phase = PhotoExporter.isCancellation(error) ? .cancelled : .failed(error.localizedDescription)
            return
        }

        var targets = photos
        if let retryIDs {
            targets = photos.filter { retryIDs.contains($0.id) }
            // Photos deleted from the trip since the first attempt simply drop out.
            total -= retryIDs.subtracting(targets.map(\.id)).count
        } else {
            total = Set(photos.map(\.id)).count
        }

        let target: any PhotoDestination = destination == .photos ? library : FolderDestination(folder: folderURL)
        do {
            try await target.prepare()
        } catch {
            if let retryIDs { failures += retryIDs.sorted().map { Failure(id: $0, message: error.localizedDescription) } }
            phase = .failed(error.localizedDescription)
            return
        }
        if destination == .photos { await forgetAssetsDeletedFromLibrary(among: targets) }

        phase = .running
        let exporter = PhotoExporter(downloader: downloader, destination: target, maxConcurrent: maxConcurrent)
        await exporter.run(targets, ledger: destination == .photos ? ledger : nil) { event in
            apply(event)
        }
        ledgerCount = ledger.count
        if destination == .files, saved > 0 { exportFolder = folderURL }
        phase = Task.isCancelled && completed < total ? .cancelled : .finished
    }

    // MARK: - Single photo

    /// Whether this device remembers saving `photoID` to Photos (see `SavedPhotoLedger` for limits).
    func isSavedToPhotos(_ photoID: String) -> Bool {
        _ = ledgerCount // observed, so views refresh after a save or "Forget"
        return ledger.assetID(for: photoID) != nil
    }

    /// Saves one photo to Photos (even if saved before: the UI offers this as "Save Again") and
    /// remembers it, so a later "Save All" skips it. Retries once with a fresh URL on failure.
    func saveToPhotos(_ photo: Photo) async throws {
        try await library.prepare()
        if case .failed = await saveOne(photo) {
            let fresh = try await fetchPhotos().first { $0.id == photo.id }
            guard let fresh else { throw ExportError.photoRemoved }
            if case .failed(let message) = await saveOne(fresh) {
                throw SingleSaveError(message: message)
            }
        }
    }

    // MARK: - Private

    private var folderURL: URL {
        filesRoot.appending(path: "Picture Ware Photos", directoryHint: .isDirectory)
    }

    private func saveOne(_ photo: Photo) async -> ExportEvent.Outcome {
        var outcome = ExportEvent.Outcome.failed("Cancelled")
        let exporter = PhotoExporter(downloader: downloader, destination: library, maxConcurrent: 1)
        await exporter.run([photo], ledger: ledger, skipAlreadySaved: false) { outcome = $0.outcome }
        ledgerCount = ledger.count
        return outcome
    }

    private func apply(_ event: ExportEvent) {
        switch event.outcome {
        case .saved: saved += 1
        case .alreadySaved: alreadySaved += 1
        case .failed(let message): failures.append(Failure(id: event.photoID, message: message))
        }
    }

    /// With read access we can see whether remembered assets were deleted from Photos since, and
    /// save those again. Without it (add-only) the ledger is all we have.
    private func forgetAssetsDeletedFromLibrary(among photos: [Photo]) async {
        let remembered = photos.compactMap { photo in ledger.assetID(for: photo.id).map { (photo.id, $0) } }
        guard !remembered.isEmpty,
              let existing = await library.existingAssetIDs(remembered.map(\.1)) else { return }
        ledger.forget(photoIDs: remembered.filter { !existing.contains($0.1) }.map(\.0))
        ledgerCount = ledger.count
    }
}

struct SingleSaveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
