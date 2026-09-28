import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TableOfContents
import TestKit

// Rows read from more than their shape (`contentsRow(affected:)`), as a note's row will show the
// names of the shapes it mentions: a ref's row shows the name of the widget it refers to.

/// A box that refers to another shape. Its row shows that shape's name, read through `RefIndex`, so
/// a commit that renames the shape changes the row without changing the ref.
struct Ref: BoxShapeProps {
    static let kind: ShapeKind = "ref"
    static let properties = Properties<Ref> {
        Property("frame", \.frame).required()
        Property("target", \.target)
    }
    var frame: CGRect
    var target: ShapeID?
    init(to target: ShapeID?) {
        frame = widgetFrame
        self.target = target
    }
}

extension Ref {
    init() { self.init(to: nil) }
}

struct RefDefinition {}

extension RefDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Ref>, in context: RenderContext) {}
}

/// Which refs refer to each shape, kept as the board changes, as a plugin's service keeps what it
/// knows: what a ref's row reads besides the ref (the name of the shape it refers to), and which
/// refs' rows a commit may change without changing them (those referring to a shape it changed),
/// each commit's worth in what the commit changed.
@MainActor
final class RefIndex {
    private unowned let editor: CanvasEditor
    private var referrers: [ShapeID: Set<ShapeID>] = [:]
    private var targets: [ShapeID: ShapeID] = [:]

    init(editor: CanvasEditor) {
        self.editor = editor
        index(editor.document.shapes.map(\.id))
    }

    /// The name of the widget `id` names, "nothing" for none.
    func name(of id: ShapeID?) -> String {
        id.flatMap { editor.document[$0]?.typed(as: Widget.self)?.props.name } ?? "nothing"
    }

    /// The refs that refer to any of `ids`.
    func refs(to ids: Set<ShapeID>) -> Set<ShapeID> {
        ids.reduce(into: []) { $0.formUnion(referrers[$1] ?? []) }
    }

    private func index(_ ids: some Sequence<ShapeID>) {
        for id in ids {
            if let old = targets.removeValue(forKey: id) { referrers[old]?.remove(id) }
            guard let target = editor.document[id]?.typed(as: Ref.self)?.props.target else { continue }
            targets[id] = target
            referrers[target, default: []].insert(id)
        }
    }
}

extension RefIndex: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) { index(changes.shapeIDs) }
}

/// How often a ref's row has been made.
@MainActor var refRowsMade = 0

/// Refs, with their index, and their rows: `bridged` gives the kind its row as a bridge would.
struct RefsPlugin: CanvasPlugin {
    var bridged = false
    var id: PluginID { "refs" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.service { RefIndex(editor: $0) }
        let affected: @MainActor (ChangeSet, ContentsContext) -> Set<ShapeID> = { changes, context in
            context.service(RefIndex.self)?.refs(to: changes.shapeIDs) ?? []
        }
        let row: @MainActor (ShapeRecord<Ref>, ContentsContext) -> ContentsLabel = { ref, context in
            refRowsMade += 1
            return ContentsLabel("→ " + (context.service(RefIndex.self)?.name(of: ref.props.target) ?? "?"), systemImage: "arrow.right")
        }
        registrar.shape(RefDefinition()) { ref in
            if !bridged { ref.contentsRow(affected: affected, row) }
        }
        if bridged { registrar.contentsRow(Ref.self, affected: affected, row) }
    }
}

/// The keyboard, the selection, the fixtures, widgets, refs, then `more`, and the table of
/// contents, so the refs' index hears of each commit before the table of contents does.
@MainActor func refsEditor(bridged: Bool = false, _ more: [any CanvasPlugin] = [], scheduler: any Scheduler = ManualScheduler()) throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), WidgetsPlugin(), RefsPlugin(bridged: bridged)]
                                            + more + [TableOfContentsPlugin()]),
                 scheduler: scheduler)
}

@MainActor let affectedRowTests = Suite("Table of contents: rows read from more than their shape", [
    test("a row shows what it reads as it is now: a rename makes the rows of the refs to the shape again, and no others") {
        let editor = try refsEditor()
        let (a, b, _) = threeWidgets(editor)
        editor.add(Ref(to: a))
        editor.add(Ref(to: b))
        editor.add(Ref(to: nil))
        expectEqual(editor.contents.entries.outline, ["A", "B", "C", "→ A", "→ B", "→ nothing"])
        let made = refRowsMade
        editor.transact { $0.update(a, as: Widget.self) { $0.props.name = "Renamed" } }
        expectEqual(editor.contents.entries.outline, ["Renamed", "B", "C", "→ Renamed", "→ B", "→ nothing"])
        expectEqual(refRowsMade, made + 1, "the ref to A's alone")
        editor.transact { $0.delete([b]) }
        expectEqual(editor.contents.entries.outline, ["Renamed", "C", "→ Renamed", "→ nothing", "→ nothing"])
        expectEqual(refRowsMade, made + 2, "the ref to B's")
    },
    test("given as a bridge gives it, the row is the same, and a name from another plugin still takes the place of its title") {
        let names = Contributor(id: "names") { r in r.contentsTitle(Ref.self) { $0.props.target == nil ? "Aimless" : nil } }
        let editor = try refsEditor(bridged: true, [names])
        let (a, _, _) = threeWidgets(editor)
        editor.add(Ref(to: a))
        editor.add(Ref(to: nil))
        expectEqual(editor.contents.entries.outline, ["A", "B", "C", "→ A", "Aimless"])
        expectEqual(editor.contents.entries.last?.label?.systemImage, "arrow.right", "the row's symbol stays")
        editor.transact { $0.update(a, as: Widget.self) { $0.props.name = "Renamed" } }
        expectEqual(editor.contents.entries.outline, ["Renamed", "B", "C", "→ Renamed", "Aimless"])
    },
    test("rows made again are replaced, and redrawn, only where their labels changed") {
        let editor = try refsEditor(scheduler: TaskScheduler())
        let (a, b, _) = threeWidgets(editor)
        editor.add(Ref(to: a))
        editor.add(Ref(to: a))
        editor.add(Ref(to: b))
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 6 }
        w.window.settle()
        let contents = editor.contents
        /// How many rows the list redraws for `change`: once one has, and a few more turns of the run
        /// loop have passed.
        @MainActor func redrawn(_ change: () -> Void) -> Int {
            let before = contents.rowsRedrawn
            change()
            w.window.spin { contents.rowsRedrawn > before }
            w.window.settle()
            return contents.rowsRedrawn - before
        }
        var made = refRowsMade
        let moved = redrawn { editor.transact { $0.update(a, as: Widget.self) { $0.props.frame.origin.x += 10 } } }
        expectEqual(refRowsMade, made + 2, "both refs to A made again")
        expectEqual(moved, 1, "A's row alone redrawn: the refs' read the same")
        made = refRowsMade
        let renamed = redrawn { editor.transact { $0.update(a, as: Widget.self) { $0.props.name = "Renamed" } } }
        expectEqual(refRowsMade, made + 2)
        expectEqual(renamed, 3, "A's row and both refs' rows, not B's or its ref's")
        expectEqual(contents.entries.outline, ["Renamed", "B", "C", "→ Renamed", "→ Renamed", "→ B"])
    },
    test("read by a service that hears of a commit first, rows read from more than their shape are made again, and stay right") {
        let reader = Contributor(id: "early-reader") { $0.service { _ in EarlyReader() } }
        let editor = try refsEditor([reader])
        let early = try require(editor.service(EarlyReader.self))
        let (a, b, _) = threeWidgets(editor)
        editor.add(Ref(to: a))
        editor.add(Ref(to: b))
        _ = editor.contents.entries
        early.reads = true
        editor.transact { $0.update(a, as: Widget.self) { $0.props.name = "Renamed" } }
        expectEqual(early.heard, ["Renamed", "B", "C", "→ Renamed", "→ B"], "as the reader read them, before the table of contents heard")
        early.reads = false
        expectEqual(editor.contents.entries.outline, ["Renamed", "B", "C", "→ Renamed", "→ B"])
        editor.transact { $0.update(b, as: Widget.self) { $0.props.name = "Bee" } }
        expectEqual(editor.contents.entries.outline, ["Renamed", "Bee", "C", "→ Renamed", "→ Bee"])
    },
])
