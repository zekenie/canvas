import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import ContextMenus
import Find
import Keyboard
import LineRows
import Selection
import TestKit
import TextEditing

/// Tallies on a real canvas in an unshown window, where the keys and the first responder are the point: keys sent as the
/// app routes them, the session's view read from the canvas.
@MainActor
final class Bench {
    let h: EditorHarness
    var editor: CanvasEditor { h.editor }
    let log = TallyLog()
    let refusals = RefusalLog()
    let window: NSWindow
    let canvas: CanvasView
    /// The editor's pasteboard: the test's own, never the person's.
    let pasteboard = NSPasteboard.withUniqueName()

    /// With `find`, Find and the tallies' entries as its texts, a text an entry by its id.
    init(find: Bool = false) throws {
        let finding: [any CanvasPlugin] = find ? [FindPlugin(), TallyFindPlugin()] : []
        h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin()] + finding
                              + [LineRowsPlugin(), TalliesPlugin(log: log), FreezingPlugin(log: refusals), PasteboardPlugin(pasteboard: pasteboard)])
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas = CanvasView(editor: h.editor)
        window.contentView = canvas
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    }

    isolated deinit {
        pasteboard.releaseGlobally()
    }

    /// A tally called `name`, its entries read from `lines`, in a step of its own.
    @discardableResult
    func tally(_ name: String, _ lines: [String], at origin: CGPoint = CGPoint(x: 100, y: 100)) -> ShapeID {
        let rows = lines.map { line -> TallyRow in
            let words = line.split(separator: " ").map(String.init)
            var row = TallyRow(words[0])
            if words.count > 1, let count = Int(words[1]) { row.count = count }
            return row
        }
        let id = h.add(Tally(CGRect(origin: origin, size: CGSize(width: 240, height: 40)), name: name, rows: rows))
        editor.undoHistory.seal()
        return id
    }

    /// Its entries' labels, in order.
    func labels(_ id: ShapeID) -> [String] { rows(id).map(\.label) }
    func rows(_ id: ShapeID) -> [TallyRow] { editor.document[id]?.typed(as: Tally.self)?.props.rows ?? [] }

    var view: LineRowsView? { canvas.descendants(LineRowsView.self).first }
    var field: LineField { view!.field }

    /// Edits `id` as Return on it does: no press, so at its waiting line.
    func begin(_ id: ShapeID, at point: CGPoint? = nil) {
        editor.selectedShapeIDs = [id]
        editor.beginEditing(id, at: point)
        window.settle()
    }

    /// Where the caret is: "row <label>", "waiting", or nil when nothing's edited.
    var focus: String? {
        guard let view, editor.editingShapeID != nil else { return nil }
        switch view.focus {
        case .title: return "title"
        case .waiting: return "waiting"
        case .row(let row):
            guard let id = editor.editingShapeID else { return nil }
            return "row " + (rows(id).first { $0.id == row }?.label ?? "?")
        }
    }

    /// The menus a row's card asked to pop up: never put on screen, where one would wait for a click.
    var menus: [NSMenu] = []

    /// A row's card showing has its menus given to `menus`.
    func holdMenus() {
        guard let card = canvas.cardView as? LineCardView, card.menuPresenter == nil else { return }
        card.menuPresenter = { [weak self] in self?.menus.append($0) }
    }

    func press(_ chord: Chord, times: Int = 1) {
        for _ in 0..<times {
            holdMenus()
            window.press(chord)
            window.settle()
        }
    }

    func type(_ text: String) {
        window.type(text)
        window.settle()
    }

    /// A key held: one press and `repeats` repeats, then let go.
    func hold(_ chord: Chord, repeats: Int) {
        KeyDriver(window).hold(chord, repeats: repeats)
        window.settle()
    }

    var undoName: String? { editor.undoHistory.undoName }

    /// The canvas drawn once, what the tallies' renders drew logged afresh.
    func drawn() -> [String] {
        log.drawn = []
        _ = renderBitmap(editor, size: CGSize(width: 600, height: 400))
        return log.drawn
    }
}

extension Chord {
    static let optionUp = Chord(Key.up, .option)
    static let optionDown = Chord(Key.down, .option)
    static let commandUp = Chord(Key.up, .command)
    static let commandDown = Chord(Key.down, .command)
    static let shiftReturn = Chord(Key.return, .shift)
    static let commandDelete = Chord(Key.delete, .command)
}

/// Gives the editor a pasteboard, as Clipboard does in the app: the test's own.
struct PasteboardPlugin: CanvasPlugin {
    let pasteboard: NSPasteboard
    var id: PluginID { "test-pasteboard" }

    func register(into registrar: inout PluginRegistrar) {
        let pasteboard = pasteboard
        registrar.pasteboard { _ in pasteboard }
    }
}
