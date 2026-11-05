import Adornments
import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Clipboard
import Colors
import CoreGraphics
import DetailPanel
import Frames
import Geometry
import LanguageModels
import Mentions
import Palette
import Queries
import Selection
import SlashCommands
import ShippedTesting
import StickyNotes
import SwiftUI
import Subboards
import TestKit
import Titles
import Types
import Validation

// Frames and subboards of types, as shipped: a frame or a subboard given a type shows its chip above it,
// has the type in its menus and the command bar, its values in the panel, its checks as issues, its type's
// color, its type in what VoiceOver says, and is drawn, queried, turned and copied with it. Only a note
// can be a type; neither draws rows on the canvas.

/// A schema with a required `owner` and an optional `budget`.
private let projectSchema = #"{"type": "object", "properties": {"owner": {"type": "string"}, "budget": {"type": "number"}}, "required": ["owner"]}"#

/// An empty board as shipped, with the type Project on it, a titled frame (Q4 launch), a titled subboard
/// (Payments) and a plain note, none of them yet of it.
@MainActor private final class Typed {
    let h: EditorHarness
    var editor: CanvasEditor { h.editor }
    let project: ShapeID, frame: ShapeID, sub: ShapeID, note: ShapeID

    init(model: ScriptedLanguageModel = ScriptedLanguageModel(), schema: String = projectSchema) {
        h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, model: model) }
        project = h.editor.addTypeNote(schema, title: "Project", frame: CGRect(x: 800, y: 100, width: 200, height: 200))
        frame = h.editor.add(Frame(frame: CGRect(x: 100, y: 300, width: 500, height: 300)), title: "Q4 launch")
        sub = h.editor.add(Subboard(frame: CGRect(x: 700, y: 400, width: 240, height: 160)), title: "Payments")
        note = h.editor.add(StickyNote(frame: CGRect(x: 120, y: 340, width: 200, height: 200), text: "Plan"))
    }

    /// The chips of a shape, in the row above it.
    func chips(_ id: ShapeID) -> [AdornmentFrame] { editor.adornmentFrames(of: id).filter { $0.adornment == .of(TypeChips.self) } }
    func types(_ id: ShapeID) -> [ShapeID] { editor.document[id]?[IsAProperty.self]?.map(\.shape) ?? [] }
    /// The shape on the board with this title.
    func shape(titled title: String) -> ShapeID? { editor.document.shapes.first { $0[TitleProperty.self] == title }?.id }
    /// The shape's issues, as Validation says them.
    func issues(_ id: ShapeID) -> [ValidationIssue] {
        _ = editor.validation?.results
        return editor.validation?.result(for: id)?.issues ?? []
    }
    /// The titles of a panel's tabs for a shape, and the one it opens on.
    func tabs(of id: ShapeID) throws -> (titles: [String], current: String?) {
        let panel = try require(editor.detailPanel)
        let layout = panel.layout(for: try require(editor.document[id]))
        return (layout.tabs.map(\.title), panel.currentTab(in: layout, for: try require(editor.document[id]).kind)?.title)
    }
}

/// Owns, a relationship type from Project to Team, a Project needing one; two Teams (a subboard, Core, and a note, Ops) and a
/// second Project subboard, Billing.
private let ownsStory = #"""
sticky-note "Owns" right of "Project" relationship: true schema: "{\"type\": \"object\"}" text: "Ownership"
sticky-note "Team" right of "Owns" schema: "{\"type\": \"object\"}" text: "A team"
edge "Project" -> "Owns" text: "owns" endRule: {"needed": true}
edge "Owns" -> "Team" text: "owned by"
subboard "Core" below "Team" is: "Team"
sticky-note "Ops" right of "Team" is: "Team"
subboard "Billing" below "Core" is: "Project"
"""#

/// The ids a query finds.
@MainActor private func found(_ query: String, in editor: CanvasEditor) throws -> [ShapeID] {
    let queries = try require(editor.queries)
    return try awaitResult { try await queries.run(QueryRequest(query, limit: QueryRequest.every, properties: .none)) }.rows.map(\.id)
}


@MainActor let typedContainersShippedTests = Suite("Typed frames and subboards", [
    test("a frame and a subboard given a type hold it, and its chip is laid out above each: after the subboard's title pill, above the frame's title tab") {
        let t = Typed()
        t.editor.addTypeLink(t.project, to: t.frame)
        t.editor.addTypeLink(t.project, to: t.sub)
        expectEqual(t.types(t.frame), [t.project])
        expectEqual(t.types(t.sub), [t.project])
        expectEqual(t.editor.types?.instances(of: t.project), [t.frame, t.sub])
        let pill = try require(t.editor.adornmentFrames(of: t.sub).first { $0.adornment == .of(TitlePill.self) }, "the subboard's pill")
        let subChips = t.chips(t.sub)
        expectEqual(subChips.map { $0.label.text ?? "" }, ["Project"])
        expect(subChips[0].rect.minX >= pill.rect.maxX, "after the pill: \(subChips[0].rect) and \(pill.rect)")
        expect(subChips[0].rect.maxY <= 400, "above the card")
        let tab = try require(t.editor.adornmentFrames(of: t.frame).first { $0.adornment == .of(TitleTab.self) }, "the frame's tab")
        let frameChips = t.chips(t.frame)
        expectEqual(frameChips.map { $0.label.text ?? "" }, ["Project"])
        expect(frameChips[0].rect.maxY <= tab.rect.minY, "above the tab: \(frameChips[0].rect) and \(tab.rect)")
        expect(tab.rect.minY < 300, "the tab on the frame's top edge")
    },
    test("a click on a chip pops its menu, Go to “Project” and Remove “Project”, and does not select the shape; a click on the frame's tab still selects the frame") {
        let t = Typed()
        t.editor.viewportDidResize(to: CGSize(width: 1440, height: 900))     // as the app's view: the tabs on view are placed
        t.editor.addTypeLink(t.project, to: t.frame)
        t.editor.addTypeLink(t.project, to: t.sub)
        for shape in [t.frame, t.sub] {
            t.editor.selection = nil
            let chip = try require(t.chips(shape).first)
            // Near the chip's left end: a subboard's top dot is in the middle of its row, and a press on a dot's disc is the dot's.
            t.h.click(at: t.editor.camera.toView(CGPoint(x: chip.rect.minX + 10, y: chip.rect.midY)))
            let (menu, rect) = try require(t.editor.menuToPopUp, "a menu waits")
            expectEqual(menu.items.map(\.title), ["Go to “Project”", "Remove “Project”"])
            expectEqual(rect, chip.rect)
            expect(t.editor.selectedShapeIDs.isEmpty, "a chip is a button: it does not select")
            t.editor.menuDidPopUp()
        }
        let tab = try require(t.editor.adornmentFrames(of: t.frame).first { $0.adornment == .of(TitleTab.self) })
        t.h.click(at: t.editor.camera.toView(tab.rect).center)
        expectEqual(t.editor.selectedShapeIDs, [t.frame], "the tab selects the frame")
        expect(t.editor.menuToPopUp == nil, "and opens no menu")
    },
    test("by keys: selected alone, a typed frame's and subboard's chip is a part ⌥Tab reaches, a menu button named for its type, whose press pops its menu") {
        let t = Typed()
        t.editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        t.editor.addTypeLink(t.project, to: t.frame)
        t.editor.addTypeLink(t.project, to: t.sub)
        for shape in [t.frame, t.sub] {
            t.editor.selection = shape
            let chip = try require(t.chips(shape).first)
            let part = try require(t.editor.shapeParts(of: shape).first { $0.title == "Project" }, "the chip is a part")
            expectEqual(part.role, .menuButton)
            expectEqual(part.rect, chip.rect)
            part.press(t.editor)
            let (menu, _) = try require(t.editor.menuToPopUp, "its press pops the chip's menu")
            expectEqual(menu.items.map(\.title), ["Go to “Project”", "Remove “Project”"])
            t.editor.menuDidPopUp()
        }
    },
    test("in the issue list, a typed frame's and subboard's row ends in its first value, in its fields' order, as a note's does") {
        let t = Typed()
        for shape in [t.frame, t.sub] {
            t.editor.addTypeLink(t.project, to: shape)
            expectEqual(t.editor.registry.issueRowValue(of: try require(t.editor.shape(inFile: shape)), in: t.editor), nil, "no values, none")
            t.editor.transact { $0.update(shape) { $0[FieldValuesProperty.self] = FieldValues(["budget": 1200, "owner": "Cy"]) } }
            expectEqual(t.editor.registry.issueRowValue(of: try require(t.editor.shape(inFile: shape)), in: t.editor), "Cy",
                        "owner comes before budget in the type")
        }
    },
    test("a frame's context menu, a subboard's, and a frame's with a note selected with it have Is a ▸ listing Project and no Type; choosing it is one step, Add Type, undone in one") {
        let t = Typed()
        let frameMenu = try require(t.h.secondaryClick(at: CGPoint(x: 500, y: 450)), "a frame's menu")
        expect(frameMenu.outline.contains("Is a ▸"), "\(frameMenu.outline)")
        let frameSub = try require(frameMenu.item(withTitle: "Is a")?.submenu)
        expectEqual(frameSub.outline, ["Project"], "no Type: a frame cannot be one")
        try frameMenu.choose("Is a", "Project")
        expectEqual(t.types(t.frame), [t.project])
        expectEqual(t.editor.undoHistory.undoName, "Add Type")
        t.editor.undo()
        expectEqual(t.types(t.frame), [])

        let subMenu = try require(t.h.secondaryClick(at: CGPoint(x: 820, y: 480)), "a subboard's menu")
        expectEqual(try require(subMenu.item(withTitle: "Is a")?.submenu).outline, ["Project"], "\(subMenu.outline)")
        try subMenu.choose("Is a", "Project")
        expectEqual(t.types(t.sub), [t.project])
        expectEqual(t.editor.undoHistory.undoName, "Add Type")
        t.editor.undo()
        expectEqual(t.types(t.sub), [])

        t.editor.selectedShapeIDs = [t.frame, t.note]
        let both = try require(t.h.secondaryClick(at: CGPoint(x: 220, y: 440)), "the selection's menu")
        expect(try require(both.item(withTitle: "Is a")?.submenu).outline.contains("Project"), "\(both.outline)")
        try both.choose("Is a", "Project")
        expectEqual([t.types(t.frame), t.types(t.note)], [[t.project], [t.project]])
        expectEqual(t.editor.undoHistory.undoName, "Add Type")
        t.editor.undo()
        expectEqual([t.types(t.frame), t.types(t.note)], [[], []], "one step takes both")
    },
    test("/is-a in the command bar with a frame selected offers Project alone and gives it, one step, Add Type") {
        let t = Typed()
        let (window, canvas) = windowed(t.editor)
        window.makeFirstResponder(canvas)
        t.editor.selection = t.frame
        window.type("/")
        let bar = try require(t.editor.slashBar, "the bar opens")
        expect(bar.typing?.picker?.listed.map(\.name).contains("is-a") == true, "\(bar.typing?.picker?.listed.map(\.name) ?? [])")
        window.type("is-a ")
        expectEqual(bar.typing?.choices?.listed.map(\.title), ["Project"])
        window.pressReturn()
        expect(bar.isOpen != true)
        expectEqual(t.types(t.frame), [t.project])
        expectEqual(t.editor.undoHistory.undoName, "Add Type")
        t.editor.undo()
        expectEqual(t.types(t.frame), [])
    },
    test("/is-a typed on an empty line of a subboard's Description box offers Project and gives it, the line gone") {
        let t = Typed()
        t.editor.selection = t.sub
        let host = NSHostingView(rootView: try require(t.editor.registry.hostInspector).view(for: t.editor, onExit: {}))
        host.frame = CGRect(x: 0, y: 0, width: DetailStyle.idealWidth, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.spin { !host.descendants(MentionTextView<AnyMentionable>.self).isEmpty }
        let box = try require(host.descendants(MentionTextView<AnyMentionable>.self).first, "the description box")
        window.makeFirstResponder(box)
        box.setSelectedRange(NSRange(location: box.textStorage?.length ?? 0, length: 0))
        window.type("/is-a ")
        expectEqual(box.slashCommands?.choices?.listed.map(\.title), ["Project"], "no Type: a subboard cannot be one")
        window.pressReturn()
        window.settle()
        expectEqual(t.types(t.sub), [t.project])
        expectEqual(t.editor.undoHistory.undoName, "Add Type")
        expectEqual(t.editor.document[t.sub]?.typed(as: Subboard.self)?.props.description.plainText(), "", "the line is gone from its description")
    },
    test("a typed subboard's panel has the tabs Description, Types, Connections, Style and opens on Description; a typed frame's opens on Types") {
        let t = Typed()
        t.editor.addTypeLink(t.project, to: t.frame)
        t.editor.addTypeLink(t.project, to: t.sub)
        let sub = try t.tabs(of: t.sub)
        expectEqual(sub.titles, ["Description", "Types", "Connections", "Style"])
        expectEqual(sub.current, "Description")
        let frame = try t.tabs(of: t.frame)
        expectEqual(frame.titles.first, "Types")
        expectEqual(frame.current, "Types")
        expectEqual(frame.titles, ["Types", "Connections", "Style"])
    },
    test("the Types tab's Fields set values through the one writer, one step named for the field, for a frame and for a subboard; a frame has no Autofill section") {
        let t = Typed()
        t.editor.addTypeLink(t.project, to: t.frame)
        t.editor.addTypeLink(t.project, to: t.sub)
        let panel = try require(t.editor.detailPanel)
        @MainActor func sections(_ id: ShapeID) throws -> [String] {
            try require(panel.layout(for: try require(t.editor.document[id]))).sections(in: .of(TypesTab.self)).map(\.section)
        }
        expectEqual(try sections(t.frame), ["types", "fields"])
        expectEqual(try sections(t.sub), ["types", "fields", "autofill"])
        let writer = try require(t.editor.fieldWriter)
        expect(writer.setTyped("Sam", as: .text, at: FieldPath(field: "owner"), of: t.frame))
        expectEqual(t.editor.document[t.frame]?[FieldValuesProperty.self]?["owner"], "Sam")
        expectEqual(t.editor.undoHistory.undoName, "Change Owner")
        t.editor.undo()
        expectEqual(t.editor.document[t.frame]?[FieldValuesProperty.self], nil)
        expect(writer.setTyped("1200", as: .number(integer: false), at: FieldPath(field: "budget"), of: t.sub))
        expectEqual(t.editor.document[t.sub]?[FieldValuesProperty.self]?["budget"], 1200)
        expectEqual(t.editor.undoHistory.undoName, "Change Budget")
        t.editor.undo()
        expectEqual(t.editor.document[t.sub]?[FieldValuesProperty.self], nil)
    },
    test("a required field left empty on a typed frame is an issue on the frame, and on a typed subboard; filling it clears it") {
        let t = Typed()
        expectEqual(t.issues(t.frame).map(\.message), [], "not typed: nothing is needed")
        t.editor.addTypeLink(t.project, to: t.frame)
        t.editor.addTypeLink(t.project, to: t.sub)
        for shape in [t.frame, t.sub] {
            expectEqual(t.issues(shape).map(\.message), ["owner is needed"])
            expectEqual(t.issues(shape).map(\.severity), [.incomplete])
        }
        let writer = try require(t.editor.fieldWriter)
        expect(writer.setTyped("Sam", as: .text, at: FieldPath(field: "owner"), of: t.frame))
        expectEqual(t.issues(t.frame).map(\.message), [], "filled")
        expectEqual(t.issues(t.sub).map(\.message), ["owner is needed"], "the other is as it was")
    },
    test("a relationship type whose end is Project with a Needed rule gives a typed subboard with no such arrow a needed issue, and none once a subboard-to-subboard or a subboard-to-note arrow of it is drawn") {
        let t = Typed()
        t.editor.addTypeLink(t.project, to: t.sub)
        _ = try drawnInProcess(ownsStory, on: t.editor)
        @MainActor func owns(_ id: ShapeID) -> [String] { t.issues(id).map(\.message).filter { $0.hasPrefix("owns") } }
        let payments = t.sub, billing = try require(t.shape(titled: "Billing")), core = try require(t.shape(titled: "Core")), ops = try require(t.shape(titled: "Ops"))
        expectEqual(owns(payments), ["owns is needed"], "no arrow of Owns leaves it")
        expectEqual(owns(billing), ["owns is needed"])
        _ = try drawnInProcess(#"edge "Payments" -> "Core" is: "Owns""#, on: t.editor)
        expectEqual(owns(payments), [], "a subboard-to-subboard arrow clears it")
        expectEqual(owns(billing), ["owns is needed"], "the other is as it was")
        _ = try drawnInProcess(#"edge "Billing" -> "Ops" is: "Owns""#, on: t.editor)
        expectEqual(owns(billing), [], "a subboard-to-note arrow too")
        let arrow = try require(t.editor.document.shapes.first { $0.kind == "arrow" && $0.typed(as: Arrow.self)?.props.end.binding?.shapeID == ops })
        expectEqual(t.issues(arrow.id).map(\.message), [], "and the arrow is a fit")
        _ = core
    },
    test("a frame of the wrong type at a relationship's end is a misfit on the arrow") {
        let t = Typed()
        t.editor.addTypeLink(t.project, to: t.sub)
        t.editor.addTypeLink(t.project, to: t.frame)
        _ = try drawnInProcess(ownsStory, on: t.editor)
        _ = try drawnInProcess(#"edge "Payments" -> "Q4 launch" is: "Owns""#, on: t.editor)
        let arrow = try require(t.editor.document.shapes.first { $0.kind == "arrow" && $0.typed(as: Arrow.self)?.props.end.binding?.shapeID == t.frame })
        expectEqual(t.issues(arrow.id).map(\.message), ["Owns runs to a Team. “Q4 launch” is a Project."])
        let team = try require(t.shape(titled: "Team"))
        t.editor.addTypeLink(team, to: t.frame)
        t.editor.removeTypeLink(t.project, from: t.frame)
        expectEqual(t.issues(arrow.id).map(\.message), [], "a Team at the end fits")
    },
    test("a type's color, set on it or else its id's, colors a typed frame with none of its own and replaces a typed subboard's indigo; their own color wins, and taken away the type's is back") {
        let t = Typed()
        t.editor.addTypeLink(t.project, to: t.frame)
        t.editor.addTypeLink(t.project, to: t.sub)
        let colors = try require(t.editor.colors)
        @MainActor func swatch(_ id: ShapeID) throws -> Swatch? { colors.swatch(of: try require(t.editor.document[id])) }
        @MainActor func surface(_ id: ShapeID) throws -> [Int]? {
            try swatch(id).map { [$0.surface[dark: false].red, $0.surface[dark: false].green, $0.surface[dark: false].blue].map { Int(($0 * 255).rounded()) } }
        }
        let inside = CGPoint(x: 500, y: 560)
        let size = CGSize(width: 1100, height: 700)
        // With none set on the type, the one its id says, as its pill shows.
        let idColor = colors.swatch(for: TypeColors.name(of: t.project))
        expectEqual(try swatch(t.frame), idColor, "a frame of a type with no color set takes the color its type's pill shows")
        expectEqual(try swatch(t.sub), idColor, "and a subboard, in place of its indigo")
        t.editor.setColor(.blue, of: [t.project])
        expectEqual(try swatch(t.frame), colors.swatch(for: .blue), "its type's blue")
        expectEqual(try swatch(t.sub), colors.swatch(for: .blue), "in place of indigo")
        expectEqual(t.editor.document[t.frame]?.ownColor, nil, "nothing is written to the frame")
        let blue = try require(try surface(t.frame))
        let drawn = Array(pixel(renderBitmap(t.editor, size: size), at: inside).prefix(3))
        expect(zip(drawn, blue).allSatisfy { abs($0 - $1) <= 2 }, "the frame is drawn in it: \(drawn) is not about \(blue)")
        t.editor.setColor(.red, of: [t.frame, t.sub])
        expectEqual(try swatch(t.frame), colors.swatch(for: .red), "its own wins")
        expectEqual(try swatch(t.sub), colors.swatch(for: .red))
        t.editor.setColor(nil, of: [t.frame, t.sub])
        expectEqual(try swatch(t.frame), colors.swatch(for: .blue), "taken away, the type's is back")
        expectEqual(try swatch(t.sub), colors.swatch(for: .blue))
    },
    test("VoiceOver says a typed frame's and subboard's type after its kind") {
        let t = Typed()
        t.editor.addTypeLink(t.project, to: t.frame)
        t.editor.addTypeLink(t.project, to: t.sub)
        expectEqual(t.editor.accessibleDescription(of: t.frame)?.label, "Q4 launch, Frame, Project")
        expectEqual(t.editor.accessibleDescription(of: t.sub)?.label, "Payments, Subboard, Project")
        t.editor.removeTypeLink(t.project, from: t.frame)
        expectEqual(t.editor.accessibleDescription(of: t.frame)?.label, "Q4 launch, Frame")
    },
    test("a typed subboard whose description changes is filled from it, one step, Fill Fields; a typed frame holds no autofill and is never filled") {
        let model = ScriptedLanguageModel()
        let t = Typed(model: model)
        let fill = try require(t.editor.fieldFill)
        expect(fill.holdsAutofill(try require(t.editor.shape(inFile: t.sub))), "a subboard holds its say")
        expect(!fill.holdsAutofill(try require(t.editor.shape(inFile: t.frame))), "a frame holds none")
        expect(!t.editor.registry.properties(for: Frame.kind).contains(AutofillProperty.key))
        expect(t.editor.registry.properties(for: Subboard.kind).contains(AutofillProperty.key))
        t.editor.addTypeLink(t.project, to: t.frame)
        t.editor.addTypeLink(t.project, to: t.sub)
        t.h.scheduler.advance(by: .zero)
        let asked = model.requests.count
        model.queue(#"{"owner": "Sam"}"#)
        t.editor.transact("Change Description") { $0.update(t.sub, as: Subboard.self) { $0.props.description = "Run by Sam" } }
        t.h.scheduler.advance(by: .seconds(4))
        expect(spinRunLoop(until: { model.requests.count > asked && fill.status(of: t.sub) != .filling }), "the model is asked, and answers")
        expectEqual(t.editor.document[t.sub]?[FieldValuesProperty.self]?["owner"], "Sam")
        expectEqual(t.editor.undoHistory.undoName, "Fill Fields")
        // The frame has no words to change: nothing is asked of it, whatever happens to it.
        let frameAsked = model.requests.count
        t.editor.transact("Resize") { $0.update(t.frame) { _ in } }
        t.editor.setColor(.green, of: [t.frame])
        t.h.scheduler.advance(by: .seconds(10))
        for _ in 0..<10 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
        expectEqual(model.requests.count, frameAsked, "a frame is never filled")
        expectEqual(t.editor.document[t.frame]?[FieldValuesProperty.self], nil)
    },
    test("canvas draw writes a frame and a subboard with is: and fieldValues: in one step, and queries find them by their type") {
        let t = Typed()
        _ = try drawnInProcess("""
        frame "Q4" right of "Q4 launch" is: "Project" fieldValues: {"owner": "Sam"}
        subboard "Billing" below "Payments" is: "Project" fieldValues: {"budget": 1200}
        """, on: t.editor)
        let frame = try require(t.shape(titled: "Q4")), sub = try require(t.shape(titled: "Billing"))
        expectEqual(t.editor.document[frame]?.kind, Frame.kind)
        expectEqual(t.editor.document[sub]?.kind, Subboard.kind)
        expectEqual(t.types(frame), [t.project])
        expectEqual(t.types(sub), [t.project])
        expectEqual(t.editor.document[frame]?[FieldValuesProperty.self], FieldValues(["owner": "Sam"]))
        expectEqual(t.editor.document[sub]?[FieldValuesProperty.self], FieldValues(["budget": 1200]))
        expectEqual(t.editor.undoHistory.undoName, "Draw")
        expectEqual(try found(#"frame:is-a("Project")"#, in: t.editor), [frame])
        expectEqual(try found(#"subboard:is-a("Project")"#, in: t.editor), [sub])
        expectEqual(try found(#"frame[fieldValues.owner="Sam"]"#, in: t.editor), [frame])
        t.editor.undo()
        expectEqual(t.shape(titled: "Q4"), nil, "one step takes both back")
        expectEqual(t.shape(titled: "Billing"), nil)
    },
    test("a typed frame with values turned into a subboard keeps its type and its values, in one step, Turn into Subboard; undone, it is a frame again") {
        let t = Typed()
        t.editor.addTypeLink(t.project, to: t.frame)
        let writer = try require(t.editor.fieldWriter)
        expect(writer.setTyped("Sam", as: .text, at: FieldPath(field: "owner"), of: t.frame))
        let menu = try require(t.h.secondaryClick(at: CGPoint(x: 500, y: 450)), "the frame's menu")
        try menu.choose("Turn into Subboard")
        expectEqual(t.editor.document[t.frame]?.kind, Subboard.kind)
        expectEqual(t.types(t.frame), [t.project])
        expectEqual(t.editor.document[t.frame]?[FieldValuesProperty.self], FieldValues(["owner": "Sam"]))
        expectEqual(t.editor.undoHistory.undoName, "Turn into Subboard")
        expectEqual(t.chips(t.frame).map { $0.label.text ?? "" }, ["Project"], "its chip is a subboard's now")
        t.editor.undo()
        expectEqual(t.editor.document[t.frame]?.kind, Frame.kind)
        expectEqual(t.types(t.frame), [t.project])
        expectEqual(t.editor.document[t.frame]?[FieldValuesProperty.self], FieldValues(["owner": "Sam"]))
    },
    test("a typed frame and subboard copied with their type note paste as a frame and a subboard of the pasted type; copied alone, of the original") {
        let t = Typed()
        t.editor.addTypeLink(t.project, to: t.frame)
        t.editor.addTypeLink(t.project, to: t.sub)
        let writer = try require(t.editor.fieldWriter)
        expect(writer.setTyped("Sam", as: .text, at: FieldPath(field: "owner"), of: t.frame))
        t.editor.selectedShapeIDs = [t.project, t.frame, t.sub]
        t.editor.perform(.copy)
        let before = t.editor.document
        t.editor.perform(.paste)
        let byOriginal = Dictionary(uniqueKeysWithValues: t.editor.shapes(since: before).compactMap { record in record.copiedFrom.map { ($0, record.id) } })
        let project = try require(byOriginal[t.project]), frame = try require(byOriginal[t.frame]), sub = try require(byOriginal[t.sub])
        expectEqual(t.editor.document[frame]?.kind, Frame.kind)
        expectEqual(t.editor.document[sub]?.kind, Subboard.kind)
        expectEqual(t.types(frame), [project], "of the pasted type")
        expectEqual(t.types(sub), [project])
        expectEqual(t.editor.document[frame]?[FieldValuesProperty.self], FieldValues(["owner": "Sam"]), "and its values with it")
        t.editor.selectedShapeIDs = [t.frame, t.sub]
        t.editor.perform(.copy)
        let again = t.editor.document
        t.editor.perform(.paste)
        let alone = t.editor.shapes(since: again)
        expectEqual(alone.map(\.kind).sorted { $0.rawValue < $1.rawValue }, [Frame.kind, Subboard.kind])
        expect(alone.allSatisfy { $0[IsAProperty.self]?.map(\.shape) == [t.project] }, "of the original")
    },
])
