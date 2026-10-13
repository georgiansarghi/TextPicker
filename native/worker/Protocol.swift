import Foundation

/// Framing is independent of JSON parsing and bounded even without a newline.
struct RequestFramer {
    static let maximumLineBytes = 65_536
    private var buffer = Data()
    private var discarding = false

    mutating func feed(_ bytes: ArraySlice<UInt8>, line: (Data) -> Void, overflow: () -> Void) {
        for byte in bytes {
            if byte == 10 {
                if !discarding { line(buffer) }
                buffer.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if buffer.count == Self.maximumLineBytes {
                    buffer.removeAll(keepingCapacity: true)
                    discarding = true
                    overflow()
                } else {
                    buffer.append(byte)
                }
            }
        }
    }

    mutating func finish(line: (Data) -> Void) {
        if !buffer.isEmpty && !discarding { line(buffer) }
        buffer.removeAll(keepingCapacity: false)
        discarding = false
    }
}

struct OCRRequest {
    let id: String
    let path: String

    static func identifier(in object: [String: Any]) -> String? {
        guard let value = object["id"] as? String, !value.isEmpty,
              value.utf8.count <= 128, !value.utf8.contains(0) else { return nil }
        return value
    }

    init(_ object: [String: Any]) throws {
        guard let id = Self.identifier(in: object), let path = object["path"] as? String,
              path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0) else {
            throw nativeError("Invalid worker request")
        }
        self.id = id
        self.path = path
    }
}
