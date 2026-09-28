import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Keyboard
import Mentions
import Observation
import Selection
import TableOfContents
import TestKit
import Titles
import Topology

// MentionState: the index both ways, resolutions, observers, rows, following and hovering.

private let frame = CGRect(x: 0, y: 0, width: 200, height: 200)

/// Whether an observation's change was heard.
final class Flag: @unchecked Sendable {
    var fired = false
}

/// Asks Mentions which rows a commit affects as it hears the commit, as the table of contents does,
/// from a service made before Mentions', so it hears first.
@MainActor
final class AffectedProbe {
    var heard: [Set<ShapeID>] = []
    var changes: [ChangeSet] = []
}

extension AffectedProbe: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        self.changes.append(changes)
        heard.append(editor.mentions?.rowsAffected(by: changes) ?? [])
    }
}

/// A board of two plates and a token, and a jot that mentions the first plate twice and the token.
@MainActor
private struct Board {
    let h: EditorHarness
    let groceries: ShapeID, errands: ShapeID, milk: ShapeID, jot: ShapeID
    var editor: CanvasEditor { h.editor }
    var state: MentionState { h.editor.mentionState }

    init(_ plugins: [any CanvasPlugin] = mentionPlugins()) throws {
        h = try EditorHarness(plugins: plugins)
        groceries = h.editor.add(Plate(CGRect(x: 400, y: 0, width: 120, height: 80)), titled: "Groceries")
        errands = h.editor.add(Plate(CGRect(x: 400, y: 200, width: 120, height: 80)), titled: "Errands")
        milk = h.add(Token(CGRect(x: 600, y: 0, width: 60, height: 60), caption: "Milk"))
        jot = h.add(Jot(frame, text: MentionText([.text("Ask "), .mention(groceries, label: "Groceries"), .text(" and "),
                                                  .mention(milk, label: "Milk"), .text(", "), .mention(groceries, label: "Groceries")])))
    }
}

/// A part of an outline: mention text in a struct, which a kind keeps in a list.
private struct Section: SchemaDefined, Hashable {
    static let properties = Properties<Section>(definition: "section") {
        Property("text", \.text)
    }
    var text: MentionText = ""
    init() {}
    init(_ text: MentionText) { self.text = text }
}

extension Section: ShapeNaming {}

/// A box that keeps mention text below the top of its props: in sections, a list of structs, and
/// in notes, a dictionary.
private struct Outline: BoxShapeProps {
    static let kind: ShapeKind = "outline"
    static let properties = Properties<Outline> {
        Property("frame", \.frame).required()
        Property("sections", \.sections)
        Property("notes", \.notes)
    }
    var frame: CGRect = .zero
    var sections: [Section] = []
    var notes: [String: MentionText] = [:]
    init() {}
}

private struct OutlineDefinition {}

extension OutlineDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Outline>, in context: RenderContext) {}
}

@MainActor let stateTests = Suite("Mention state", [
    test("the index: what each shape mentions, in text order, once each; and who mentions each shape, in document order") {
        let b = try Board()
        expectEqual(b.state.mentions(in: b.jot), [b.groceries, b.milk])
        expectEqual(b.state.mentioners(of: b.groceries), [b.jot])
        expectEqual(b.state.mentioners(of: b.errands), [])
        let second = b.h.add(Jot(frame, text: MentionText([.mention(b.errands, label: "E"), .mention(b.groceries, label: "G")])))
        expectEqual(b.state.mentioners(of: b.groceries), [b.jot, second])
        expectEqual(b.state.mentions(in: second), [b.errands, b.groceries])
        b.editor.setText(b.jot, MentionText([.mention(b.errands, label: "E")]))
        expectEqual(b.state.mentions(in: b.jot), [b.errands])
        expectEqual(b.state.mentioners(of: b.groceries), [second])
        expectEqual(b.state.mentioners(of: b.errands), [b.jot, second])
        b.editor.delete(second)
        expectEqual(b.state.mentioners(of: b.groceries), [])
        expectEqual(b.state.mentions(in: second), [])
    },

    test("mention text below the top of a shape's props is indexed too: in a struct in a list, and in a dictionary") {
        let probe = AffectedProbe()
        var plugins = mentionPlugins([Contributor(id: "outlines") { $0.shape(OutlineDefinition()) }])
        plugins.insert(Contributor(id: "probe") { $0.service { _ in probe } }, at: plugins.count - 2)
        let b = try Board(plugins)
        var outline = Outline()
        outline.frame = frame
        outline.sections = [Section(MentionText([.text("See "), .mention(b.errands, label: "Errands")])),
                            Section(MentionText([.mention(b.groceries, label: "Groceries")]))]
        outline.notes = ["milk": MentionText([.mention(b.milk, label: "Milk")])]
        let id = b.h.add(outline)
        expectEqual(b.state.mentions(in: id), [b.errands, b.groceries, b.milk])
        expectEqual(b.state.mentioners(of: b.errands), [id])
        expectEqual(b.state.mentioners(of: b.milk), [b.jot, id])
        b.editor.rename(b.errands, "Chores")
        expectEqual(probe.heard.last, [id], "a rename names the outline's row")
        b.editor.transact { $0.update(id, as: Outline.self) { $0.props.sections.removeFirst() } }
        expectEqual(b.state.mentioners(of: b.errands), [])
        expectEqual(b.state.mentions(in: id), [b.groceries, b.milk])
    },

    test("built as a board opens: in init for an editor made with a document, and through replaceDocument's commit") {
        let b = try Board()
        let document = b.editor.document
        let registry = b.editor.registry
        let made = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
        let state = try require(made.mentions)
        expectEqual(state.mentions(in: b.jot), [b.groceries, b.milk])
        expectEqual(state.mentioners(of: b.milk), [b.jot])
        expectEqual(state.candidates(matching: "errands", in: AnyMentionable.self, for: nil).matches.first?.id, b.errands)
        let opened = CanvasEditor(registry: registry, scheduler: ManualScheduler())
        let other = try require(opened.mentions)
        expectEqual(other.mentioners(of: b.groceries), [])
        #if DEBUG
        let entries = other.entriesRead
        opened.replaceDocument(with: document)
        expectEqual(other.entriesRead - entries, 4, "the catalog is read as the board opens, not at the first @")
        #else
        opened.replaceDocument(with: document)
        #endif
        expectEqual(other.mentioners(of: b.groceries), [b.jot])
        expectEqual(other.resolve(b.groceries).appearance?.label, "Groceries")
        // A board opened again over edits: nothing to undo, and the state reads the board as opened.
        opened.transact { $0.update(b.groceries) { $0[TitleProperty.self] = "Food" } }
        opened.transact { $0.delete([b.jot]) }
        opened.replaceDocument(with: document)
        expect(!opened.canUndo, "opening a board clears what there was to undo")
        expectEqual(other.mentioners(of: b.groceries), [b.jot])
        expectEqual(other.resolve(b.groceries).appearance?.label, "Groceries")
    },

    test("only kinds that can hold names are read, and a commit reads only the shapes it changed, but not those it only moved") {
        let b = try Board()
        #if DEBUG
        let topology = try require(b.editor.topology)
        let read = topology.recordsRead
        b.editor.rename(b.groceries, "Food")
        expectEqual(topology.recordsRead, read, "a plate holds no names")
        b.editor.setText(b.jot, MentionText([.mention(b.milk, label: "Milk")]))
        expectEqual(topology.recordsRead, read + 1)
        b.editor.transact { $0.translate([b.jot, b.groceries, b.milk], by: CGPoint(x: 10, y: 10)) }
        expectEqual(topology.recordsRead, read + 1, "a drag reads nothing")
        #endif
    },

    test("resolve: live with the target's appearance, missing once it's deleted, live again once that's undone, missing again redone") {
        let b = try Board()
        expectEqual(b.state.resolve(b.groceries).appearance?.label, "Groceries")
        b.editor.delete(b.groceries)
        expectEqual(b.state.resolve(b.groceries), .missing)
        expectEqual(b.state.mentioners(of: b.groceries), [b.jot], "a deleted target keeps its mentioners")
        b.editor.undo()
        expectEqual(b.state.resolve(b.groceries).appearance?.label, "Groceries")
        b.editor.redo()
        expectEqual(b.state.resolve(b.groceries), .missing)
        b.editor.undo()
        expectEqual(b.state.resolve(b.groceries).appearance?.label, "Groceries")
        let box = b.h.add(Box(frame))
        expectEqual(b.state.resolve(box), .unavailable)
    },

    test("the plain form: live names where the target is, the name held where it isn't") {
        let b = try Board()
        let text = try require(b.editor.document[b.jot]?.typed(as: Jot.self)).props.text
        b.editor.rename(b.groceries, "Food")
        expectEqual(b.state.plainText(text), "Ask @Food and @Milk, @Food")
        b.editor.delete(b.milk)
        expectEqual(b.state.plainText(text), "Ask @Food and @Milk, @Food")
        b.editor.transact { $0.update(b.groceries) { $0[TitleProperty.self] = nil } }
        expectEqual(b.state.plainText(text), "Ask @Untitled Plate and @Milk, @Untitled Plate")
    },

    test("observers hear only their targets' changes, once per commit, and nothing after they're cancelled or let go of") {
        let b = try Board()
        var heard: [Set<ShapeID>] = []
        var observation: MentionObservation? = b.state.observe([b.groceries, b.errands]) { heard.append($0) }
        b.editor.rename(b.milk, "ignored")
        b.editor.transact { $0.update(b.milk, as: Token.self) { $0.props.caption = "Oat milk" } }
        expectEqual(heard, [])
        b.editor.rename(b.groceries, "Food")
        expectEqual(heard, [[b.groceries]])
        b.editor.transact { transaction in
            transaction.update(b.groceries) { $0[TitleProperty.self] = "Supplies" }
            transaction.update(b.errands) { $0[TitleProperty.self] = "Chores" }
        }
        expectEqual(heard.last, [b.groceries, b.errands])
        b.editor.rename(b.groceries, "Supplies")
        expectEqual(heard.count, 2, "no change, no call")
        b.editor.delete(b.errands)
        expectEqual(heard.last, [b.errands])
        observation?.cancel()
        b.editor.rename(b.groceries, "Stores")
        expectEqual(heard.count, 3)
        // Let go of without being cancelled: never called again.
        var late = 0
        observation = b.state.observe([b.groceries]) { _ in late += 1 }
        b.editor.rename(b.groceries, "Shops")
        expectEqual(late, 1)
        observation = nil
        b.editor.rename(b.groceries, "Market")
        expectEqual(late, 1)
        _ = observation
        // Let go of, it keeps nothing its closure holds.
        weak var held: Flag?
        do {
            let flag = Flag()
            held = flag
            var kept: MentionObservation? = b.state.observe([b.groceries]) { _ in flag.fired = true }
            expect(kept != nil)
            kept = nil
        }
        expect(held == nil)
    },

    test("an observed target nobody mentions is resolved too, so its changes are heard") {
        let b = try Board()
        var heard: [Set<ShapeID>] = []
        let observation = b.state.observe([b.errands]) { heard.append($0) }
        b.editor.rename(b.errands, "Chores")
        expectEqual(heard, [[b.errands]])
        observation.cancel()
    },

    test("labelRevision is observed a target at a time") {
        let b = try Board()
        let flag = Flag()
        withObservationTracking { _ = b.state.labelRevision(of: b.groceries) } onChange: { flag.fired = true }
        b.editor.rename(b.errands, "Chores")
        expect(!flag.fired, "another target's change")
        b.editor.transact { $0.translate([b.groceries], by: CGPoint(x: 5, y: 5)) }
        expect(!flag.fired, "a drag changes no name")
        let before = b.state.labelRevision(of: b.groceries)
        b.editor.rename(b.groceries, "Food")
        expect(flag.fired)
        expectEqual(b.state.labelRevision(of: b.groceries), before + 1)
    },

    test("isMentioned: by another shape; a shape's mention of itself doesn't count, and a deleted shape is still mentioned") {
        let b = try Board()
        expect(b.state.isMentioned(b.groceries))
        expect(b.state.isMentioned(b.milk))
        expect(!b.state.isMentioned(b.errands))
        expect(!b.state.isMentioned(b.jot))
        b.editor.setText(b.jot, MentionText([.text("Me: "), .mention(b.jot, label: "Me"), .text(" and "), .mention(b.errands, label: "Errands")]))
        expect(!b.state.isMentioned(b.jot), "its own mention")
        expect(b.state.isMentioned(b.errands))
        expect(!b.state.isMentioned(b.groceries), "no longer")
        let second = b.h.add(Jot(frame, text: MentionText([.mention(b.jot, label: "Me")])))
        expect(b.state.isMentioned(b.jot), "another shape's mention")
        b.editor.delete(b.errands)
        expect(b.state.isMentioned(b.errands), "its mentioners still mention it")
        b.editor.delete(second)
        expect(!b.state.isMentioned(b.jot))
        b.editor.undo()
        expect(b.state.isMentioned(b.jot))
    },

    test("backlinkRevision changes with what mentions a target: a mentioner added, changed or removed, and a name its quote shows; not a drag, another target's mentioner, nor a shape's own mention of itself") {
        let b = try Board()
        @MainActor func revision(_ id: ShapeID) -> Int { b.state.backlinkRevision(of: id) }
        let groceries = revision(b.groceries), errands = revision(b.errands), milk = revision(b.milk)
        b.editor.transact { $0.translate([b.jot, b.groceries, b.milk], by: CGPoint(x: 10, y: 10)) }
        expectEqual([revision(b.groceries), revision(b.milk)], [groceries, milk], "a drag changes no text")
        b.editor.rename(b.errands, "Chores")
        expectEqual(revision(b.groceries), groceries, "a name no quote shows")

        let second = b.h.add(Jot(frame, text: MentionText([.mention(b.errands, label: "Chores")])))
        expectEqual(revision(b.errands), errands + 1, "a mentioner came")
        expectEqual(revision(b.groceries), groceries, "another target's")
        b.editor.setText(second, MentionText([.text("Then "), .mention(b.errands, label: "Chores")]))
        expectEqual(revision(b.errands), errands + 2, "its text changed, and with it its quote")
        let own = revision(second)
        b.editor.setText(second, MentionText([.mention(second, label: "Me"), .text(" then "), .mention(b.errands, label: "Chores")]))
        expectEqual(revision(second), own, "a shape's own text is none of its backlinks")
        expectEqual(revision(b.errands), errands + 3)

        b.editor.transact { $0.update(b.milk, as: Token.self) { $0.props.caption = "Oat milk" } }
        expectEqual(revision(b.groceries), groceries + 1, "the jot's quote around the groceries shows the milk's name")
        expectEqual(revision(b.milk), milk + 1)
        b.editor.setText(b.jot, MentionText([.mention(b.milk, label: "Oat milk")]))
        expectEqual(revision(b.groceries), groceries + 2, "no longer mentioned")
        b.editor.delete(b.jot)
        expectEqual(revision(b.milk), milk + 3, "a mentioner went")
        expectEqual(revision(b.errands), errands + 3)
        b.editor.undo()
        expectEqual(revision(b.milk), milk + 4, "undo is a commit")
        b.editor.redo()
        expectEqual(revision(b.milk), milk + 5)
        expect(!b.state.isMentioned(b.milk))
    },

    test("backlinkRevision is observed a target at a time: its observers hear a change of its backlinks, and nothing else") {
        let b = try Board()
        let flag = Flag()
        withObservationTracking { _ = b.state.backlinkRevision(of: b.groceries) } onChange: { flag.fired = true }
        b.h.add(Jot(frame, text: MentionText([.mention(b.errands, label: "Errands")])))
        expect(!flag.fired, "another target's")
        b.editor.transact { $0.translate([b.jot], by: CGPoint(x: 5, y: 5)) }
        expect(!flag.fired, "a drag")
        b.h.add(Jot(frame, text: MentionText([.mention(b.groceries, label: "Groceries")])))
        expect(flag.fired)
        // Heard once, it tells again only once read again, as SwiftUI reads it on redrawing.
        let again = Flag()
        withObservationTracking { _ = b.state.backlinkRevision(of: b.groceries) } onChange: { again.fired = true }
        b.editor.delete(b.jot)
        expect(again.fired)
    },

    test("rows affected: exactly the mentioners of a target whose name changed; none for a drag, or a change that shows nothing new") {
        let b = try Board()
        let second = b.h.add(Jot(frame, text: MentionText([.mention(b.milk, label: "Milk")])))
        let probe = AffectedProbe()
        var plugins = mentionPlugins()
        plugins.insert(Contributor(id: "probe") { $0.service { _ in probe } }, at: plugins.count - 1)
        let h = try EditorHarness(plugins: plugins, document: b.editor.document)
        let state = h.editor.mentionState
        h.editor.rename(b.groceries, "Food")
        expectEqual(probe.heard.last, [b.jot])
        expectEqual(state.rowsAffected(by: try require(probe.changes.last)), [b.jot], "asked again, the same answer")
        h.editor.transact { $0.translate([b.groceries, b.milk], by: CGPoint(x: 30, y: 0)) }
        expectEqual(probe.heard.last, [])
        h.editor.transact { $0.update(b.milk, as: Token.self) { $0.props.caption = "Oat milk" } }
        expectEqual(probe.heard.last, [b.jot, second])
        h.editor.transact { $0.update(b.milk, as: Token.self) { $0.props.frame.size.width = 90 } }
        expectEqual(probe.heard.last, [], "a resize changes no name")
        h.editor.delete(b.milk)
        expectEqual(probe.heard.last, [b.jot, second])
        h.editor.delete(b.jot)
        expectEqual(probe.heard.last, [], "a mentioner going changes no other row")
        expectEqual(state.mentioners(of: b.groceries), [])
    },

    test("heard first through rowsAffected, a commit is applied once: observers hear it once") {
        let b = try Board()
        let probe = AffectedProbe()
        var plugins = mentionPlugins()
        plugins.insert(Contributor(id: "probe") { $0.service { _ in probe } }, at: plugins.count - 1)
        let h = try EditorHarness(plugins: plugins, document: b.editor.document)
        var calls = 0
        let observation = h.editor.mentionState.observe([b.groceries]) { _ in calls += 1 }
        h.editor.rename(b.groceries, "Food")
        expectEqual(calls, 1)
        expectEqual(probe.heard.count, 1)
        observation.cancel()
    },

    test("the table of contents shows live names, and a rename remakes only the mentioners' rows") {
        let b = try Board()
        let contents = try require(b.editor.tableOfContents)
        @MainActor func row(_ id: ShapeID) -> String? { contents.entries.first { $0.id == id }?.label?.text }
        expectEqual(row(b.jot), "Ask @Groceries and @Milk, @Groceries")
        b.editor.rename(b.groceries, "Food")
        expectEqual(row(b.jot), "Ask @Food and @Milk, @Food")
        b.editor.delete(b.milk)
        expectEqual(row(b.jot), "Ask @Food and @Milk, @Food", "a missing target shows the name held")
        b.editor.rename(b.jot, "Titled")
        expectEqual(row(b.jot), "Titled")
    },

    test("nothing transacts while the state follows a commit: each commit is one revision") {
        let b = try Board()
        let observation = b.state.observe([b.groceries, b.milk]) { _ in }
        let revision = b.editor.revision
        b.editor.rename(b.groceries, "Food")
        b.editor.delete(b.milk)
        b.editor.setText(b.jot, "plain")
        expectEqual(b.editor.revision, revision + 3)
        observation.cancel()
    },

    test("undo and redo are commits the state follows exactly: names, pills, the index both ways and rows go back and forth, one revision each, and nothing transacts") {
        let b = try Board()
        let contents = try require(b.editor.tableOfContents)
        @MainActor func row(_ id: ShapeID) -> String? { contents.entries.first { $0.id == id }?.label?.text }
        var heard: [Set<ShapeID>] = []
        let observation = b.state.observe([b.groceries, b.milk, b.errands]) { heard.append($0) }
        b.editor.rename(b.groceries, "Food")
        b.editor.delete(b.milk)
        b.editor.setText(b.jot, MentionText([.text("See "), .mention(b.errands, label: "Errands")]))
        expectEqual(row(b.jot), "See @Errands")
        expectEqual(b.state.mentions(in: b.jot), [b.errands])
        heard = []
        let revision = b.editor.revision
        let labels = b.state.labelRevision(of: b.groceries)

        b.editor.undo()
        expectEqual(b.state.mentions(in: b.jot), [b.groceries, b.milk], "the text undone: the index follows it back")
        expectEqual(b.state.mentioners(of: b.errands), [])
        expectEqual(b.state.mentioners(of: b.milk), [b.jot])
        expectEqual(row(b.jot), "Ask @Food and @Milk, @Food", "the milk still deleted, the name held")
        b.editor.undo()
        expectEqual(b.state.resolve(b.milk).appearance?.label, "Milk", "the deletion undone: live again")
        expectEqual(heard.last, [b.milk])
        expectEqual(row(b.jot), "Ask @Food and @Milk, @Food")
        b.editor.undo()
        expectEqual(b.state.resolve(b.groceries).appearance?.label, "Groceries", "the rename undone: the name as it was")
        expectEqual(heard.last, [b.groceries])
        expectEqual(b.state.labelRevision(of: b.groceries), labels + 1)
        expectEqual(row(b.jot), "Ask @Groceries and @Milk, @Groceries")
        expectEqual(b.editor.revision, revision + 3, "one commit each, and nothing transacted beside them")

        b.editor.redo()
        expectEqual(row(b.jot), "Ask @Food and @Milk, @Food")
        b.editor.redo()
        expectEqual(b.state.resolve(b.milk), .missing)
        expectEqual(heard.last, [b.milk])
        b.editor.redo()
        expectEqual(b.state.mentions(in: b.jot), [b.errands])
        expectEqual(row(b.jot), "See @Errands")
        expectEqual(b.editor.revision, revision + 6)
        observation.cancel()
    },

    test("going to a shape is no step: undo after following a mention undoes the edit before it, putting its selection back, and Back returns to where the mention went") {
        let b = try Board()
        b.editor.selection = b.jot
        b.editor.setText(b.jot, MentionText([.text("See "), .mention(b.groceries, label: "Groceries")]))
        b.state.follow(b.groceries)
        b.h.wait(0)
        expectEqual(b.editor.selection, b.groceries)
        b.editor.undo()
        expectEqual(b.state.mentions(in: b.jot), [b.groceries, b.milk], "the text as it was")
        expectEqual(b.editor.selection, b.jot, "selected as when the edit was made")
        b.editor.goBack()
        expectEqual(b.editor.selection, b.groceries, "Back: what was selected before the undo")
        b.editor.goBack()
        expectEqual(b.editor.selection, b.jot)
    },

    test("hover sets the editor's hovered shape; endHover clears it only if it's still that target") {
        let b = try Board()
        b.state.hover(b.groceries)
        expectEqual(b.editor.hovered, b.groceries)
        b.state.endHover(b.errands)
        expectEqual(b.editor.hovered, b.groceries, "another's hover stays")
        b.editor.hovered = b.errands
        b.state.endHover(b.groceries)
        expectEqual(b.editor.hovered, b.errands)
        b.state.endHover(b.errands)
        expectEqual(b.editor.hovered, nil)
    },

    test("follow goes to the target on the next turn of the scheduler, and Back returns") {
        let b = try Board()
        b.editor.selection = b.jot
        b.state.follow(b.groceries)
        expectEqual(b.editor.selection, b.jot, "not yet")
        b.h.wait(0)
        expectEqual(b.editor.selection, b.groceries)
        b.editor.goBack()
        expectEqual(b.editor.selection, b.jot)
    },

    test("follow ends editing first, as goTo does") {
        let b = try Board()
        b.editor.selection = b.jot
        expect(b.editor.beginEditing(b.jot))
        b.state.follow(b.milk)
        b.h.wait(0)
        expectEqual(b.editor.editingShapeID, nil)
        expectEqual(b.editor.selection, b.milk)
    },

    test("recent picks: the latest first, each once, 20 kept") {
        let h = try mentionHarness()
        let plates = (0..<25).map { h.editor.add(Plate(CGRect(x: $0 * 130, y: 0, width: 120, height: 80)), titled: "Plate \($0)") }
        let state = h.editor.mentionState
        for id in plates { state.didPick(id) }
        state.didPick(plates[22])
        let recent = state.candidates(matching: "", in: AnyMentionable.self, for: nil).recent.map(\.id)
        expectEqual(recent, [plates[22], plates[24], plates[23], plates[21]])
        // Among equal matches, recent picks come first, the latest first.
        let ranked = state.candidates(matching: "plate", in: AnyMentionable.self, for: nil).matches.map(\.id)
        expectEqual(Array(ranked.prefix(3)), [plates[22], plates[24], plates[23]])
    },
])
