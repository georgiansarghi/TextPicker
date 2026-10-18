import AppKit
import Foundation

@main
struct Tests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    static func wait(_ seconds: Double = 3, mode: RunLoop.Mode = .default, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        let keepAlive = Timer(timeInterval: 0.01, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: mode)
        defer { keepAlive.invalidate() }
        while !condition() && Date() < deadline {
            _ = RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.01))
        }
        check(condition(), "Timed out waiting for test event")
    }
    static func main() throws {
        check(!diagnosticTracingEnabled([:]), "Verbose capture logs default off")
        check(diagnosticTracingEnabled(["TEXTPICKER_DEBUG": "1"]), "Explicit debug opt-in")
        check(!diagnosticTracingEnabled(["TEXTPICKER_DEBUG": "0"]), "Debug disabled")
        check(!diagnosticTracingEnabled(["TEXTPICKER_DEBUG": "true"]), "Debug opt-in requires exact value")
        let view = CGSize(width: 100, height: 80), image = CGSize(width: 200, height: 160)
        check(pixelCrop(selection: CGRect(x: 10, y: 20, width: 30, height: 40), viewSize: view, imageSize: image)
              == CGRect(x: 20, y: 40, width: 60, height: 80), "Retina coordinates and Y flip")
        check(pixelCrop(selection: CGRect(x: 40, y: 60, width: -30, height: -40), viewSize: view, imageSize: image)
              == CGRect(x: 20, y: 40, width: 60, height: 80), "Reverse-direction drag")
        check(pixelCrop(selection: CGRect(x: -10, y: -5, width: 120, height: 100), viewSize: view, imageSize: image)
              == CGRect(origin: .zero, size: image), "Clamping at screen edges")
        check(pixelCrop(selection: CGRect(x: 120, y: 20, width: 10, height: 10), viewSize: view, imageSize: image).isEmpty,
              "Out-of-bounds selection")
        check(pixelCrop(selection: CGRect(x: 0, y: 79, width: 1, height: 1), viewSize: view, imageSize: view)
              == CGRect(x: 0, y: 0, width: 1, height: 1), "Top-left non-Retina pixel")
        check(clipboardText("  Grüße!\n  Café\n", keepLineBreaks: true) == "Grüße!\n  Café", "Preserve inner spacing/newlines")
        check(clipboardText("Grüße!\n\n  Café\r\n", keepLineBreaks: false) == "Grüße! Café", "Join lines")
        check(clipboardText(" \n \t", keepLineBreaks: true).isEmpty, "No-text output")

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("TextPicker-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = try CaptureFiles(directory: temp.appendingPathComponent("captures"))
        let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let saved = try store.save(ctx.makeImage()!)
        let attributes = try FileManager.default.attributesOfItem(atPath: saved.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Private capture file permissions")
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        check((dirAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Private directory permissions")
        store.remove(temp.appendingPathComponent("not-ours"))
        check(FileManager.default.fileExists(atPath: saved.path), "Cleanup scope")
        store.remove(saved)
        check(!FileManager.default.fileExists(atPath: saved.path), "Capture deletion")

        let resources = temp.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let script = """
        #!/usr/bin/env python3
        import json,sys,time,pathlib
        assert pathlib.Path(sys.argv[0]).name == 'TextPickerNative'
        assert len(sys.argv)==2 and pathlib.Path(sys.argv[1]).parts[-2:]==('models','native')
        resources=pathlib.Path(sys.argv[1]).parent.parent
        backend='native-cpu'
        import os
        assert os.environ['VECLIB_MAXIMUM_THREADS']=='4' and os.environ['TEXTPICKER_THREADS']=='4'
        mode=(resources/'mode').read_text()
        if mode=='startup-timeout': time.sleep(5)
        print(json.dumps({'type':'ready','backend':('wrong' if mode=='bad-ready' else backend),'load_ms':1}),flush=True)
        served=0
        for line in sys.stdin:
            request=json.loads(line)
            served+=1
            if mode=='request-error' and served==1: print(json.dumps({'type':'error','id':request['id'],'message':'Selection is too large'}),flush=True); continue
            if mode=='request-timeout': time.sleep(5)
            if mode=='crash': sys.exit(7)
            if mode=='malformed': print('not-json',flush=True); continue
            if mode=='bad-result': print(json.dumps({'type':'result','id':request['id'],'ocr_ms':2}),flush=True); continue
            if mode=='invalid-time': print(json.dumps({'type':'result','id':request['id'],'text':'NO','ocr_ms':-1}),flush=True); continue
            if mode=='oversized': print('x'*2000001,flush=True); continue
            if mode=='flood': print((json.dumps({'type':'result','id':'stale','text':'x','ocr_ms':0})+'\\n')*10000,flush=True); continue
            if mode=='stale': print(json.dumps({'type':'result','id':'old','text':'WRONG'}),flush=True)
            print(json.dumps({'type':'result','id':request['id'],'text':'Grüße!','ocr_ms':2}),flush=True)
        """
        let fakeNative = resources.deletingLastPathComponent().appendingPathComponent("MacOS/TextPickerNative")
        try FileManager.default.createDirectory(at: fakeNative.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: fakeNative, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeNative.path)
        let modes = ["normal", "stale", "crash", "malformed", "startup-timeout", "request-timeout", "bad-ready", "bad-result", "invalid-time", "oversized", "flood"]
        for mode in modes {
            try mode.write(to: resources.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let worker = OCRWorker(resources: resources, startupTimeout: 0.5, recognitionTimeout: 0.3)
            var ready = false, result: String?, failure: String?
            worker.onReady = { _ in ready = true }
            worker.onResult = { text, _ in result = text }
            worker.onFailure = { failure = $0 }
            worker.start()
            wait { ready || failure != nil }
            if ready { worker.recognize(temp.appendingPathComponent("fake.png")) }
            wait { result != nil || failure != nil }
            if ["normal", "stale"].contains(mode) {
                check(result == "Grüße!" && failure == nil, "Worker result and stale response protection: \(mode); failure=\(failure ?? "none"); result=\(result ?? "nil")")
            } else {
                check(failure != nil && !worker.ready, "Worker failure recovery: \(mode)")
            }
            worker.stop()
        }
        // A per-request error must keep the warm process serving later captures.
        try "request-error".write(to: resources.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        do {
            let worker = OCRWorker(resources: resources, startupTimeout: 0.5, recognitionTimeout: 0.3)
            var ready = false, result: String?, failure: String?, requestFailure: String?
            worker.onReady = { _ in ready = true }
            worker.onResult = { text, _ in result = text }
            worker.onFailure = { failure = $0 }
            worker.onRequestFailure = { requestFailure = $0 }
            worker.start()
            wait { ready || failure != nil }
            worker.recognize(temp.appendingPathComponent("fake.png"))
            wait { requestFailure != nil || failure != nil }
            check(requestFailure == "Selection is too large" && failure == nil && worker.ready, "Request error keeps worker warm")
            worker.recognize(temp.appendingPathComponent("fake.png"))
            wait { result != nil || failure != nil }
            check(result == "Grüße!" && failure == nil, "Worker serves the next request after a request error")
            worker.stop()
        }
        // A nested tracking loop can run while a main-queue action is still on
        // the stack. Worker replies AND deadlines must complete without closing
        // the menu or unwinding that outer action.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        var trackingFinished = false
        DispatchQueue.main.async {
            do {
                for mode in ["normal", "stale", "startup-timeout", "request-timeout", "flood"] {
                    try mode.write(to: resources.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
                    let tracked = OCRWorker(resources: resources, startupTimeout: 0.5, recognitionTimeout: 0.3)
                    var ready = false, result: String?, failure: String?
                    tracked.onReady = { _ in ready = true }
                    tracked.onResult = { text, _ in result = text }
                    tracked.onFailure = { failure = $0 }
                    tracked.start()
                    wait(mode: .eventTracking) { ready || failure != nil }
                    if ready { tracked.recognize(temp.appendingPathComponent("fake.png")) }
                    wait(mode: .eventTracking) { result != nil || failure != nil }
                    if ["normal", "stale"].contains(mode) {
                        check(result == "Grüße!" && failure == nil, "Reply inside nested menu tracking: \(mode); failure=\(failure ?? "none"); result=\(result ?? "nil")")
                    } else {
                        check(failure != nil && !tracked.ready, "Timeout/flood protection inside nested menu tracking")
                    }
                    tracked.stop()
                }
                trackingFinished = true
            } catch { fatalError("Tracking fixture failed: \(error)") }
        }
        wait(15) { trackingFinished }

        // Restarting/cancelling a loading worker must suppress its callbacks and
        // cancelled deadline, including data already queued by its old process.
        try "startup-timeout".write(to: resources.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let worker = OCRWorker(resources: resources, startupTimeout: 0.5, recognitionTimeout: 0.3)
        var readyCount = 0, errors = 0, result: String?
        worker.onReady = { _ in readyCount += 1 }
        worker.onFailure = { _ in errors += 1 }
        worker.onResult = { text, _ in result = text }
        worker.start()
        worker.stop()
        try "normal".write(to: resources.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        worker.start()
        wait { readyCount > 0 || errors > 0 }
        worker.recognize(temp.appendingPathComponent("fake.png"))
        wait { result != nil || errors > 0 }
        worker.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.65))
        check(readyCount == 1 && errors == 0 && result == "Grüße!", "Restart isolation and cancelled deadlines")
        print("PASS: \(checks) checks (geometry, text, privacy, worker IPC, stale replies, crash, malformed output, timeouts, restart)")
    }
}
