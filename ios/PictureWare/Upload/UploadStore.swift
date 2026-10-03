import Foundation

/// On-disk home of the upload queue:
///
///     <directory>/state.json            queue items + uploaded ledger
///     <directory>/photos/<item id>      the prepared image bytes
///     <directory>/bodies/<item id>      multipart body for the current presign (background
///                                       sessions only upload from files)
///
/// Lives in Application Support (not Caches/tmp, which the system may purge mid-batch) and is
/// readable after first unlock so a background relaunch can use it.
struct UploadStore: Sendable {
    let directory: URL

    static var standard: UploadStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return UploadStore(directory: base.appending(path: "Uploads", directoryHint: .isDirectory))
    }

    private var stateURL: URL { directory.appending(path: "state.json") }
    private var photosDirectory: URL { directory.appending(path: "photos", directoryHint: .isDirectory) }
    private var bodiesDirectory: URL { directory.appending(path: "bodies", directoryHint: .isDirectory) }

    /// The saved state, or an empty one if there is none. A file we can't decode (e.g. written by
    /// a newer version) is moved aside rather than silently overwritten.
    func load() -> UploadQueueState {
        guard let data = try? Data(contentsOf: stateURL) else { return UploadQueueState() }
        if let state = try? APICoding.decoder().decode(UploadQueueState.self, from: data),
           state.version == UploadQueueState.currentVersion {
            return state
        }
        try? FileManager.default.moveItem(at: stateURL, to: directory.appending(path: "state-unreadable-\(UUID().uuidString).json"))
        return UploadQueueState()
    }

    func save(_ state: UploadQueueState) throws {
        try ensureDirectories()
        try write(APICoding.encoder().encode(state), to: stateURL)
    }

    func savePhoto(_ data: Data, itemID: String) throws {
        try ensureDirectories()
        try write(data, to: photoURL(itemID: itemID))
    }

    func photoData(itemID: String) throws -> Data {
        try Data(contentsOf: photoURL(itemID: itemID))
    }

    /// Writes the multipart body for `item`'s current presign and returns its file URL.
    func writeBody(for item: UploadItem, target: StoredUploadTarget) throws -> (url: URL, contentType: String) {
        let form = MultipartFormBody.s3Upload(
            fields: target.fields, file: try photoData(itemID: item.id),
            filename: "photo.\(item.contentType.fileExtension)", contentType: item.contentType.rawValue
        )
        try ensureDirectories()
        let url = bodyURL(itemID: item.id)
        try write(form.finalized(), to: url)
        return (url, form.contentType)
    }

    func bodyURL(itemID: String) -> URL { bodiesDirectory.appending(path: itemID) }

    func removeBody(itemID: String) {
        try? FileManager.default.removeItem(at: bodyURL(itemID: itemID))
    }

    func removeFiles(itemID: String) {
        try? FileManager.default.removeItem(at: photoURL(itemID: itemID))
        removeBody(itemID: itemID)
    }

    private func photoURL(itemID: String) -> URL { photosDirectory.appending(path: itemID) }

    private func ensureDirectories() throws {
        for url in [photosDirectory, bodiesDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directory
        try? directory.setResourceValues(values)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
