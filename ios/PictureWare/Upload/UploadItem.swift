import Foundation

/// One photo in the upload queue. Persisted (as part of `UploadQueueState`) so a batch survives
/// the app being suspended, killed or relaunched.
struct UploadItem: Codable, Sendable, Identifiable, Equatable {
    enum Status: Codable, Sendable, Equatable {
        /// Queued, or waiting out a retry backoff (`nextAttemptAt`).
        case waiting
        /// Asking the API for a photo record and presigned upload.
        case creating
        /// Sending the file to storage.
        case uploading
        /// Storage accepted the file. The backend lists it shortly after.
        case done
        /// Gave up; the user can retry or remove it.
        case failed(String)
    }

    let id: String
    /// `destination|contentHash`: the same picture is uploaded at most once per destination.
    let dedupeKey: String
    let destination: String
    /// `PhotosPickerItem.itemIdentifier`, when the picker gave one.
    let sourceIdentifier: String?
    let contentHash: String
    let contentType: PhotoContentType
    let lat: Double
    let lng: Double
    let takenAt: Date?
    let addedAt: Date

    var status: Status = .waiting
    /// 0...1 while uploading. Not meaningful in other states.
    var progress: Double = 0
    /// Failed attempts that count toward the retry limit (offline time doesn't).
    var attempts = 0
    /// Retries spent waiting for a connection; only used to space them out.
    var offlineRetries = 0
    var nextAttemptAt: Date?
    var lastError: String?
    /// Set once the API created the record; the presign belongs to this id.
    var photoID: String?
    var target: StoredUploadTarget?
    /// True once bytes may have reached storage with the current `photoID`. Before replacing an
    /// expired presign we then check whether that photo already landed, so a retry can't duplicate it.
    var uploadAttempted = false

    var createRequest: CreatePhotoRequest {
        CreatePhotoRequest(lat: lat, lng: lng, takenAt: takenAt, contentType: contentType)
    }

    var isFinished: Bool {
        switch status {
        case .done, .failed: true
        case .waiting, .creating, .uploading: false
        }
    }
}

/// `UploadTarget` plus when we got it (the presigned POST policy expires after 10 minutes).
struct StoredUploadTarget: Codable, Sendable, Equatable {
    let url: URL
    let fields: [String: String]
    let issuedAt: Date

    init(_ target: UploadTarget, issuedAt: Date) {
        url = target.url
        fields = target.fields
        self.issuedAt = issuedAt
    }

    /// The API's policy lasts 10 minutes; treat it as stale a little early so an upload that starts
    /// now has time to finish.
    static let usableLifetime: TimeInterval = 8 * 60

    func isUsable(at now: Date) -> Bool {
        now.timeIntervalSince(issuedAt) < Self.usableLifetime
    }
}

/// Everything the queue persists.
struct UploadQueueState: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version = currentVersion
    var items: [UploadItem] = []
    /// `dedupeKey -> photoID` for photos already uploaded and cleared from the list, so picking
    /// the same photo again doesn't add it twice.
    var uploaded: [String: String] = [:]
}

/// Outcome of adding one picked photo.
enum EnqueueResult: Sendable, Equatable {
    case added(itemID: String)
    /// Already queued, or already uploaded to this destination.
    case duplicate
}
