@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TableOfContents
import TestKit

extension Array where Element == ContentsEntry {
    /// Each row's shape, kind, text, badge and symbol, nested rows indented under theirs: all a
    /// row shows, and which shape it's for.
    @MainActor var tree: [String] {
        flatMap { entry -> [String] in
            let line = "\(entry.id) \(entry.kind) \(entry.label?.text ?? "<view>") \(entry.label?.badge ?? "-") \(entry.symbol)"
            return [entry.children?.isEmpty == true ? line + " (no children, but not nil)" : line] + (entry.children ?? []).tree.map { "  " + $0 }
        }
    }
}

/// What listing the editor's rows from scratch gives: another editor on the same board, listing
/// the same shapes.
@MainActor func listedAfresh(_ editor: CanvasEditor) -> [String] {
    let fresh = CanvasEditor(registry: editor.registry, document: editor.document, scheduler: ManualScheduler())
    if let scope = editor.contents.scope {
        let present = scope.filter { editor.document[$0] != nil }
        guard !present.isEmpty else { return [] }
        fresh.selectedShapeIDs = present
    }
    return fresh.contents.entries.tree
}

/// Reads the table of contents as it hears of a commit, before the table of contents does, when
/// `reads` is set.
@MainActor
final class EarlyReader {
    var reads = false
    private(set) var heard: [String] = []
    /// Each row's marks' help, as `heard` has the rows' text.
    private(set) var heardMarks: [[String]] = []
}

extension EarlyReader: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard reads else { return }
        let entries = editor.contents.entries
        heard = entries.outline
        heardMarks = entries.marks
    }
}

/// The keyboard, the selection, the fixtures, widgets, an early reader, and the table of contents,
/// in that order.
@MainActor func editorWithEarlyReader() throws -> CanvasEditor {
    let reader = Contributor(id: "early-reader") { $0.service { _ in EarlyReader() } }
    return CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), WidgetsPlugin(), reader,
                                                         TableOfContentsPlugin()]),
                        scheduler: ManualScheduler())
}

/// A reproducible stream of choices for the fuzz test.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 11 | state << 53
    }
}

@MainActor let keepingUpTests = Suite("Table of contents: keeping up with the board", [
    test("a restack moves a row, with the rows nested under it") {
        let editor = try contentsEditor()
        let (a, b, _) = threeWidgets(editor)
        editor.add(Pin("on A", on: a))
        expectEqual(editor.contents.entries.outline, ["A", "  on A", "B", "C"])
        editor.transact { $0.bringToFront(a) }
        expectEqual(editor.contents.entries.outline, ["B", "C", "A", "  on A"])
        editor.transact { $0.move(b, above: a) }
        expectEqual(editor.contents.entries.outline, ["C", "A", "  on A", "B"])
        editor.transact { $0.sendToBack(b) }
        expectEqual(editor.contents.entries.outline, ["B", "C", "A", "  on A"])
    },
    test("a shape that comes takes the rows naming it, in document order; one that goes lets them go to the top") {
        let editor = try contentsEditor()
        let board = ShapeID()
        editor.add(Pin("first", on: board))
        editor.add(Widget(name: "Other"))
        editor.add(Pin("second", on: board))
        expectEqual(editor.contents.entries.outline, ["first", "Other", "second"])
        editor.add(Widget(name: "Board"), id: board)
        expectEqual(editor.contents.entries.outline, ["Other", "Board", "  first", "  second"])
        editor.transact { $0.update(board, as: Widget.self) { $0.props.isHidden = true } }
        expectEqual(editor.contents.entries.outline, ["first", "Other", "second"])
        editor.transact { $0.update(board, as: Widget.self) { $0.props.isHidden = false } }
        expectEqual(editor.contents.entries.outline, ["Other", "Board", "  first", "  second"])
        editor.transact { $0.delete([board]) }
        expectEqual(editor.contents.entries.outline, ["first", "Other", "second"])
    },
    test("a row that names another shape moves under it, and to the top when it names none") {
        let editor = try contentsEditor()
        let (a, b, _) = threeWidgets(editor)
        let pin = editor.add(Pin("pin", on: nil))
        editor.add(Pin("under the pin", on: pin))
        expectEqual(editor.contents.entries.outline, ["A", "B", "C", "pin", "  under the pin"])
        editor.transact { $0.update(pin, as: Pin.self) { $0.props.target = b } }
        expectEqual(editor.contents.entries.outline, ["A", "B", "  pin", "    under the pin", "C"])
        editor.transact { $0.update(pin, as: Pin.self) { $0.props.target = a } }
        expectEqual(editor.contents.entries.outline, ["A", "  pin", "    under the pin", "B", "C"])
        editor.transact { $0.update(pin, as: Pin.self) { $0.props.target = pin } }
        expectEqual(editor.contents.entries.outline, ["A", "B", "C", "pin", "  under the pin"], "a row naming itself stays at the top")
    },
    test("rows nested under a shape that leaves go to the top, in document order, among the others") {
        let editor = try contentsEditor()
        let a = editor.add(Widget(name: "A"))
        let early = editor.add(Pin("early", on: a))
        editor.add(Widget(name: "B"))
        editor.add(Pin("late", on: a))
        editor.add(Widget(name: "C"))
        editor.transact { $0.move(early, below: a) }
        expectEqual(editor.contents.entries.outline, ["A", "  early", "  late", "B", "C"])
        editor.transact { $0.delete([a]) }
        expectEqual(editor.contents.entries.outline, ["early", "B", "late", "C"])
    },
    test("a row that leaves is forgotten by the shape it named, which can come and go after") {
        let editor = try contentsEditor()
        let widget = editor.add(Widget(name: "W"))
        let pin = editor.add(Pin("gone", on: widget))
        editor.add(Pin("kept", on: widget))
        expectEqual(editor.contents.entries.outline, ["W", "  gone", "  kept"])
        editor.transact { $0.delete([pin]) }
        expectEqual(editor.contents.entries.outline, ["W", "  kept"])
        editor.transact { $0.update(widget, as: Widget.self) { $0.props.isHidden = true } }
        expectEqual(editor.contents.entries.outline, ["kept"])
        editor.transact { $0.update(widget, as: Widget.self) { $0.props.isHidden = false } }
        expectEqual(editor.contents.entries.outline, ["W", "  kept"])
    },
    test("a loop made or broken by a change lists as a loop does from scratch") {
        let editor = try contentsEditor()
        let a = editor.add(Pin("a", on: nil))
        let b = editor.add(Pin("b", on: a))
        editor.add(Pin("c", on: a))
        expectEqual(editor.contents.entries.outline, ["a", "  b", "  c"])
        editor.transact { $0.update(a, as: Pin.self) { $0.props.target = b } }       // a loop: the later shape stays at the top
        expectEqual(editor.contents.entries.outline, ["b", "  a", "    c"])
        editor.transact { $0.bringToFront(a) }
        expectEqual(editor.contents.entries.outline, ["a", "  b", "  c"], "now a is the later one")
        editor.transact { $0.update(a, as: Pin.self) { $0.props.target = nil } }
        expectEqual(editor.contents.entries.outline, ["a", "  b", "  c"])
        editor.transact { $0.delete([a]) }
        expectEqual(editor.contents.entries.outline, ["b", "c"])
    },
    test("many rows moving at once are listed again, as from scratch") {
        let editor = try contentsEditor()
        let widgets = (0..<200).map { editor.add(Widget(name: "w\($0)")) }
        for (i, widget) in widgets.enumerated() where i % 3 == 0 { editor.add(Pin("pin \(i)", on: widget)) }
        _ = editor.contents.entries
        let made = widgetRowsMade
        editor.transact { tx in for widget in widgets.reversed() { tx.bringToFront(widget) } }
        let entries = editor.contents.entries
        expectEqual(widgetRowsMade, made + 200, "each restacked row made once")
        expectEqual(entries.tree, listedAfresh(editor))
        expectEqual(entries.first?.label?.text, "w199", "the widgets in the other order, in front of the pins nested under them")
        expectEqual(entries.last?.children?.map { $0.label?.text }, ["pin 0"])
    },
    test("commits between reads are caught up with in one read, each changed row made once") {
        let editor = try contentsEditor()
        let widget = editor.add(Widget(name: "Watched"))
        let other = editor.add(Widget(name: "Other"))
        _ = editor.contents.entries
        let made = widgetRowsMade
        for count in 1...5 { editor.transact { $0.update(widget, as: Widget.self) { $0.props.count = count } } }
        editor.transact { $0.bringToFront(widget) }
        editor.transact { $0.update(other, as: Widget.self) { $0.props.frame.origin.x += 10 } }
        expectEqual(editor.contents.entries.outline, ["Other", "Watched"])
        expectEqual(editor.contents.entries.last?.label?.badge, "5")
        expectEqual(widgetRowsMade, made + 2)
    },
    test("the board and a selection each keep their list, from rows made once") {
        let editor = try contentsEditor()
        let (a, b, _) = threeWidgets(editor)
        expectEqual(editor.contents.entries.outline, ["A", "B", "C"])
        editor.selectedShapeIDs = [a, b]
        expectEqual(editor.contents.entries.outline, ["A", "B"])
        let made = widgetRowsMade
        editor.transact { $0.update(b, as: Widget.self) { $0.props.name = "Bee" } }
        expectEqual(editor.contents.entries.outline, ["A", "Bee"])
        editor.selectedShapeIDs = []
        expectEqual(editor.contents.entries.outline, ["A", "Bee", "C"])
        expectEqual(widgetRowsMade, made + 1, "the board's list takes the row the selection's made")
    },
    test("read by a service that hears of a commit first, the rows are up to date, and stay so") {
        let editor = try editorWithEarlyReader()
        let reader = try require(editor.service(EarlyReader.self))
        let (a, _, _) = threeWidgets(editor)
        _ = editor.contents.entries
        reader.reads = true
        editor.transact { $0.update(a, as: Widget.self) { $0.props.name = "Renamed" } }
        expectEqual(reader.heard, ["Renamed", "B", "C"])
        editor.add(Pin("pin", on: a))
        expectEqual(reader.heard, ["Renamed", "  pin", "B", "C"])
        reader.reads = false
        editor.transact { $0.bringToFront(a) }
        expectEqual(editor.contents.entries.outline, ["B", "C", "Renamed", "  pin"])
    },
    test("kept up to date commit by commit, the rows are those listing from scratch gives") {
        var random = SeededRandom(state: 2026_09_27)
        let editor = try editorWithEarlyReader()
        let reader = try require(editor.service(EarlyReader.self))
        var future = (0..<30).map { _ in ShapeID() }        // shapes named before they're added
        @MainActor func chance(_ percent: Int) -> Bool { Int.random(in: 0..<100, using: &random) < percent }
        @MainActor func anyShape() -> ShapeID? { editor.document.shapes.randomElement(using: &random)?.id }
        // Pins and links often name each other, so rows nest deep, and loops come and go.
        @MainActor func target() -> ShapeID? {
            switch Int.random(in: 0..<20, using: &random) {
            case 0, 1: nil
            case 2, 3: future.randomElement(using: &random)
            case 4: ShapeID()                                  // a shape that never is
            case 5..<12: editor.document.shapes.filter { $0.kind == Pin.kind || $0.kind == Link.kind }.randomElement(using: &random)?.id
            default: anyShape()
            }
        }
        @MainActor func someShapes(_ most: Int) -> [ShapeID] {
            (0..<Int.random(in: 1...most, using: &random)).compactMap { _ in anyShape() }
        }
        @MainActor func newShape() -> AnyShapeRecord {
            let id = chance(15) && !future.isEmpty ? future.removeLast() : ShapeID()
            let frame = CGRect(x: Int.random(in: 0...2000, using: &random), y: Int.random(in: 0...2000, using: &random), width: 100, height: 60)
            return switch Int.random(in: 0..<10, using: &random) {
            case 0..<3: AnyShapeRecord(ShapeRecord(id: id, Widget(frame, name: chance(20) ? " " : "w\(Int.random(in: 0..<99, using: &random))",
                                                                   isHidden: chance(20))))
            case 3..<6: AnyShapeRecord(ShapeRecord(id: id, Pin("p\(Int.random(in: 0..<99, using: &random))", on: target())))
            case 6..<8: AnyShapeRecord(ShapeRecord(id: id, Link(on: target())))
            case 8: AnyShapeRecord(ShapeRecord(id: id, Gizmo(frame)))
            default: AnyShapeRecord(ShapeRecord(id: id, Box(frame)))
            }
        }
        @MainActor func change(_ tx: inout Transaction) {
            guard let id = anyShape(), let record = tx.document[id] else { return tx.insert(newShape()) }
            switch Int.random(in: 0..<12, using: &random) {
            case 0, 1:
                tx.insert(newShape())
            case 2:
                tx.delete(Set(someShapes(2)))
            case 3:
                tx.bringToFront(id)
            case 4:
                tx.sendToBack(id)
            case 5:
                guard let other = anyShape() else { return }
                if chance(50) { tx.move(id, above: other) } else { tx.move(id, below: other) }
            case 6, 7:
                tx.update(id, as: Pin.self) { $0.props.target = chance(10) ? id : target() }
                tx.update(id, as: Link.self) { $0.props.target = target() }
            case 8:
                tx.update(id, as: Widget.self) { $0.props.isHidden.toggle() }
            case 9:
                tx.update(id, as: Widget.self) { $0.props.name = "w\(Int.random(in: 0..<99, using: &random))" }
                tx.update(id, as: Pin.self) { $0.props.name = "p\(Int.random(in: 0..<99, using: &random))" }
            default:                                            // as a drag does
                if record.box != nil { tx.update(id) { $0.box?.origin.x += 7 } }
                tx.update(id, as: Widget.self) { $0.props.count += 1 }
            }
        }
        /// Reads the rows, and fails the test if they aren't those listing from scratch gives.
        @MainActor func matches(after step: Int) -> Bool {
            let tree = editor.contents.entries.tree
            guard tree == listedAfresh(editor) else {
                expectEqual(tree, listedAfresh(editor), "after step \(step)")
                return false
            }
            return true
        }
        for _ in 0..<40 { editor.transact { $0.insert(newShape()) } }
        for step in 0..<3000 {
            reader.reads = chance(3)
            switch Int.random(in: 0..<100, using: &random) {
            case 0..<55:
                editor.transact { change(&$0) }
            case 55..<65:
                editor.transact { tx in for _ in 0..<Int.random(in: 2...6, using: &random) { change(&tx) } }
            case 65..<75:                                        // a drag, the rows read after every step of it
                guard let id = anyShape() else { continue }
                for _ in 0..<Int.random(in: 1...4, using: &random) {
                    editor.transact { tx in
                        tx.update(id) { $0.box?.origin.y += 3 }
                        tx.update(id, as: Widget.self) { $0.props.count += 1 }
                    }
                    guard matches(after: step) else { return }
                }
            case 75..<77:                                        // many rows moving at once
                editor.transact { tx in for id in someShapes(90) { tx.bringToFront(id) } }
            case 77:                                             // another board opened in its place
                var shapes = editor.document.shapes.filter { _ in chance(97) }
                shapes.shuffle(using: &random)
                editor.replaceDocument(with: CanvasDocument(shapes: shapes + (0..<3).map { _ in newShape() }))
            case 78..<80 where step >= 2000:                    // two rows naming each other: a loop (late on, since loops last)
                let named = editor.document.shapes.filter { $0.kind == Pin.kind || $0.kind == Link.kind }.map(\.id)
                guard let a = named.randomElement(using: &random), let b = named.randomElement(using: &random) else { continue }
                editor.transact { tx in
                    for (id, other) in [(a, b), (b, a)] {
                        tx.update(id, as: Pin.self) { $0.props.target = other }
                        tx.update(id, as: Link.self) { $0.props.target = other }
                    }
                }
            case 80..<83:
                editor.selectedShapeIDs = someShapes(8)
            case 83..<93:
                editor.selectedShapeIDs = []
            case 93..<96:
                editor.contents.showAll()
            default:
                editor.contents.select(Set(someShapes(4)))
            }
            guard chance(40) else { continue }
            guard matches(after: step) else { return }
        }
        expect(editor.document.shapes.count > 20, "the board didn't empty: \(editor.document.shapes.count) shapes")
    },
])
