import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import DrawLexicon
import Foundation
import Mentions
import TestKit
import Titles

// `canvas draw` writing mention text, in DrawLexicon: in a text whose schema says it's mention text,
// `@[Title]` mentions the shape called Title, and the shape keeps the stored form with its id. Over
// fixtures only: a folder, a crate that can't be mentioned, and a dispatch holding every kind of
// mention text (Fixtures.swift).

private let frame = CGRect(x: 0, y: 0, width: 100, height: 80)

/// A shape of any kind, titled, put on the board as a person would (a script can't make two shapes
/// called alike).
@MainActor private func insert<P: ShapeProps>(_ props: P, titled title: String, in editor: CanvasEditor) -> ShapeID {
    var record = AnyShapeRecord(ShapeRecord(props))
    record[TitleProperty.self] = title
    editor.transact { $0.insert(record) }
    return record.id
}

@MainActor let mentionTextsTests = Suite("Mention text in canvas draw", [
    test("@[Title] is a mention of the shape called that: its id in uppercase, the shape's title for the label, the rest of the text as written; the pill is live") {
        let editor = try lexiconEditor()
        _ = try drawn(#"folder "Owner""#, on: editor)
        let owner = try require(editor.shape(called: "Owner")).id
        let result = try drawn(#"dispatch "Plan" below "Owner" body: "Ask @[Owner] first, then @[  Owner ]!  Done.""#, on: editor)
        expectEqual(warnings(result), [])
        let plan = try require(editor.dispatch("Plan"))
        expectEqual(plan.body.stored, "Ask @[Owner](shape:\(owner)) first, then @[Owner](shape:\(owner))!  Done.", "a title is folded as titles are")
        expectEqual(plan.body.mentioned, [owner, owner])
        expectEqual(plan.body.plainText(), "Ask @Owner first, then @Owner!  Done.")
        expect(editor.mentions?.resolve(owner).isLive == true, "the app shows it as a pill")
        expectEqual(editor.mentions?.mentioners(of: owner), [try require(editor.shape(called: "Plan")).id])
        // Text without a name is as it was written, with its words in any script and its brackets.
        _ = try drawn(#"dispatch "Plan" body: "日本語 [1] a@b.c @ [x] and 1 < 2""#, on: editor)
        expectEqual(editor.dispatch("Plan")?.body.stored, "日本語 [1] a@b.c @ [x] and 1 < 2")
    },

    test("a whole mention a script writes is kept as it's written, an id in any case; a literal @[ is written \\\\@[ in a script") {
        let editor = try lexiconEditor()
        _ = try drawn(#"folder "Owner""#, on: editor)
        let owner = try require(editor.shape(called: "Owner")).id
        let lowercase = owner.rawValue.uuidString.lowercased()
        _ = try drawn(#"dispatch "Plan" below "Owner" body: "See @[Owner](shape:\#(lowercase)) and @[Owner], not @[Old name](shape:\#(owner))""#, on: editor)
        expectEqual(editor.dispatch("Plan")?.body.stored,
                    "See @[Owner](shape:\(lowercase)) and @[Owner](shape:\(owner)), not @[Old name](shape:\(owner))")
        // `\\@[` in a script is `\@[` in the text: a literal @[, no mention. Four backslashes are two: one, then a mention.
        _ = try drawn(#"dispatch "Plan" body: "Write \\@[Owner] as text""#, on: editor)
        expectEqual(editor.dispatch("Plan")?.body.stored, #"Write \@[Owner] as text"#)
        expectEqual(editor.dispatch("Plan")?.body.runs, [.text("Write @[Owner] as text")])
        _ = try drawn(#"dispatch "Plan" body: "C:\\\\@[Owner]""#, on: editor)
        expectEqual(editor.dispatch("Plan")?.body.stored, #"C:\\@[Owner](shape:\#(owner))"#)
        expectEqual(editor.dispatch("Plan")?.body.runs, [.text("C:\\"), .mention(owner, label: "Owner")])
    },

    test("text that looks like a mention and isn't stays text, and the run warns, as the app does; a name that doesn't close on its line is text") {
        let editor = try lexiconEditor()
        _ = try drawn(#"folder "Owner""#, on: editor)
        let lookalike = "@[x](shape: 7C1E0B8A-2F4D-4A6B-9C3E-5D2F1A0B9C8D)"
        let result = try drawn(#"dispatch "Plan" below "Owner" body: "see \#(lookalike) too""#, on: editor)
        expectEqual(editor.dispatch("Plan")?.body.stored, "see \(lookalike) too")
        expectEqual(editor.dispatch("Plan")?.body.mentioned, [])
        expect(warnings(result).first?.contains("isn’t a mention.") == true, "\(warnings(result))")
        // An unclosed name, one broken by a line break, and one with a backslash that escapes nothing.
        for text in ["see @[Owner", "see @[Owner\\nand more", #"see @[C:\\temp]"#] {
            let result = try drawn(#"dispatch "Plan" body: "\#(text)""#, on: editor)
            expectEqual(editor.dispatch("Plan")?.body.mentioned, [], text)
            expectEqual(dids(result).count, 1, text)
        }
        expectEqual(editor.dispatch("Plan")?.body.stored, #"see @[C:\temp]"#)
    },

    test("a title with a ] in it is escaped as a label is, in the text and in what's kept") {
        let editor = try lexiconEditor()
        _ = try drawn(#"folder "a]b\\c""#, on: editor)
        let folder = try require(editor.shape(called: "a]b\\c")).id
        _ = try drawn(#"dispatch "Plan" below "a]b\\c" body: "see @[a\\]b\\\\c]""#, on: editor)
        expectEqual(editor.dispatch("Plan")?.body.stored, #"see @[a\]b\\c](shape:\#(folder))"#)
        expectEqual(editor.dispatch("Plan")?.body.runs, [.text("see "), .mention(folder, label: "a]b\\c")])
    },

    test("@[] is refused: a mention with no title in it, with how to write the characters as text") {
        let editor = try lexiconEditor()
        for text in ["see @[] here", "see @[   ] here"] {
            let blank = try refused(#"dispatch "Plan" body: "\#(text)""#, on: editor)
            expectEqual(blank.reason, "invalid_value")
            expectEqual(blank.message, #""Plan": body: @[] is a mention with no title in it"#)
            expectEqual(blank.hint, #"write the title of the shape between the brackets, as @[Owner]; to write @[ as text, write \\@["#)
            expectEqual(blank.data?["line"], 1)
        }
        expectEqual(editor.document.shapes.count, 0, "nothing drawn")
    },

    test("a title nobody has is unknown, with the ones like it among what the text may mention and how to write @[ as text") {
        let editor = try lexiconEditor()
        _ = try drawn(#"folder "Owner""#, on: editor)
        _ = insert(Crate(frame), titled: "Owned", in: editor)
        let typo = try refused(#"dispatch "Plan" body: "ask @[Ownr]""#, on: editor)
        expectEqual(typo.reason, "unknown_title")
        expectEqual(typo.message, #""Plan": body: there's no shape called "Ownr""#)
        expectEqual(typo.hint, #"did you mean "Owner"? to write @[ as text, write \\@["#, "a crate can't be mentioned, so it's no guess")
        let nothing = try refused(#"dispatch "Plan" body: "ask @[Zzzz]""#, on: editor)
        expectEqual(nothing.hint, #"a title is one the file has as the script starts, or one the script draws; to write @[ as text, write \\@["#)
        expectEqual(typo.data?["statement"], #"dispatch "Plan" body: "ask @[Ownr]""#)
    },

    test("what a text may mention is asked of each shape called that: its scope, and whether its kind can be mentioned at all") {
        let editor = try lexiconEditor()
        let folder = insert(Folder(frame), titled: "Row", in: editor)
        _ = insert(Dispatch(CGRect(x: 300, y: 0, width: 160, height: 100)), titled: "Row", in: editor)
        // Any shape: both are called Row, so it's ambiguous. Only folders, there's one.
        let ambiguous = try refused(#"dispatch "Plan" body: "@[Row]""#, on: editor)
        expectEqual(ambiguous.reason, "ambiguous_title")
        expect(ambiguous.hint?.contains("@[") == false, "two shapes have the title: it was meant as a mention, so the hint says to rename one, not how to write the characters")
        _ = try drawn(#"dispatch "Plan" to: "@[Row]""#, on: editor)
        expectEqual(editor.dispatch("Plan")?.to.stored, "@[Row](shape:\(folder))")
        // A name only a dispatch has, in text that mentions only folders.
        _ = insert(Dispatch(CGRect(x: 600, y: 0, width: 160, height: 100)), titled: "Letter", in: editor)
        let out = try refused(#"dispatch "Plan" to: "@[Letter]""#, on: editor)
        expectEqual(out.reason, "invalid_value")
        expectEqual(out.message, #""Plan": to: "Letter" is a dispatch, which this text can't mention: it mentions only folder shapes"#)
        expectEqual(out.hint, nil, "it was meant as a mention, so the way to write the characters isn't the hint")
        // A kind that can't be mentioned, in text that mentions anything.
        _ = insert(Crate(CGRect(x: 900, y: 0, width: 100, height: 100)), titled: "Cargo", in: editor)
        let crate = try refused(#"dispatch "Plan" body: "@[Cargo]""#, on: editor)
        expectEqual(crate.reason, "invalid_value")
        expectEqual(crate.message, #""Plan": body: "Cargo" is a crate, which can't be mentioned"#)
        expectEqual(crate.hint, nil)
        // A scope a plugin declares: what joined it, the folders.
        _ = try drawn(#"dispatch "Plan" tags: "@[Row]""#, on: editor)
        expectEqual(editor.dispatch("Plan")?.tags.stored, "@[Row](shape:\(folder))")
        let notJoined = try refused(#"dispatch "Plan" tags: "@[Letter] and @[Cargo]""#, on: editor)
        expectEqual(notJoined.message, #""Plan": tags: "Letter" is a dispatch, which this text can't mention: it mentions only folder shapes"#)
    },

    test("a text inside a list of objects is written, by its own schema; a shape drawn further down is named too, and the shape itself") {
        let editor = try lexiconEditor()
        _ = try drawn(#"folder "Owner""#, on: editor)
        let owner = try require(editor.shape(called: "Owner")).id
        _ = try drawn(#"""
        dispatch "Plan" below "Owner" steps: [{"text": "ask @[Owner]"}, {"text": "plain, 1 < 2"}, {"text": "after @[Later], by @[Plan]"}]
        folder "Later" right of "Plan"
        """#, on: editor)
        let later = try require(editor.shape(called: "Later")).id
        let plan = try require(editor.shape(called: "Plan")).id
        expectEqual(editor.dispatch("Plan")?.steps.map(\.text.stored),
                    ["ask @[Owner](shape:\(owner))", "plain, 1 < 2", "after @[Later](shape:\(later)), by @[Plan](shape:\(plan))"])
        let nested = try refused(#"dispatch "Plan" steps: [{"text": "ask @[Nobody]"}]"#, on: editor)
        expectEqual(nested.reason, "unknown_title")
        expectEqual(nested.message, #""Plan": steps: there's no shape called "Nobody""#)
    },

    test("kinds says what a mention text takes, and a refusal's hint does too") {
        let editor = try lexiconEditor()
        let dispatch = try require(run(["kinds", "dispatch"], on: nil, registry: editor.registry).get().arrayValue?.first)
        for key in ["body", "to", "tags"] { expectEqual(dispatch["attributes"]?[key], "text (@[Title] mentions)", key) }
        expectEqual(dispatch["attributes"]?["steps"], "JSON [{text}]")
        let json = try refused(#"dispatch "Plan" body: [1]"#, on: editor)
        expectEqual(json.reason, "invalid_value")
        expectEqual(json.hint, "body: takes text (@[Title] mentions)")
        // Without the plugin, a mention text is a plain string as far as draw knows.
        let plain = try lexiconEditor(mentionTexts: false)
        expectEqual(try run(["kinds", "dispatch"], on: nil, registry: plain.registry).get().arrayValue?.first?["attributes"]?["body"], "text")
        _ = try drawn(#"dispatch "Plan" body: "Ask @[Owner] and @[]""#, on: plain)
        expectEqual(plain.dispatch("Plan")?.body.stored, "Ask @[Owner] and @[]", "kept as written")
    },

    test("a script run twice says unchanged the second time; a dry run resolves the same and changes nothing") {
        let editor = try lexiconEditor()
        let script = #"""
        dispatch "Plan" body: "Ask @[Owner] before @[Later]"
        folder "Owner" right of "Plan"
        folder "Later" below "Plan"
        """#
        expectEqual(dids(try drawn(script, on: editor, dryRun: true)), ["created", "created", "created"])
        expectEqual(editor.document.shapes.count, 0)
        expect(!editor.canUndo)
        _ = try drawn(script, on: editor)
        expectEqual(editor.document.shapes.count, 3)
        let before = editor.document
        expectEqual(dids(try drawn(script, on: editor)), ["unchanged", "unchanged", "unchanged"])
        expectEqual(editor.document, before)
        expectEqual(dids(try drawn(script, on: editor, dryRun: true)), ["unchanged", "unchanged", "unchanged"])
        // The refusals a dry run gives are a real run's.
        let bad = #"dispatch "Plan" body: "Ask @[Nobody]""#
        expectEqual(try refused(bad, on: editor).message, #""Plan": body: there's no shape called "Nobody""#)
        expectEqual(editor.document, before)
        // One undo step takes the whole run back.
        let again = try lexiconEditor()
        _ = try drawn(script, on: again)
        again.undo()
        expectEqual(again.document.shapes.count, 0)
    },

    test("the registry report says what the plugin writes") {
        let report = try lexiconEditor().registry.report.split(separator: "\n")
        expect(report.contains { $0.hasPrefix("mention-texts ") && $0.hasSuffix(" draw text \(MentionTextFormat.mediaType)") }, report.joined(separator: "\n"))
    },
])
