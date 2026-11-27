//
// From call-window frames (CallFrames.swift) to what the transcript uses:
//
//   - who the operator is on screen (the "(me)"/"You" tile, or the name
//     that lights up while only the mic has speech), so their tile never
//     names a remote voice;
//   - the remote participants, and the one other person in a 1:1;
//   - a name for each diarized "Them" voice: every frame in which exactly
//     one remote tile is highlighted votes for that name on the voice
//     speaking at that moment, and a caption line with a speaker votes for
//     the voice whose segment says the same words (twice the weight). A
//     voice gets the name with most votes when it has at least two and at
//     least half of that voice's votes; each name goes to one voice;
//   - spelling: transcript words a letter or two away from a name or a
//     term seen on screen are written the way the screen writes them;
//   - caption lines no transcript segment covers, kept as marked segments.
//
// Pure functions over plain values; the job wires them in.
//

import Foundation

struct CallEvidence: Sendable, Equatable {
    var me: String?
    var others: [String]
    /// Diarized speaker id ("A") → name.
    var voiceNames: [String: String]
    /// Lower-cased wrong spelling → screen spelling.
    var corrections: [String: String]
    /// Caption lines with no transcript segment, on the system track's
    /// timeline, already marked.
    var captionFills: [STTSegment]

    var soleOther: String? { others.count == 1 ? others[0] : nil }

    static let empty = CallEvidence(me: nil, others: [], voiceNames: [:], corrections: [:], captionFills: [])
}

enum CallEvidenceBuilder {
    /// A name must be on screen in at least this many frames to count as a
    /// participant: one frame can be a misread or a passing list.
    static let minFramesForParticipant = 2
    static let captionMark = "[captions]"
    /// A caption fill's speaker id: the prefix and the name on screen; the
    /// name is also in voiceNames under that id.
    static let captionSpeakerPrefix = "~"

    /// Seconds on the mic track's timeline at which each frame was taken.
    static func frameTimes(_ frames: [CallFrame], micStartHost: Double?, startedAt: Date) -> [Double] {
        frames.map { frame in
            if let micStartHost { return frame.host - micStartHost }
            return frame.wall.timeIntervalSince(startedAt)
        }
    }

    static func build(frames: [CallFrame], times: [Double], systemOffset: Double,
                      mic: [STTSegment], system: [STTSegment]) -> CallEvidence {
        guard !frames.isEmpty, frames.count == times.count else { return .empty }
        // One spelling per person before anything is counted.
        let canon = canonicalNames(frames)
        let byLower = Dictionary(frames.flatMap(\.participants).map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        func fix(_ name: String) -> String {
            guard let target = canon[name.lowercased()] else { return name }
            return byLower[target] ?? name
        }
        // Saved names are checked against today's label rules too, so a
        // recording read by an older version loses what they now reject.
        let isName = { (n: String) in CallFrameAnalyzer.nameLabel(n) != nil }
        let frames = frames.map { frame in
            var f = frame
            f.participants = frame.participants.filter(isName).map(fix)
            f.active = frame.active.filter(isName).map(fix)
            f.me = frame.me.map(fix)
            return f
        }

        // Participants seen often enough.
        var frameCount: [String: Int] = [:]
        var spelling: [String: String] = [:]
        for frame in frames {
            for name in Set(frame.participants.map { $0.lowercased() }) { frameCount[name, default: 0] += 1 }
            for name in frame.participants { spelling[name.lowercased()] = spelling[name.lowercased()] ?? name }
        }
        let roster = frameCount.filter { $0.value >= minFramesForParticipant }.keys
            .sorted { frameCount[$0]! != frameCount[$1]! ? frameCount[$0]! > frameCount[$1]! : $0 < $1 }

        func covers(_ segments: [STTSegment], _ t: Double) -> STTSegment? {
            segments.first { Double($0.start) - 0.3 <= t && t <= Double($0.end) + 0.3 }
        }

        // The operator: marked on screen, else lit up while only the mic speaks.
        var me: String?
        let marked = frames.compactMap { $0.me?.lowercased() }
        if let top = Dictionary(grouping: marked, by: { $0 }).max(by: { $0.value.count < $1.value.count }) {
            me = top.key
        } else {
            var meVotes: [String: Int] = [:], themVotes: [String: Int] = [:]
            for (frame, t) in zip(frames, times) {
                let micTalking = covers(mic, t) != nil
                let sysTalking = covers(system, t - systemOffset) != nil
                for name in frame.active.map({ $0.lowercased() }) {
                    if micTalking && !sysTalking { meVotes[name, default: 0] += 1 }
                    if sysTalking && !micTalking { themVotes[name, default: 0] += 1 }
                }
            }
            me = meVotes.filter { $0.value >= 3 && $0.value > 2 * (themVotes[$0.key] ?? 0) }
                .max { $0.value < $1.value }?.key
        }
        let others = roster.filter { $0 != me }

        // Votes per diarized voice.
        var votes: [String: [String: Int]] = [:]
        for (frame, t) in zip(frames, times) {
            let remote = Set(frame.active.map { $0.lowercased() }).subtracting([me].compactMap { $0 })
            if remote.count == 1, let name = remote.first, let seg = covers(system, t - systemOffset), let id = seg.speaker {
                votes[id, default: [:]][name, default: 0] += 1
            }
            for caption in frame.captions {
                guard let who = caption.speaker?.lowercased(), who != me else { continue }
                let words = normalizedWords(caption.text)
                guard words.count >= 3 else { continue }
                let tSys = t - systemOffset
                let match = system
                    .filter { Double($0.end) >= tSys - 12 && Double($0.start) <= tSys + 2 && $0.speaker != nil }
                    .map { ($0, Set(normalizedWords($0.text)).intersection(words).count) }
                    .max { $0.1 < $1.1 }
                if let (seg, shared) = match, shared >= 3, let id = seg.speaker {
                    votes[id, default: [:]][who, default: 0] += 2
                }
            }
        }
        var voiceNames: [String: String] = [:]
        var usedNames = Set<String>()
        let ranked = votes.flatMap { id, names in names.map { (id, $0.key, $0.value) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : ($0.0, $0.1) < ($1.0, $1.1) }
        for (id, name, count) in ranked where voiceNames[id] == nil && !usedNames.contains(name) {
            let total = votes[id]!.values.reduce(0, +)
            guard count >= 2, Double(count) >= Double(total) / 2 else { continue }
            voiceNames[id] = spelling[name] ?? captionSpelling(name, frames) ?? name
            usedNames.insert(name)
        }

        // Spelling: names (every part) and words seen on 2+ frames.
        var wordFrames: [String: Int] = [:]
        var wordSpelling: [String: String] = [:]
        for frame in frames {
            for w in Set(frame.words) { wordFrames[w.lowercased(), default: 0] += 1; wordSpelling[w.lowercased()] = w }
        }
        var vocabulary = Set(wordFrames.filter { $0.value >= 2 }.keys.compactMap { wordSpelling[$0] })
        var nameParts = Set<String>()
        for name in roster.compactMap({ spelling[$0] }) {
            for part in name.split(separator: " ") where part.count >= 4 { nameParts.insert(String(part)) }
        }
        vocabulary.formUnion(nameParts)
        let corrections = spellingCorrections(texts: (mic + system).map(\.text), vocabulary: vocabulary, names: nameParts)

        let fills = captionFills(frames: frames, times: times, systemOffset: systemOffset, me: me, system: system)
        for id in fills.compactMap(\.speaker) where voiceNames[id] == nil {
            voiceNames[id] = String(id.dropFirst(captionSpeakerPrefix.count))
        }

        return CallEvidence(me: me.flatMap { spelling[$0] } ?? me,
                            others: others.compactMap { spelling[$0] },
                            voiceNames: voiceNames,
                            corrections: corrections,
                            captionFills: fills)
    }

    private static func captionSpelling(_ lower: String, _ frames: [CallFrame]) -> String? {
        frames.lazy.flatMap(\.captions).compactMap(\.speaker).first { $0.lowercased() == lower }
    }

    static func normalizedWords(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).filter { $0.count >= 2 })
    }

    /// Edits between two words, a swap of neighbours counting as one
    /// (optimal string alignment): "Ejadha" is one edit from "Ejadah".
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    /// The lower-case entries of the system word list: a word in it is a
    /// word, not a misheard name, and is never "corrected".
    static var dictionary: Set<String>? { WordList.lowercase }

    /// Capitalised transcript words that are one edit (five to seven
    /// letters) or two (eight or more) from exactly one vocabulary word with
    /// the same first letter, and not themselves on screen.
    /// Without the word list only names are trusted (`names`), since a
    /// common word one letter from a screen word would be changed.
    static func spellingCorrections(texts: [String], vocabulary: Set<String>, names: Set<String>? = nil,
                                    dictionary: Set<String>? = CallEvidenceBuilder.dictionary) -> [String: String] {
        let vocab = (dictionary == nil ? (names ?? []) : vocabulary).filter { $0.count >= 5 }
        let vocabLower = Set(vocabulary.map { $0.lowercased() })
        var out: [String: String] = [:]
        for text in texts {
            for raw in text.split(whereSeparator: { !($0.isLetter || $0 == "-" || $0 == "'") }) {
                let word = String(raw)
                guard word.count >= 5, let first = word.first, first.isUppercase,
                      !vocabLower.contains(word.lowercased()), out[word.lowercased()] == nil,
                      dictionary?.contains(word.lowercased()) != true else { continue }
                let limit = word.count >= 8 ? 2 : 1
                let candidates = vocab.filter {
                    $0.first?.lowercased() == first.lowercased() && abs($0.count - word.count) <= limit
                        && editDistance($0.lowercased(), word.lowercased()) <= limit
                }
                if candidates.count == 1 { out[word.lowercased()] = candidates.first! }
            }
        }
        return out
    }

    static func applyCorrections(_ text: String, _ corrections: [String: String]) -> String {
        guard !corrections.isEmpty else { return text }
        var result = ""
        var word = ""
        func flush() {
            if !word.isEmpty { result += corrections[word.lowercased()] ?? word; word = "" }
        }
        for ch in text {
            if ch.isLetter || ch == "-" || ch == "'" { word.append(ch) } else { flush(); result.append(ch) }
        }
        flush()
        return result
    }

    /// Caption lines (from a remote speaker) that stayed on screen for two
    /// frames or more and that no system segment within 10 s shares three
    /// words with, where the system track has no segment at that moment.
    static func captionFills(frames: [CallFrame], times: [Double], systemOffset: Double,
                             me: String?, system: [STTSegment]) -> [STTSegment] {
        struct Seen { var text: String; var speaker: String?; var first: Double; var last: Double; var frames: Int }
        var lines: [Seen] = []
        for (frame, t) in zip(frames, times) {
            for caption in frame.captions {
                let key = normalizedWords(caption.text)
                if let i = lines.lastIndex(where: { t - $0.last <= 6 && (normalizedWords($0.text).isSubset(of: key) || key.isSubset(of: normalizedWords($0.text))) }) {
                    if caption.text.count > lines[i].text.count { lines[i].text = caption.text }
                    lines[i].last = t
                    lines[i].frames += 1
                } else {
                    lines.append(Seen(text: caption.text, speaker: caption.speaker, first: t, last: t, frames: 1))
                }
            }
        }
        var fills: [STTSegment] = []
        for line in lines where line.frames >= 2 && line.speaker?.lowercased() != me {
            let words = normalizedWords(line.text)
            guard words.count >= 4 else { continue }
            let start = line.first - systemOffset - 4, end = line.last - systemOffset
            let covered = system.contains { Double($0.end) >= start - 10 && Double($0.start) <= end + 10
                && normalizedWords($0.text).intersection(words).count >= 3 }
            let busy = system.contains { Double($0.end) >= start && Double($0.start) <= end }
            guard !covered, !busy, start >= 0 else { continue }
            fills.append(STTSegment(start: Float(start), end: Float(max(end, start + 1)),
                                    text: "\(captionMark) \(line.text)",
                                    speaker: line.speaker.map { captionSpeakerPrefix + $0 }))
        }
        return fills
    }
}

extension CallEvidenceBuilder {
    /// The evidence for a slot whose recording read the call window; nil
    /// when it didn't (no call.jsonl, or nothing in it).
    static func evidence(slot: OutboxSlot, meta: RecordingMeta,
                         micResults: [STTResult], systemResults: [STTResult]) -> CallEvidence? {
        let frames = CallFrameLog.read(CallFrameLog.url(in: slot))
        guard !frames.isEmpty else { return nil }
        let times = frameTimes(frames, micStartHost: meta.capture_health?.mic_start_host_seconds, startedAt: meta.started_at)
        return build(frames: frames, times: times,
                     systemOffset: meta.capture_health?.system_start_offset_seconds ?? 0,
                     mic: micResults.flatMap(\.segments), system: systemResults.flatMap(\.segments))
    }
}

/// The system word list (/usr/share/dict/words, Webster's 2nd), split by
/// case: "perception" is a common word, "Leah" a name. nil when the file
/// isn't there.
enum WordList {
    private static let entries: (lower: Set<String>, capitalized: Set<String>)? = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return nil }
        var lower = Set<String>(), capitalized = Set<String>()
        for line in text.split(separator: "\n") {
            let word = String(line)
            if word.first?.isUppercase == true { capitalized.insert(word.lowercased()) } else { lower.insert(word) }
        }
        return (lower, capitalized)
    }()

    static var lowercase: Set<String>? { entries?.lower }

    /// A common word that isn't also listed as a name ("All", "Perception";
    /// not "Anna", which is both).
    static func isCommonWordOnly(_ word: String) -> Bool {
        guard let entries else { return false }
        let w = word.lowercased()
        return entries.lower.contains(w) && !entries.capitalized.contains(w)
    }
}

extension CallEvidenceBuilder {
    /// OCR variants of one name ("Roberta Seme", "Roberta Semel" beside
    /// "Roberta Semer") mapped to the spelling seen on most frames:
    /// lower-cased name → lower-cased canonical name. Two names are one
    /// when they share the first word and the rest is a prefix of the
    /// other's or one or two edits away.
    static func canonicalNames(_ frames: [CallFrame]) -> [String: String] {
        var counts: [String: Int] = [:]
        for frame in frames {
            for name in Set((frame.participants + frame.active + [frame.me].compactMap { $0 }).map { $0.lowercased() }) {
                counts[name, default: 0] += 1
            }
        }
        let ordered = counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }
        var canonical: [String] = []
        var map: [String: String] = [:]
        for name in ordered {
            let parts = name.split(separator: " ")
            let match = canonical.first { kept in
                let keptParts = kept.split(separator: " ")
                guard parts.first == keptParts.first, parts.count == keptParts.count, parts.count >= 2 else { return false }
                let a = parts.dropFirst().joined(separator: " "), b = keptParts.dropFirst().joined(separator: " ")
                return (b.hasPrefix(a) && a.count >= 3) || editDistance(a, b) <= (b.count >= 6 ? 2 : 1)
            }
            if let match { map[name] = match } else { canonical.append(name); map[name] = name }
        }
        // One word of a longer name, from a frame where OCR split the label
        // ("Barba" | "Adler" for "Barbara Adler"), belongs to that name.
        for (name, target) in map where target == name && !name.contains(" ") {
            if let whole = canonical.first(where: { kept in
                kept.contains(" ") && kept.split(separator: " ").contains { $0 == name || ($0.hasPrefix(name) && name.count >= 4) }
            }) {
                map[name] = whole
            }
        }
        return map
    }
}
