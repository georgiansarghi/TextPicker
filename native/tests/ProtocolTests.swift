import Foundation

@main struct ProtocolTests {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool) {
            precondition(condition, "Protocol assertion failed")
            count += 1
        }
        var framer = RequestFramer()
        var lines: [Data] = []
        var errors = 0
        func feed(_ string: String) {
            framer.feed(Array(string.utf8)[...], line: { lines.append($0) }, overflow: { errors += 1 })
        }
        feed("a")
        check(lines.isEmpty)
        feed("b\nc\nd")
        check(lines == [Data("ab".utf8), Data("c".utf8)])
        framer.finish { lines.append($0) }
        check(lines.last == Data("d".utf8))
        lines.removeAll()
        feed(String(repeating: "x", count: RequestFramer.maximumLineBytes))
        check(errors == 0)
        feed("\n")
        check(lines.last?.count == RequestFramer.maximumLineBytes)
        feed(String(repeating: "x", count: RequestFramer.maximumLineBytes + 1))
        check(errors == 1)
        feed("ignored\nrecovered\n")
        check(errors == 1 && lines.last == Data("recovered".utf8))
        let before = lines.count
        feed(String(repeating: "x", count: RequestFramer.maximumLineBytes + 1))
        framer.finish { lines.append($0) }
        check(lines.count == before && errors == 2)
        for object: [String: Any] in [[:], ["id": 1, "path": "/tmp/x"], ["id": "", "path": "/tmp/x"],
                                    ["id": "ok", "path": "relative"], ["id": "ok", "path": "/tmp/\0x"],
                                    ["id": "a\0b", "path": "/tmp/x"], ["id": String(repeating: "ü", count: 65), "path": "/x"]] {
            var rejected = false
            do { _ = try OCRRequest(object) } catch { rejected = true }
            check(rejected)
        }
        check(try OCRRequest(["id": "ok", "path": "/tmp/x"]).id == "ok")
        print("PASS: \(count) native protocol checks")
    }
}
