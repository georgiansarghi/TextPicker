import Foundation
import Darwin

/// One process per model, warm between captures. All public methods/callbacks
/// run on the main thread; each process has its own bounded JSON read buffer.
final class OCRWorker {
    private final class Session {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let queue = DispatchQueue(label: "TextOCR.worker-output")
        var buffer = Data()
    }
    private var session: Session?
    private var timer: DispatchWorkItem?
    private var pendingID: String?
    private(set) var ready = false
    var onReady: ((Double) -> Void)?
    var onResult: ((String, Double) -> Void)?
    var onFailure: ((String) -> Void)?
    private let resources: URL
    private let startupTimeout: Double
    private let recognitionTimeout: Double

    init(resources: URL, startupTimeout: Double = 30, recognitionTimeout: Double = 10) {
        self.resources = resources
        self.startupTimeout = startupTimeout
        self.recognitionTimeout = recognitionTimeout
    }

    func start(_ backend: Backend) {
        stop()
        let session = Session()
        self.session = session
        let process = session.process
        if backend == .nativeCPU {
            process.executableURL = resources.deletingLastPathComponent().appendingPathComponent("MacOS/TextOCRNative")
            process.arguments = [resources.appendingPathComponent("models/native").path]
        } else {
            process.executableURL = resources.appendingPathComponent("python/bin/python3.12")
            process.arguments = ["-I", "-B", "-u", resources.appendingPathComponent("worker.py").path, resources.path, backend.rawValue]
        }
        process.currentDirectoryURL = resources
        var environment = ProcessInfo.processInfo.environment
        // Bundled Python must not inherit an activated development environment.
        for key in ["PYTHONPATH", "PYTHONHOME", "VIRTUAL_ENV", "CONDA_PREFIX"] { environment.removeValue(forKey: key) }
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        if backend == .nativeCPU {
            environment["VECLIB_MAXIMUM_THREADS"] = "4"
            environment["INFEXP_THREADS"] = "4"
            for key in ["INFEXP_PROFILE", "INFEXP_ALLOC"] { environment.removeValue(forKey: key) }
        }
        process.environment = environment
        process.standardInput = session.input
        process.standardOutput = session.output
        process.standardError = session.errors
        session.output.fileHandleForReading.readabilityHandler = { [weak self, weak session] handle in
            let data = handle.availableData
            guard !data.isEmpty, let session else { return }
            session.queue.async {
                session.buffer.append(data)
                guard session.buffer.count <= 2_000_000 else {
                    DispatchQueue.main.async { [weak self] in
                        guard self?.session === session else { return }
                        self?.fail("OCR worker exceeded the output limit")
                    }
                    return
                }
                while let newline = session.buffer.firstIndex(of: 10) {
                    let line = session.buffer.subdata(in: 0..<newline)
                    session.buffer.removeSubrange(0...newline)
                    let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.session === session else { return }
                        guard let message else { self.fail("OCR worker returned an invalid response"); return }
                        self.receive(message)
                    }
                }
            }
        }
        // Drain stderr to avoid a full pipe blocking the worker. Do not persist
        // arbitrary library output, which could contain input or OCR text.
        session.errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self, weak session] process in
            DispatchQueue.main.async {
                guard let self, let session, self.session === session else { return }
                self.fail("OCR worker exited (status \(process.terminationStatus)). Choose Restart OCR Engine or another model.")
            }
        }
        do {
            try process.run()
            let limit = startupTimeout
            scheduleTimeout(seconds: limit, message: "Model startup exceeded \(Int(limit)) seconds. Choose another model or Restart OCR Engine.")
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
            scheduleTimeout(seconds: recognitionTimeout, message: "Recognition exceeded \(Int(recognitionTimeout)) seconds. The worker was stopped; try a smaller selection or a different model.")
        } catch { fail("Cannot send capture to OCR worker") }
    }

    private func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            guard !ready, pendingID == nil else { fail("Unexpected worker ready response"); return }
            timer?.cancel(); timer = nil
            ready = true
            onReady?(message["load_ms"] as? Double ?? 0)
        case "result":
            guard let id = message["id"] as? String, id == pendingID,
                  let text = message["text"] as? String else { return }
            timer?.cancel(); timer = nil; pendingID = nil
            onResult?(text, message["ocr_ms"] as? Double ?? 0)
        case "error":
            // Stale IDs must never terminate a newer request.
            if let id = message["id"] as? String, let pendingID, id != pendingID { return }
            fail(String((message["message"] as? String ?? "OCR failed").prefix(700)))
        default: fail("Unknown OCR worker response")
        }
    }

    private func scheduleTimeout(seconds: Double, message: String) {
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fail(message) }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func fail(_ message: String) { stop(); onFailure?(message) }

    func stop() {
        timer?.cancel(); timer = nil
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
