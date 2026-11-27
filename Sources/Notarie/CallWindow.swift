//
// Finding the call's window, taking a screenshot of it, and reading its
// text.
//
// The window: ScreenCaptureKit lists every window with its app and title.
// A call app's meeting window is recognised by bundle id and title (Zoom's
// "Zoom Meeting", a Teams meeting or call window, a browser window whose
// front tab is Google Meet or Teams on the web). Among several, the one
// whose app is playing audio wins, then the biggest. A browser window shows
// only its front tab: when Meet is in a background tab the title says so
// and the window isn't taken.
//
// The screenshot: SCScreenshotManager with a filter for that one window,
// so other windows on top of it don't matter (a minimised window can't be
// captured). Needs the Screen Recording grant, like the ScreenCaptureKit
// audio engine.
//
// The text: Apple Vision's accurate recognition with language correction,
// on an image scaled so it is at least 2× the window's points (Retina
// screens already are). Lines come back with boxes in image pixels, origin
// top left.
//

import AppKit
import CoreAudio
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import Vision

enum CallWindowMatcher {
    static let zoom: Set<String> = ["us.zoom.xos"]
    static let teams: Set<String> = ["com.microsoft.teams2", "com.microsoft.teams"]
    static let webex: Set<String> = ["com.cisco.webexmeetingsapp", "Cisco-Systems.Spark"]
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.microsoft.edgemac", "com.apple.Safari",
        "company.thebrowser.Browser", "com.brave.Browser", "org.mozilla.firefox", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// The call app a window belongs to, by bundle id and title, or nil
    /// when it isn't a meeting window. `titleOverride` (the harness) takes
    /// any window whose title contains it.
    /// `playingAudio`: the window's app is playing sound. Browsers shorten
    /// long titles in the middle ("Weekly sync wi… | Microsoft Teams"), so a
    /// Teams tab whose "meeting" was cut out still counts when it plays.
    static func classify(bundleID: String, title: String, titleOverride: String? = nil,
                         playingAudio: Bool = false) -> String? {
        let t = title.lowercased()
        if let titleOverride, !titleOverride.isEmpty {
            return t.contains(titleOverride.lowercased()) ? "Window" : nil
        }
        if zoom.contains(bundleID) {
            return t.contains("zoom meeting") || t.contains("zoom webinar") || t == "meeting" ? "Zoom" : nil
        }
        if teams.contains(bundleID) {
            // Meeting and call windows; the main window's title is a chat,
            // channel or "Calendar".
            let call = t.contains("meeting") || t.contains("call") || t.contains("meet now")
                || t.contains("möte") || t.contains("samtal")
            let main = t.hasPrefix("chat |") || t.hasPrefix("activity |") || t.hasPrefix("calendar |")
                || t.hasPrefix("teams |") || t.hasPrefix("calendar") || t.hasPrefix("files |")
            return call && !main ? "Teams" : nil
        }
        if webex.contains(bundleID) {
            return t.contains("meeting") || t.contains("webex") ? "Webex" : nil
        }
        if browsers.contains(bundleID) {
            if t.hasPrefix("meet - ") || t.hasPrefix("meet – ") || t.contains("google meet") { return "Meet" }
            if t.contains("| microsoft teams") && (t.contains("meeting") || t.contains("call") || t.contains("meet now")
                || (playingAudio && t.contains("…"))) {
                return "Teams (web)"
            }
            if t.contains("zoom meeting") || t.hasPrefix("zoom") && t.contains("meeting") { return "Zoom (web)" }
            return nil
        }
        return nil
    }

    /// Process ids currently playing audio (Core Audio's process list).
    static func pidsPlayingAudio() -> Set<pid_t> {
        guard let objects = try? CoreAudioHAL.getArray(AudioObjectID(kAudioObjectSystemObject),
                                                       kAudioHardwarePropertyProcessObjectList,
                                                       AudioObjectID.self, step: "list process objects") else { return [] }
        var pids = Set<pid_t>()
        for object in objects {
            guard let running: UInt32 = try? CoreAudioHAL.get(object, kAudioProcessPropertyIsRunningOutput, step: "process output"), running != 0,
                  let pid: pid_t = try? CoreAudioHAL.get(object, kAudioProcessPropertyPID, step: "process pid")
            else { continue }
            pids.insert(pid)
        }
        return pids
    }
}

struct CallWindowChoice: @unchecked Sendable {
    let window: SCWindow
    let app: String
    let title: String
    let bundleID: String
}

enum CallWindowLocator {
    /// The meeting window, or nil when no call app shows one.
    static func find(titleOverride: String? = nil) async throws -> CallWindowChoice? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        // Helper processes (a browser's renderer, Teams' web view) play the
        // audio, so a window counts as playing when any process of its app
        // family does: compare by the owning app's pid and its children's
        // bundle ids sharing its prefix.
        let playing = CallWindowMatcher.pidsPlayingAudio()
        let playingBundles = Set(playing.compactMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier })
        var best: (CallWindowChoice, Int)?
        for window in content.windows {
            guard let app = window.owningApplication, window.windowLayer == 0,
                  window.frame.width >= 320, window.frame.height >= 200 else { continue }
            let title = window.title ?? ""
            let isPlaying = playing.contains(app.processID)
                || playingBundles.contains(where: { $0.hasPrefix(app.bundleIdentifier) })
            guard let kind = CallWindowMatcher.classify(bundleID: app.bundleIdentifier, title: title,
                                                        titleOverride: titleOverride, playingAudio: isPlaying) else { continue }
            var score = Int(window.frame.width * window.frame.height / 10_000)
            if window.isOnScreen { score += 1_000 }
            if isPlaying { score += 10_000 }
            let choice = CallWindowChoice(window: window, app: kind, title: title, bundleID: app.bundleIdentifier)
            if best == nil || score > best!.1 { best = (choice, score) }
        }
        return best?.0
    }

    /// A screenshot of the window at (at least) twice its size in points.
    static func capture(_ choice: CallWindowChoice) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: choice.window)
        let config = SCStreamConfiguration()
        let scale = max(2, CGFloat(filter.pointPixelScale))
        config.width = Int(choice.window.frame.width * scale)
        config.height = Int(choice.window.frame.height * scale)
        config.showsCursor = false
        config.capturesAudio = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

enum CallFrameReader {
    /// Vision text lines of `image`, boxes in its pixels, origin top left.
    static func recognize(_ image: CGImage, languages: [String] = ["en-US", "sv-SE"]) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let wanted = languages.filter { supported.contains($0) }
        if !wanted.isEmpty { request.recognitionLanguages = wanted }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let w = Double(image.width), h = Double(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let top = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRLine(text: top.string, x: box.minX * w, y: (1 - box.maxY) * h,
                           width: box.width * w, height: box.height * h, confidence: top.confidence)
        }
    }

    /// RGB access to `image`, drawn once into an 8-bit RGBA buffer.
    static func sampler(_ image: CGImage) -> PixelSampler {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        let buffer = drawn ? pixels : []
        return { x, y in
            guard !buffer.isEmpty, x >= 0, y >= 0, x < w, y < h else { return nil }
            let i = (y * w + x) * 4
            return (Double(buffer[i]) / 255, Double(buffer[i + 1]) / 255, Double(buffer[i + 2]) / 255)
        }
    }

    /// OCR plus analysis of one image.
    static func frame(from image: CGImage, app: String, host: Double, wall: Date) throws -> CallFrame {
        let lines = try recognize(image)
        return CallFrameAnalyzer.analyze(lines: lines, width: Double(image.width), height: Double(image.height),
                                         app: app, host: host, wall: wall, sample: sampler(image))
    }
}
