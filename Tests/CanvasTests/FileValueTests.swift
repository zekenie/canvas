import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// File values (`FileProperty`): what a plugin keeps on the file as a whole. Read from the file, a
// transaction, a render and a layout; written in a transaction, so undone and redone with its step;
// heard in `ChangeSet.fileValues`. CanvasTesting's `Letterhead` is the property.

private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

private func box(_ id: ShapeID = ShapeID(), _ frame: CGRect = unit) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Box(frame))) }
private func pocket(_ id: ShapeID, _ frame: CGRect = unit) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(frame))) }
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

/// A root holding box A and pocket P, whose board holds box B.
private struct Headed {
    let a = ShapeID(), p = ShapeID(), b = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: board(box(a), pocket(p, CGRect(x: 200, y: 0, width: 100, height: 100))), children: [p: board(box(b))])
    }
    var pBoard: BoardID { BoardID(owner: p) }
}

/// What services hear: each commit's change set, and each switch's file values.
@MainActor private final class Heard {
    var changes: [ChangeSet] = []
    var switches: [(replaced: Bool, fileValues: Set<PropertyKey>, inChanges: Set<PropertyKey>)] = []
}

private final class Hearing {
    let heard: Heard
    init(heard: Heard) { self.heard = heard }
}

extension Hearing: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) { heard.changes.append(changes) }
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        heard.switches.append((change.isFileReplaced, change.fileValues, change.changes.fileValues))
    }
}

@MainActor private func harness(_ file: CanvasFile = CanvasFile(), heard: Heard = Heard(), _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), LetterheadPlugin(),
                                Contributor(id: "hearing") { r in r.service { _ in Hearing(heard: heard) } }] + more, file: file)
}

@MainActor private func head(_ h: EditorHarness, _ value: String, _ name: String = "Head File") {
    h.editor.transact(name) { $0.setFileValue(Letterhead.self, to: value) }
}

/// The file, and the file as a board file's bytes: what a round trip must come back to.
@MainActor private func expectFile(_ h: EditorHarness, _ expected: CanvasFile, _ message: String,
                                   file: StaticString = #fileID, line: UInt = #line) throws {
    expectEqual(h.file, expected, message, file: file, line: line)
    let codec = BoardCodec(registry: h.editor.registry)
    expectEqual(try codec.encode(h.file), try codec.encode(expected), "\(message), as a file", file: file, line: line)
}

/// The same property a version on, by a step that rewrites nothing.
private enum LaterLetterhead {}
extension LaterLetterhead: FileProperty {
    static let key: PropertyKey = "letterhead"
    static var defaultValue: String { "" }
    static let migrations = [PropertyMigration("letterheads take a step")]
}

/// An added property under the key the file property has: a shape's values and the file's are apart.
private enum ShapeLetterhead {}
extension ShapeLetterhead: ShapeProperty {
    static let key: PropertyKey = "letterhead"
    static var defaultValue: String? { nil }
}

/// A box drawn black while the file has a letterhead, else not at all.
private struct Banner: BoxShapeProps {
    static let kind: ShapeKind = "banner"
    static let properties = Properties<Banner> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Banner {
    init() { self.init(.zero) }
}

private struct BannerDefinition {}

extension BannerDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Banner>, in context: RenderContext) {
        guard !context.fileValue(Letterhead.self).isEmpty else { return }
        context.cg.setFillColor(CGColor(gray: 0, alpha: 1))
        context.cg.fill(shape.frame)
    }
}

/// What a layout provider reads of the file: its letterhead.
private let heading = LayoutInputKey<String>("heading")

@MainActor let fileValueTests = Suite("File values", [
    test("a file reads a property's default until it's set, then the value, from the file and from the transaction that sets it") {
        let h = try harness()
        expectEqual(h.file[Letterhead.self], "")
        expectEqual(h.file.fileValueKeys, [], "a default is nothing the file holds")
        var seen: [String] = []
        h.editor.transact("Head File") { transaction in
            seen.append(transaction.fileValue(Letterhead.self))
            transaction.setFileValue(Letterhead.self, to: "Acme")
            seen.append(transaction.fileValue(Letterhead.self))
            transaction.setFileValue(Letterhead.self, to: "Apex")
            seen.append(transaction.fileValue(Letterhead.self))
        }
        expectEqual(seen, ["", "Acme", "Apex"], "as the transaction leaves it")
        expectEqual(h.editor.file[Letterhead.self], "Apex")
        expectEqual(h.file.fileValueKeys, ["letterhead"])
        var later = ""
        h.editor.transact { later = $0.fileValue(Letterhead.self) }
        expectEqual(later, "Apex", "a later transaction reads what the file holds")
    },
    test("setting the default takes the value off the file, which is then the file it was") {
        let tree = Headed()
        let h = try harness(tree.file)
        let before = h.file
        head(h, "Acme")
        expect(h.file != before, "a file with a value isn't the file without")
        head(h, "")
        expectEqual(h.file.fileValueKeys, [])
        try expectFile(h, before, "the default set")
    },
    test("a file value is one undo step, named as its transaction: undo and redo put it back and again") {
        let h = try harness()
        let events = UndoEvents(h.editor)
        head(h, "Acme")
        expectEqual(events.events, [.began, .closed])
        expectEqual(h.editor.undoHistory.undoName, "Head File")
        head(h, "Apex", "Head Again")
        h.editor.undo()
        expectEqual(h.file[Letterhead.self], "Acme")
        expectEqual(h.editor.undoHistory.redoName, "Head Again")
        h.editor.undo()
        expectEqual(h.file[Letterhead.self], "")
        expectEqual(h.file.fileValueKeys, [], "undone to none, the file holds none")
        expect(!h.editor.canUndo)
        h.editor.redo()
        expectEqual(h.file[Letterhead.self], "Acme")
        h.editor.redo()
        expectEqual(h.file[Letterhead.self], "Apex")
        expect(!h.editor.canRedo)
    },
    test("a file value and a shape changed in one transaction are one step, undone and redone together") {
        let tree = Headed()
        let h = try harness(tree.file)
        let before = h.file
        h.editor.transact("Rebrand") { transaction in
            transaction.update(tree.a, as: Box.self) { $0.frame.origin.x = 40 }
            transaction.setFileValue(Letterhead.self, to: "Acme")
            transaction.insert(ShapeRecord(Box(unit)))
        }
        let after = h.file
        expectEqual(after[Letterhead.self], "Acme")
        expectEqual(h.editor.undoHistory.undoName, "Rebrand")
        h.editor.undo()
        try expectFile(h, before, "undone")
        expect(!h.editor.canUndo, "one step")
        h.editor.redo()
        try expectFile(h, after, "redone")
    },
    test("commits under one key coalesce a file value with the rest of their run, and a run back where it began is no step") {
        let h = try harness()
        h.editor.transact("Head File", coalescing: "head") { $0.setFileValue(Letterhead.self, to: "A") }
        h.editor.transact("Head File", coalescing: "head") { $0.setFileValue(Letterhead.self, to: "Ac") }
        h.editor.undo()
        expectEqual(h.file[Letterhead.self], "", "one step")
        expect(!h.editor.canUndo)
        h.editor.transact("Head File", coalescing: "head") { $0.setFileValue(Letterhead.self, to: "A") }
        h.editor.transact("Head File", coalescing: "head") { $0.setFileValue(Letterhead.self, to: "") }
        expect(!h.editor.canUndo, "typed and typed back: nothing to undo")
    },
    test("a file value set from a board that isn't the root is the file's on every board, and undoing it from another shows its board first") {
        let tree = Headed()
        let h = try harness(tree.file)
        expect(h.enter(tree.p))
        head(h, "Acme")
        expectEqual(h.editor.file[Letterhead.self], "Acme")
        expect(h.editor.showBoard(.root))
        expectEqual(h.editor.file[Letterhead.self], "Acme", "it's no board's")
        h.editor.undo()
        expectEqual(h.editor.board, tree.pBoard, "the step was made on P")
        expectEqual(h.editor.file[Letterhead.self], "")
        expect(h.editor.showBoard(.root))
        h.editor.redo()
        expectEqual(h.editor.board, tree.pBoard)
        expectEqual(h.editor.file[Letterhead.self], "Acme")
        try expectFile(h, { var file = tree.file; file[Letterhead.self] = "Acme"; return file }(), "no shape moved")
    },
    test("a transaction on a board that isn't shown sets a file value: no board changes, and it's a step on that board") {
        let tree = Headed(), heard = Heard()
        let h = try harness(tree.file, heard: heard)
        let revisions = [h.file.revision(of: .root), h.file.revision(of: tree.pBoard)]
        h.editor.transact(on: tree.pBoard, "Head File") { $0.setFileValue(Letterhead.self, to: "Acme") }
        expectEqual(h.editor.file[Letterhead.self], "Acme")
        let changes = try require(heard.changes.last)
        expectEqual(changes.fileValues, ["letterhead"])
        expectEqual(changes.boardsReached, [], "no board changed")
        expectEqual(changes.elsewhere, [])
        expectEqual([h.file.revision(of: .root), h.file.revision(of: tree.pBoard)], revisions, "no board's revision moved")
        h.editor.undo()
        expectEqual(h.editor.board, tree.pBoard)
        expectEqual(h.editor.file[Letterhead.self], "")
        // With a shape of that board, it's the board's change too.
        expect(h.editor.showBoard(.root))
        h.editor.transact(on: tree.pBoard, "Rebrand") { transaction in
            transaction.update(tree.b, as: Box.self) { $0.frame.origin.x = 40 }
            transaction.setFileValue(Letterhead.self, to: "Apex")
        }
        expectEqual(heard.changes.last?.fileValues, ["letterhead"])
        expectEqual(heard.changes.last?.boardsChanged, [tree.pBoard])
        expectEqual(heard.changes.last?.elsewhere, [tree.b])
        h.editor.undo()
        try expectFile(h, tree.file, "one step undoes both")
    },
    test("no board's lock holds a file value: it's set from a read-only board, in a transaction whose shape changes are refused") {
        let tree = Headed(), refusals = RefusalLog()
        let h = try harness(tree.file, heard: Heard(), [FreezingPlugin(log: refusals)])
        h.editor.transact { $0.update(tree.p) { $0[Frozen.self] = true } }
        expect(h.enter(tree.p))
        expect(h.editor.isBoardReadOnly)
        h.editor.transact("Head File") { transaction in
            transaction.update(tree.b, as: Box.self) { $0.frame.origin.x = 40 }
            transaction.setFileValue(Letterhead.self, to: "Acme")
        }
        expectEqual(h.editor.file[Letterhead.self], "Acme")
        expectEqual(h.file.record(tree.b)?.box?.minX, 0, "the board's shapes are held")
        expectEqual(refusals.refusals, [[tree.b]])
        h.editor.undo()
        expectEqual(h.editor.file[Letterhead.self], "")
    },
    test("a transaction whose body throws sets nothing: no change to hear, no step, and the error comes out") {
        struct Stop: Error, Equatable {}
        let heard = Heard()
        let h = try harness(heard: heard)
        head(h, "Acme")
        let events = UndoEvents(h.editor)
        let count = heard.changes.count, revision = h.editor.revision
        do {
            try h.editor.transact("Throw") { transaction in
                transaction.setFileValue(Letterhead.self, to: "Apex")
                throw Stop()
            }
            expect(false, "the error didn't come out")
        } catch {
            expectEqual(error as? Stop, Stop())
        }
        expectEqual(h.file[Letterhead.self], "Acme")
        expectEqual(heard.changes.count, count)
        expectEqual(h.editor.revision, revision)
        expectEqual(events.events, [])
        expectEqual(h.editor.undoHistory.undoName, "Head File", "the step before is the one to undo")
    },
    test("a write that changes nothing is no commit and no step: the value it is, the default of a file with none, or there and back") {
        let heard = Heard()
        let h = try harness(heard: heard)
        let events = UndoEvents(h.editor)
        head(h, "")
        expectEqual(heard.changes.count, 0, "the default, of a file with none")
        expectEqual(events.events, [])
        head(h, "Acme")
        events.events = []
        let revision = h.editor.revision
        head(h, "Acme", "Again")
        h.editor.transact("There and Back") { transaction in
            transaction.setFileValue(Letterhead.self, to: "Apex")
            transaction.setFileValue(Letterhead.self, to: "Acme")
        }
        expectEqual(heard.changes.count, 1)
        expectEqual(h.editor.revision, revision)
        expectEqual(events.events, [])
        expectEqual(h.editor.undoHistory.undoName, "Head File")
    },
    test("a commit says which file values it changed, and of one that changed nothing else, no shape and no board") {
        let tree = Headed(), heard = Heard()
        let h = try harness(tree.file, heard: heard)
        let revision = h.file.revision(of: .root), document = h.editor.document
        head(h, "Acme")
        var changes = try require(heard.changes.last)
        expectEqual(changes.fileValues, ["letterhead"])
        expectEqual(changes.shapeIDs, [])
        expectEqual(changes.moved, [])
        expectEqual(changes.elsewhere, [])
        expectEqual(changes.boardsReached, [])
        expect(!changes.reordered && !changes.replacedDocument && !changes.restoredStep)
        expectEqual(h.file.revision(of: .root), revision, "the board shown didn't change, so its revision didn't")
        expectEqual(h.editor.document, document)

        h.editor.transact { $0.update(tree.a, as: Box.self) { $0.frame.origin.x = 40 } }
        expectEqual(heard.changes.last?.fileValues, [], "a commit that set none names none")
        h.editor.transact { transaction in
            transaction.update(tree.a, as: Box.self) { $0.frame.origin.x = 80 }
            transaction.setFileValue(Letterhead.self, to: "Apex")
        }
        expectEqual(heard.changes.last?.fileValues, ["letterhead"])
        expectEqual(heard.changes.last?.changed, [tree.a])

        h.editor.undo()
        changes = try require(heard.changes.last)
        expectEqual(changes.fileValues, ["letterhead"])
        expect(changes.restoredStep)
        h.editor.undo()
        expectEqual(heard.changes.last?.fileValues, [], "the step undone set none")
        h.editor.undo()
        changes = try require(heard.changes.last)
        expectEqual(changes.fileValues, ["letterhead"])
        expectEqual(changes.shapeIDs, [], "undoing a file value alone names no shape")
        expect(changes.restoredStep)
        h.editor.redo()
        expectEqual(heard.changes.last?.fileValues, ["letterhead"])
        expectEqual(heard.changes.last?.shapeIDs, [])
    },
    test("a file put in place carries its values, and services hear the ones that differ, on the board shown or with a switch") {
        let tree = Headed(), heard = Heard()
        let h = try harness(tree.file, heard: heard)
        var headed = tree.file
        headed[Letterhead.self] = "Acme"
        h.editor.replaceFile(with: headed)
        expectEqual(h.editor.file[Letterhead.self], "Acme")
        expectEqual(heard.changes.last?.fileValues, ["letterhead"])
        expectEqual(heard.changes.last?.replacedDocument, true)
        expect(!h.editor.canUndo, "a file put in place is no step")
        h.editor.replaceFile(with: headed)
        expectEqual(heard.changes.last?.fileValues, [], "the same values: none differ")
        expect(h.enter(tree.p))
        heard.switches = []
        // The board shown isn't in the new file, so it goes to the root as a switch does.
        h.editor.replaceFile(with: CanvasFile(root: board(box())))
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.file[Letterhead.self], "")
        expectEqual(heard.switches.map(\.replaced), [true])
        expectEqual(heard.switches.map(\.fileValues), [["letterhead"]])
        expectEqual(heard.switches.map(\.inChanges), [["letterhead"]], "and in the switch's change set")
        expect(h.editor.showBoard(.root))
        let editor = CanvasEditor(registry: h.editor.registry, file: headed, scheduler: ManualScheduler())
        expectEqual(editor.file[Letterhead.self], "Acme", "an editor made on a file holds its values")
    },
    test("the registry refuses a file property's key declared twice, and its report shows a declared one") {
        expectThrows(RegistryError.conflict(point: "FilePropertyDeclarations", key: "letterhead", plugins: ["letterhead", "later"])) {
            _ = try Registry(plugins: [LetterheadPlugin(), Contributor(id: "later") { $0.declare(file: LaterLetterhead.self) }])
        }
        let registry = try Registry(plugins: [FixturesPlugin(), LetterheadPlugin()])
        expectEqual(registry.report, """
        core          tool hand · command undo · command redo · command zoomIn in ViewMenu.Zoom · command zoomOut in ViewMenu.Zoom · command zoomToActualSize in ViewMenu.Zoom · command zoomToFit in ViewMenu.Zoom · command pageUp · command pageDown · command scrollToStart · command scrollToEnd
        fixtures      shape box · shape disc · shape tag
        letterhead    file property letterhead
        """)
        expectEqual(registry.declaredFileProperties, ["letterhead"])
        expectEqual(registry.owner(ofFileProperty: "letterhead"), "letterhead")
        expectEqual(registry.owner(ofFileProperty: "nothing"), nil)
        expectEqual(registry.declaredProperties, [], "it's no shape's property")
        let later = try Registry(plugins: [Contributor(id: "later") { $0.declare(file: LaterLetterhead.self) }])
        expect(later.report.contains("file property letterhead v1"), later.report)
        // A shape's property may have the key: the two are kept apart.
        let both = try Registry(plugins: [FixturesPlugin(), LetterheadPlugin(), Contributor(id: "shapes") { r in
            r.declare(ShapeLetterhead.self)
            r.optIn(Box.self, to: ShapeLetterhead.self)
        }])
        let editor = CanvasEditor(registry: both, scheduler: ManualScheduler())
        let id = editor.add(Box(unit))
        editor.transact { transaction in
            transaction.update(id) { $0[ShapeLetterhead.self] = "On the box" }
            transaction.setFileValue(Letterhead.self, to: "On the file")
        }
        expectEqual(editor.document[id]?[ShapeLetterhead.self], "On the box")
        expectEqual(editor.file[Letterhead.self], "On the file")
    },
    test("a property no installed plugin declares reads its default and takes no write") {
        let heard = Heard()
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "hearing") { r in r.service { _ in Hearing(heard: heard) } }])
        head(h, "Acme")
        expectEqual(h.file[Letterhead.self], "")
        expectEqual(heard.changes.count, 0)
        expect(!h.editor.canUndo)
        // Nor one declared under the key by another type.
        let later = try EditorHarness(plugins: [Contributor(id: "later") { $0.declare(file: LaterLetterhead.self) }])
        head(later, "Acme")
        expectEqual(later.file.fileValueKeys, [])
    },
    test("a render reads a file value with no service, and the commit that changes it redraws") {
        let h = try harness(CanvasFile(), heard: Heard(), [Contributor(id: "banners") { $0.shape(BannerDefinition()) }])
        h.add(Banner(CGRect(x: 20, y: 20, width: 60, height: 60)))
        let host = DisplayCounter()
        h.editor.delegate = host
        let size = CGSize(width: 100, height: 100), middle = CGPoint(x: 50, y: 50)
        expectEqual(pixel(renderBitmap(h.editor, size: size), at: middle), [246, 246, 246, 255])
        head(h, "Acme")
        expect(host.redraws > 0, "the commit redraws")
        expectEqual(pixel(renderBitmap(h.editor, size: size), at: middle), [0, 0, 0, 255])
        h.editor.undo()
        expectEqual(pixel(renderBitmap(h.editor, size: size), at: middle), [246, 246, 246, 255])
    },
    test("a layout reads a file value as its reader sees the file: the editor's committed, a transaction's as it leaves it") {
        let h = try harness(CanvasFile(), heard: Heard(), [Contributor(id: "headings") { r in
            r.layoutInput(heading) { _, reading in reading.fileValue(Letterhead.self) }
        }])
        let id = h.add(Box(unit))
        expectEqual(h.editor.shapeContext.reading?.fileValue(Letterhead.self), "")
        expectEqual(h.editor.shapeContext.layoutInput(heading, for: id), "")
        var inside: [String?] = []
        h.editor.transact { transaction in
            transaction.setFileValue(Letterhead.self, to: "Acme")
            inside = [transaction.shapes.reading?.fileValue(Letterhead.self), transaction.shapes.layoutInput(heading, for: id),
                      h.editor.shapeContext.reading?.fileValue(Letterhead.self)]
        }
        expectEqual(inside, ["Acme", "Acme", ""], "the transaction's reading has it; the editor's is still the committed file")
        expectEqual(h.editor.shapeContext.layoutInput(heading, for: id), "Acme")
        expect(ShapeContext(document: h.editor.document, registry: h.editor.registry).reading == nil, "a plain context reads no file")
    },
    test("a step's delta holds a file value before and after, and applies both ways") {
        var before = CanvasFile(root: board(box()))
        before[Letterhead.self] = "Acme"
        var after = before
        after[Letterhead.self] = "Apex"
        var builder = DocumentDelta.Builder()
        expect(!builder.isHolding)
        // A change set that names the value, as an editor's commit hands one.
        let heard = Heard()
        let h = try harness(before, heard: heard)
        head(h, "Apex")
        builder.willCommit(try require(heard.changes.last), from: before)
        expect(builder.isHolding)
        expect(builder.hasChanges(now: after))
        expect(!builder.hasChanges(now: before), "back where it began")
        expect(builder.delta(now: before).isEmpty)
        let delta = builder.delta(now: after)
        expectEqual(Array(delta.fileValues.keys), ["letterhead"])
        expectEqual(delta.fileValues["letterhead"]?.before(Letterhead.self), "Acme")
        expectEqual(delta.fileValues["letterhead"]?.after(Letterhead.self), "Apex")
        expectEqual(delta.shapeIDs, [])
        expectEqual(ChangeSet(delta).fileValues, ["letterhead"])
        expectEqual(delta, DocumentDelta(fileValues: ["letterhead": .init(Letterhead.self, before: "Acme", after: "Apex")]))
        var file = before
        file.apply(delta)
        expectEqual(file, after)
        file.apply(delta.inverted)
        expectEqual(file, before)
        // From none, and to none.
        var unset = DocumentDelta(fileValues: ["letterhead": .init(Letterhead.self, before: "Acme", after: "")])
        file.apply(unset)
        expectEqual(file.fileValueKeys, [])
        unset = unset.inverted
        file.apply(unset)
        expectEqual(file, before)
        expect(DocumentDelta(fileValues: ["letterhead": .init(Letterhead.self, before: "Acme", after: "Acme")]).isEmpty, "equal sides are left out")
    },
])
