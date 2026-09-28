@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Keyboard
import MentionValidation
import Mentions
import Selection
import TestKit
import Validation

private let frame = CGRect(x: 0, y: 0, width: 100, height: 80)
private let a = idA.rawValue.uuidString

@MainActor let mentionValidationTests = Suite("Mention validation", [
    test("a mention of a shape that can't be mentioned warns about the text's property, named as the mention holds it, else by its kind") {
        let h = try validationHarness()
        let blob = h.add(Blob(frame)), nameless = h.add(Blob(frame)), box = h.add(Box(frame))
        let card = h.editor.add(Card(frame), titled: "Groceries")
        let letter = h.add(Letter(body: MentionText([.text("See "), .mention(blob, label: "Blobby"), .text(", "), .mention(blob, label: "again"),
                                                      .text(", "), .mention(nameless, label: " "), .text(", "), .mention(box, label: ""),
                                                      .text(" and "), .mention(card, label: "Groceries")])))
        expectEqual(h.editor.issues(of: letter), ["body: “Blobby” can’t be mentioned.", "body: “Blob” can’t be mentioned.",
                                                  "body: “box” can’t be mentioned."],
                    "each target once, by the name the first mention of it holds; a blank name is none, and a kind without a tool is its id")
        expectEqual(h.editor.validation?.results[letter]?.worst, .warning, "warnings: a mention that's there stays")
        expectEqual(h.editor.issues(of: card), [], "the mentioned shapes have no issue of their own")
        expectEqual(h.editor.issues(of: blob), [])
    },
    test("a mention of a shape that isn't there, or is kept aside, isn't a problem") {
        let h = try validationHarness()
        let letter = h.add(Letter(body: MentionText([.mention(idA, label: "Gone"), .text(" and "), .mention(idB, label: "Newer")])))
        expectEqual(h.editor.issues(of: letter), [], "a missing shape's pill says so")
        // A blob from a newer version of its kind, which this app keeps aside.
        let aside = try keptAside(Blob.kind, id: idB, in: h.editor.registry)
        h.editor.replaceDocument(with: CanvasDocument(shapes: h.editor.document.shapes + [aside]))
        expect(h.editor.document[idB]?.isOpaque == true)
        expectEqual(h.editor.issues(of: letter), [], "a shape kept aside isn't the app's to judge")
        // And one that comes later warns: the check looked it up.
        h.add(Blob(frame), id: idA)
        expectEqual(h.editor.issues(of: letter), ["body: “Gone” can’t be mentioned."])
    },
    test("deleting a target that can't be mentioned takes its warning away, and undo brings it back") {
        let h = try validationHarness()
        let blob = h.add(Blob(frame))
        let letter = h.add(Letter(body: MentionText([.text("See "), .mention(blob, label: "Blobby")])))
        let warned = ["body: “Blobby” can’t be mentioned."]
        expectEqual(h.editor.issues(of: letter), warned)
        h.editor.transact { $0.delete([blob]) }
        expectEqual(h.editor.issues(of: letter), [])
        h.editor.undo()
        expectEqual(h.editor.issues(of: letter), warned)
        h.editor.redo()
        expectEqual(h.editor.issues(of: letter), [])
        h.editor.undo()
        // Moving the target, or the letter, changes nothing it found: the rule ignores moves.
        h.editor.transact { $0.translate([blob, letter], by: CGPoint(x: 10, y: 0)) }
        expectEqual(h.editor.issues(of: letter), warned)
    },
    test("a move checks no text: dragging a target, or its mentioner, runs the rule for neither; a rename of a target checks its mentioner again") {
        let h = try validationHarness()
        let blob = h.add(Blob(CGRect(x: 0, y: 0, width: 100, height: 80)))
        let card = h.editor.add(Card(CGRect(x: 0, y: 200, width: 100, height: 80)), titled: "Alice")
        let letter = h.add(Letter(CGRect(x: 300, y: 0, width: 100, height: 80),
                                  body: MentionText([.mention(blob, label: "Blobby"), .text(" for "), .mention(card, label: "Alice")])))
        let warned = ["body: “Blobby” can’t be mentioned."]
        expectEqual(h.editor.issues(of: letter), warned)
        let checked = MentionValidationPlugin.textsChecked
        // Dragged as a person drags, an event at a time, then moved by `translate`.
        for (id, start) in [(blob, CGPoint(x: 50, y: 40)), (letter, CGPoint(x: 350, y: 40)), (card, CGPoint(x: 50, y: 240))] {
            h.press(at: start)
            h.drag(to: CGPoint(x: start.x + 20, y: start.y + 10))
            h.drag(to: CGPoint(x: start.x + 40, y: start.y + 20))
            expectEqual(h.editor.issues(of: letter), warned)
            h.release()
            expectEqual(h.editor.shapeContext.bounds(of: [id])?.minX, start.x - 50 + 40, "it moved")
        }
        h.editor.transact { $0.translate([blob, card, letter], by: CGPoint(x: 10, y: 0)) }
        expectEqual(h.editor.issues(of: letter), warned)
        expectEqual(MentionValidationPlugin.textsChecked, checked, "no text checked again for a move")
        h.editor.rename(card, "Alicia")
        expectEqual(h.editor.issues(of: letter), warned)
        expectEqual(MentionValidationPlugin.textsChecked, checked + 1, "the letter looked the card up: checked once more")
    },
    test("a mention outside its text's scope warns, named as its shape is called now; only scoped text has a scope to leave") {
        let h = try validationHarness()
        let card = h.editor.add(Card(frame), titled: "Alice")
        let sheet = h.editor.add(Sheet(frame), titled: "Minutes")
        let both: [MentionRun] = [.mention(sheet, label: "Old name"), .text(" for "), .mention(card, label: "Alice")]
        let letter = h.add(Letter(body: MentionText(both), to: ScopedMentionText(both)))
        expectEqual(h.editor.issues(of: letter), ["to: “Minutes” can’t be mentioned here."], "the body may mention any mentionable shape")
        h.editor.rename(sheet, "Agenda")
        expectEqual(h.editor.issues(of: letter), ["to: “Agenda” can’t be mentioned here."], "the check looked the sheet up")
        // One that can't be mentioned at all says so, in either text.
        let blob = h.add(Blob(frame))
        h.editor.transact { $0.update(letter, as: Letter.self) { $0.props.to = ScopedMentionText([.mention(blob, label: "Blobby")]) } }
        expectEqual(h.editor.issues(of: letter), ["to: “Blobby” can’t be mentioned."])
    },
    test("text that looks like a mention but isn't one warns, quoted to 30 characters; a mention with a lowercase id, an escaped @[ and an @[ alone don't") {
        let h = try validationHarness()
        let body = MentionText(stored: "Ask @[x](shape: \(a)) and @[y](shape:1234), then @[a]b](shape:\(a)).\n"
            + "Fine: \\@[z](shape: \(a)), @[w], @[v](shape:\(a.lowercased())).")
        expectEqual(body.mentioned, [idA], "the lowercase id is a mention")
        let letter = h.add(Letter(body: body))
        expectEqual(h.editor.issues(of: letter), ["body: “@[x](shape: 7C1E0B8A-2F4D-4A6B…” isn’t a mention.",
                                                  "body: “@[y](shape:1234)” isn’t a mention.",
                                                  "body: “@[a]b](shape:7C1E0B8A-2F4D-4A6…” isn’t a mention."])
        h.editor.transact { $0.update(letter, as: Letter.self) { $0.props.body = MentionText(plain: body.plainText()) } }
        expectEqual(h.editor.issues(of: letter), [], "written as plain text, every @[ is escaped")
    },
    test("look-alikes: what each is, as written") {
        func lookalikes(_ stored: String) -> [String] { MentionText(stored: stored).lookalikes }
        expectEqual(lookalikes("@[x](shape: \(a))"), ["@[x](shape: \(a))"])
        expectEqual(lookalikes("@[x](SHAPE:\(a))"), ["@[x](SHAPE:\(a))"], "(shape in any case")
        expectEqual(lookalikes("@[x](shape: oops   \nnext (shape)"), ["@[x](shape: oops"], "to the line's end, without its spaces")
        expectEqual(lookalikes("@[a @[b](shape: 1)"), ["@[b](shape: 1)"], "the @[ nearest the (shape")
        expectEqual(lookalikes("@[x](shape: @[y](shape:1))"), ["@[x](shape:", "@[y](shape:1)"], "each stops short of the next @[")
        expectEqual(lookalikes("@[x](shape: @[y](shape:\(a))"), ["@[x](shape:"], "so none holds a mention")
        expectEqual(lookalikes("\\\\@[x](shape:1)"), ["@[x](shape:1)"], "two backslashes are one, so the @[ isn't escaped")
        expectEqual(lookalikes("\\@[x](shape:1)"), [], "an escaped @[ is text")
        expectEqual(lookalikes("@[x] and\n(shape: 1)"), [], "(shape on another line")
        expectEqual(lookalikes("@[w], @[v](shape:\(a))"), [], "an @[ alone, before a mention")
        expectEqual(lookalikes("@[x](shape:\(a)) and more"), [], "a mention")
        expectEqual(lookalikes("no mentions at all"), [])
        expectEqual(MentionText(plain: "@[x](shape: 1)").lookalikes, [], "plain text escapes what would read as one")
        expectEqual(ScopedMentionText<Only<Card>>(stored: "@[x](shape:1)").lookalikes, ["@[x](shape:1)"], "any scope's")
    },
    test("text made from runs never has a look-alike: 20,000 fuzzed run lists, written and read back") {
        let pieces = ["@[", "@", "[", "]", "(shape:", "(Shape", "(shape", ")", "\\", "a", " ", "\n", a, "é"]
        var rng = SplitMix(seed: 0x6C6F_6F6B_616C_696B)
        var failures = 0
        for _ in 0..<20_000 {
            var runs: [MentionRun] = []
            for _ in 0..<Int.random(in: 1...5, using: &rng) {
                let piece = (0..<Int.random(in: 0...8, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
                runs.append(Bool.random(using: &rng) ? .text(piece) : .mention(Bool.random(using: &rng) ? idA : idB, label: piece))
            }
            let written = MentionText(runs)
            let read = MentionText(stored: written.stored)
            if !written.lookalikes.isEmpty || !read.lookalikes.isEmpty {
                failures += 1
                if failures < 4 { expect(false, "\(written.stored.debugDescription) has look-alikes \(read.lookalikes)") }
            }
        }
        expectEqual(failures, 0)
    },
    test("fuzzed strings: every look-alike starts at an @[ that starts no mention, has (shape after it, and is on one line") {
        let pieces = ["@[", "\\@[", "\\\\@[", "x", "]", "](shape:", "(shape: ", ")", a, "\n", " "]
        var rng = SplitMix(seed: 0x7374_7261_7973)
        for _ in 0..<5_000 {
            let stored = (0..<Int.random(in: 1...12, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            for lookalike in MentionText(stored: stored).lookalikes {
                expect(lookalike.hasPrefix("@["), lookalike)
                expect(lookalike.lowercased().contains("(shape"), lookalike)
                expect(!lookalike.contains("\n"), lookalike)
                expect(MentionText(stored: lookalike).mentioned.isEmpty, "\(lookalike) is a mention")
                expect(stored.contains(lookalike), "\(lookalike) isn't in \(stored.debugDescription)")
            }
        }
    },
    test("a locked mentioner is checked as any other") {
        let h = try validationHarness()
        let blob = h.add(Blob(frame))
        let letter = h.add(Letter(body: MentionText([.mention(blob, label: "Blobby")])))
        h.editor.freeze([letter])
        expect(h.editor.isReadOnly(letter))
        expectEqual(h.editor.issues(of: letter), ["body: “Blobby” can’t be mentioned."])
        h.editor.transact { $0.delete([blob]) }
        expectEqual(h.editor.issues(of: letter), [], "a change to its target checks it again")
    },
    test("mention text in an added property warns about that property") {
        let h = try validationHarness()
        let blob = h.add(Blob(frame))
        var record = ShapeRecord(Letter())
        record[Postscript.self] = MentionText(stored: "PS: @[Blobby](shape:\(blob.rawValue.uuidString)) @[x](shape:1)")
        h.editor.transact { $0.insert(record) }
        expectEqual(h.editor.issues(of: record.id), ["postscript: “Blobby” can’t be mentioned.", "postscript: “@[x](shape:1)” isn’t a mention."])
    },
    test("it checks the board shown: a target on another board is looked up there no more than a missing one") {
        let blob = ShapeRecord(Blob(frame)), pocket = ShapeRecord(Pocket(frame))
        let outer = ShapeRecord(Letter(body: MentionText([.mention(blob.id, label: "Blobby")])))
        let inner = ShapeRecord(Letter(body: MentionText([.mention(blob.id, label: "Blobby")])))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket), AnyShapeRecord(outer)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(blob), AnyShapeRecord(inner)])])
        let h = try EditorHarness(plugins: validationPlugins(), file: file)
        expectEqual(h.editor.issues(of: outer.id), [])
        expect(h.enter(pocket.id))
        expectEqual(h.editor.issues(of: inner.id), ["body: “Blobby” can’t be mentioned."])
    },
    test("mentionProblems: none for a kind that can't hold names or a shape kept aside, and each text looks each target up once") {
        let h = try validationHarness()
        let registry = h.editor.registry
        let blob = h.add(Blob(frame))
        var asked: [ShapeID] = []
        let lookup = { (id: ShapeID) -> AnyShapeRecord? in
            asked.append(id)
            return h.editor.document[id]
        }
        expectEqual(registry.mentionProblems(of: try require(h.editor.document[blob]), lookup: lookup), [])
        expectEqual(asked, [], "a blob holds no names")
        let twice: [MentionRun] = [.mention(blob, label: "Blobby"), .text(" "), .mention(blob, label: "Blobby")]
        let letter = h.add(Letter(body: MentionText(twice), to: ScopedMentionText(twice)))
        expectEqual(registry.mentionProblems(of: try require(h.editor.document[letter]), lookup: lookup),
                    [MentionProblem(property: "body", message: "“Blobby” can’t be mentioned."),
                     MentionProblem(property: "to", message: "“Blobby” can’t be mentioned.")])
        expectEqual(asked, [blob, blob], "once per text")
        let aside = try keptAside(Letter.kind, id: idA, in: registry)
        expectEqual(registry.mentionProblems(of: aside, lookup: lookup), [])
    },
    test("the bridge needs Validation, whose rules it adds to") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ValidationRules", owner: .validation, contributor: "mention-validation")) {
            _ = try Registry(plugins: validationPlugins().filter { $0.id != .validation })
        }
    },
])
