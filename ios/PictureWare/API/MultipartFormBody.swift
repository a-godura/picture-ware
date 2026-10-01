import Foundation

/// Minimal `multipart/form-data` builder (RFC 7578) for S3 presigned POST.
/// Parts are written in the order they are added; S3 requires `file` last.
struct MultipartFormBody: Sendable {
    let boundary: String
    private var body = Data()

    init(boundary: String = "PictureWare-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(escape(name))\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func addFile(name: String, filename: String, contentType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(escape(name))\"; filename=\"\(escape(filename))\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    /// The finished body including the closing boundary.
    func finalized() -> Data {
        var data = body
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    /// Presigned POST body: every policy field (sorted for determinism), then `file`.
    static func s3Upload(fields: [String: String], file: Data, filename: String, contentType: String,
                         boundary: String = "PictureWare-\(UUID().uuidString)") -> MultipartFormBody {
        var form = MultipartFormBody(boundary: boundary)
        for key in fields.keys.sorted() {
            form.addField(name: key, value: fields[key]!)
        }
        form.addFile(name: "file", filename: filename, contentType: contentType, data: file)
        return form
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}
