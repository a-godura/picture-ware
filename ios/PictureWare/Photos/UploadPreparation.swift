import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo ready to be sent: bytes in an accepted format plus where/when it was taken.
struct PreparedUpload: Sendable {
    let data: Data
    let contentType: PhotoContentType
    let location: GeoPoint
    let takenAt: Date?
}

enum UploadPreparationError: LocalizedError, Equatable {
    case unreadableImage
    case noLocation
    case tooLarge(bytes: Int)

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "Couldn't read that image."
        case .noLocation: "This photo has no location, so it can't be placed on the map."
        case .tooLarge(let bytes):
            "This photo is too large (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), max 15 MB)."
        }
    }
}

enum UploadPreparation {
    /// Chooses `image/heic` or `image/jpeg`. Anything else (PNG, etc.) is re-encoded as JPEG;
    /// the location was already extracted, so metadata lost in re-encoding doesn't matter.
    static func encode(_ data: Data, declaredType: UTType?) throws -> (Data, PhotoContentType) {
        let detected = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap(CGImageSourceGetType)
            .flatMap { UTType($0 as String) }
        let type = detected ?? declaredType

        let result: (Data, PhotoContentType)
        if let type, type.conforms(to: .heic) || type.conforms(to: .heif) {
            result = (data, .heic)
        } else if let type, type.conforms(to: .jpeg) {
            result = (data, .jpeg)
        } else {
            result = (try jpegData(from: data), .jpeg)
        }
        guard result.0.count <= APIClient.maxUploadBytes else {
            throw UploadPreparationError.tooLarge(bytes: result.0.count)
        }
        return result
    }

    static func jpegData(from data: Data, quality: Double = 0.9) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw UploadPreparationError.unreadableImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw UploadPreparationError.unreadableImage }
        // Keep orientation so the re-encoded image displays upright.
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let orientation = props[kCGImagePropertyOrientation] {
            options[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw UploadPreparationError.unreadableImage }
        return output as Data
    }
}
