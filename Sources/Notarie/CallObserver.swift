//
// Reads the call window while a recording runs (Settings › Transcription ›
// "Read the call window for names"; READ_CALL_WINDOW).
//
// Every 2 seconds: find the call window (again every 30 s, or after a
// failed capture, since the meeting window can change), take a screenshot,
// read it (CallFrameReader) and append the derived CallFrame to the slot's
// call.jsonl. The screenshot itself is dropped at once. Frames with nothing
// on them aren't written. A tick that runs long (OCR on a big window takes
// about a second) just delays the next one.
//
// Best-effort throughout: no window, no grant or a failed read costs a
// frame, never the recording.
//

import Foundation
import os

private let callLog = Logger(subsystem: "com.jwiderberg.notarie", category: "CallWindow")

final class CallObserver: @unchecked Sendable {
    static let interval: Double = 2
    static let refindInterval: Double = 30

    private let url: URL
    private let titleOverride: String?
    private var task: Task<Void, Never>?

    /// `titleOverride` (harness): any window whose title contains it.
    init(url: URL, titleOverride: String? = nil) {
        self.url = url
        self.titleOverride = titleOverride
    }

    func start() {
        let url = url, titleOverride = titleOverride
        task = Task.detached(priority: .utility) {
            await Self.run(url: url, titleOverride: titleOverride)
        }
    }

    func stop() async {
        task?.cancel()
        await task?.value
        task = nil
    }

    private static func run(url: URL, titleOverride: String?) async {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            callLog.error("can't open \(url.lastPathComponent, privacy: .public)")
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()

        var choice: CallWindowChoice?
        var lastFind = Date.distantPast
        var written = 0, failures = 0
        var apps = Set<String>()
        var reportedMissing = false
        var foundTitle: String?
        while !Task.isCancelled {
            let tick = Date()
            if choice == nil || tick.timeIntervalSince(lastFind) >= refindInterval {
                do {
                    choice = try await CallWindowLocator.find(titleOverride: titleOverride)
                } catch {
                    choice = nil
                    if failures == 0 {
                        callLog.error("listing windows failed: \(String(describing: error), privacy: .public)")
                    }
                    failures += 1
                }
                if choice == nil && !reportedMissing {
                    callLog.notice("no call window found")
                    reportedMissing = true
                } else if let found = choice, foundTitle != found.title {
                    callLog.notice("call window: \(found.app, privacy: .public) (\(found.bundleID, privacy: .public))")
                    foundTitle = found.title
                }
                lastFind = tick
            }
            if let current = choice {
                do {
                    let image = try await CallWindowLocator.capture(current)
                    let host = Double(mach_absolute_time()) / HostClock.ticksPerSecond
                    let frame = try CallFrameReader.frame(from: image, app: current.app, host: host, wall: tick)
                    if !(frame.participants.isEmpty && frame.captions.isEmpty && frame.words.isEmpty) {
                        try handle.write(contentsOf: CallFrameLog.encode(frame))
                        written += 1
                        apps.insert(current.app)
                    }
                } catch {
                    failures += 1
                    if failures == 1 {
                        callLog.error("call window read failed: \(String(describing: error), privacy: .public)")
                    }
                    choice = nil
                }
            }
            let wait = interval - Date().timeIntervalSince(tick)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        callLog.notice("call window: \(written, privacy: .public) frames from \(apps.sorted().joined(separator: ","), privacy: .public), \(failures, privacy: .public) failed reads")
    }
}
