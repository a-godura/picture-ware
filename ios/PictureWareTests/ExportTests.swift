import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PictureWare

// MARK: - Fakes

/// Serves the photo list and counts fetches (each run/retry re-fetches for fresh URLs).
actor FakePhotoSource {
    var photos: [Photo]
    private(set) var fetches = 0

    init(_ photos: [Photo]) { self.photos = photos }

    func fetch() -> [Photo] {
        fetches += 1
        return photos
    }

    func remove(_ id: String) { photos.removeAll { $0.id == id } }
}

actor FakeDownloader: PhotoDownloading {
    /// Photo id -> how many more attempts fail with `linkExpired`.
    var failuresLeft: [String: Int] = [:]
    /// Downloads of these ids hang until the task is cancelled.
    var blocked: Set<String> = []
    var delay: Duration = .zero
    private(set) var attempts: [String] = []
    private(set) var inFlight = 0
    private(set) var peakInFlight = 0

    init(failuresLeft: [String: Int] = [:], blocked: Set<String> = [], delay: Duration = .zero) {
        self.failuresLeft = failuresLeft
        self.blocked = blocked
        self.delay = delay
    }

    func unblockAll() { blocked = [] }

    func download(_ photo: Photo) async throws -> DownloadedPhoto {
        attempts.append(photo.id)
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        defer { inFlight -= 1 }
        if blocked.contains(photo.id) {
            try await Task.sleep(for: .seconds(60))
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let left = failuresLeft[photo.id], left > 0 {
            failuresLeft[photo.id] = left - 1
            throw ExportError.linkExpired
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "ExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(photo.id).jpg")
        try TestFixtures.image().write(to: file)
        return DownloadedPhoto(fileURL: file)
    }
}

actor FakeLibrary: PhotoDestination {
    var denied = false
    /// What `existingAssetIDs` answers; nil = "can't tell" (add-only access).
    var existing: Set<String>?
    private(set) var stored: [String] = []

    init(denied: Bool = false, existing: Set<String>? = nil) {
        self.denied = denied
        self.existing = existing
    }

    func prepare() async throws {
        if denied { throw ExportError.photosAccessDenied }
    }

    func store(_ file: DownloadedPhoto, for photo: Photo) async throws -> String? {
        #expect(FileManager.default.fileExists(atPath: file.fileURL.path(percentEncoded: false)))
        stored.append(photo.id)
        return "asset-\(photo.id)-\(stored.count)"
    }

    func existingAssetIDs(_ assetIDs: [String]) async -> Set<String>? { existing }
}

final class InMemoryLedger: SavedPhotoLedger {
    var entries: [String: String] = [:]
    var count: Int { entries.count }
    func assetID(for photoID: String) -> String? { entries[photoID] }
    func record(photoID: String, assetID: String) { entries[photoID] = assetID }
    func forget(photoIDs: [String]) { photoIDs.forEach { entries[$0] = nil } }
    func forgetAll() { entries = [:] }
}

enum ExportFixtures {
    static func photos(_ count: Int) -> [Photo] {
        (1...count).map { i in
            Photo(id: "p\(i)", lat: 10, lng: 20, takenAt: Date(timeIntervalSince1970: 1_788_256_800 + Double(i)),
                  createdAt: Date(timeIntervalSince1970: 1_788_260_000),
                  imageUrl: URL(string: "https://bucket.example.com/p\(i).jpg?X-Amz-Signature=x")!)
        }
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Model

@MainActor
@Suite("Save all photos")
struct ExportModelTests {
    let source: FakePhotoSource
    let downloader: FakeDownloader
    let library: FakeLibrary
    let ledger = InMemoryLedger()
    let filesRoot = FileManager.default.temporaryDirectory.appending(path: "ExportModelTests-\(UUID().uuidString)")

    init(count: Int = 5, downloader: FakeDownloader = FakeDownloader(), library: FakeLibrary = FakeLibrary()) {
        source = FakePhotoSource(ExportFixtures.photos(count))
        self.downloader = downloader
        self.library = library
    }

    func model(maxConcurrent: Int = 3) -> ExportModel {
        let source = source
        return ExportModel(fetchPhotos: { await source.fetch() }, downloader: downloader, library: library,
                           ledger: ledger, filesRoot: filesRoot, maxConcurrent: maxConcurrent)
    }

    @Test func savesEveryPhotoAndRemembersIt() async {
        let model = model()
        await model.run(.photos)
        #expect(model.phase == .finished)
        #expect(model.total == 5)
        #expect(model.saved == 5)
        #expect(model.failures.isEmpty)
        #expect(model.fractionComplete == 1)
        #expect(Set(await library.stored) == ["p1", "p2", "p3", "p4", "p5"])
        #expect(ledger.count == 5)
        #expect(model.rememberedCount == 5)
    }

    @Test func progressThenCancelThenResumeWithoutDuplicates() async throws {
        let test = ExportModelTests(downloader: FakeDownloader(blocked: ["p4", "p5"]))
        let model = test.model(maxConcurrent: 5)
        model.start(.photos)
        try await waitUntil { model.completed == 3 }
        #expect(model.phase == .running)
        #expect(model.fractionComplete == 0.6)

        model.cancel()
        await model.waitUntilIdle()
        #expect(model.phase == .cancelled)
        #expect(model.saved == 3)
        #expect(model.failures.isEmpty, "cancelled photos are not failures")
        #expect(test.ledger.count == 3)

        await test.downloader.unblockAll()
        model.start(.photos)
        await model.waitUntilIdle()
        #expect(model.phase == .finished)
        #expect(model.alreadySaved == 3)
        #expect(model.saved == 2)
        let stored = await test.library.stored
        #expect(stored.count == 5)
        #expect(Set(stored).count == 5, "no photo saved twice")
    }

    @Test func partialFailureThenRetryOnlyTheFailedOnes() async {
        let test = ExportModelTests(downloader: FakeDownloader(failuresLeft: ["p2": 1, "p4": 1]))
        let model = test.model()
        await model.run(.photos)
        #expect(model.phase == .finished)
        #expect(model.saved == 3)
        #expect(model.failures.map(\.id).sorted() == ["p2", "p4"])
        #expect(model.failures.allSatisfy { $0.message == ExportError.linkExpired.errorDescription })
        #expect(model.fractionComplete == 1)

        model.retryFailed()
        await model.waitUntilIdle()
        #expect(model.failures.isEmpty)
        #expect(model.saved == 5)
        #expect(model.total == 5)
        #expect(await test.source.fetches == 2, "retry fetches fresh URLs")
        let attempts = await test.downloader.attempts
        #expect(attempts.filter { $0 == "p1" }.count == 1, "retry doesn't touch photos that succeeded")
        #expect(Set(await test.library.stored).count == 5)
        #expect(await test.library.stored.count == 5)
    }

    @Test func retryDropsPhotosDeletedMeanwhile() async {
        let test = ExportModelTests(downloader: FakeDownloader(failuresLeft: ["p2": 1]))
        let model = test.model()
        await model.run(.photos)
        await test.source.remove("p2")
        model.retryFailed()
        await model.waitUntilIdle()
        #expect(model.failures.isEmpty)
        #expect(model.total == 4)
        #expect(model.fractionComplete == 1)
    }

    @Test func secondRunSkipsAlreadySavedWithoutDownloading() async {
        let model = model()
        await model.run(.photos)
        await model.run(.photos)
        #expect(model.alreadySaved == 5)
        #expect(model.saved == 0)
        #expect(await downloader.attempts.count == 5)
        #expect(await library.stored.count == 5)
    }

    @Test func savesAgainWhatWasDeletedFromTheLibraryWhenItCanTell() async {
        let test = ExportModelTests(library: FakeLibrary(existing: []))
        let model = test.model()
        await model.run(.photos)
        await model.run(.photos)
        #expect(model.saved == 5)
        #expect(await test.library.stored.count == 10)
    }

    @Test func singleSaveIsRememberedSoSaveAllSkipsIt() async throws {
        let model = model()
        try await model.saveToPhotos(ExportFixtures.photos(1)[0])
        #expect(await library.stored == ["p1"])
        await model.run(.photos)
        #expect(model.alreadySaved == 1)
        #expect(model.saved == 4)
        #expect(await library.stored.count == 5)
    }

    @Test func knowsWhichPhotosAreAlreadyInPhotosAndCanSaveAgain() async throws {
        let model = model()
        let photo = ExportFixtures.photos(1)[0]
        #expect(!model.isSavedToPhotos(photo.id))
        await model.run(.photos)
        #expect(model.isSavedToPhotos(photo.id))
        // "Save Again" from the detail sheet saves another copy on purpose.
        try await model.saveToPhotos(photo)
        #expect(await library.stored.filter { $0 == photo.id }.count == 2)
        model.forgetSavedHistory()
        #expect(!model.isSavedToPhotos(photo.id))
    }

    @Test func singleSaveRetriesWithAFreshURL() async throws {
        let test = ExportModelTests(downloader: FakeDownloader(failuresLeft: ["p1": 1]))
        let model = test.model()
        try await model.saveToPhotos(ExportFixtures.photos(1)[0])
        #expect(await test.source.fetches == 1)
        #expect(await test.library.stored == ["p1"])
    }

    @Test func singleSaveSurfacesPersistentFailure() async {
        let test = ExportModelTests(downloader: FakeDownloader(failuresLeft: ["p1": 5]))
        let model = test.model()
        await #expect(throws: (any Error).self) { try await model.saveToPhotos(ExportFixtures.photos(1)[0]) }
        #expect(await test.library.stored.isEmpty)
        #expect(test.ledger.count == 0)
    }

    @Test func concurrencyIsBounded() async {
        let test = ExportModelTests(count: 8, downloader: FakeDownloader(delay: .milliseconds(20)))
        let model = test.model(maxConcurrent: 2)
        await model.run(.photos)
        #expect(model.saved == 8)
        #expect(await test.downloader.peakInFlight == 2)
    }

    @Test func deniedPhotosAccessFailsBeforeDownloading() async {
        let test = ExportModelTests(library: FakeLibrary(denied: true))
        let model = test.model()
        await model.run(.photos)
        #expect(model.phase == .failed(ExportError.photosAccessDenied.errorDescription!))
        #expect(await test.downloader.attempts.isEmpty)
    }

    @Test func filesExportWritesEveryOriginalAndIgnoresPhotosHistory() async throws {
        ledger.record(photoID: "p1", assetID: "asset-p1")
        let model = model()
        await model.run(.files)
        #expect(model.phase == .finished)
        #expect(model.saved == 5)
        let folder = try #require(model.exportFolder)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        #expect(files.count == 5)
        #expect(files.allSatisfy { $0.hasSuffix(".jpg") })
        #expect(await library.stored.isEmpty)
        #expect(ledger.count == 1)

        // A new files export starts from an empty folder.
        await model.run(.files)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).count == 5)
    }
}

// MARK: - Engine and helpers

@Suite("Photo exporter")
struct PhotoExporterTests {
    @Test @MainActor func duplicateIDsAreExportedOnce() async {
        let library = FakeLibrary()
        var events: [ExportEvent] = []
        let photos = ExportFixtures.photos(2)
        await PhotoExporter(downloader: FakeDownloader(), destination: library)
            .run(photos + photos) { events.append($0) }
        #expect(events.count == 2)
        #expect(await library.stored.sorted() == ["p1", "p2"])
    }

    @Test func fileNameSortsByCaptureTime() {
        let photo = Photo(id: "3f2a9c1e-77aa-4b1d", lat: 1, lng: 1,
                          takenAt: Date(timeIntervalSince1970: 1_788_256_800), createdAt: .now,
                          imageUrl: URL(string: "https://x.example.com/a")!)
        let name = ExportFileNaming.fileName(for: photo, extension: "heic", timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "2026-09-01 10.00.00 (3f2a9c1e).heic")
    }

    @Test(arguments: [(UTType.jpeg, "jpg"), (UTType.heic, "heic")])
    func extensionComesFromTheBytes(type: UTType, expected: String) throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "sniff-\(UUID().uuidString).bin")
        try TestFixtures.image(type: type).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(ExportFileNaming.imageExtension(of: file) == expected)
    }

    @Test func nonImageHasNoExtension() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "sniff-\(UUID().uuidString).jpg")
        try Data("<Error>AccessDenied</Error>".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(ExportFileNaming.imageExtension(of: file) == nil)
    }

    @Test func folderDestinationKeepsBothFilesOnNameClash() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "folder-\(UUID().uuidString)")
        let destination = FolderDestination(folder: folder)
        try await destination.prepare()
        let source = FileManager.default.temporaryDirectory.appending(path: "same name.jpg")
        try TestFixtures.image().write(to: source)
        let photo = ExportFixtures.photos(1)[0]
        _ = try await destination.store(DownloadedPhoto(fileURL: source), for: photo)
        _ = try await destination.store(DownloadedPhoto(fileURL: source), for: photo)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        #expect(names == ["same name 2.jpg", "same name.jpg"])
    }

    @Test func userDefaultsLedgerPersists() throws {
        let suite = "ExportTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        UserDefaultsSavedPhotoLedger(defaults: defaults).record(photoID: "p1", assetID: "A/L0/001")
        let reloaded = UserDefaultsSavedPhotoLedger(defaults: defaults)
        #expect(reloaded.assetID(for: "p1") == "A/L0/001")
        reloaded.forget(photoIDs: ["p1"])
        #expect(reloaded.count == 0)
    }

    @Test func embeddedMetadataIsReadFromTheFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "meta-\(UUID().uuidString).jpg")
        try TestFixtures.image(gps: TestFixtures.gps(lat: 48.8584, latRef: "N", lng: 2.2945, lngRef: "E"),
                               exif: [kCGImagePropertyExifDateTimeOriginal: "2026:09:01 12:00:00",
                                      kCGImagePropertyExifOffsetTimeOriginal: "+02:00"]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let metadata = PhotoLibraryDestination.embeddedMetadata(of: file)
        #expect(metadata.location != nil)
        #expect(metadata.takenAt == Date(timeIntervalSince1970: 1_788_256_800))
    }
}
