#if DEBUG
import Foundation

/// The upload queue's transport in mock mode: instead of POSTing the multipart body to
/// storage, unpacks it (policy fields + `file`) and hands it to `MockAPI.upload`, which applies
/// the same checks as the presigned policy. Debug only.
actor MockUploadTransport: UploadTransport {
    let api: MockAPI

    init(api: MockAPI) { self.api = api }

    func attach(itemID: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Int? { nil }

    func upload(itemID: String, bodyFile: URL, contentType: String, to url: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        guard let boundary = Self.boundary(in: contentType),
              let form = Self.parse(try Data(contentsOf: bodyFile), boundary: boundary),
              let file = form.file, let type = form.fields["Content-Type"].flatMap(PhotoContentType.init(rawValue:))
        else { return 400 }
        do {
            try await api.upload(file, contentType: type, to: UploadTarget(url: url, fields: form.fields), progress: progress)
            return 204
        } catch APIError.uploadFailed(let status) {
            return status
        }
    }

    func cancel(itemID: String) async {}

    // MARK: - multipart/form-data (as written by `MultipartFormBody`)

    static func boundary(in contentType: String) -> String? {
        contentType.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("boundary=") }
            .map { String($0.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }

    /// Text fields by name, plus the part named `file`.
    static func parse(_ body: Data, boundary: String) -> (fields: [String: String], file: Data?)? {
        let delimiter = Data("--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        var fields: [String: String] = [:]
        var file: Data?
        guard var cursor = body.range(of: delimiter)?.upperBound else { return nil }
        while true {
            // "--" after the delimiter closes the body.
            if body[cursor...].starts(with: Data("--".utf8)) { return (fields, file) }
            guard body[cursor...].starts(with: crlf) else { return nil }
            let partStart = cursor + crlf.count
            guard let next = body.range(of: crlf + delimiter, in: partStart..<body.endIndex),
                  let headersRange = body.range(of: headerEnd, in: partStart..<next.lowerBound)
            else { return nil }
            let headers = String(decoding: body[partStart..<headersRange.lowerBound], as: UTF8.self)
            let content = body[headersRange.upperBound..<next.lowerBound]
            guard let name = Self.name(in: headers) else { return nil }
            if name == "file" { file = Data(content) } else { fields[name] = String(decoding: content, as: UTF8.self) }
            cursor = next.upperBound
        }
    }

    private static func name(in headers: String) -> String? {
        guard let range = headers.range(of: "name=\"") else { return nil }
        let rest = headers[range.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
}
#endif
