import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Geometry
import TestKit

// The canvas as VoiceOver sees it (ShapeElements.swift): a layout area named for its board, whose
// children are its shapes as layout items, said as the plugins describe them, the selection its focus.
// On a probe kind with a label and a description of its own, a selection the test keeps, and states a
// second plugin adds.

/// A box with a name, said first: "Alpha, Spot".
struct Spot: BoxShapeProps {
    static let kind: ShapeKind = "spot"
    static let properties = Properties<Spot> {
        Property("frame", \.frame).required()
        Property("name", \.name)
    }
    var frame: CGRect
    var name: String
}

extension Spot {
    init() { self.init(frame: .zero, name: "") }
    init(_ name: String, at origin: CGPoint, size: CGFloat = 100) {
        self.init(frame: CGRect(origin: origin, size: CGSize(width: size, height: size)), name: name)
    }
}

struct SpotDefinition {}

extension SpotDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Spot>, in context: RenderContext) {}
}

/// A box edited in two fields, as a typed note is in its words and its rows: an editing view with more than one control.
struct Duo: BoxShapeProps {
    static let kind: ShapeKind = "duo"
    static let properties = Properties<Duo> { Property("frame", \.frame).required() }
    var frame: CGRect
}

extension Duo {
    init() { self.init(frame: .zero) }
}

struct DuoDefinition {}

extension DuoDefinition: ShapeDefinition, Editable {
    func render(_ shape: ShapeRecord<Duo>, in context: RenderContext) {}
    func makeEditingView(for shape: ShapeRecord<Duo>, context: EditContext<Duo>) -> EditingView {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let words = NSTextField(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        let row = NSTextField(frame: CGRect(x: 0, y: 50, width: 200, height: 40))
        row.cell?.setAccessibilityLabel("Row")
        view.addSubview(words)
        view.addSubview(row)
        return EditingView(view: view, firstResponder: words)
    }
}

/// What the probe plugins read: the selection, the shapes said to be frozen, the names of the other
/// kinds' shapes.
@MainActor final class AccessibilityProbeState {
    var selection: [ShapeID] = []
    var frozen: Set<ShapeID> = []
    var names: [ShapeID: String] = [:]
}

/// A canvas 800 × 600 in an unshown window, its editor with spots, the cards (editable), pockets (each
/// owning a board) and the probe's selection, names and states.
@MainActor func accessibleCanvas(_ probe: AccessibilityProbeState) throws -> (h: EditorHarness, window: NSWindow, canvas: CanvasView) {
    let h = try EditorHarness(plugins: [FixturesPlugin(), CardsPlugin(), PocketsPlugin(), Contributor(id: "spots") { r in
        r.shape(DuoDefinition()) { duo in duo.label("Duo", systemImage: "square") }
        r.shape(SpotDefinition()) { spot in
            spot.label("Spot", systemImage: "circle")
            spot.accessibility { record, _ in AccessibleTraits(name: record.props.name) }
        }
        r.commandShapes({ _ in probe.selection }, select: { editor, ids in
            probe.selection = ids
            editor.accessibilityFocusDidChange()
        })
        r.forEveryShape { every in every.accessibility { record, _ in AccessibleTraits(name: probe.names[record.id]) } }
    }, Contributor(id: "states") { r in
        r.forShapes(adopting: .box) { boxes in
            boxes.accessibility { record, _ in
                probe.frozen.contains(record.id) ? AccessibleTraits(labelParts: ["Probe"], value: "held", states: ["frozen"], help: "Unlock to change") : nil
            }
        }
    }])
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let canvas = CanvasView(editor: h.editor)
    window.contentView = canvas
    return (h, window, canvas)
}

/// The children that are shapes, by their ids.
@MainActor func shapeChildren(_ canvas: CanvasView) -> [NSAccessibilityElement] {
    (canvas.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.filter { $0.accessibilityRole() == .layoutItem }
}

@MainActor func labels(_ elements: [NSAccessibilityElement]) -> [String] { elements.map { $0.accessibilityLabel() ?? "?" } }

/// Selects as the probe's plugin does (VoiceOver's press, Tab's step).
@MainActor func select(_ ids: [ShapeID], _ h: EditorHarness) { expect(h.editor.selectForAccessibility(ids)) }

@MainActor let canvasAccessibilityTests = Suite("Canvas accessibility", [
    test("the canvas is a layout area named for its board: the file's name, else Canvas, and inside a shape's board that shape's name") {
        let probe = AccessibilityProbeState()
        let (h, _, canvas) = try accessibleCanvas(probe)
        expectEqual(canvas.accessibilityRole(), .layoutArea)
        expect(canvas.isAccessibilityElement())
        expectEqual(canvas.accessibilityLabel(), "Canvas", "a root the host hasn't named")
        h.editor.nameRoot("Plans")
        expectEqual(canvas.accessibilityLabel(), "Plans")
        let pocket = h.add(Pocket(CGRect(x: 0, y: 0, width: 200, height: 200)))
        probe.names[pocket] = "Sprint"
        expect(h.enter(pocket))
        expectEqual(canvas.accessibilityLabel(), "Sprint")
    },
    test("a shape is said as every plugin describes it: its name, its kind, what else it is and its states, joined; the first value and help") {
        let probe = AccessibilityProbeState()
        let (h, _, canvas) = try accessibleCanvas(probe)
        let alpha = h.add(Spot("Alpha", at: CGPoint(x: 100, y: 100)))
        let card = h.add(Card(CGRect(x: 300, y: 100, width: 100, height: 60)))
        expectEqual(h.editor.accessibleDescription(of: alpha)?.label, "Alpha, Spot")
        expectEqual(h.editor.accessibleDescription(of: card)?.label, "Card", "untitled: its kind, its tool's label")
        probe.names[card] = "Draft"
        probe.frozen = [alpha]
        let said = try require(h.editor.accessibleDescription(of: alpha))
        expectEqual(said.label, "Alpha, Spot, Probe, frozen", "the kind's own name first, though the every-shape plugin's came before it")
        expectEqual(said.name, "Alpha")
        expectEqual(said.kind, "Spot")
        expectEqual(said.value, "held")
        expectEqual(said.help, "Unlock to change")
        expectEqual(h.editor.accessibleDescription(of: card)?.label, "Draft, Card")
        let element = try require(shapeChildren(canvas).first { $0.accessibilityLabel() == "Alpha, Spot, Probe, frozen" })
        expectEqual(element.accessibilityValue() as? String, "held")
        expectEqual(element.accessibilityHelp(), "Unlock to change")
        expectEqual(h.editor.registry.report.contains("accessibility → spot"), true, "the registry's report names the kind's own")
        expectEqual(h.editor.registry.report.contains("accessibility → every shape with a box"), true)
    },
    test("the children are the shapes in view in paint order, the selection first even out of view, then the views the canvas hosts") {
        let probe = AccessibilityProbeState()
        let (h, _, canvas) = try accessibleCanvas(probe)
        let alpha = h.add(Spot("Alpha", at: CGPoint(x: 100, y: 100)))
        _ = h.add(Spot("Beta", at: CGPoint(x: 400, y: 100)))
        let far = h.add(Spot("Far", at: CGPoint(x: 5000, y: 5000)))
        expectEqual(labels(shapeChildren(canvas)), ["Alpha, Spot", "Beta, Spot"])
        select([far], h)
        expectEqual(labels(shapeChildren(canvas)), ["Far, Spot", "Alpha, Spot", "Beta, Spot"], "the selection, out of view, first")
        canvas.showsMinimap = true
        let hosted = (canvas.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        expect(hosted.contains { $0 === canvas.minimap }, "the minimap after the shapes")
        expectEqual(canvas.minimap?.accessibilityValue() as? String, "Showing 2 of 3 shapes")
        expect(shapeChildren(canvas).allSatisfy { $0.accessibilityParent() as AnyObject === canvas })
        expectEqual(shapeChildren(canvas).map { $0.isAccessibilitySelected() }, [true, false, false])
        expectEqual(canvas.accessibilitySelectedChildren()?.count, 1)
        _ = alpha
    },
    test("past 500, those nearest the selection, the selection always among them") {
        let probe = AccessibilityProbeState()
        let (h, _, canvas) = try accessibleCanvas(probe)
        var grid: [[ShapeID]] = []
        h.editor.transact { t in
            for row in 0..<25 {
                var line: [ShapeID] = []
                for column in 0..<32 {
                    let record = ShapeRecord(Spot("\(row).\(column)", at: CGPoint(x: column * 25, y: row * 24), size: 20))
                    t.insert(record)
                    line.append(record.id)
                }
                grid.append(line)
            }
        }
        let far = h.add(Spot("Far", at: CGPoint(x: 5000, y: 5000)))
        expectEqual(shapeChildren(canvas).count, 500, "800 in view")
        select([grid[0][0], far], h)
        let ids = Set(h.editor.accessibleShapes(limit: 500))
        expectEqual(ids.count, 500)
        expect(ids.contains(far) && ids.contains(grid[0][0]), "the selection")
        expect(ids.contains(grid[1][1]), "beside the selection")
        expect(!ids.contains(grid[24][31]), "the far corner of the view")
        expectEqual(shapeChildren(canvas).count, 500)
        // Every one selected (⌘A): the selected children are those VoiceOver is given, not an element each.
        select(grid.flatMap { $0 } + [far], h)
        let selected = (canvas.accessibilitySelectedChildren() ?? []).map { $0 as AnyObject }
        expectEqual(selected.count, 500, "the selection VoiceOver is given, of 801")
        let given = Set(shapeChildren(canvas).map(ObjectIdentifier.init))
        expect(selected.allSatisfy { given.contains(ObjectIdentifier($0)) }, "each one of the children")
    },
    test("a part's role, label, frame and focus are asked of one listing of its shape's parts, listed again once the camera moves or a part is pressed") {
        final class Count { var listings = 0, presses = 0 }
        let count = Count()
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "parts") { r in
            r.accessibleParts({ _, _ in
                count.listings += 1
                return (0..<4).map { index in
                    AccessiblePart(id: index, title: "Part \(index)", role: .button, rect: CGRect(x: 100 + index * 20, y: 100, width: 10, height: 10)) { _ in
                        count.presses += 1
                    }
                }
            }, focused: { _ in nil })
        }])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let canvas = CanvasView(editor: h.editor)
        window.contentView = canvas
        _ = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let element = try require(shapeChildren(canvas).first)
        let parts = (element.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        expectEqual(parts.count, 4)
        for part in parts {
            _ = part.accessibilityRole()
            _ = part.accessibilityLabel()
            _ = part.accessibilityFrame()
            _ = part.isAccessibilityFocused()
        }
        expectEqual(count.listings, 1, "one listing for every question of every part")
        h.editor.camera = Camera(origin: CGPoint(x: 10, y: 0), zoom: 1)
        expectEqual(parts[0].accessibilityLabel(), "Part 0")
        _ = parts[1].accessibilityLabel()
        expectEqual(count.listings, 2, "the camera moved: listed again, once")
        expect(parts[0].accessibilityPerformPress())
        expectEqual(count.presses, 1)
        _ = parts[1].accessibilityLabel()
        expectEqual(count.listings, 3, "pressed: listed again")
    },
    test("an element is the same across a pan, and its frame follows the camera without the children worked out again") {
        let probe = AccessibilityProbeState()
        let (h, _, canvas) = try accessibleCanvas(probe)
        let alpha = h.add(Spot("Alpha", at: CGPoint(x: 100, y: 100)))
        let element = try require(shapeChildren(canvas).first)
        let builds = canvas.accessibleChildrenBuilds
        let before = element.accessibilityFrame()
        expectEqual(before.size, CGSize(width: 100, height: 100))
        let viewBefore = h.editor.camera.toView(CGPoint(x: 100, y: 100))
        h.editor.camera.pan(by: CGSize(width: 120, height: 40))
        let moved = h.editor.camera.toView(CGPoint(x: 100, y: 100)) - viewBefore
        let after = element.accessibilityFrame()
        expectEqual(after.minX - before.minX, moved.x)
        expectEqual(after.maxY - before.maxY, -moved.y, "screen coordinates go up")
        expectEqual(canvas.accessibleChildrenBuilds, builds, "a frame is asked for, never kept")
        _ = shapeChildren(canvas)
        _ = shapeChildren(canvas)
        expectEqual(canvas.accessibleChildrenBuilds, builds + 1, "the camera moved: once, then kept")
        expect(shapeChildren(canvas).first === element, "the same element")
        h.editor.transact { $0.update(alpha, as: Spot.self) { $0.props.name = "Renamed" } }
        expectEqual(element.accessibilityLabel(), "Renamed, Spot", "said as it is now")
    },
    test("the focused element follows the selection, VoiceOver hears it move, and how many are selected; a press selects") {
        let probe = AccessibilityProbeState()
        let (h, window, canvas) = try accessibleCanvas(probe)
        let alpha = h.add(Spot("Alpha", at: CGPoint(x: 100, y: 100)))
        let beta = h.add(Spot("Beta", at: CGPoint(x: 400, y: 100)))
        select([alpha], h)
        window.settle()
        expectEqual(canvas.accessibilityPosts, [], "nothing is posted before an assistive app asks")
        expect(canvas.accessibilityFocusedUIElement as AnyObject !== canvas)
        let elements = shapeChildren(canvas)
        expect(canvas.accessibilityFocusedUIElement as AnyObject === elements[0], "the selected shape's")
        select([], h)
        window.settle()
        expect(canvas.accessibilityFocusedUIElement as AnyObject === canvas, "nothing selected: the canvas")
        expectEqual(canvas.accessibilityPosts, [.focusedUIElementChanged])
        let betaElement = try require(shapeChildren(canvas).first { $0.accessibilityLabel() == "Beta, Spot" })
        expect(betaElement.accessibilityPerformPress())
        window.settle()
        expectEqual(probe.selection, [beta])
        expect(betaElement.isAccessibilityFocused())
        select([beta, alpha], h)
        window.settle()
        expect((canvas.accessibilityFocusedUIElement as? NSAccessibilityElement)?.accessibilityLabel() == "Alpha, Spot", "the last selected")
        expectEqual(canvas.accessibilityPosts, [.focusedUIElementChanged, .focusedUIElementChanged, .focusedUIElementChanged,
                                                .selectedChildrenChanged, .announcementRequested])
        expectEqual(h.editor.announcements, ["2 selected"])
        // The window's focus, as VoiceOver asks it, while the canvas has the keyboard.
        window.makeFirstResponder(canvas)
        AccessibilityProbe.expectNamed(AccessibilityProbe.focused(in: window), "the selection")
        expectEqual(AccessibilityProbe.focused(in: window).map(AccessibilityProbe.label(of:)), "Alpha, Spot")
    },
    test("while another view has the keyboard (a list that selects as it's walked), the selection is no focus VoiceOver is told of") {
        let probe = AccessibilityProbeState()
        let (h, window, canvas) = try accessibleCanvas(probe)
        let alpha = h.add(Spot("Alpha", at: CGPoint(x: 100, y: 100)))
        let beta = h.add(Spot("Beta", at: CGPoint(x: 400, y: 100)))
        let elements = shapeChildren(canvas)
        h.editor.keyboardDidChange(hasKeyboard: false)
        select([alpha], h)
        window.settle()
        select([alpha, beta], h)
        window.settle()
        expectEqual(canvas.accessibilityPosts, [], "nothing said over the list's row")
        expectEqual(h.editor.announcements, [])
        expect(!elements[0].isAccessibilityFocused() && !elements[1].isAccessibilityFocused())
        expect(canvas.accessibilityFocusedUIElement as AnyObject === canvas)
        h.editor.keyboardDidChange(hasKeyboard: true)
        expect(elements[1].isAccessibilityFocused(), "the canvas has it back: the last selected")
        select([beta], h)
        window.settle()
        expectEqual(canvas.accessibilityPosts, [.focusedUIElementChanged])
    },
    test("an announcement reaches the canvas, and the editor keeps it") {
        let probe = AccessibilityProbeState()
        let (h, _, canvas) = try accessibleCanvas(probe)
        h.editor.announce("Saved", priority: .low)
        expectEqual(h.editor.announcements, ["Saved"])
        expectEqual(canvas.accessibilityPosts, [.announcementRequested])
    },
    test("VoiceOver hears the layout changed once a commit adds or takes a shape it sees, never for one out of view or a change") {
        let probe = AccessibilityProbeState()
        let (h, window, canvas) = try accessibleCanvas(probe)
        let alpha = h.add(Spot("Alpha", at: CGPoint(x: 100, y: 100)))
        _ = shapeChildren(canvas)
        @MainActor func layoutChanges() -> Int { canvas.accessibilityPosts.filter { $0 == .layoutChanged }.count }
        _ = h.add(Spot("Beta", at: CGPoint(x: 400, y: 100)))
        _ = h.add(Spot("Gamma", at: CGPoint(x: 500, y: 100)))
        window.settle()
        expectEqual(layoutChanges(), 1, "two commits in one turn: once")
        let far = h.add(Spot("Far", at: CGPoint(x: 5000, y: 5000)))
        h.editor.transact { $0.update(alpha, as: Spot.self) { $0.props.name = "Renamed" } }
        window.settle()
        expectEqual(layoutChanges(), 1, "out of view, and a change")
        h.editor.transact { $0.delete([far]) }
        window.settle()
        expectEqual(layoutChanges(), 1, "one VoiceOver never saw")
        _ = shapeChildren(canvas)
        h.editor.transact { $0.delete([alpha]) }
        window.settle()
        expectEqual(layoutChanges(), 2)
    },
    test("the shape being edited names its editing view for VoiceOver, which is its element's child") {
        let probe = AccessibilityProbeState()
        let (h, window, canvas) = try accessibleCanvas(probe)
        let card = h.add(Card(CGRect(x: 100, y: 100, width: 200, height: 100)))
        probe.names[card] = "Draft"
        _ = shapeChildren(canvas)
        expect(h.editor.beginEditing(card))
        let field = try require(window.firstResponder.flatMap { ($0 as? NSTextView)?.delegate as? CardField } ?? (window.firstResponder as? CardField))
        expectEqual(field.accessibilityLabel(), "Draft, Card")
        let element = try require(shapeChildren(canvas).first { $0.accessibilityLabel() == "Draft, Card" })
        expect(field.accessibilityParent() as AnyObject === element)
        expect(element.accessibilityChildren()?.first as AnyObject === NSAccessibility.unignoredDescendant(of: field) as AnyObject, "the field, as AppKit shows it (its cell)")
        let hosted = (canvas.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        expect(!hosted.contains { $0 === field || $0.isDescendant(of: field) }, "under its shape, not beside it")
    },
    test("every control of the editing view is its shape's element's child, not only the first responder; editing ended, its parts again") {
        let probe = AccessibilityProbeState()
        let (h, window, canvas) = try accessibleCanvas(probe)
        let duo = h.add(Duo(frame: CGRect(x: 100, y: 100, width: 200, height: 100)))
        _ = shapeChildren(canvas)
        expect(h.editor.beginEditing(duo))
        let element = try require(shapeChildren(canvas).first { $0.accessibilityLabel() == "Duo" })
        let controls = (element.accessibilityChildren() ?? []).compactMap { $0 as? NSTextFieldCell }
        expectEqual(controls.count, 2, "the words and the row, as AppKit shows them (their cells)")
        let row = try require(controls.first { $0.accessibilityLabel() == "Row" })
        expect(row.accessibilityParent() as AnyObject === element, "the row's way up is the shape")
        h.editor.endEditing()
        window.settle()
        expect(!(element.accessibilityChildren() ?? []).contains { $0 as AnyObject === row }, "a view no longer in the window is no child")
        expect(row.accessibilityParent() as AnyObject !== element)
    },
    test("the editing view is named when VoiceOver first asks during editing too") {
        let probe = AccessibilityProbeState()
        let (h, window, canvas) = try accessibleCanvas(probe)
        let card = h.add(Card(CGRect(x: 100, y: 100, width: 200, height: 100)))
        expect(h.editor.beginEditing(card))
        let field = try require(window.firstResponder.flatMap { ($0 as? NSTextView)?.delegate as? CardField } ?? (window.firstResponder as? CardField))
        expect((field.accessibilityLabel() ?? "").isEmpty, "nothing asked yet")
        _ = canvas.accessibilityChildren()
        expectEqual(field.accessibilityLabel(), "Card")
    },
])
