import CryptoKit
import Foundation

/// Uploads photos reliably, a few at a time.
///
/// - **Survives relaunch:** every state change is written to `UploadStore` before the next step,
///   and on launch the queue picks up where it left off (re-attaching to uploads the system kept
///   running in the background).
/// - **Retries** transient failures with exponential backoff; waits out lost connectivity without
///   using up attempts; replaces an expired presigned upload with a fresh one.
/// - **No duplicates:** the same picture (by content hash) is queued at most once per destination,
///   is remembered after it's uploaded, and an expired presign is only replaced after checking
///   that the earlier attempt didn't already land.
actor UploadQueue {
    struct Configuration: Sendable {
        var maxConcurrent = 3
        var retry = RetryPolicy.standard
    }

    private let backend: any UploadBackend
    private let transport: any UploadTransport
    private let store: UploadStore
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var state: UploadQueueState
    private var started = false
    private var running: [String: Task<Void, Never>] = [:]
    private var wakeTask: Task<Void, Never>?
    private var wakeAt: Date?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [UUID: AsyncStream<[UploadItem]>.Continuation] = [:]

    init(
        backend: any UploadBackend,
        transport: any UploadTransport,
        store: UploadStore = .standard,
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.backend = backend
        self.transport = transport
        self.store = store
        self.configuration = configuration
        self.now = now
        self.sleep = sleep
        var state = store.load()
        for index in state.items.indices where state.items[index].status == .creating {
            // We don't know whether the record was created; a new one is harmless (an unused
            // pending record is never listed).
            state.items[index].status = .waiting
        }
        self.state = state
    }

    // MARK: - Reading

    var items: [UploadItem] { state.items }

    /// The current items, then every change.
    func updates() -> AsyncStream<[UploadItem]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [UploadItem].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(state.items)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    /// Whether a picker item is already queued or uploaded here (lets the importer skip loading it).
    func contains(sourceIdentifier: String, destination: String) -> Bool {
        state.items.contains { $0.sourceIdentifier == sourceIdentifier && $0.destination == destination }
    }

    /// Returns once nothing is running or waiting to run (every item is done or failed).
    func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - Changing

    /// Starts processing (restored items first). Call once the backend is usable (signed in).
    func start() {
        started = true
        pump()
    }

    func enqueue(_ prepared: PreparedUpload, sourceIdentifier: String?, destination: String) throws -> EnqueueResult {
        let hash = Self.contentHash(prepared.data)
        let key = "\(destination)|\(hash)"
        if state.uploaded[key] != nil || state.items.contains(where: { $0.dedupeKey == key }) {
            return .duplicate
        }
        let item = UploadItem(
            id: UUID().uuidString, dedupeKey: key, destination: destination, sourceIdentifier: sourceIdentifier,
            contentHash: hash, contentType: prepared.contentType, lat: prepared.location.latitude,
            lng: prepared.location.longitude, takenAt: prepared.takenAt, addedAt: now()
        )
        try store.savePhoto(prepared.data, itemID: item.id)
        state.items.append(item)
        persist()
        pump()
        return .added(itemID: item.id)
    }

    /// Tries a failed item again from scratch (fresh attempt budget).
    func retry(itemID: String) {
        update(itemID) { item in
            guard case .failed = item.status else { return }
            item.status = .waiting
            item.attempts = 0
            item.offlineRetries = 0
            item.nextAttemptAt = nil
            item.lastError = nil
        }
        persist()
        pump()
    }

    func retryAllFailed() {
        for item in state.items {
            if case .failed = item.status { retry(itemID: item.id) }
        }
    }

    /// Retries anything waiting out a backoff right away (e.g. the app came back to the foreground).
    func retryWaitingNow() {
        for index in state.items.indices where state.items[index].status == .waiting {
            state.items[index].nextAttemptAt = nil
        }
        pump()
    }

    /// Drops an item that isn't done yet, cancelling its upload.
    func remove(itemID: String) async {
        running.removeValue(forKey: itemID)?.cancel()
        await transport.cancel(itemID: itemID)
        state.items.removeAll { $0.id == itemID }
        store.removeFiles(itemID: itemID)
        persist()
        pump()
    }

    /// Removes finished (done) items from the list. They stay in the dedupe ledger.
    func clearCompleted() {
        state.items.removeAll { $0.status == .done }
        persist()
        publish()
    }

    /// The photo was deleted, so picking that picture again should upload it again.
    func forget(photoID: String) {
        state.uploaded = state.uploaded.filter { $0.value != photoID }
        state.items.removeAll { $0.status == .done && $0.photoID == photoID }
        persist()
        publish()
    }

    /// Cancels everything and forgets all state (sign-out).
    func removeAll() async {
        for (id, task) in running {
            task.cancel()
            await transport.cancel(itemID: id)
        }
        running = [:]
        for item in state.items { store.removeFiles(itemID: item.id) }
        state = UploadQueueState()
        persist()
        pump()
    }

    // MARK: - Scheduling

    private var isIdle: Bool {
        running.isEmpty && !state.items.contains { !$0.isFinished }
    }

    private func pump() {
        defer {
            publish()
            if isIdle {
                let waiters = idleWaiters
                idleWaiters = []
                waiters.forEach { $0.resume() }
            }
        }
        guard started else { return }
        let current = now()
        for item in state.items where running.count < configuration.maxConcurrent {
            guard running[item.id] == nil, !item.isFinished else { continue }
            if let next = item.nextAttemptAt, next > current { continue }
            let id = item.id
            running[id] = Task { await self.process(id) }
        }
        scheduleWake()
    }

    /// Sleeps until the earliest backoff ends, then pumps.
    private func scheduleWake() {
        let current = now()
        let next = state.items
            .filter { !$0.isFinished && running[$0.id] == nil }
            .compactMap(\.nextAttemptAt)
            .filter { $0 > current }
            .min()
        guard let next else {
            wakeTask?.cancel()
            wakeTask = nil
            wakeAt = nil
            return
        }
        if wakeAt == next, wakeTask != nil { return }
        wakeTask?.cancel()
        wakeAt = next
        let delay = next.timeIntervalSince(current)
        wakeTask = Task { [sleep] in
            try? await sleep(delay)
            guard !Task.isCancelled else { return }
            self.wake()
        }
    }

    private func wake() {
        wakeTask = nil
        wakeAt = nil
        pump()
    }

    private func process(_ id: String) async {
        do {
            try await attempt(id)
        } catch {
            if !Task.isCancelled { recordFailure(id, error) }
        }
        if running[id] != nil {
            running[id] = nil
            pump()
        }
    }

    // MARK: - One attempt

    private func attempt(_ id: String) async throws {
        // 1. The system may still be running (or have finished) an upload we started before a relaunch.
        if item(id)?.status == .uploading,
           let status = try await transport.attach(itemID: id, progress: progressHandler(id)) {
            try finishUpload(id, status: status)
            return
        }

        // 2. Make sure we hold a usable presign.
        guard var item = item(id) else { return }
        if item.target.map({ !$0.isUsable(at: now()) }) ?? true {
            if let photoID = item.photoID, item.uploadAttempted, try await backend.isPhotoListed(id: photoID) {
                markDone(id)
                return
            }
            update(id) { $0.status = .creating }
            persist()
            let response = try await backend.createPhoto(item.createRequest)
            guard self.item(id) != nil else { return } // removed meanwhile; the pending record is never listed
            let issuedAt = now()
            update(id) { item in
                item.photoID = response.id
                item.target = StoredUploadTarget(response.upload, issuedAt: issuedAt)
                item.uploadAttempted = false
            }
            store.removeBody(itemID: id)
            persist()
            guard let refreshed = self.item(id) else { return }
            item = refreshed
        }
        guard let target = item.target else { return }

        // 3. Upload from a file (background sessions require one).
        let body = try store.writeBody(for: item, target: target)
        update(id) { item in
            item.status = .uploading
            item.progress = 0
            item.uploadAttempted = true
        }
        persist()
        let status = try await transport.upload(
            itemID: id, bodyFile: body.url, contentType: body.contentType, to: target.url,
            progress: progressHandler(id)
        )
        try finishUpload(id, status: status)
    }

    private func finishUpload(_ id: String, status: Int) throws {
        guard (200..<300).contains(status) else { throw APIError.uploadFailed(status: status) }
        markDone(id)
    }

    private func markDone(_ id: String) {
        update(id) { item in
            item.status = .done
            item.progress = 1
            item.nextAttemptAt = nil
            item.lastError = nil
        }
        if let item = item(id), let photoID = item.photoID {
            state.uploaded[item.dedupeKey] = photoID
        }
        store.removeFiles(itemID: id)
        persist()
    }

    private func recordFailure(_ id: String, _ error: any Error) {
        guard item(id) != nil else { return }
        let kind = UploadFailure.classify(error)
        let message = UploadFailure.message(for: error)
        let policy = configuration.retry
        let current = now()
        update(id) { item in
            item.lastError = message
            item.progress = 0
            switch kind {
            case .permanent, .needsSignIn:
                item.status = .failed(message)
            case .offline:
                item.offlineRetries += 1
                item.status = .waiting
                item.nextAttemptAt = current.addingTimeInterval(policy.delay(afterAttempt: item.offlineRetries))
            case .transient, .presignRejected:
                item.attempts += 1
                if kind == .presignRejected { item.target = nil }
                if item.attempts >= policy.maxAttempts {
                    item.status = .failed(message)
                } else {
                    item.status = .waiting
                    // A rejected presign is replaced straight away the first time.
                    let delay = kind == .presignRejected && item.attempts == 1 ? 0 : policy.delay(afterAttempt: item.attempts)
                    item.nextAttemptAt = current.addingTimeInterval(delay)
                }
            }
        }
        persist()
    }

    // MARK: - Helpers

    private func progressHandler(_ id: String) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { await self?.setProgress(id, fraction) }
        }
    }

    private func setProgress(_ id: String, _ fraction: Double) {
        guard let index = state.items.firstIndex(where: { $0.id == id }),
              state.items[index].status == .uploading else { return }
        state.items[index].progress = min(1, max(0, fraction))
        publish()
    }

    private func item(_ id: String) -> UploadItem? {
        state.items.first { $0.id == id }
    }

    private func update(_ id: String, _ change: (inout UploadItem) -> Void) {
        guard let index = state.items.firstIndex(where: { $0.id == id }) else { return }
        change(&state.items[index])
        publish()
    }

    private func persist() {
        do {
            try store.save(state)
        } catch {
            // Keep going in memory; the next state change tries again.
            print("UploadQueue: couldn't save state: \(error)")
        }
    }

    private func publish() {
        for continuation in observers.values { continuation.yield(state.items) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Totals for a progress display.
struct UploadSummary: Equatable, Sendable {
    var total = 0
    var done = 0
    var failed = 0
    /// 0...1 across the whole batch (done items count fully, uploading ones partially).
    var fraction = 0.0

    var active: Int { total - done - failed }
    var isEmpty: Bool { total == 0 }

    init(_ items: [UploadItem]) {
        total = items.count
        var sum = 0.0
        for item in items {
            switch item.status {
            case .done: done += 1; sum += 1
            case .failed: failed += 1
            case .uploading: sum += item.progress
            case .waiting, .creating: break
            }
        }
        let counted = total - failed
        fraction = counted > 0 ? min(1, sum / Double(counted)) : 0
    }
}
