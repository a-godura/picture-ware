import Foundation
@testable import PictureWare

/// A clock whose `sleep` returns at once after moving time forward, so backoff is instant but
/// still measurable.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var _sleeps: [TimeInterval] = []
    var sleeps: [TimeInterval] { lock.withLock { _sleeps } }

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }

    func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock {
            _sleeps.append(seconds)
            current += max(0, seconds)
        }
        await Task.yield()
    }
}

/// Scripted API. Creates `p1`, `p2`, ... unless a scripted error is next in line.
actor FakeUploadBackend: UploadBackend {
    private(set) var createRequests: [CreatePhotoRequest] = []
    private(set) var listedChecks: [String] = []
    /// Errors returned by the next create calls, in order.
    var createErrors: [any Error] = []
    var listed: Set<String> = []
    /// Called after each successful create (e.g. to move the clock).
    var afterCreate: (@Sendable () -> Void)?

    func setCreateErrors(_ errors: [any Error]) { createErrors = errors }
    func setListed(_ ids: Set<String>) { listed = ids }
    func setAfterCreate(_ action: @escaping @Sendable () -> Void) { afterCreate = action }

    func createPhoto(_ request: CreatePhotoRequest) async throws -> CreatePhotoResponse {
        createRequests.append(request)
        if !createErrors.isEmpty { throw createErrors.removeFirst() }
        let id = "p\(createRequests.count)"
        afterCreate?()
        return CreatePhotoResponse(id: id, upload: UploadTarget(
            url: URL(string: "https://bucket.example.com")!,
            fields: ["key": "photos/u/\(id)", "policy": "policy-\(id)"]
        ))
    }

    func isPhotoListed(id: String) async throws -> Bool {
        listedChecks.append(id)
        return listed.contains(id)
    }
}

/// Records uploads; answers with `respond(itemID, key, attemptNumberForItem)`.
actor FakeUploadTransport: UploadTransport {
    struct Upload: Sendable, Equatable {
        let itemID: String
        /// The presign's `key` field, read back from the multipart body file.
        let key: String?
    }

    typealias Responder = @Sendable (_ itemID: String, _ key: String?, _ attempt: Int) throws -> Int

    private(set) var uploads: [Upload] = []
    private(set) var maxInFlight = 0
    private(set) var cancelled: [String] = []
    private var inFlight = 0
    private var respond: Responder
    /// Results for `attach` (uploads "still running" from before a relaunch).
    var attachable: [String: Int] = [:]
    /// Real delay per upload so concurrent uploads overlap.
    var duration: Duration = .milliseconds(5)

    init(respond: @escaping Responder = { _, _, _ in 204 }) { self.respond = respond }

    func setResponder(_ respond: @escaping Responder) { self.respond = respond }
    func setAttachable(_ results: [String: Int]) { attachable = results }

    func attach(itemID: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Int? {
        attachable.removeValue(forKey: itemID)
    }

    func upload(itemID: String, bodyFile: URL, contentType: String, to url: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        let body = (try? Data(contentsOf: bodyFile)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let key = Self.field("key", in: body)
        uploads.append(Upload(itemID: itemID, key: key))
        let attempt = uploads.filter { $0.itemID == itemID }.count
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        progress(0.5)
        try await Task.sleep(for: duration)
        progress(1)
        return try respond(itemID, key, attempt)
    }

    func cancel(itemID: String) async { cancelled.append(itemID) }

    /// Reads a multipart field value: `name="key"\r\n\r\nVALUE\r\n`.
    static func field(_ name: String, in body: String) -> String? {
        guard let range = body.range(of: "name=\"\(name)\"\r\n\r\n") else { return nil }
        return body[range.upperBound...].components(separatedBy: "\r\n").first
    }
}

enum UploadFixtures {
    static func prepared(_ tag: String, lat: Double = 38.7, lng: Double = -9.1) -> PreparedUpload {
        PreparedUpload(data: Data("image-bytes-\(tag)".utf8), contentType: .jpeg,
                       location: GeoPoint(latitude: lat, longitude: lng), takenAt: nil)
    }

    static func temporaryStore() -> UploadStore {
        UploadStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "upload-tests-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    /// Deterministic policy: 2 s, 4 s, 8 s, ... capped at 60 s; 5 attempts.
    static let policy = RetryPolicy(maxAttempts: 5, baseDelay: 2, maxDelay: 60, jitter: 0)
}
