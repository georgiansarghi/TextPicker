import Foundation
import Darwin

/// One process per model, warm between captures. All public methods/callbacks
/// run on the main thread; each process has its own bounded JSON read buffer.
final class OCRWorker {
    private final class Session {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let queue = DispatchQueue(label: "TextPicker.worker-output")
        var buffer = Data()
        var rejectedOutput = false // Access these framing/delivery fields only on queue.
        var queuedMessages = 0
        var queuedBytes = 0
    }
    private var session: Session?
    private var timer: Timer?
    private var pendingID: String?
    private(set) var ready = false
    var onReady: ((Double) -> Void)?
    var onResult: ((String, Double) -> Void)?
    var onFailure: ((String) -> Void)?
    /// One request failed but the process is healthy and stays warm.
    var onRequestFailure: ((String) -> Void)?
    private let resources: URL
    private let startupTimeout: Double
    private let recognitionTimeout: Double

    init(resources: URL, startupTimeout: Double = 30, recognitionTimeout: Double = 10) {
        self.resources = resources
        self.startupTimeout = startupTimeout
        self.recognitionTimeout = recognitionTimeout
    }

    func start() {
        stop()
        let session = Session()
        self.session = session
        let process = session.process
        process.executableURL = resources.deletingLastPathComponent().appendingPathComponent("MacOS/TextPickerNative")
        process.arguments = [resources.appendingPathComponent("models/native").path]
        process.currentDirectoryURL = resources
        var environment = ProcessInfo.processInfo.environment
        environment["VECLIB_MAXIMUM_THREADS"] = "4"
        environment["TEXTPICKER_THREADS"] = "4"
        environment["OPENCV_LOG_LEVEL"] = "ERROR"
        process.environment = environment
        process.standardInput = session.input
        process.standardOutput = session.output
        process.standardError = session.errors
        session.output.fileHandleForReading.readabilityHandler = { [weak self, weak session] handle in
            let data = handle.availableData
            guard !data.isEmpty, let session else { return }
            // Synchronous handoff provides backpressure: a child cannot queue an
            // unbounded number of Data blocks while the parser catches up.
            session.queue.sync {
                guard !session.rejectedOutput else { return }
                session.buffer.append(data)
                guard session.buffer.count + session.queuedBytes <= 2_000_000 else {
                    session.rejectedOutput = true
                    onCaptureRunLoop { [weak self] in
                        guard self?.session === session else { return }
                        self?.fail("OCR worker exceeded the output limit")
                    }
                    return
                }
                while let newline = session.buffer.firstIndex(of: 10) {
                    // Small valid JSON lines can otherwise evade the byte-buffer
                    // cap and accumulate unbounded callbacks on a busy UI thread.
                    guard session.queuedMessages < 64 else {
                        session.rejectedOutput = true
                        onCaptureRunLoop { [weak self] in
                            guard self?.session === session else { return }
                            self?.fail("OCR worker exceeded the message limit")
                        }
                        break
                    }
                    let line = session.buffer.subdata(in: 0..<newline)
                    let byteCount = line.count
                    session.buffer.removeSubrange(0...newline)
                    session.queuedMessages += 1
                    session.queuedBytes += byteCount
                    let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                    if message == nil { session.rejectedOutput = true }
                    onCaptureRunLoop { [weak self] in
                        defer {
                            session.queue.async {
                                session.queuedMessages -= 1
                                session.queuedBytes -= byteCount
                            }
                        }
                        guard let self, self.session === session else { return }
                        guard let message else { self.fail("OCR worker returned an invalid response"); return }
                        self.receive(message)
                    }
                    if session.rejectedOutput { break }
                }
            }
        }
        // Drain stderr to avoid a full pipe blocking the worker. Do not persist
        // arbitrary library output, which could contain input or OCR text.
        session.errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self, weak session] process in
            onCaptureRunLoop {
                guard let self, let session, self.session === session else { return }
                self.fail("OCR worker exited (status \(process.terminationStatus)). Use Retry OCR Engine from the menu.")
            }
        }
        do {
            try process.run()
            let limit = startupTimeout
            scheduleTimeout(seconds: limit, message: "Model startup exceeded \(Int(limit)) seconds. Use Retry OCR Engine from the menu.")
        } catch { fail("Cannot launch OCR worker: \(error.localizedDescription)") }
    }

    func recognize(_ image: URL) {
        guard ready, pendingID == nil, let session else {
            onFailure?("OCR engine is not ready")
            return
        }
        let id = UUID().uuidString
        pendingID = id
        do {
            var data = try JSONSerialization.data(withJSONObject: ["id": id, "path": image.path])
            data.append(10)
            try session.input.fileHandleForWriting.write(contentsOf: data)
            scheduleTimeout(seconds: recognitionTimeout, message: "Recognition exceeded \(Int(recognitionTimeout)) seconds. Use Retry OCR Engine, then capture a smaller region.")
        } catch { fail("Cannot send capture to OCR worker") }
    }

    private func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            guard !ready, pendingID == nil, message["backend"] as? String == "native-cpu",
                  let elapsed = validDuration(message["load_ms"]) else {
                fail("Invalid or unexpected worker ready response"); return
            }
            timer?.invalidate(); timer = nil
            ready = true
            onReady?(elapsed)
        case "result":
            guard let id = message["id"] as? String else { fail("OCR response is missing its request ID"); return }
            guard id == pendingID else { return } // Old request; never consume it.
            guard let text = message["text"] as? String, let elapsed = validDuration(message["ocr_ms"]) else {
                fail("OCR worker returned an invalid result"); return
            }
            timer?.invalidate(); timer = nil; pendingID = nil
            onResult?(text, elapsed)
        case "error":
            // Stale IDs must never terminate a newer request.
            if let id = message["id"] as? String, let pendingID, id != pendingID { return }
            let text = String((message["message"] as? String ?? "OCR failed").prefix(700))
            // A correlated error (oversized selection, bad image) ends only that
            // request. Uncorrelated errors mean the process itself is broken.
            if ready, let id = message["id"] as? String, id == pendingID {
                timer?.invalidate(); timer = nil; pendingID = nil
                onRequestFailure?(text)
            } else { fail(text) }
        default: fail("Unknown OCR worker response")
        }
    }

    private func validDuration(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    private func scheduleTimeout(seconds: Double, message: String) {
        timer?.invalidate()
        let token = session
        let request = pendingID
        let work = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session === token, self.pendingID == request else { return }
                self.fail(message)
            }
        }
        timer = work
        RunLoop.main.add(work, forMode: .common)
    }
    private func fail(_ message: String) { stop(); onFailure?(message) }

    func stop() {
        timer?.invalidate(); timer = nil
        ready = false; pendingID = nil
        guard let old = session else { return }
        session = nil // Invalidate all delayed messages before terminating.
        old.process.terminationHandler = nil
        old.output.fileHandleForReading.readabilityHandler = nil
        old.errors.fileHandleForReading.readabilityHandler = nil
        try? old.input.fileHandleForWriting.close()
        if old.process.isRunning {
            old.process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if old.process.isRunning { kill(old.process.processIdentifier, SIGKILL) }
            }
        }
    }
    deinit { stop() }
}
