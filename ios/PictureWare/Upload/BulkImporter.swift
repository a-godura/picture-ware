import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One picked photo, before it's loaded. Abstracts `PhotosPickerItem` so import can be tested.
struct ImportCandidate: Sendable {
    let identifier: String?
    let declaredType: UTType?
    let load: @Sendable () async throws -> Data?

    init(identifier: String?, declaredType: UTType?, load: @escaping @Sendable () async throws -> Data?) {
        self.identifier = identifier
        self.declaredType = declaredType
        self.load = load
    }

    init(_ item: PhotosPickerItem) {
        self.init(identifier: item.itemIdentifier,
                  declaredType: item.supportedContentTypes.first { $0.conforms(to: .image) },
                  load: { try await item.loadTransferable(type: Data.self) })
    }
}

/// A picked photo that couldn't be queued, with a thumbnail so the user can tell which one.
struct ImportRejection: Identifiable, Sendable, Equatable {
    let id = UUID()
    /// 1-based position in the selection.
    let position: Int
    let reason: String
    /// Small JPEG, when the image could be read.
    let thumbnail: Data?
}

struct ImportReport: Sendable, Equatable {
    var added = 0
    var duplicates = 0
    var rejections: [ImportRejection] = []
}

/// Imports a multi-selection into the upload queue, one photo at a time (keeps memory flat for
/// large selections). A photo that can't be used (no location, unreadable, too large) is reported
/// and skipped; it never fails the rest of the batch.
enum BulkImporter {
    /// Most photos accepted from one pick.
    static let maxSelection = 50

    typealias Prepare = @Sendable (_ data: Data, _ identifier: String?, _ declaredType: UTType?) async throws -> PreparedUpload

    static func run(
        _ candidates: [ImportCandidate],
        into queue: UploadQueue,
        destination: String,
        prepare: Prepare = { try await PhotoImporter.prepare(data: $0, itemIdentifier: $1, declaredType: $2) },
        onProgress: @Sendable (Int) async -> Void = { _ in }
    ) async -> ImportReport {
        var report = ImportReport()
        for (index, candidate) in candidates.prefix(maxSelection).enumerated() {
            await onProgress(index)
            if Task.isCancelled { break }
            if let identifier = candidate.identifier,
               await queue.contains(sourceIdentifier: identifier, destination: destination) {
                report.duplicates += 1
                continue
            }
            var data: Data?
            do {
                data = try await candidate.load()
                guard let data else { throw UploadPreparationError.unreadableImage }
                let prepared = try await prepare(data, candidate.identifier, candidate.declaredType)
                switch try await queue.enqueue(prepared, sourceIdentifier: candidate.identifier, destination: destination) {
                case .added: report.added += 1
                case .duplicate: report.duplicates += 1
                }
            } catch {
                report.rejections.append(ImportRejection(
                    position: index + 1, reason: UploadFailure.message(for: error),
                    thumbnail: data.flatMap { thumbnail(from: $0) }
                ))
            }
        }
        await onProgress(min(candidates.count, maxSelection))
        return report
    }

    static func thumbnail(from data: Data, maxPixels: Int = 120) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
