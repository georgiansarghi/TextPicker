import Darwin
import Foundation

private func emit(_ message: [String: Any]) {
    do {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        // Reserve headroom below the controller's 2 MB read bound. The C++ UTF-8
        // limit also allows worst-case JSON escaping, not just visible glyphs.
        if data.count > 1_900_000 {
            emit(["type": "error", "id": message["id"] as? String ?? "",
                  "message": "OCR result exceeds output bound"])
            return
        }
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    } catch {
        exit(0) // Owner closed its pipe. Do not persist OCR output as a fallback.
    }
}

private func bridgeError() -> NSError {
    nativeError(String(cString: textpicker_native_error()))
}

private func handleRequest(_ data: Data, engine: UnsafeMutableRawPointer) {
    autoreleasepool {
        var id: String?
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw nativeError("Invalid worker request")
            }
            // Preserve a valid ID even when the path is invalid, so the owner
            // receives a correlated error immediately instead of timing out.
            id = OCRRequest.identifier(in: object)
            let request = try OCRRequest(object)
            let start = ProcessInfo.processInfo.systemUptime
            let image = try decodeCapture(request.path)
            let result = image.bgra.withUnsafeBufferPointer {
                textpicker_native_predict(engine, $0.baseAddress, $0.count,
                    Int32(image.width), Int32(image.height), Int32(image.width * 4))
            }
            guard let result else { throw bridgeError() }
            defer { textpicker_native_free(result) }
            emit(["type": "result", "id": request.id, "text": String(cString: result),
                  "ocr_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000])
        } catch {
            let message = (error as NSError).domain == "TextPickerNative"
                ? error.localizedDescription : "Invalid worker request"
            var response: [String: Any] = ["type": "error", "message": String(message.prefix(700))]
            if let id { response["id"] = id }
            emit(response)
        }
    }
}

@main struct NativeWorker {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        setenv("OPENCV_LOG_LEVEL", "ERROR", 1)
        guard CommandLine.arguments.count == 2 else {
            emit(["type": "error", "message": "Invalid native worker arguments"])
            exit(1)
        }
        do {
            let start = ProcessInfo.processInfo.systemUptime
            guard let engine = textpicker_native_create(CommandLine.arguments[1]) else { throw bridgeError() }
            defer { textpicker_native_destroy(engine) }
            guard textpicker_native_warmup(engine) == 1 else { throw bridgeError() }
            emit(["type": "ready", "backend": "native-cpu", "runtime": "C++/Accelerate",
                  "device_policy": "CPU", "load_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000])
            var framer = RequestFramer()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw nativeError("Cannot read worker requests")
                }
                if count == 0 {
                    framer.finish { handleRequest($0, engine: engine) }
                    break
                }
                framer.feed(chunk.prefix(count), line: { handleRequest($0, engine: engine) }, overflow: {
                    emit(["type": "error", "message": "Worker request exceeds input bound"])
                })
            }
        } catch {
            emit(["type": "error", "message": error.localizedDescription])
            exit(1)
        }
    }
}
