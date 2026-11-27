import Foundation
import Testing
@testable import Notarie

/// The call window: recognising meeting windows, reading names, the active
/// speaker and captions off a frame, and turning frames into speaker names
/// and spelling for the transcript.
@Suite struct CallWindowTests {
    // MARK: windows

    @Test func meetingWindowsAreRecognised() {
        #expect(CallWindowMatcher.classify(bundleID: "us.zoom.xos", title: "Zoom Meeting") == "Zoom")
        #expect(CallWindowMatcher.classify(bundleID: "us.zoom.xos", title: "Zoom Workplace") == nil)
        #expect(CallWindowMatcher.classify(bundleID: "com.microsoft.teams2", title: "Weekly sync | Meeting | Microsoft Teams") == "Teams")
        #expect(CallWindowMatcher.classify(bundleID: "com.microsoft.teams2", title: "Chat | Anna | Microsoft Teams") == nil)
        #expect(CallWindowMatcher.classify(bundleID: "com.google.Chrome", title: "Meet - abc-defg-hij 🔊") == "Meet")
        #expect(CallWindowMatcher.classify(bundleID: "com.google.Chrome", title: "Inbox - Gmail") == nil)
        #expect(CallWindowMatcher.classify(bundleID: "com.apple.Safari", title: "Meeting in General | Microsoft Teams") == "Teams (web)")
        #expect(CallWindowMatcher.classify(bundleID: "com.apple.TextEdit", title: "Zoom Meeting notes") == nil)
        #expect(CallWindowMatcher.classify(bundleID: "com.google.Chrome", title: "Weekly sync with th… | Microsoft Teams") == nil)
        #expect(CallWindowMatcher.classify(bundleID: "com.google.Chrome", title: "Weekly sync with th… | Microsoft Teams",
                                           playingAudio: true) == "Teams (web)")
        #expect(CallWindowMatcher.classify(bundleID: "com.google.Chrome", title: "Board meeting - YouTube", titleOverride: "board") == "Window")
    }

    // MARK: labels

    @Test func nameLabelsAreCleaned() {
        #expect(CallFrameAnalyzer.nameLabel("Jane Doe (Host)")?.name == "Jane Doe")
        #expect(CallFrameAnalyzer.nameLabel("Jakob W (me)")! == ("Jakob W", true))
        #expect(CallFrameAnalyzer.nameLabel("Community Board…")?.name == "Community Board")
        #expect(CallFrameAnalyzer.nameLabel("Cristian Cotovan ***")?.name == "Cristian Cotovan")
        #expect(CallFrameAnalyzer.nameLabel("Leah Flax:")?.name == "Leah Flax")
        #expect(CallFrameAnalyzer.nameLabel("Åsa Öberg-Lind")?.name == "Åsa Öberg-Lind")
        #expect(CallFrameAnalyzer.nameLabel("Mute") == nil)
        #expect(CallFrameAnalyzer.nameLabel("Share Screen") == nil)
        #expect(CallFrameAnalyzer.nameLabel("THE MOST BRUTAL BEAT") == nil)
        #expect(CallFrameAnalyzer.nameLabel("Q3 planning 2026") == nil)
        #expect(CallFrameAnalyzer.nameLabel("we should ship it") == nil)
        #expect(CallFrameAnalyzer.nameLabel("Perception") == nil)
        #expect(CallFrameAnalyzer.nameLabel("ITS") == nil)
        #expect(CallFrameAnalyzer.nameLabel("Anna")?.name == "Anna")
    }

    @Test func aLabelSplitInTwoIsJoined() {
        let joined = CallFrameAnalyzer.joinSplitLabels([
            OCRLine(text: "Barbal", x: 710, y: 450, width: 46, height: 17, confidence: 1),
            OCRLine(text: "Adler", x: 770, y: 450, width: 44, height: 17, confidence: 1),
            OCRLine(text: "Sara Lind", x: 1000, y: 450, width: 70, height: 17, confidence: 1),
        ])
        #expect(joined.map(\.text) == ["Barbal Adler", "Sara Lind"])
    }

    @Test func sentencesAreCaptionShaped() {
        #expect(CallFrameAnalyzer.isSentence("so the next thing is the budget"))
        #expect(!CallFrameAnalyzer.isSentence("Jane Doe"))
        #expect(!CallFrameAnalyzer.isSentence("• 2M 11 mo ago"))
    }

    // MARK: a synthetic frame

    /// A 1000×600 frame: dark tiles with white name plates; `activeTile`
    /// gets a green frame; optional caption block at the bottom.
    struct Canvas {
        var tiles: [(name: String, x: Double, y: Double)]
        var activeTile: Int?
        let tileW = 300.0, tileH = 200.0

        func sample(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double)? {
            guard x >= 0, y >= 0, x < 1000, y < 600 else { return nil }
            let fx = Double(x), fy = Double(y)
            for (i, tile) in tiles.enumerated() {
                let inside = fx >= tile.x && fx < tile.x + tileW && fy >= tile.y && fy < tile.y + tileH
                guard inside else { continue }
                if i == activeTile && (fx < tile.x + 4 || fy >= tile.y + tileH - 4) { return (0.14, 0.85, 0.35) }
                // Name plate: bottom-left; text stripes white, plate dark.
                let plate = label(i)
                if fx >= plate.x && fx <= plate.maxX && fy >= plate.y && fy <= plate.maxY {
                    return (x * 7 + y * 13) % 10 < 3 ? (1, 1, 1) : (0.1, 0.1, 0.1)
                }
                return (0.45, 0.4, 0.38)
            }
            return (0.05, 0.05, 0.05)
        }

        func label(_ i: Int) -> OCRLine {
            let t = tiles[i]
            return OCRLine(text: t.name, x: t.x + 10, y: t.y + tileH - 34, width: 140, height: 22, confidence: 1)
        }

        var lines: [OCRLine] { tiles.indices.map(label) }
    }

    static let threeTiles = [("Anna Svensson", 0.0, 0.0), ("Bob Lee", 320.0, 0.0), ("Jakob W (me)", 640.0, 0.0)]

    @Test func tilesAndTheActiveSpeakerAreRead() {
        let canvas = Canvas(tiles: Self.threeTiles, activeTile: 1)
        let frame = CallFrameAnalyzer.analyze(lines: canvas.lines, width: 1000, height: 600, app: "Zoom",
                                              host: 0, wall: Date(), sample: canvas.sample)
        #expect(frame.participants == ["Anna Svensson", "Bob Lee", "Jakob W"])
        #expect(frame.me == "Jakob W")
        #expect(frame.active == ["Bob Lee"])
    }

    @Test func aColouredNamePlateMarksTheSpeaker() {
        // Black strips with white names; Bob's plate is lavender instead.
        let lines = [
            OCRLine(text: "Anna Svensson", x: 10, y: 170, width: 140, height: 22, confidence: 1),
            OCRLine(text: "Bob Lee", x: 330, y: 170, width: 100, height: 22, confidence: 1),
            OCRLine(text: "Cleo Park", x: 650, y: 170, width: 100, height: 22, confidence: 1),
        ]
        let sample: PixelSampler = { x, y in
            let glyph = (x * 7 + y * 13) % 10 < 3
            if glyph { return (1, 1, 1) }
            if x >= 330 && x <= 430 && y >= 170 && y <= 192 { return (0.55, 0.55, 0.85) }
            return (0.08, 0.08, 0.08)
        }
        let frame = CallFrameAnalyzer.analyze(lines: lines, width: 1000, height: 600, app: "Zoom",
                                              host: 0, wall: Date(), sample: sample)
        #expect(frame.participants.count == 3)
        #expect(frame.active == ["Bob Lee"])
    }

    @Test func noHighlightNoActiveSpeaker() {
        let canvas = Canvas(tiles: Self.threeTiles, activeTile: nil)
        let frame = CallFrameAnalyzer.analyze(lines: canvas.lines, width: 1000, height: 600, app: "Zoom",
                                              host: 0, wall: Date(), sample: canvas.sample)
        #expect(frame.active.isEmpty)
    }

    @Test func textOnALightPageIsNotATile() {
        let canvas = Canvas(tiles: [], activeTile: nil)
        let light: PixelSampler = { _, _ in (0.97, 0.97, 0.97) }
        let lines = [OCRLine(text: "Executive Summary", x: 100, y: 100, width: 200, height: 24, confidence: 1)]
        let frame = CallFrameAnalyzer.analyze(lines: lines, width: 1000, height: 600, app: "Zoom",
                                              host: 0, wall: Date(), sample: light)
        #expect(frame.participants.isEmpty)
        #expect(frame.words.contains("Executive"))
        _ = canvas
    }

    @Test func captionsTakeTheNameAboveOrBeforeTheColon() {
        let dark: PixelSampler = { _, _ in (0.1, 0.1, 0.1) }
        let lines = [
            OCRLine(text: "Anna Svensson", x: 100, y: 450, width: 120, height: 20, confidence: 1),
            OCRLine(text: "so the budget is not final yet", x: 100, y: 474, width: 400, height: 22, confidence: 1),
            OCRLine(text: "Bob Lee: we need it by friday then", x: 100, y: 540, width: 400, height: 22, confidence: 1),
            OCRLine(text: "and some text without any name here", x: 600, y: 560, width: 300, height: 22, confidence: 1),
        ]
        let frame = CallFrameAnalyzer.analyze(lines: lines, width: 1000, height: 600, app: "Teams",
                                              host: 0, wall: Date(), sample: dark)
        #expect(frame.captions == [
            CaptionLine(speaker: "Anna Svensson", text: "so the budget is not final yet"),
            CaptionLine(speaker: "Bob Lee", text: "we need it by friday then"),
        ])
        #expect(!frame.participants.contains("Anna Svensson"))
    }

    @Test func frameLogRoundTripsAndSkipsATornLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("call.jsonl")
        let frame = CallFrame(host: 12.5, wall: Date(timeIntervalSince1970: 1_000), app: "Zoom", participants: ["Anna"],
                              me: nil, active: ["Anna"], captions: [], words: ["Ejadah"])
        var data = try CallFrameLog.encode(frame)
        data += Data("{\"host\": 1".utf8)
        try data.write(to: url)
        #expect(CallFrameLog.read(url) == [frame])
    }

    // MARK: evidence

    static func frame(_ t: Double, participants: [String] = ["Anna Svensson", "Bob Lee", "Jakob W"],
                      me: String? = "Jakob W", active: [String] = [], captions: [CaptionLine] = [],
                      words: [String] = []) -> CallFrame {
        CallFrame(host: t, wall: Date(timeIntervalSince1970: t), app: "Zoom", participants: participants,
                  me: me, active: active, captions: captions, words: words)
    }

    static func seg(_ start: Float, _ end: Float, _ text: String, _ speaker: String? = nil) -> STTSegment {
        STTSegment(start: start, end: end, text: text, speaker: speaker)
    }

    @Test func highlightedTilesNameTheDiarizedVoices() {
        // A speaks 0–10 s while Bob is lit; B speaks 10–20 s while Anna is lit.
        let frames = stride(from: 0.0, to: 20, by: 2).map { t in Self.frame(t, active: [t < 10 ? "Bob Lee" : "Anna Svensson"]) }
        let system = [Self.seg(0, 10, "first part", "A"), Self.seg(10, 20, "second part", "B")]
        let ev = CallEvidenceBuilder.build(frames: frames, times: frames.map(\.host), systemOffset: 0, mic: [], system: system)
        #expect(ev.me == "Jakob W")
        #expect(ev.others == ["Anna Svensson", "Bob Lee"])
        #expect(ev.voiceNames == ["A": "Bob Lee", "B": "Anna Svensson"])
    }

    @Test func theSystemOffsetMovesFramesOntoTheSystemTrack() {
        // The system file starts 5 s into the mic file; A's 0–10 s is mic 5–15 s.
        let frames = stride(from: 5.0, to: 15, by: 2).map { Self.frame($0, active: ["Bob Lee"]) }
        let system = [Self.seg(0, 10, "x", "A"), Self.seg(10, 30, "y", "B")]
        let ev = CallEvidenceBuilder.build(frames: frames, times: frames.map(\.host), systemOffset: 5, mic: [], system: system)
        #expect(ev.voiceNames == ["A": "Bob Lee"])
    }

    @Test func aSplitVoteNamesNobody() {
        let frames = (0..<6).map { i in Self.frame(Double(i), active: [i % 2 == 0 ? "Bob Lee" : "Anna Svensson"]) }
        let ev = CallEvidenceBuilder.build(frames: frames, times: frames.map(\.host), systemOffset: 0,
                                           mic: [], system: [Self.seg(0, 10, "x", "A")])
        // 3 against 3: half is enough for the first, and then the name is used.
        #expect(ev.voiceNames.count <= 1)
        let frames2 = (0..<9).map { i in Self.frame(Double(i), active: [["Bob Lee", "Anna Svensson", "Cleo Park"][i % 3]]) }
        let ev2 = CallEvidenceBuilder.build(frames: frames2, times: frames2.map(\.host), systemOffset: 0,
                                            mic: [], system: [Self.seg(0, 10, "x", "A")])
        #expect(ev2.voiceNames.isEmpty)
    }

    @Test func theOperatorIsFoundFromTheMicWhenUnmarked() {
        // Jakob is lit whenever only the mic speaks.
        let frames = stride(from: 0.0, to: 12, by: 2).map { Self.frame($0, me: nil, active: ["Jakob W"]) }
        let mic = [Self.seg(0, 12, "I talk")]
        let ev = CallEvidenceBuilder.build(frames: frames, times: frames.map(\.host), systemOffset: 0, mic: mic, system: [])
        #expect(ev.me == "Jakob W")
        #expect(!ev.others.contains("Jakob W"))
    }

    @Test func ocrVariantsOfANameAreMerged() {
        let frames = [
            Self.frame(0, participants: ["Roberta Semer", "Steven Brown"], me: nil),
            Self.frame(2, participants: ["Roberta Semer", "Steven Brow"], me: nil),
            Self.frame(4, participants: ["Roberta Semel", "Steven Brown"], me: nil, active: ["Roberta Seme"]),
            Self.frame(6, participants: ["Roberta Semer", "Robert Smith"], me: nil, active: ["Roberta Semer"]),
            Self.frame(8, participants: ["Robert Smith"], me: nil),
        ]
        let ev = CallEvidenceBuilder.build(frames: frames, times: [0, 2, 4, 6, 8], systemOffset: 0, mic: [],
                                           system: [Self.seg(0, 10, "x", "A")])
        #expect(ev.others == ["Roberta Semer", "Steven Brown", "Robert Smith"])
        let split = [Self.frame(0, participants: ["Barbara Adler", "Barba", "Adler"], me: nil),
                     Self.frame(2, participants: ["Barbara Adler", "Barba", "Adler"], me: nil)]
        #expect(CallEvidenceBuilder.build(frames: split, times: [0, 2], systemOffset: 0, mic: [], system: []).others == ["Barbara Adler"])
        #expect(ev.voiceNames == ["A": "Roberta Semer"])
    }

    @Test func aOneToOneCallHasASoleOther() {
        let frames = (0..<3).map { Self.frame(Double($0), participants: ["Anna Svensson", "Jakob W"]) }
        let ev = CallEvidenceBuilder.build(frames: frames, times: frames.map(\.host), systemOffset: 0, mic: [], system: [])
        #expect(ev.soleOther == "Anna Svensson")
    }

    @Test func aNameOnOneFrameIsNotAParticipant() {
        let frames = [Self.frame(0, participants: ["Anna Svensson", "Jakob W", "Flash Name"]), Self.frame(2, participants: ["Anna Svensson", "Jakob W"])]
        let ev = CallEvidenceBuilder.build(frames: frames, times: [0, 2], systemOffset: 0, mic: [], system: [])
        #expect(ev.others == ["Anna Svensson"])
    }

    @Test func captionsVoteForTheVoiceThatSaidTheWords() {
        let frames = [Self.frame(9, captions: [CaptionLine(speaker: "Anna Svensson", text: "the budget is not final yet")])]
        let system = [Self.seg(4, 8, "The budget is not final yet.", "B"), Self.seg(0, 4, "Hello everyone.", "A")]
        let ev = CallEvidenceBuilder.build(frames: frames, times: [9], systemOffset: 0, mic: [], system: system)
        #expect(ev.voiceNames == ["B": "Anna Svensson"])
    }

    @Test func screenSpellingFixesNearMisses() {
        let fixes = CallEvidenceBuilder.spellingCorrections(
            texts: ["Thanks Svenson, and the Ejadha numbers.", "There we go."],
            vocabulary: ["Svensson", "Ejadah", "Theme"])
        #expect(fixes == ["svenson": "Svensson", "ejadha": "Ejadah"])
        #expect(CallEvidenceBuilder.applyCorrections("Thanks Svenson, and the Ejadha numbers.", fixes)
                == "Thanks Svensson, and the Ejadah numbers.")
    }

    @Test func withoutAWordListOnlyNamesAreTrusted() {
        let fixes = CallEvidenceBuilder.spellingCorrections(
            texts: ["Thanks Svenson, and the Ejadha numbers."], vocabulary: ["Svensson", "Ejadah"],
            names: ["Svensson"], dictionary: nil)
        #expect(fixes == ["svenson": "Svensson"])
    }

    @Test func spellingNeedsTheWordOnTwoFramesOrInAName() {
        let frames = [Self.frame(0, words: ["Ejadah"]), Self.frame(2, words: ["Ejadah", "Once"])]
        let ev = CallEvidenceBuilder.build(frames: frames, times: [0, 2], systemOffset: 0,
                                           mic: [Self.seg(0, 2, "The Ejadha report, says Svenson.")], system: [])
        #expect(ev.corrections == ["ejadha": "Ejadah", "svenson": "Svensson"])
    }

    @Test func captionsNoSegmentCoversAreFilledAndMarked() {
        let caption = CaptionLine(speaker: "Bob Lee", text: "we can move the launch to march")
        let frames = [Self.frame(30, captions: [caption]), Self.frame(32, captions: [caption])]
        let ev = CallEvidenceBuilder.build(frames: frames, times: [30, 32], systemOffset: 0, mic: [],
                                           system: [Self.seg(0, 5, "Hello.", "A")])
        #expect(ev.captionFills.count == 1)
        #expect(ev.captionFills.first?.text == "[captions] we can move the launch to march")
        #expect(ev.voiceNames["~Bob Lee"] == "Bob Lee")
        // Covered by a segment saying the same words: no fill.
        let ev2 = CallEvidenceBuilder.build(frames: frames, times: [30, 32], systemOffset: 0, mic: [],
                                            system: [Self.seg(26, 31, "We can move the launch to March.", "A")])
        #expect(ev2.captionFills.isEmpty)
    }

    @Test func aSlotsCallLogNamesTheVoicesInTheWrittenTranscript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("callslot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let slot = Outbox.slot(forDir: dir)
        var meta = RecordingMeta(title: "Sync", started_at: Date(timeIntervalSince1970: 1_000), device: "mac", client_version: "1")
        meta.capture_health = CaptureHealth(mic_restarts: 0, mic_padded_seconds: 0, mic_seconds_captured: 20, mic_had_signal: true,
                                            system_restarts: 0, system_padded_seconds: 0, system_buffers: 1, system_had_signal: true,
                                            system_writer_failed: false, system_start_offset_seconds: 0,
                                            mic_start_host_seconds: 500)
        try Outbox.writeMeta(meta, to: slot.metaURL)
        // Host 500 is the mic's first sample: frames at host 500…518 are 0…18 s.
        var log = Data()
        for t in stride(from: 0.0, to: 20, by: 2) {
            log += try CallFrameLog.encode(Self.frame(500 + t, active: [t < 10 ? "Bob Lee" : "Anna Svensson"]))
        }
        try log.write(to: CallFrameLog.url(in: slot))
        let system = [STTResult(segments: [Self.seg(0, 9, "Good morning all.", "A"), Self.seg(11, 19, "Morning, Bob.", "B")], language: "en")]
        let call = CallEvidenceBuilder.evidence(slot: slot, meta: meta, micResults: [], systemResults: system)
        #expect(call?.voiceNames == ["A": "Bob Lee", "B": "Anna Svensson"])
        try TranscriptionJob.finish(slot: slot, meta: meta, micResults: [], systemResults: system,
                                    provenance: TranscriptionProvenance(engine: "whisperkit", model: "test", transcribed_at: Date()),
                                    call: call)
        let written = try String(contentsOf: slot.transcriptURL, encoding: .utf8)
        #expect(written.contains("**Bob Lee:**\nGood morning all."))
        #expect(written.contains("**Anna Svensson:**\nMorning, Bob."))
    }

    @Test func theTranscriptUsesTheNames() {
        let meta = RecordingMeta(title: "Sync", started_at: Date(timeIntervalSince1970: 0), device: "mac", client_version: "1")
        let system = [STTResult(segments: [Self.seg(0, 2, "Hi Svenson.", "A"), Self.seg(3, 5, "Hello.", "B")], language: "en")]
        let call = CallEvidence(me: "Jakob W", others: ["Anna Svensson", "Bob Lee"], voiceNames: ["A": "Bob Lee"],
                                corrections: ["svenson": "Svensson"], captionFills: [])
        let out = TranscriptBuilder.build(meta: meta, micResults: [], systemResults: system, call: call)
        #expect(out.markdown.contains("**Bob Lee:**\nHi Svensson."))
        #expect(out.markdown.contains("**Them (B):**\nHello."))
    }

    @Test func aOneToOneOnScreenNamesTheWholeStream() {
        let meta = RecordingMeta(title: "Sync", started_at: Date(timeIntervalSince1970: 0), device: "mac", client_version: "1")
        let system = [STTResult(segments: [Self.seg(0, 2, "Hi there.")], language: "en")]
        let call = CallEvidence(me: "Jakob W", others: ["Anna Svensson"], voiceNames: [:], corrections: [:], captionFills: [])
        let out = TranscriptBuilder.build(meta: meta, micResults: [], systemResults: system, call: call)
        #expect(out.markdown.contains("**Anna Svensson:**\nHi there."))
    }
}
