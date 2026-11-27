//
// What a screenshot of the call window says, as data (no pixels kept).
//
// While a recording runs with "Read the call window" on, CallObserver takes
// a screenshot of the call app's window every couple of seconds, reads its
// text (Apple Vision) and keeps only what this file derives from it:
//
//   - participants: the name labels on the video tiles;
//   - active: the labels whose tile carries the active-speaker highlight
//     (a coloured frame around the tile that the other tiles don't have);
//   - captions: live caption lines with the speaker's name, when the call
//     shows captions;
//   - words: other text on screen worth knowing for spelling (names, terms
//     on a shared slide).
//
// One CallFrame per screenshot, one JSON line each in the slot's call.jsonl.
// CallEvidence (CallEvidence.swift) turns them into speaker names for the
// transcript.
//
// Everything here is pure: the analyzer gets OCR lines and a pixel sampler,
// so tests run on synthetic frames.
//

import Foundation

/// One recognised text line, box in pixels of the analysed image, origin
/// top left.
struct OCRLine: Sendable, Equatable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Float

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midY: Double { y + height / 2 }
}

struct CaptionLine: Codable, Sendable, Equatable {
    let speaker: String?
    let text: String
}

struct CallFrame: Codable, Sendable, Equatable {
    /// Host-clock seconds when the screenshot was taken (the same clock the
    /// capture engines stamp audio with).
    var host: Double
    /// Wall clock, for recordings whose mic start time isn't known.
    var wall: Date
    var app: String
    var participants: [String]
    /// The participant shown as "you" (Zoom's "(me)", Teams' and Meet's
    /// "You"), when the call marks one.
    var me: String?
    var active: [String]
    var captions: [CaptionLine]
    var words: [String]
}

/// RGB in 0…1 at a pixel of the analysed image; nil outside it.
typealias PixelSampler = (_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double)?

enum CallFrameAnalyzer {
    /// Interface words that look like names (short, capitalised) but are
    /// buttons, menus or status text in Zoom, Teams, Meet and Webex.
    static let interfaceWords: Set<String> = [
        "mute", "unmute", "share", "share screen", "stop share", "chat", "people", "participants", "leave",
        "end", "reactions", "react", "raise", "raise hand", "more", "camera", "mic", "microphone", "view",
        "apps", "record", "recording", "transcript", "captions", "live captions", "gallery", "gallery view",
        "speaker", "speaker view", "meeting", "meetings", "join", "rooms", "breakout rooms", "settings",
        "security", "start video", "stop video", "video", "audio", "you", "present", "present now", "host",
        "co-host", "live", "summary", "whiteboard", "notes", "invite", "details", "activities", "options",
        "layout", "immersive view", "together mode", "focus", "chat with everyone", "everyone", "send",
        "copilot", "ai companion", "zoom", "microsoft teams", "teams", "google meet", "meet", "webex",
        "turn on captions", "turn off captions", "hand", "lower hand", "pin", "unpin", "spotlight",
        "full screen", "exit full screen", "minimize", "close", "new", "calendar", "activity", "files",
        "help", "search", "home", "back", "next", "cancel", "ok", "done", "allow", "deny", "continue",
        "connecting", "reconnecting", "waiting", "lobby", "admit", "admit all", "deny all", "presenting",
        "is presenting", "you are presenting", "stop presenting", "screen", "window", "tab", "untitled",
        "subscribe", "subscribed", "share", "download", "save",
    ]

    /// Suffixes call apps put after a name; stripped, and "(me)"/"(You)"
    /// mark the operator.
    static let selfMarkers = ["(me)", "(you)", "(du)", "(jag)"]
    static let roleMarkers = ["(host)", "(co-host)", "(guest)", "(external)", "(unverified)", "(organizer)",
                              "(organiser)", "(presenter)", "(värd)", "(gäst)"]

    /// A tile's name label, cleaned: "Jane Doe (Host)" → ("Jane Doe",
    /// false), "Jakob W (me)" → ("Jakob W", true). nil when the line isn't
    /// shaped like a name.
    static func nameLabel(_ raw: String) -> (name: String, isSelf: Bool)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Trailing marks: a name cut by the tile ("Community Board…"), a
        // menu button ("Cristian Cotovan ···"), a caption colon ("Leah Flax:").
        while let last = text.last, !(last.isLetter || last == ")") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        var isSelf = false
        var changed = true
        while changed {
            changed = false
            let lower = text.lowercased()
            for marker in selfMarkers + roleMarkers where lower.hasSuffix(marker) {
                if selfMarkers.contains(marker) { isSelf = true }
                text = String(text.dropLast(marker.count)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        guard (2...40).contains(text.count), !interfaceWords.contains(text.lowercased()) else { return nil }
        let words = text.split(separator: " ")
        guard (1...4).contains(words.count) else { return nil }
        // Headings and banners are set in capitals; names aren't.
        let letters = text.filter(\.isLetter)
        if letters.count >= 4 && letters.allSatisfy(\.isUppercase) { return nil }
        for word in words {
            guard let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else { return nil }
            let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "-'’."))
            guard word.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        }
        // One word alone is a name only if it isn't an ordinary word
        // ("All", "Perception") or set in capitals ("ITS"); a single
        // capitalised word is too often a heading or a button.
        if words.count == 1 {
            if text.count < 3 || letters.allSatisfy(\.isUppercase) || WordList.isCommonWordOnly(text) { return nil }
        }
        return (text, isSelf)
    }

    /// Whether the label is drawn as tile labels are: light text over a
    /// darker backdrop (Zoom, Teams and Meet put names on a translucent
    /// dark plate over the video). Measured as light glyph pixels plus a
    /// dark-enough mean of everything else in the box.
    static func isOnDarkBackdrop(_ line: OCRLine, sample: PixelSampler) -> Bool {
        // Measured on real Zoom and Teams tiles (glyphs brighter than 0.62):
        // 10–45 % of the box, the rest 0.3–0.56 bright; a light button or
        // page is 65 % light and more.
        // Thin small names on a black strip (another Zoom layout) have few
        // glyph pixels but a very dark rest.
        let stats = backdropStats(line, sample: sample)
        guard stats.lightShare <= 0.5 else { return false }
        return (stats.lightShare >= 0.08 && stats.restMean < 0.6) || (stats.lightShare >= 0.03 && stats.restMean < 0.3)
    }

    /// The share of light (glyph) pixels in the box and the mean
    /// brightness of the rest.
    static func backdropStats(_ line: OCRLine, sample: PixelSampler) -> (lightShare: Double, restMean: Double) {
        var light = 0, total = 0
        var rest = 0.0, restCount = 0
        let stepX = max(1, Int(line.width / 40)), stepY = max(1, Int(line.height / 8))
        var y = Int(line.y)
        while y <= Int(line.maxY) {
            var x = Int(line.x)
            while x <= Int(line.maxX) {
                if let p = sample(x, y) {
                    let l = 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b
                    if l > 0.62 { light += 1 } else { rest += l; restCount += 1 }
                    total += 1
                }
                x += stepX
            }
            y += stepY
        }
        guard total > 0, restCount > 0 else { return (0, 1) }
        return (Double(light) / Double(total), rest / Double(restCount))
    }

    /// A saturated, bright pixel: the colour of an active-speaker frame
    /// (Zoom green or yellow, Teams indigo, Meet blue), not grey video.
    static func isHighlight(_ p: (r: Double, g: Double, b: Double)) -> Bool {
        let maxC = max(p.r, p.g, p.b), minC = min(p.r, p.g, p.b)
        guard maxC > 0.45 else { return false }
        return (maxC - minC) / maxC > 0.45
    }

    /// The highlight colour found near a label's tile corner, as a coarse
    /// hue bucket (0…11), or nil. Tile labels sit just inside the tile's
    /// bottom-left corner, so the frame passes left of and below the label.
    static func highlightHue(near line: OCRLine, sample: PixelSampler) -> Int? {
        let reach = max(24, Int(line.height * 2.5))
        func scan(_ points: [(Int, Int)]) -> Int? {
            var run = 0
            for (x, y) in points {
                if let p = sample(x, y), isHighlight(p) {
                    run += 1
                    if run >= 2 { return hueBucket(p) }
                } else {
                    run = 0
                }
            }
            return nil
        }
        let y = Int(line.midY), x = Int(line.x + min(line.width / 2, 40))
        let left = scan((0..<reach).map { (Int(line.x) - 1 - $0, y) })
        let below = scan((0..<reach).map { (x, Int(line.maxY) + 1 + $0) })
        if let l = left, let b = below, abs(l - b) <= 1 || abs(l - b) == 11 { return l }
        return plateHue(line, sample: sample)
    }

    /// The other marking some layouts use: the speaker's name plate itself
    /// is coloured (a lavender or blue plate behind the name) where the
    /// others are black or grey. The hue (offset by 12, so it never equals
    /// a frame's) when the pixels behind the glyphs are clearly coloured.
    static func plateHue(_ line: OCRLine, sample: PixelSampler) -> Int? {
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        let stepX = max(1, Int(line.width / 40)), stepY = max(1, Int(line.height / 8))
        var yy = Int(line.y)
        while yy <= Int(line.maxY) {
            var xx = Int(line.x)
            while xx <= Int(line.maxX) {
                if let p = sample(xx, yy), 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b <= 0.85 {
                    r += p.r; g += p.g; b += p.b; n += 1
                }
                xx += stepX
            }
            yy += stepY
        }
        guard n > 0 else { return nil }
        let mean = (r: r / n, g: g / n, b: b / n)
        let maxC = max(mean.r, mean.g, mean.b), minC = min(mean.r, mean.g, mean.b)
        guard maxC > 0.4, (maxC - minC) / maxC > 0.25 else { return nil }
        return 12 + hueBucket(mean)
    }

    static func hueBucket(_ p: (r: Double, g: Double, b: Double)) -> Int {
        let maxC = max(p.r, p.g, p.b), minC = min(p.r, p.g, p.b), d = maxC - minC
        guard d > 0 else { return 0 }
        var h: Double
        if maxC == p.r { h = ((p.g - p.b) / d).truncatingRemainder(dividingBy: 6) }
        else if maxC == p.g { h = (p.b - p.r) / d + 2 }
        else { h = (p.r - p.g) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return Int(h / 30) % 12
    }

    /// Whether a line reads like spoken text (a caption) rather than a
    /// label: several words, mostly lower case.
    static func isSentence(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 4, words.filter({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }).count >= 3 else { return false }
        let lowerStarts = words.filter { $0.first.map { $0.isLowercase } ?? false }.count
        return Double(lowerStarts) / Double(words.count) >= 0.4
    }

    /// Text worth keeping for spelling: capitalised or mixed-case words and
    /// acronyms of 3+ characters that aren't interface words.
    static func vocabulary(from text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "'") })
            .map(String.init)
            .filter { word in
                guard word.count >= 3, word.count <= 40, let first = word.first, first.isLetter, first.isUppercase else { return false }
                return !interfaceWords.contains(word.lowercased())
            }
    }

    /// OCR sometimes splits one label into words ("Barbal" | "Adler"):
    /// join single capitalised words that sit side by side on one baseline
    /// with a gap under a letter height.
    static func joinSplitLabels(_ lines: [OCRLine]) -> [OCRLine] {
        var out: [OCRLine] = []
        for line in lines.sorted(by: { ($0.midY, $0.x) < ($1.midY, $1.x) }) {
            if let prev = out.last,
               !prev.text.contains(":"),
               abs(prev.midY - line.midY) < min(prev.height, line.height) * 0.3,
               line.x - prev.maxX > 0, line.x - prev.maxX < line.height * 1.2,
               prev.text.split(separator: " ").count < 4,
               !line.text.contains(" "), line.text.first?.isUppercase == true {
                out[out.count - 1] = OCRLine(text: prev.text + " " + line.text, x: prev.x, y: min(prev.y, line.y),
                                             width: line.maxX - prev.x, height: max(prev.height, line.height),
                                             confidence: min(prev.confidence, line.confidence))
            } else {
                out.append(line)
            }
        }
        return out
    }

    static func analyze(lines rawLines: [OCRLine], width: Double, height: Double, app: String,
                        host: Double, wall: Date, sample: PixelSampler) -> CallFrame {
        let lines = joinSplitLabels(rawLines)
        // Captions: the lowest part of the window, sentence-like lines, with
        // the name-shaped line just above (Teams, Meet) or a "Name: text"
        // prefix (Zoom).
        var captions: [CaptionLine] = []
        var captionLineIDs = Set<Int>()
        let captionTop = height * 0.55
        for (i, line) in lines.enumerated() where line.y >= captionTop {
            var text = line.text.trimmingCharacters(in: .whitespaces)
            var speaker: String?
            if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 40,
               let label = nameLabel(String(text[..<colon])) {
                let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if isSentence(rest) { speaker = label.name; text = rest }
            }
            guard isSentence(text) else { continue }
            if speaker == nil {
                let above = lines.enumerated()
                    .filter { $0.element.maxY <= line.y + 2 && line.y - $0.element.maxY < line.height * 1.0
                        && abs($0.element.x - line.x) < max(line.height * 2, 40) && nameLabel($0.element.text) != nil
                        // A caption's name is set near the caption's size; a
                        // tile label just above burned-in subtitles is far smaller.
                        && $0.element.height >= line.height * 0.6 }
                    .min { (line.y - $0.element.maxY) < (line.y - $1.element.maxY) }
                if let above { speaker = nameLabel(above.element.text)?.name; captionLineIDs.insert(above.offset) }
            }
            // Without a name it is just text near the bottom (a chat, a
            // slide, a terminal), not a caption.
            guard let speaker else { continue }
            captions.append(CaptionLine(speaker: speaker, text: text))
            captionLineIDs.insert(i)
        }

        // Tile labels: name-shaped, isolated (no line stacked tight above or
        // below at the same left edge, as in a paragraph or a menu), and
        // light on dark.
        struct Label { let name: String; let isSelf: Bool; let line: OCRLine }
        var labels: [Label] = []
        for (i, line) in lines.enumerated() where !captionLineIDs.contains(i) && line.confidence >= 0.8 {
            guard let parsed = nameLabel(line.text) else { continue }
            let stacked = lines.enumerated().contains { j, other in
                j != i && abs(other.x - line.x) < line.height && abs(other.midY - line.midY) < line.height * 1.6
                    && abs(other.midY - line.midY) > line.height * 0.3
            }
            guard !stacked, isOnDarkBackdrop(line, sample: sample) else { continue }
            labels.append(Label(name: parsed.name, isSelf: parsed.isSelf, line: line))
        }
        // The same name twice (a tile and a participant list) counts once.
        var seen = Set<String>()
        labels = labels.filter { seen.insert($0.name.lowercased()).inserted }

        // Active speaker: a highlight colour around some tiles but not most.
        var active: [String] = []
        let hues = labels.map { highlightHue(near: $0.line, sample: sample) }
        let lit = hues.compactMap { $0 }
        if !lit.isEmpty {
            let counts = Dictionary(grouping: lit, by: { $0 }).mapValues(\.count)
            for (hue, count) in counts where labels.count == 1 || Double(count) <= Double(labels.count) / 2 {
                for (k, h) in hues.enumerated() where h == hue { active.append(labels[k].name) }
            }
        }

        var words: [String] = []
        let labelNames = Set(labels.map { $0.name.lowercased() })
        for (i, line) in lines.enumerated() where !captionLineIDs.contains(i) && !labelNames.contains(line.text.lowercased()) {
            words += vocabulary(from: line.text)
        }
        var seenWords = Set<String>()
        words = words.filter { seenWords.insert($0).inserted }

        return CallFrame(host: host, wall: wall, app: app,
                         participants: labels.map(\.name),
                         me: labels.first(where: \.isSelf)?.name,
                         active: active,
                         captions: captions,
                         words: Array(words.prefix(200)))
    }
}

enum CallFrameLog {
    static let fileName = "call.jsonl"

    static func url(in slot: OutboxSlot) -> URL { slot.dirURL.appendingPathComponent(fileName) }

    static func encode(_ frame: CallFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(frame) + Data("\n".utf8)
    }

    /// Every readable line; a torn last line (a crash mid-write) is skipped.
    static func read(_ url: URL) -> [CallFrame] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(CallFrame.self, from: Data($0)) }
    }
}
