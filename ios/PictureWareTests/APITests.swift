import Foundation
import Testing
@testable import PictureWare

@Suite("Multipart body")
struct MultipartFormBodyTests {
    @Test func s3UploadLayout() {
        let file = Data([0xFF, 0xD8, 0xFF, 0x00, 0x01])
        let form = MultipartFormBody.s3Upload(
            fields: ["policy": "pol", "key": "photos/abc", "Content-Type": "image/jpeg", "X-Amz-Signature": "sig"],
            file: file, filename: "photo.jpg", contentType: "image/jpeg", boundary: "BOUNDARY"
        )
        #expect(form.contentType == "multipart/form-data; boundary=BOUNDARY")

        let body = form.finalized()
        let head = Data("""
        --BOUNDARY\r
        Content-Disposition: form-data; name="Content-Type"\r
        \r
        image/jpeg\r
        --BOUNDARY\r
        Content-Disposition: form-data; name="X-Amz-Signature"\r
        \r
        sig\r
        --BOUNDARY\r
        Content-Disposition: form-data; name="key"\r
        \r
        photos/abc\r
        --BOUNDARY\r
        Content-Disposition: form-data; name="policy"\r
        \r
        pol\r
        --BOUNDARY\r
        Content-Disposition: form-data; name="file"; filename="photo.jpg"\r
        Content-Type: image/jpeg\r
        \r

        """.utf8)
        let tail = Data("\r\n--BOUNDARY--\r\n".utf8)
        #expect(body == head + file + tail)
    }

    @Test func fileIsLastPart() throws {
        let fields = Dictionary(uniqueKeysWithValues: (0..<20).map { ("field\($0)", "v") })
        let body = MultipartFormBody.s3Upload(fields: fields, file: Data("IMG".utf8), filename: "p.heic",
                                              contentType: "image/heic", boundary: "B").finalized()
        let text = String(decoding: body, as: UTF8.self)
        let parts = text.components(separatedBy: "--B\r\n").dropFirst()
        #expect(parts.count == 21)
        #expect(parts.last!.hasPrefix("Content-Disposition: form-data; name=\"file\"; filename=\"p.heic\"\r\nContent-Type: image/heic"))
        #expect(text.hasSuffix("IMG\r\n--B--\r\n"))
        // Every part starts on its own line with the boundary delimiter.
        #expect(text.hasPrefix("--B\r\n"))
    }

    @Test func defaultBoundaryIsUnique() {
        #expect(MultipartFormBody().boundary != MultipartFormBody().boundary)
    }
}

@Suite("API models")
struct ModelTests {
    @Test func decodesPhotoList() throws {
        let json = """
        {"photos":[
          {"id":"6f1c0e8e","lat":37.8199,"lng":-122.4783,"takenAt":"2026-09-01T10:00:00Z",
           "createdAt":"2026-10-01T18:00:00.123456789Z","imageUrl":"https://bucket.s3.us-east-2.amazonaws.com/photos/6f1c0e8e?X-Amz-Signature=abc"},
          {"id":"b","lat":-33.8568,"lng":151.2153,"takenAt":null,
           "createdAt":"2026-10-01T18:00:00+02:00","imageUrl":"https://example.com/b"}
        ]}
        """
        let photos = try APICoding.decoder().decode(PhotoList.self, from: Data(json.utf8)).photos
        #expect(photos.count == 2)
        #expect(photos[0].id == "6f1c0e8e")
        #expect(photos[0].coordinate.latitude == 37.8199)
        #expect(photos[0].coordinate.longitude == -122.4783)
        #expect(photos[0].takenAt == Date(timeIntervalSince1970: 1_788_256_800))
        #expect(abs(photos[0].createdAt.timeIntervalSince1970 - 1_790_877_600.123) < 0.001)
        #expect(photos[0].imageUrl.query()?.contains("X-Amz-Signature") == true)
        #expect(photos[1].takenAt == nil)
        #expect(photos[1].createdAt == Date(timeIntervalSince1970: 1_790_877_600 - 7200))
    }

    @Test func decodesEmptyList() throws {
        let list = try APICoding.decoder().decode(PhotoList.self, from: Data(#"{"photos":[]}"#.utf8))
        #expect(list.photos.isEmpty)
    }

    @Test func decodesCreateResponse() throws {
        let json = """
        {"id":"abc","upload":{"url":"https://bucket.s3.us-east-2.amazonaws.com",
          "fields":{"key":"photos/abc","Content-Type":"image/heic","policy":"p","X-Amz-Signature":"s"}}}
        """
        let response = try APICoding.decoder().decode(CreatePhotoResponse.self, from: Data(json.utf8))
        #expect(response.id == "abc")
        #expect(response.upload.url.absoluteString == "https://bucket.s3.us-east-2.amazonaws.com")
        #expect(response.upload.fields["key"] == "photos/abc")
        #expect(response.upload.fields.count == 4)
    }

    @Test func encodesCreateRequest() throws {
        let request = CreatePhotoRequest(lat: 37.8199, lng: -122.4783,
                                         takenAt: Date(timeIntervalSince1970: 1_788_256_800), contentType: .heic)
        let json = String(decoding: try APICoding.encoder().encode(request), as: UTF8.self)
        #expect(json == #"{"contentType":"image\/heic","lat":37.8199,"lng":-122.4783,"takenAt":"2026-09-01T10:00:00Z"}"#)

        let noDate = CreatePhotoRequest(lat: 1, lng: 2, takenAt: nil, contentType: .jpeg)
        let object = try JSONSerialization.jsonObject(with: APICoding.encoder().encode(noDate)) as! [String: Any]
        #expect(Set(object.keys) == ["lat", "lng", "contentType"]) // takenAt omitted, not null
    }

    @Test func rejectsBadDate() {
        let json = #"{"photos":[{"id":"a","lat":0,"lng":0,"takenAt":"yesterday","createdAt":"x","imageUrl":"https://e.com"}]}"#
        #expect(throws: DecodingError.self) {
            try APICoding.decoder().decode(PhotoList.self, from: Data(json.utf8))
        }
    }
}
