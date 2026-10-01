import Photos
import PhotosUI
import SwiftUI

/// Turns a `PhotosPickerItem` into a `PreparedUpload`.
///
/// Location comes from the file's own GPS metadata. If the file has none, we fall
/// back to `PHAsset.location` (asking for library access only at that point).
enum PhotoImporter {
    static func prepare(_ item: PhotosPickerItem) async throws -> PreparedUpload {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw UploadPreparationError.unreadableImage
        }
        var metadata = LocationExtractor.metadata(from: data)

        if metadata.location == nil, let identifier = item.itemIdentifier,
           let asset = await libraryAsset(identifier: identifier) {
            if let location = asset.location {
                let point = GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                metadata.location = point.isValid ? point : nil
            }
            metadata.takenAt = metadata.takenAt ?? asset.creationDate
        }

        guard let location = metadata.location else { throw UploadPreparationError.noLocation }
        let declaredType = item.supportedContentTypes.first { $0.conforms(to: .image) }
        let (fileData, contentType) = try UploadPreparation.encode(data, declaredType: declaredType)
        return PreparedUpload(data: fileData, contentType: contentType, location: location, takenAt: metadata.takenAt)
    }

    private static func libraryAsset(identifier: String) async -> PHAsset? {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }
}
