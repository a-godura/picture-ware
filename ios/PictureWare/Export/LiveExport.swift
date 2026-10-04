import CoreLocation
import Foundation
import ImageIO
import os
import Photos
import UniformTypeIdentifiers

/// Downloads a photo's original file (the presigned `imageUrl`) byte for byte, so the
/// file's own EXIF (capture date, GPS, camera) survives.
struct URLSessionPhotoDownloader: PhotoDownloading {
    var session: URLSession = .shared

    func download(_ photo: Photo) async throws -> DownloadedPhoto {
        let (temporary, response) = try await session.download(from: photo.imageUrl)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // S3 answers 403 once the presigned URL has expired (~1 hour).
            throw http.statusCode == 403 ? ExportError.linkExpired : ExportError.downloadFailed(status: http.statusCode)
        }
        guard let fileExtension = ExportFileNaming.imageExtension(of: temporary) else { throw ExportError.notAnImage }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PictureWareExport/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: ExportFileNaming.fileName(for: photo, extension: fileExtension))
        try FileManager.default.moveItem(at: temporary, to: destination)
        return DownloadedPhoto(fileURL: destination)
    }
}

enum ExportFileNaming {
    /// "jpg" / "heic" / ... from the file's actual bytes (not the URL or a declared type).
    static func imageExtension(of file: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .image)
        else { return nil }
        if type == .jpeg { return "jpg" }
        return type.preferredFilenameExtension
    }

    /// Sorts by capture time in Files: "2026-09-01 10.00.00 (ab12cd34).jpg". The id suffix keeps
    /// names unique for photos taken in the same second.
    static func fileName(for photo: Photo, extension fileExtension: String, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = photo.takenAt ?? photo.createdAt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d-%02d-%02d %02d.%02d.%02d",
                           c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let safeID = photo.id.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(8)
        return "\(stamp) (\(safeID)).\(fileExtension)"
    }
}

/// Adds originals to the Photos library with add-only access.
///
/// `PHAssetCreationRequest.addResource(with: .photo, fileURL:)` imports the file as is, so Photos
/// reads the capture date and location from its EXIF. Only when the file has no GPS / no capture
/// date (e.g. the uploader's location came from their library, not the file) do we fill them in
/// from the API's `lat`/`lng`/`takenAt`; the file itself is never rewritten.
struct PhotoLibraryDestination: PhotoDestination {
    func prepare() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else { throw ExportError.photosAccessDenied }
    }

    func store(_ file: DownloadedPhoto, for photo: Photo) async throws -> String? {
        let embedded = Self.embeddedMetadata(of: file.fileURL)
        let createdID = OSAllocatedUnfairLock<String?>(initialState: nil)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = file.fileURL.lastPathComponent
            request.addResource(with: .photo, fileURL: file.fileURL, options: options)
            if embedded.location == nil {
                request.location = CLLocation(latitude: photo.lat, longitude: photo.lng)
            }
            if embedded.takenAt == nil, let takenAt = photo.takenAt {
                request.creationDate = takenAt
            }
            let identifier = request.placeholderForCreatedAsset?.localIdentifier
            createdID.withLock { $0 = identifier }
        }
        return createdID.withLock { $0 }
    }

    /// Only possible when the user has also granted read access (the uploader asks for it to read
    /// a photo's location). With add-only access we can't see the library and trust the ledger.
    func existingAssetIDs(_ assetIDs: [String]) async -> Set<String>? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized, !assetIDs.isEmpty else { return nil }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        var found = Set<String>()
        result.enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
        return found
    }

    static func embeddedMetadata(of file: URL) -> LocationExtractor.Metadata {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return .init() }
        return LocationExtractor.metadata(fromProperties: properties)
    }
}

/// Copies originals into a folder, which the user then saves to Files in one go.
struct FolderDestination: PhotoDestination {
    let folder: URL

    func prepare() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func store(_ file: DownloadedPhoto, for photo: Photo) async throws -> String? {
        let name = file.fileURL.lastPathComponent
        var target = folder.appending(path: name)
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            target = folder.appending(path: "\(base) \(counter).\(ext)")
            counter += 1
        }
        try FileManager.default.copyItem(at: file.fileURL, to: target)
        return nil
    }
}

/// Persists photo id -> Photos asset local identifier in UserDefaults.
///
/// Scope: this app install on this device, i.e. effectively this device's Photos library.
/// Photo ids are server-generated and unique, so one map works across accounts.
final class UserDefaultsSavedPhotoLedger: SavedPhotoLedger {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "export.savedToPhotos.v1") {
        self.defaults = defaults
        self.key = key
    }

    private var entries: [String: String] {
        get { defaults.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    var count: Int { entries.count }
    func assetID(for photoID: String) -> String? { entries[photoID] }
    func record(photoID: String, assetID: String) { entries[photoID] = assetID }
    func forget(photoIDs: [String]) {
        var current = entries
        for id in photoIDs { current[id] = nil }
        entries = current
    }
    func forgetAll() { defaults.removeObject(forKey: key) }
}
