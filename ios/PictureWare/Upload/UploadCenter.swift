import Observation
import PhotosUI
import SwiftUI
import UIKit

/// Main-actor view of the upload queue for SwiftUI, plus import of picker selections.
///
/// There is one per process (`shared`) because the queue's files and the background `URLSession`
/// are process-wide. It's activated with a backend once the user is signed in.
@MainActor
@Observable
final class UploadCenter {
    static let shared = UploadCenter()

    /// Where photos go. Today every photo belongs to the signed-in user's single map; trips will
    /// add more destinations.
    static let defaultDestination = "photos"

    private(set) var items: [UploadItem] = []
    private(set) var summary = UploadSummary([])
    /// `(done, total)` while a selection is being read and queued.
    private(set) var importing: (done: Int, total: Int)?
    /// Photos from recent picks that couldn't be queued.
    private(set) var rejections: [ImportRejection] = []
    /// Photos from recent picks that were skipped because they're already queued or uploaded.
    private(set) var skippedDuplicates = 0
    /// Bumped whenever an item finishes uploading (so the map can refresh).
    private(set) var completedGeneration = 0

    @ObservationIgnored private(set) var queue: UploadQueue?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private let transport: any UploadTransport
    @ObservationIgnored private let store: UploadStore

    init(transport: any UploadTransport = BackgroundUploadTransport.shared, store: UploadStore = .standard) {
        self.transport = transport
        self.store = store
    }

    var isVisible: Bool { !items.isEmpty || importing != nil || !rejections.isEmpty }

    /// Starts (or resumes) uploading with `backend`. Safe to call repeatedly; the first call wins
    /// until `signOut()`.
    func activate(backend: any UploadBackend) {
        guard queue == nil else { return }
        let queue = UploadQueue(backend: backend, transport: transport, store: store)
        self.queue = queue
        observation = Task { [weak self] in
            for await items in await queue.updates() {
                self?.apply(items)
            }
        }
        Task { await queue.start() }
    }

    /// Clears the queue and everything it stored. Pending uploads belong to the user signing out.
    func signOut() async {
        observation?.cancel()
        observation = nil
        await queue?.removeAll()
        queue = nil
        apply([])
        rejections = []
        skippedDuplicates = 0
    }

    func importPicked(_ items: [PhotosPickerItem]) async {
        await importCandidates(items.map(ImportCandidate.init))
    }

    func importCandidates(_ candidates: [ImportCandidate]) async {
        guard let queue, !candidates.isEmpty, importing == nil else { return }
        let total = min(candidates.count, BulkImporter.maxSelection)
        importing = (0, total)
        let report = await BulkImporter.run(candidates, into: queue, destination: Self.defaultDestination,
                                            onProgress: { done in
            await MainActor.run { [weak self] in self?.importing = (done, total) }
        })
        importing = nil
        rejections += report.rejections
        skippedDuplicates += report.duplicates
    }

    func retry(_ item: UploadItem) { Task { await queue?.retry(itemID: item.id) } }
    func retryAllFailed() { Task { await queue?.retryAllFailed() } }
    func remove(_ item: UploadItem) { Task { await queue?.remove(itemID: item.id) } }
    func retryWaitingNow() { Task { await queue?.retryWaitingNow() } }
    func forget(photoID: String) { Task { await queue?.forget(photoID: photoID) } }

    /// Hides finished uploads and import notes.
    func dismissFinished() {
        rejections = []
        skippedDuplicates = 0
        Task { await queue?.clearCompleted() }
    }

    func dismissRejection(_ rejection: ImportRejection) {
        rejections.removeAll { $0.id == rejection.id }
    }

    private func apply(_ items: [UploadItem]) {
        let previousDone = Set(self.items.filter { $0.status == .done }.map(\.id))
        let nowDone = Set(items.filter { $0.status == .done }.map(\.id))
        self.items = items
        summary = UploadSummary(items)
        if !nowDone.subtracting(previousDone).isEmpty { completedGeneration += 1 }
    }
}

/// Lets the system hand background-upload events to the app when it relaunches it for them.
final class UploadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Recreating the background session early reconnects to uploads that ran while we were gone.
        _ = BackgroundUploadTransport.shared
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploadTransport.sessionIdentifier else {
            completionHandler()
            return
        }
        nonisolated(unsafe) let handler = completionHandler
        BackgroundUploadTransport.shared.setEventsCompletionHandler { handler() }
    }
}
