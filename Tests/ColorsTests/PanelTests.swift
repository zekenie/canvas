import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import DetailPanel
import Palette
import Selection
import SwiftUI
import TestKit

/// The panel's plugins, and a frozen shape's.
@MainActor func panelHarness(_ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try colorHarness([DetailPanelPlugin(), ColorDetailsPlugin(), FreezingPlugin()] + more)
}

/// The row as a person reads it, for a shape in the editor.
@MainActor func rowModel(_ editor: CanvasEditor, _ id: ShapeID) throws -> ColorRowModel {
    ColorRowModel(record: try require(editor.document[id]), book: try require(editor.colors))
}

/// What a write through the panel's row does, as the panel makes it: the shape's color property
/// bound by the section, named for it.
@MainActor func rowSections(_ editor: CanvasEditor, _ id: ShapeID) throws -> [String] {
    let layout = try require(editor.detailPanel).layout(for: try require(editor.document[id]))
    return layout.sections(in: .of(StyleTab.self)).map(\.section)
}

/// A section of the panel's own, titled as the row's is, that keeps the binding the panel hands it
/// for the shape shown: the row's writes go through one such, named by the panel.
@MainActor
final class BindingProbe {
    var binding: ShapeBinding<AnyShapeRecord>?
    func keep(_ binding: ShapeBinding<AnyShapeRecord>) { self.binding = binding }

    var contributor: Contributor {
        Contributor(id: "binding-probe") { registrar in
            registrar.forEveryShape { scope in
                scope.details {
                    DetailSection(ColorsStyle.color, in: StyleTab.self, id: "probe") { $record in
                        let _ = self.keep($record)
                        Text("probe")
                    }
                }
            }
        }
    }
}

/// The panel showing a shape in an unshown window, on the real scheduler, and the binding its
/// sections are handed.
@MainActor
struct ShownPanel {
    let harness: EditorHarness
    let window: NSWindow
    let probe: BindingProbe
    var editor: CanvasEditor { harness.editor }

    /// The shape's color as the row binds it.
    func color() throws -> Binding<ShapeColor?> { try require(probe.binding)[ColorProperty.self] }

    init(_ props: some ShapeProps) throws {
        probe = BindingProbe()
        let registry = try Registry(plugins: colorPlugins([DetailPanelPlugin(), ColorDetailsPlugin(), FreezingPlugin(), probe.contributor]))
        harness = EditorHarness { _ in CanvasEditor(registry: registry, document: CanvasDocument(), scheduler: TaskScheduler()) }
        let id = harness.add(props)
        harness.editor.replaceDocument(with: harness.editor.document)
        let frame = CGRect(x: 0, y: 0, width: 300, height: 500)
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        let hosting = NSHostingView(rootView: DetailPanelView(editor: harness.editor, onExit: {}))
        hosting.frame = frame
        window.contentView = hosting
        harness.editor.selection = id
        window.spin { probe.binding != nil }
    }

    var id: ShapeID { probe.binding?.shapeID ?? ShapeID() }
}

/// How many steps there are to undo; all of them redone after.
@MainActor func undoSteps(_ editor: CanvasEditor) -> Int {
    var n = 0
    while editor.canUndo { editor.undo(); n += 1 }
    while editor.canRedo { editor.redo() }
    return n
}

@MainActor let colorPanelTests = Suite("The panel's color row", [
    test("the row is in the Style tab of a kind that has colors, and of no other") {
        let h = try panelHarness()
        let sheet = h.add(Sheet(CGRect(x: 0, y: 0, width: 80, height: 60)))
        let pane = h.add(Pane(CGRect(x: 0, y: 0, width: 80, height: 60)))
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 80, height: 60)))
        expectEqual(try rowSections(h.editor, sheet), ["Color"])
        expectEqual(try rowSections(h.editor, pane), ["Color"])
        expectEqual(try rowSections(h.editor, box), [])
        let layout = try require(h.editor.detailPanel).layout(for: try require(h.editor.document[sheet]))
        expect(layout.tabs.contains(.of(StyleTab.self)), "\(layout.tabs.map(\.title))")
        expectEqual(layout.sections(in: .of(StyleTab.self)).first?.section, ColorsStyle.color)
    },
    test("the row says what the color is called: a default dimmed, a name capitalized, a value as hex, none dimmed") {
        let h = try panelHarness()
        let sheet = h.add(Sheet(CGRect(x: 0, y: 0, width: 80, height: 60)))
        let pane = h.add(Pane(CGRect(x: 0, y: 0, width: 80, height: 60)))
        var sheetRow = try rowModel(h.editor, sheet)
        expectEqual(sheetRow.title, "Yellow")
        expect(sheetRow.isDimmed, "a default is dimmed")
        expect(sheetRow.tone != nil, "and has its dot")
        var paneRow = try rowModel(h.editor, pane)
        expectEqual(paneRow.title, ColorsStyle.none)
        expect(paneRow.isDimmed, "none is dimmed")
        expect(paneRow.tone == nil, "and has no dot")
        h.editor.setColor(.blue, of: [sheet, pane])
        sheetRow = try rowModel(h.editor, sheet)
        paneRow = try rowModel(h.editor, pane)
        expectEqual(sheetRow.title, "Blue")
        expectEqual(paneRow.title, "Blue")
        expect(!sheetRow.isDimmed, "a color of its own isn't")
        expectEqual(sheetRow.tone, Tone(BuiltInColors.blue.value))
        h.editor.setColor(.value(RGB(hex: 0x123456)), of: [sheet])
        sheetRow = try rowModel(h.editor, sheet)
        expectEqual(sheetRow.title, "#123456")
        expect(!sheetRow.isDimmed, "a value is its own")
        expectEqual(sheetRow.tone, Tone(RGB(hex: 0x123456)))
        h.editor.transact { $0.update(sheet) { $0[ColorProperty.self] = .named("brand") } }
        sheetRow = try rowModel(h.editor, sheet)
        expectEqual(sheetRow.title, "Yellow", "a name the file lacks is shown as the default it is drawn as")
        expect(sheetRow.isDimmed, "dimmed")
    },
    test("the grid is the built-in colors in list order, and the shape's own color is ringed") {
        let h = try panelHarness()
        let sheet = h.add(Sheet(CGRect(x: 0, y: 0, width: 80, height: 60)))
        var row = try rowModel(h.editor, sheet)
        expectEqual(row.groups.count, 1)
        expectEqual(row.groups[0].map(\.name), BuiltInColors.all.map(\.name))
        expect(row.groups[0].allSatisfy { !row.isRinged($0) }, "a default is no ring")
        h.editor.setColor(.named("TEAL"), of: [sheet])
        row = try rowModel(h.editor, sheet)
        expectEqual(row.groups[0].filter(row.isRinged).map(\.name), ["teal"])
        h.editor.setColor(.value(RGB(hex: 0x123456)), of: [sheet])
        row = try rowModel(h.editor, sheet)
        expect(row.groups[0].allSatisfy { !row.isRinged($0) }, "a value is none of the dots")
    },
    test("a dot writes its name in the list's spelling, None writes nothing, a system color its hex as sRGB") {
        let h = try panelHarness()
        let sheet = h.add(Sheet(CGRect(x: 0, y: 0, width: 80, height: 60)))
        let row = try rowModel(h.editor, sheet)
        let dot = try require(row.groups[0].first { $0.name == "purple" })
        expectEqual(row.writes(dot: dot), ShapeColor.purple)
        expectEqual(row.writesNone, nil)
        expectEqual(row.writes(picked: NSColor(srgbRed: 0x44 / 255, green: 0x65 / 255, blue: 0xE9 / 255, alpha: 1)), .value(RGB(hex: 0x4465E9)))
        // A color in another space is converted to sRGB first.
        let white = try require(row.writes(picked: NSColor(white: 1, alpha: 1)))
        expectEqual(white.text, "#FFFFFF")
        let p3 = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
        let converted = try require(row.writes(picked: p3))
        expect(converted.text.hasPrefix("#FF"), "\(converted.text)")
    },
    test("picking a dot writes the canonical name in one step, Change Color, and undo puts the shape back") {
        let panel = try ShownPanel(Sheet(CGRect(x: 0, y: 0, width: 80, height: 60)))
        let row = try rowModel(panel.editor, panel.id)
        row.apply(.color(row.writes(dot: BuiltInColors.blue)), to: try panel.color())
        expectEqual(panel.editor.document[panel.id]?.ownColor, .blue)
        expectEqual(panel.editor.undoHistory.undoName, ColorsStyle.changeColor)
        expectEqual(undoSteps(panel.editor), 1)
        panel.editor.undo()
        expectEqual(panel.editor.document[panel.id]?.ownColor, nil)
        panel.editor.redo()
        expectEqual(panel.editor.document[panel.id]?.ownColor, .blue)
    },
    test("None takes the color away, in a step of its own") {
        let panel = try ShownPanel(Pane(CGRect(x: 0, y: 0, width: 80, height: 60)))
        panel.editor.setColor(.red, of: [panel.id])
        panel.editor.undoHistory.seal()
        let row = try rowModel(panel.editor, panel.id)
        row.apply(.color(row.writesNone), to: try panel.color())
        expectEqual(panel.editor.document[panel.id]?.ownColor, nil)
        expectEqual(panel.editor.undoHistory.undoName, ColorsStyle.changeColor)
        panel.editor.undo()
        expectEqual(panel.editor.document[panel.id]?.ownColor, .red)
    },
    test("Other opens the system color panel from the shape's color, and each color it reports is written as hex, a drag being one step") {
        let panel = try ShownPanel(Sheet(CGRect(x: 0, y: 0, width: 80, height: 60)))
        let row = try rowModel(panel.editor, panel.id)
        var started: NSColor?? = .none
        var report: ((NSColor) -> Void)?
        row.apply(.other, to: try panel.color()) { start, reporter in
            started = .some(start)
            report = reporter
        }
        expect(started != nil, "the panel was opened")
        expect(panel.editor.document[panel.id]?.ownColor == nil, "opening it writes nothing")
        let start = try require((started ?? nil)?.usingColorSpace(.sRGB))
        expectEqual(RGB(Double(start.redComponent), Double(start.greenComponent), Double(start.blueComponent)).hexString,
                    BuiltInColors.yellow.value.hexString, "from the color itself (a sheet's default), in either appearance, never a role of it")
        let send = try require(report)
        for hex in [0x112233, 0x223344, 0x4465E9] as [UInt32] {
            send(NSColor(srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: 1))
        }
        expectEqual(panel.editor.document[panel.id]?.ownColor, .value(RGB(hex: 0x4465E9)))
        expectEqual(panel.editor.document[panel.id]?.ownColor?.text, "#4465E9")
        expectEqual(panel.editor.undoHistory.undoName, ColorsStyle.changeColor)
        expectEqual(undoSteps(panel.editor), 1)
    },
    test("a frozen shape's row changes nothing") {
        let panel = try ShownPanel(Sheet(CGRect(x: 0, y: 0, width: 80, height: 60)))
        panel.editor.freeze([panel.id])
        let row = try rowModel(panel.editor, panel.id)
        let revision = panel.editor.revision
        row.apply(.color(.pink), to: try panel.color())
        row.apply(.color(nil), to: try panel.color())
        expectEqual(panel.editor.document[panel.id]?.ownColor, nil)
        expectEqual(panel.editor.revision, revision)
    },
])

@MainActor let colorPanelFileTests = Suite("The panel's grid and the file's colors", [
    test("a value the shape holds can be named: the file gains the color and the shape names it, in one step, Add Color") {
        let h = try panelHarness()
        let sheet = h.add(Sheet(CGRect(x: 0, y: 0, width: 80, height: 60)))
        expectEqual(try rowModel(h.editor, sheet).nameable, nil, "a default is no value to name")
        h.editor.setColor(.blue, of: [sheet])
        expectEqual(try rowModel(h.editor, sheet).nameable, nil, "nor is a named color")
        h.editor.setColor(.value(RGB(hex: 0x0055FF)), of: [sheet])
        let row = try rowModel(h.editor, sheet)
        expectEqual(row.nameable, RGB(hex: 0x0055FF))
        expectEqual(row.refusal(ofName: ""), .empty)
        expectEqual(row.refusal(ofName: "Blue"), .builtIn)
        expectEqual(row.refusal(ofName: "Brand"), nil)
        row.apply(.name("  Brand   Blue "), to: .constant(nil))
        expectEqual(h.editor.colors?.fileColors.map(\.name), ["Brand Blue"])
        expectEqual(h.editor.document[sheet]?.ownColor, .named("Brand Blue"))
        expectEqual(h.editor.undoHistory.undoName, "Add Color")
        let after = try rowModel(h.editor, sheet)
        expectEqual(after.title, "Brand Blue")
        expectEqual(after.groups.count, 2, "the file's colors are a second group")
        expect(after.isRinged(try require(after.groups[1].first)))
        expectEqual(after.refusal(ofName: "brand blue"), .taken)
        h.editor.undo()
        expectEqual(h.editor.colors?.fileColors.map(\.name), [], "one step: the color is gone")
        expectEqual(h.editor.document[sheet]?.ownColor, .value(RGB(hex: 0x0055FF)), "and the shape holds its value again")
    },
    test("a color of the file's is renamed, given another value and removed from the grid") {
        let h = try panelHarness()
        let sheet = h.add(Sheet(CGRect(x: 0, y: 0, width: 80, height: 60)))
        expect(h.editor.defineColor(named: "Brand", value: RGB(hex: 0x0055FF)))
        h.editor.setColor(.named("Brand"), of: [sheet])
        var row = try rowModel(h.editor, sheet)
        var brand = try require(row.groups.last?.first)
        expectEqual(row.refusal(ofName: "brand", renaming: brand), nil, "its own name in another case is no clash")
        expectEqual(row.refusal(ofName: "red", renaming: brand), .builtIn)
        row.apply(.rename(brand, to: "House"), to: .constant(nil))
        expectEqual(h.editor.colors?.fileColors.map(\.name), ["House"])
        expectEqual(h.editor.document[sheet]?.ownColor, .named("House"))
        expectEqual(h.editor.undoHistory.undoName, "Rename Color")

        // A drag in the color panel is one step.
        row = try rowModel(h.editor, sheet)
        brand = try require(row.groups.last?.first)
        let before = undoSteps(h.editor)
        row.apply(.changeValue(brand), to: .constant(nil)) { start, report in
            expectEqual(start?.usingColorSpace(.sRGB)?.blueComponent, 1)
            for hex: UInt32 in [0x111111, 0x222222, 0x333333] { report(NSColor(RGB(hex: hex))) }
        }
        expectEqual(h.editor.colors?.fileColors.map(\.value), [RGB(hex: 0x333333)])
        expectEqual(undoSteps(h.editor), before + 1, "three colors reported, one step")
        expectEqual(h.editor.undoHistory.undoName, "Change Color")
        expectEqual(h.editor.document[sheet]?.ownColor, .named("House"), "the shape wasn't written")

        row = try rowModel(h.editor, sheet)
        row.apply(.remove(try require(row.groups.last?.first)), to: .constant(nil))
        expectEqual(h.editor.colors?.fileColors, [])
        expectEqual(h.editor.document[sheet]?.ownColor, .value(RGB(hex: 0x333333)), "it keeps its look")
        expectEqual(h.editor.undoHistory.undoName, "Remove Color")
    },
])
