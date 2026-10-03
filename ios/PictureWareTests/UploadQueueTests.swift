import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PictureWare

/// Builds a queue over fakes and a fresh temporary store.
private struct Harness {
    let backend = FakeUploadBackend()
    let transport: FakeUploadTransport
    let clock = FakeClock()
    let store: UploadStore
    let queue: UploadQueue

    init(maxConcurrent: Int = 3, policy: RetryPolicy = UploadFixtures.policy,
         store: UploadStore = UploadFixtures.temporaryStore(),
         transport: FakeUploadTransport = FakeUploadTransport()) {
        self.store = store
        self.transport = transport
        queue = Self.makeQueue(backend: backend, transport: transport, store: store, clock: clock,
                               maxConcurrent: maxConcurrent, policy: policy)
    }

    static func makeQueue(backend: FakeUploadBackend, transport: FakeUploadTransport, store: UploadStore,
                          clock: FakeClock, maxConcurrent: Int = 3, policy: RetryPolicy = UploadFixtures.policy) -> UploadQueue {
        UploadQueue(backend: backend, transport: transport, store: store,
                    configuration: .init(maxConcurrent: maxConcurrent, retry: policy),
                    now: { clock.now }, sleep: { try await clock.sleep($0) })
    }

    @discardableResult
    func add(_ tag: String, destination: String = "photos", source: String? = nil) async throws -> String {
        let result = try await queue.enqueue(UploadFixtures.prepared(tag), sourceIdentifier: source, destination: destination)
        guard case .added(let id) = result else { throw TestFailure("expected \(tag) to be added, got \(result)") }
        return id
    }

    func run() async -> [UploadItem] {
        await queue.start()
        await queue.waitUntilIdle()
        return await queue.items
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@Suite("Upload queue", .timeLimit(.minutes(1)))
struct UploadQueueTests {
    // MARK: Happy path and concurrency

    @Test func uploadsEveryItemOnce() async throws {
        let h = Harness()
        for tag in ["a", "b", "c", "d", "e"] { try await h.add(tag) }
        let items = await h.run()

        #expect(items.count == 5)
        #expect(items.allSatisfy { $0.status == .done && $0.progress == 1 })
        #expect(await h.backend.createRequests.count == 5)
        let uploads = await h.transport.uploads
        #expect(uploads.count == 5)
        // Each upload used its own presign.
        #expect(Set(uploads.compactMap(\.key)) == ["photos/u/p1", "photos/u/p2", "photos/u/p3", "photos/u/p4", "photos/u/p5"])
        #expect(UploadSummary(items) == UploadSummary(items))
        #expect(UploadSummary(items).done == 5)
    }

    @Test func createRequestCarriesLocationAndType() async throws {
        let h = Harness()
        _ = try await h.queue.enqueue(UploadFixtures.prepared("a", lat: 48.85, lng: 2.29), sourceIdentifier: nil, destination: "photos")
        _ = await h.run()
        #expect(await h.backend.createRequests == [CreatePhotoRequest(lat: 48.85, lng: 2.29, takenAt: nil, contentType: .jpeg)])
    }

    @Test func concurrencyIsBounded() async throws {
        let h = Harness(maxConcurrent: 3)
        for index in 0..<12 { try await h.add("photo-\(index)") }
        let items = await h.run()
        #expect(items.allSatisfy { $0.status == .done })
        let maxInFlight = await h.transport.maxInFlight
        #expect(maxInFlight <= 3)
        #expect(maxInFlight >= 2) // they really ran in parallel
    }

    @Test func doneItemsReleaseTheirFiles() async throws {
        let h = Harness()
        let id = try await h.add("a")
        #expect((try? h.store.photoData(itemID: id)) != nil)
        _ = await h.run()
        #expect((try? h.store.photoData(itemID: id)) == nil)
        #expect(!FileManager.default.fileExists(atPath: h.store.bodyURL(itemID: id).path()))
    }

    // MARK: Retry and backoff

    @Test func transientStorageErrorsRetryWithBackoff() async throws {
        let transport = FakeUploadTransport { _, _, attempt in attempt <= 2 ? 500 : 204 }
        let h = Harness(transport: transport)
        try await h.add("a")
        let items = await h.run()

        #expect(items.first?.status == .done)
        #expect(await h.transport.uploads.count == 3)
        #expect(h.clock.sleeps == [2, 4]) // exponential
        // The presign was still fresh, so it was reused rather than creating more records.
        #expect(await h.backend.createRequests.count == 1)
    }

    @Test func transientAPIErrorsRetry() async throws {
        let h = Harness()
        await h.backend.setCreateErrors([APIError.http(status: 503, message: nil), APIError.http(status: 429, message: nil)])
        try await h.add("a")
        let items = await h.run()
        #expect(items.first?.status == .done)
        #expect(await h.backend.createRequests.count == 3)
        #expect(h.clock.sleeps == [2, 4])
    }

    @Test func givesUpAfterMaxAttemptsThenManualRetrySucceeds() async throws {
        let transport = FakeUploadTransport { _, _, _ in 500 }
        let h = Harness(transport: transport)
        let id = try await h.add("a")
        var items = await h.run()

        guard case .failed(let message) = items.first?.status else { Issue.record("expected failure"); return }
        #expect(message == APIError.uploadFailed(status: 500).errorDescription)
        #expect(items.first?.attempts == 5)
        #expect(await h.transport.uploads.count == 5)
        #expect(h.clock.sleeps == [2, 4, 8, 16])

        await h.transport.setResponder { _, _, _ in 204 }
        await h.queue.retry(itemID: id)
        await h.queue.waitUntilIdle()
        items = await h.queue.items
        #expect(items.first?.status == .done)
    }

    @Test func permanentErrorsAreNotRetried() async throws {
        let h = Harness()
        await h.backend.setCreateErrors([APIError.http(status: 400, message: "lat out of range")])
        try await h.add("a")
        let items = await h.run()
        #expect(items.first?.status == .failed("Server error (400): lat out of range"))
        #expect(await h.backend.createRequests.count == 1)
        #expect(h.clock.sleeps.isEmpty)
    }

    @Test func signedOutStopsWithoutRetrying() async throws {
        let h = Harness()
        await h.backend.setCreateErrors([APIError.unauthorized])
        try await h.add("a")
        let items = await h.run()
        #expect(items.first?.status == .failed(APIError.unauthorized.errorDescription!))
        #expect(await h.backend.createRequests.count == 1)
    }

    @Test func offlineWaitsWithoutUsingUpAttempts() async throws {
        // Seven connection failures (more than maxAttempts) and the upload still completes.
        let transport = FakeUploadTransport { _, _, attempt in
            if attempt <= 7 { throw URLError(.notConnectedToInternet) }
            return 204
        }
        let h = Harness(transport: transport)
        try await h.add("a")
        let items = await h.run()
        #expect(items.first?.status == .done)
        #expect(items.first?.attempts == 0)
        #expect(h.clock.sleeps == [2, 4, 8, 16, 32, 60, 60]) // capped
    }

    @Test func partialFailureDoesNotStopTheBatch() async throws {
        let h = Harness()
        let bad = try await h.add("bad")
        for tag in ["a", "b", "c"] { try await h.add(tag) }
        await h.transport.setResponder { itemID, _, _ in itemID == bad ? 400 : 204 }
        let items = await h.run()

        let summary = UploadSummary(items)
        #expect(summary.done == 3)
        #expect(summary.failed == 1)
        #expect(summary.fraction == 1)
        #expect(items.first { $0.id == bad }?.status == .failed(APIError.uploadFailed(status: 400).errorDescription!))
    }

    // MARK: Presign expiry and duplicates

    @Test func rejectedPresignIsReplacedWithANewOne() async throws {
        // Storage answers 403 (expired policy) to the first presign only.
        let transport = FakeUploadTransport { _, key, _ in key == "photos/u/p1" ? 403 : 204 }
        let h = Harness(transport: transport)
        try await h.add("a")
        let items = await h.run()

        #expect(items.first?.status == .done)
        #expect(items.first?.photoID == "p2")
        #expect(await h.transport.uploads.map(\.key) == ["photos/u/p1", "photos/u/p2"])
        // Checked that p1 hadn't landed before creating p2; retried immediately.
        #expect(await h.backend.listedChecks == ["p1"])
        #expect(h.clock.sleeps.isEmpty)
    }

    @Test func expiredPresignIsNotReplacedIfTheUploadAlreadyLanded() async throws {
        // The first upload's response is lost (timeout) but storage got the file. The retry
        // happens after the presign expired; the queue sees p1 is listed and doesn't create p2.
        let transport = FakeUploadTransport { _, _, _ in throw URLError(.timedOut) }
        let h = Harness(policy: RetryPolicy(maxAttempts: 5, baseDelay: 600, maxDelay: 600, jitter: 0), transport: transport)
        await h.backend.setListed(["p1"])
        try await h.add("a")
        let items = await h.run()

        #expect(items.first?.status == .done)
        #expect(items.first?.photoID == "p1")
        #expect(await h.backend.createRequests.count == 1)
        #expect(await h.transport.uploads.count == 1)
    }

    @Test func expiredPresignIsReplacedWhenTheUploadDidNotLand() async throws {
        let transport = FakeUploadTransport { _, _, attempt in
            if attempt == 1 { throw URLError(.timedOut) }
            return 204
        }
        let h = Harness(policy: RetryPolicy(maxAttempts: 5, baseDelay: 600, maxDelay: 600, jitter: 0), transport: transport)
        try await h.add("a")
        let items = await h.run()

        #expect(items.first?.status == .done)
        #expect(await h.backend.listedChecks == ["p1"])
        #expect(await h.transport.uploads.map(\.key) == ["photos/u/p1", "photos/u/p2"])
    }

    @Test func freshPresignIsReusedOnRetry() async throws {
        let transport = FakeUploadTransport { _, _, attempt in
            if attempt == 1 { throw URLError(.timedOut) }
            return 204
        }
        let h = Harness(transport: transport)
        try await h.add("a")
        _ = await h.run()
        // Same key both times: storage overwrites, so even a "lost" first success can't duplicate.
        #expect(await h.transport.uploads.map(\.key) == ["photos/u/p1", "photos/u/p1"])
        #expect(await h.backend.listedChecks.isEmpty)
    }

    @Test func samePictureIsQueuedOncePerDestination() async throws {
        let h = Harness()
        #expect(try await h.queue.enqueue(UploadFixtures.prepared("a"), sourceIdentifier: "A", destination: "photos") != .duplicate)
        #expect(try await h.queue.enqueue(UploadFixtures.prepared("a"), sourceIdentifier: "other", destination: "photos") == .duplicate)
        #expect(try await h.queue.enqueue(UploadFixtures.prepared("a"), sourceIdentifier: "A", destination: "trip-1") != .duplicate)
        #expect(await h.queue.contains(sourceIdentifier: "A", destination: "photos"))
        #expect(await !h.queue.contains(sourceIdentifier: "B", destination: "photos"))
        #expect(await h.queue.items.count == 2)
    }

    @Test func uploadedPicturesStayDedupedAfterClearingUntilForgotten() async throws {
        let h = Harness()
        try await h.add("a")
        _ = await h.run()
        await h.queue.clearCompleted()
        #expect(await h.queue.items.isEmpty)

        #expect(try await h.queue.enqueue(UploadFixtures.prepared("a"), sourceIdentifier: nil, destination: "photos") == .duplicate)

        // Deleting the photo makes it uploadable again.
        await h.queue.forget(photoID: "p1")
        #expect(try await h.queue.enqueue(UploadFixtures.prepared("a"), sourceIdentifier: nil, destination: "photos") != .duplicate)
    }

    // MARK: Persistence and relaunch

    @Test func stateSurvivesRelaunch() async throws {
        let store = UploadFixtures.temporaryStore()
        let first = Harness(store: store)
        try await first.add("a")
        try await first.add("b")
        let saved = await first.queue.items
        // Not started: simulates the app being killed before anything ran.

        let backend = FakeUploadBackend()
        let transport = FakeUploadTransport()
        let relaunched = Harness.makeQueue(backend: backend, transport: transport, store: store, clock: FakeClock())
        #expect(await relaunched.items == saved)

        await relaunched.start()
        await relaunched.waitUntilIdle()
        #expect(await relaunched.items.allSatisfy { $0.status == .done })
        #expect(await transport.uploads.count == 2)
    }

    @Test func persistedStateRoundTrips() throws {
        let store = UploadFixtures.temporaryStore()
        var item = UploadItem(id: "i1", dedupeKey: "photos|abc", destination: "photos", sourceIdentifier: "S1",
                              contentHash: "abc", contentType: .heic, lat: 1.5, lng: -2.5,
                              takenAt: Date(timeIntervalSince1970: 1_788_256_800), addedAt: Date(timeIntervalSince1970: 1_790_000_000))
        item.status = .failed("Upload failed (HTTP 400).")
        item.attempts = 2
        item.nextAttemptAt = Date(timeIntervalSince1970: 1_790_000_100)
        item.photoID = "p9"
        item.target = StoredUploadTarget(UploadTarget(url: URL(string: "https://b.example.com")!, fields: ["key": "k"]),
                                         issuedAt: Date(timeIntervalSince1970: 1_790_000_000))
        item.uploadAttempted = true
        let state = UploadQueueState(items: [item], uploaded: ["photos|old": "p1"])
        try store.save(state)
        #expect(store.load() == state)
    }

    @Test func unreadableStateStartsEmptyAndIsKeptAside() throws {
        let store = UploadFixtures.temporaryStore()
        try store.save(UploadQueueState())
        try Data("{not json".utf8).write(to: store.directory.appending(path: "state.json"))
        #expect(store.load() == UploadQueueState())
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path())
        #expect(files.contains { $0.hasPrefix("state-unreadable-") })
    }

    @Test func relaunchReattachesToARunningBackgroundUpload() async throws {
        let store = UploadFixtures.temporaryStore()
        let clock = FakeClock()
        let item = try Self.inFlightItem(store: store, issuedAt: clock.now.addingTimeInterval(-3600))
        let backend = FakeUploadBackend()
        let transport = FakeUploadTransport()
        await transport.setAttachable([item.id: 204])
        let queue = Harness.makeQueue(backend: backend, transport: transport, store: store, clock: clock)

        await queue.start()
        await queue.waitUntilIdle()
        #expect(await queue.items.first?.status == .done)
        // Even though its presign is long expired: the system finished the original upload.
        #expect(await backend.createRequests.isEmpty)
        #expect(await transport.uploads.isEmpty)
    }

    @Test func relaunchWithLostUploadChecksBeforeCreatingAgain() async throws {
        // The app was killed and the system dropped the task. The presign expired meanwhile.
        let store = UploadFixtures.temporaryStore()
        let clock = FakeClock()
        _ = try Self.inFlightItem(store: store, issuedAt: clock.now.addingTimeInterval(-3600))
        let backend = FakeUploadBackend()
        let transport = FakeUploadTransport()
        let queue = Harness.makeQueue(backend: backend, transport: transport, store: store, clock: clock)

        await queue.start()
        await queue.waitUntilIdle()
        #expect(await queue.items.first?.status == .done)
        #expect(await backend.listedChecks == ["p-old"])
        #expect(await transport.uploads.map(\.key) == ["photos/u/p1"])
    }

    @Test func relaunchMidCreateGoesBackToWaiting() async throws {
        let store = UploadFixtures.temporaryStore()
        var item = try Self.inFlightItem(store: store, issuedAt: Date())
        item.status = .creating
        item.photoID = nil
        item.target = nil
        item.uploadAttempted = false
        try store.save(UploadQueueState(items: [item]))
        let queue = Harness.makeQueue(backend: FakeUploadBackend(), transport: FakeUploadTransport(), store: store, clock: FakeClock())
        #expect(await queue.items.first?.status == .waiting)
    }

    // MARK: Removing

    @Test func removeCancelsAndDeletesFiles() async throws {
        let h = Harness()
        let id = try await h.add("a")
        await h.queue.remove(itemID: id)
        #expect(await h.queue.items.isEmpty)
        #expect(await h.transport.cancelled == [id])
        #expect((try? h.store.photoData(itemID: id)) == nil)
        #expect(h.store.load().items.isEmpty)
    }

    @Test func removeAllClearsEverything() async throws {
        let h = Harness()
        try await h.add("a")
        _ = await h.run()
        try await h.add("b")
        await h.queue.removeAll()
        #expect(await h.queue.items.isEmpty)
        #expect(h.store.load() == UploadQueueState())
        // Ledger is gone too: the next user can add the same picture.
        #expect(try await h.queue.enqueue(UploadFixtures.prepared("a"), sourceIdentifier: nil, destination: "photos") != .duplicate)
    }

    @Test func updatesStreamReportsProgress() async throws {
        let h = Harness()
        try await h.add("a")
        let stream = await h.queue.updates()
        await h.queue.start()
        var statuses: [UploadItem.Status] = []
        for await items in stream {
            if let status = items.first?.status, statuses.last != status { statuses.append(status) }
            if items.first?.status == .done { break }
        }
        #expect(statuses.first == .waiting || statuses.first == .creating)
        #expect(statuses.contains(.uploading))
        #expect(statuses.last == .done)
    }

    // MARK: Helpers

    /// An item persisted as `.uploading` with a presign issued at `issuedAt`.
    private static func inFlightItem(store: UploadStore, issuedAt: Date) throws -> UploadItem {
        let prepared = UploadFixtures.prepared("relaunch")
        var item = UploadItem(id: "item-1", dedupeKey: "photos|x", destination: "photos", sourceIdentifier: nil,
                              contentHash: "x", contentType: .jpeg, lat: 1, lng: 2, takenAt: nil, addedAt: issuedAt)
        item.status = .uploading
        item.photoID = "p-old"
        item.target = StoredUploadTarget(UploadTarget(url: URL(string: "https://bucket.example.com")!,
                                                      fields: ["key": "photos/u/p-old"]), issuedAt: issuedAt)
        item.uploadAttempted = true
        try store.savePhoto(prepared.data, itemID: item.id)
        try store.save(UploadQueueState(items: [item]))
        return item
    }
}

@Suite("Upload policy")
struct UploadPolicyTests {
    @Test func backoffDoublesAndCaps() {
        let policy = UploadFixtures.policy
        #expect((1...7).map { policy.delay(afterAttempt: $0) } == [2, 4, 8, 16, 32, 60, 60])
    }

    @Test func jitterOnlyShortensWithinBounds() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 10, maxDelay: 60, jitter: 0.25)
        #expect(policy.delay(afterAttempt: 1, random: 0) == 10)
        #expect(policy.delay(afterAttempt: 1, random: 1) == 7.5)
    }

    @Test("Failure classification", arguments: [
        (APIError.http(status: 503, message: nil) as any Error, FailureKind.transient),
        (APIError.http(status: 429, message: nil), .transient),
        (APIError.http(status: 400, message: nil), .permanent),
        (APIError.http(status: 413, message: nil), .permanent),
        (APIError.unauthorized, .needsSignIn),
        (AuthError.sessionExpired, .needsSignIn),
        (AuthError.badResponse(500), .transient),
        (APIError.uploadFailed(status: 403), .presignRejected),
        (APIError.uploadFailed(status: 500), .transient),
        (APIError.uploadFailed(status: 400), .permanent),
        (URLError(.notConnectedToInternet), .offline),
        (URLError(.networkConnectionLost), .offline),
        (URLError(.timedOut), .transient),
        (CocoaError(.fileNoSuchFile), .transient),
    ])
    func classification(error: any Error, expected: FailureKind) {
        #expect(UploadFailure.classify(error) == expected)
    }

    @Test func presignLifetime() {
        let issued = Date(timeIntervalSince1970: 0)
        let target = StoredUploadTarget(UploadTarget(url: URL(string: "https://b.example.com")!, fields: [:]), issuedAt: issued)
        #expect(target.isUsable(at: issued.addingTimeInterval(7 * 60)))
        #expect(!target.isUsable(at: issued.addingTimeInterval(8 * 60)))
    }

    @Test func summaryCountsPartialProgress() {
        func item(_ status: UploadItem.Status, progress: Double = 0) -> UploadItem {
            var item = UploadItem(id: UUID().uuidString, dedupeKey: "", destination: "", sourceIdentifier: nil, contentHash: "",
                                  contentType: .jpeg, lat: 0, lng: 0, takenAt: nil, addedAt: Date())
            item.status = status
            item.progress = progress
            return item
        }
        let summary = UploadSummary([item(.done), item(.uploading, progress: 0.5), item(.waiting), item(.failed("x"))])
        #expect(summary.total == 4)
        #expect(summary.done == 1)
        #expect(summary.failed == 1)
        #expect(summary.active == 2)
        #expect(summary.fraction == 0.5) // (1 + 0.5) / 3 not-failed items
        #expect(UploadSummary([]).isEmpty)
    }

    @Test func bodyFileIsAPresignedPostForm() throws {
        let store = UploadFixtures.temporaryStore()
        let item = UploadItem(id: "i1", dedupeKey: "", destination: "", sourceIdentifier: nil, contentHash: "",
                              contentType: .heic, lat: 0, lng: 0, takenAt: nil, addedAt: Date())
        try store.savePhoto(Data("HEICDATA".utf8), itemID: item.id)
        let target = StoredUploadTarget(UploadTarget(url: URL(string: "https://b.example.com")!,
                                                     fields: ["key": "photos/u/p1", "policy": "pol"]), issuedAt: Date())
        let (url, contentType) = try store.writeBody(for: item, target: target)
        let body = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        #expect(body.hasPrefix("--\(boundary)\r\n"))
        #expect(body.hasSuffix("--\(boundary)--\r\n"))
        #expect(FakeUploadTransport.field("key", in: body) == "photos/u/p1")
        #expect(body.contains("filename=\"photo.heic\"\r\nContent-Type: image/heic\r\n\r\nHEICDATA\r\n"))
        // The file comes after every policy field.
        let file = try #require(body.range(of: "name=\"file\""))
        let policy = try #require(body.range(of: "name=\"policy\""))
        #expect(policy.lowerBound < file.lowerBound)
    }
}

@Suite("Bulk import", .timeLimit(.minutes(1)))
struct BulkImportTests {
    @Test func reportsEachPhotoWithoutFailingTheBatch() async throws {
        let h = Harness()
        let withGPS: @Sendable (Double) -> Data = { lat in
            TestFixtures.image(gps: TestFixtures.gps(lat: lat, latRef: "N", lng: 9.1, lngRef: "W"))
        }
        let candidates = [
            ImportCandidate(identifier: nil, declaredType: .jpeg) { withGPS(38.70) },
            ImportCandidate(identifier: nil, declaredType: .jpeg) { TestFixtures.image() },          // no location
            ImportCandidate(identifier: nil, declaredType: .jpeg) { nil },                            // unreadable
            ImportCandidate(identifier: nil, declaredType: .jpeg) { withGPS(38.71) },
            ImportCandidate(identifier: nil, declaredType: .jpeg) { withGPS(38.70) },                 // same picture again
            ImportCandidate(identifier: nil, declaredType: .jpeg) { throw CocoaError(.fileReadCorruptFile) },
        ]
        let progress = ProgressRecorder()
        let report = await BulkImporter.run(candidates, into: h.queue, destination: "photos",
                                            onProgress: { await progress.record($0) })

        #expect(report.added == 2)
        #expect(report.duplicates == 1)
        #expect(report.rejections.map(\.position) == [2, 3, 6])
        #expect(report.rejections[0].reason == UploadPreparationError.noLocation.errorDescription)
        #expect(report.rejections[0].thumbnail != nil)
        #expect(report.rejections[1].reason == UploadPreparationError.unreadableImage.errorDescription)
        #expect(report.rejections[1].thumbnail == nil)
        #expect(await h.queue.items.count == 2)
        #expect(await progress.values == [0, 1, 2, 3, 4, 5, 6])
    }

    @Test func knownPickerItemsAreSkippedWithoutLoading() async throws {
        let h = Harness()
        try await h.add("a", source: "asset-1")
        let loads = ProgressRecorder()
        let report = await BulkImporter.run([
            ImportCandidate(identifier: "asset-1", declaredType: .jpeg) { await loads.record(1); return Data() },
        ], into: h.queue, destination: "photos")
        #expect(report.duplicates == 1)
        #expect(await loads.values.isEmpty)
    }

    @Test func selectionIsCapped() async throws {
        let h = Harness()
        let candidates = (0..<(BulkImporter.maxSelection + 5)).map { index in
            ImportCandidate(identifier: nil, declaredType: .jpeg) {
                TestFixtures.image(gps: TestFixtures.gps(lat: 1 + Double(index) / 1000, latRef: "N", lng: 1, lngRef: "E"))
            }
        }
        let report = await BulkImporter.run(candidates, into: h.queue, destination: "photos")
        #expect(report.added + report.duplicates == BulkImporter.maxSelection)
    }
}

private actor ProgressRecorder {
    private(set) var values: [Int] = []
    func record(_ value: Int) { values.append(value) }
}
