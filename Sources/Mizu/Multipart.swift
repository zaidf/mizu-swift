import Foundation

/// Just enough multipart/form-data for one report upload.
struct Multipart {
    let boundary = "mizu-\(UUID().uuidString)"
    private(set) var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, value: Data, contentType: String = "application/json") {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(value)
        append("\r\n")
    }

    mutating func addFile(_ name: String, filename: String, contentType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    mutating func finish() -> Data {
        append("--\(boundary)--\r\n")
        return body
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
