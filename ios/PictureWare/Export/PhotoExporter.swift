import Foundation

// "Keep the memories" (#13): copy every photo's original file out of picture-ware,
// either into the Photos library or into a folder the user saves to Files.
//
// The engine below is UI-free and talks to two ports so it can be tested with fakes:
//   PhotoDownloading  - fetches a photo's original file (live: presigned S3 GET)
//   PhotoDestination  - stores a downloaded file (live: PhotoKit, or a folder)

/// A photo's original file, downloaded to a temporary location the exporter owns
/// (it deletes the file once the destination has stored it).
struct DownloadedPhoto: Sendable, Equatable {
    let fileURL: URL
}

protocol PhotoDownloading: Sendable {
    func download(_ photo: Photo) async throws -> DownloadedPhoto
}

protocol PhotoDestination: Sendable {
    /// Called once before a run, e.g. to ask for Photos access. Throwing aborts the run.
    func prepare() async throws
    /// Stores the original file. Returns an identifier for what was created (the Photos
    /// asset's local identifier), or nil when there is nothing to remember.
    func store(_ file: DownloadedPhoto, for photo: Photo) async throws -> String?
    /// Which of `assetIDs` still exist, or nil when the destination can't tell
    /// (Photos with add-only access can't read the library).
    func existingAssetIDs(_ assetIDs: [String]) async -> Set<String>?
}

extension PhotoDestination {
    func prepare() async throws {}
    func existingAssetIDs(_ assetIDs: [String]) async -> Set<String>? { nil }
}

/// Remembers which picture-ware photos were already saved into this device's Photos library,
/// so a second "Save all" doesn't create duplicates. Used only from the caller's isolation.
protocol SavedPhotoLedger: AnyObject {
    func assetID(for photoID: String) -> String?
    func record(photoID: String, assetID: String)
    func forget(photoIDs: [String])
    func forgetAll()
    var count: Int { get }
}

enum ExportError: LocalizedError, Equatable {
    case photosAccessDenied
    case linkExpired
    case downloadFailed(status: Int)
    case notAnImage
    case photoRemoved

    var errorDescription: String? {
        switch self {
        case .photosAccessDenied:
            "Picture Ware isn't allowed to add photos. You can allow it in Settings › Privacy & Security › Photos."
        case .linkExpired: "The download link expired."
        case .downloadFailed(let status): "Download failed (HTTP \(status))."
        case .notAnImage: "The downloaded file isn't an image."
        case .photoRemoved: "This photo was deleted from the trip."
        }
    }
}

struct ExportEvent: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        /// Already in the destination from an earlier run; nothing was downloaded.
        case alreadySaved
        case saved
        case failed(String)
    }

    let photoID: String
    let outcome: Outcome
}

/// Downloads and stores photos with at most `maxConcurrent` in flight.
struct PhotoExporter: Sendable {
    let downloader: any PhotoDownloading
    let destination: any PhotoDestination
    var maxConcurrent = 3

    /// Exports `photos`, reporting one event per photo as it completes.
    ///
    /// With a `ledger`, every newly created asset is recorded, and (when `skipAlreadySaved`)
    /// photos it already lists are reported `.alreadySaved` without being downloaded. On cancellation the run stops
    /// starting new photos and returns; photos that hadn't finished produce no event (they are
    /// neither saved nor failed), except that a store that already completed is still recorded,
    /// so a re-run can't duplicate it.
    func run(
        _ photos: [Photo],
        ledger: (any SavedPhotoLedger)? = nil,
        skipAlreadySaved: Bool = true,
        isolation: isolated (any Actor)? = #isolation,
        onEvent: (ExportEvent) -> Void
    ) async {
        var seen = Set<String>()
        var pending: [Photo] = []
        for photo in photos where seen.insert(photo.id).inserted {
            if skipAlreadySaved, ledger?.assetID(for: photo.id) != nil {
                onEvent(ExportEvent(photoID: photo.id, outcome: .alreadySaved))
            } else {
                pending.append(photo)
            }
        }

        await withTaskGroup(of: (ExportEvent, String?)?.self) { group in
            var queue = pending.makeIterator()
            func startNext() {
                guard !Task.isCancelled, let photo = queue.next() else { return }
                group.addTask { await export(photo) }
            }
            for _ in 0..<max(1, maxConcurrent) { startNext() }
            while let result = await group.next() {
                if let (event, assetID) = result {
                    if let assetID { ledger?.record(photoID: event.photoID, assetID: assetID) }
                    onEvent(event)
                }
                startNext()
            }
        }
    }

    /// nil means "cancelled before anything was stored".
    private func export(_ photo: Photo) async -> (ExportEvent, String?)? {
        guard !Task.isCancelled else { return nil }
        let file: DownloadedPhoto
        do {
            file = try await downloader.download(photo)
        } catch {
            if Task.isCancelled || Self.isCancellation(error) { return nil }
            return (ExportEvent(photoID: photo.id, outcome: .failed(error.localizedDescription)), nil)
        }
        defer { try? FileManager.default.removeItem(at: file.fileURL) }
        guard !Task.isCancelled else { return nil }
        do {
            // Not cancellable: once PhotoKit has the file, the asset will exist, so always report it.
            let assetID = try await destination.store(file, for: photo)
            return (ExportEvent(photoID: photo.id, outcome: .saved), assetID)
        } catch {
            return (ExportEvent(photoID: photo.id, outcome: .failed(error.localizedDescription)), nil)
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
