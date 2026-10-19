import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Observation
import Selection
import SwiftUI
import TestKit

// Sections for the shapes a scope reaches, shown while a shape says so, DetailCheckbox and DetailShapeRow:
// generic pieces, on the fixture gadget.

/// The binding a picked section was built with, for a test to write through.
@MainActor var pickedBinding: ShapeBinding<AnyShapeRecord>?

struct PickingPlugin: CanvasPlugin {
    var id: PluginID { "picking" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.forEveryShape { every in
            every.details {
                DetailSection("Choice", in: GadgetTab.self) { $shape in
                    let _ = (pickedBinding = $shape)
                    Text("Picked")
                }
                .shownWhile { shape, _ in shape.typed(as: Gadget.self)?.props.name == "pick" }
            }
        }
    }
}

struct FlagPlugin: CanvasPlugin {
    var id: PluginID { "flag" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.details(Gadget.self) {
            DetailSection("Flag", in: GadgetTab.self) { $gadget in
                LabeledContent("Flag") {
                    DetailCheckbox("Allowed", isOn: Binding(get: { gadget.count > 0 }, set: { $gadget.count.wrappedValue = $0 ? 1 : 0 }))
                }
            }
        }
    }
}

@MainActor private func rowHeight(_ row: DetailShapeRow) -> CGFloat {
    let view = NSHostingView(rootView: row.frame(width: 228))
    return view.fittingSize.height
}

@MainActor private func ink(_ row: DetailShapeRow) -> Int {
    let view = NSHostingView(rootView: row.frame(width: 228).background(Color.white).environment(\.colorScheme, .light))
    view.frame = CGRect(origin: .zero, size: CGSize(width: 228, height: view.fittingSize.height))
    let rep = snapshot(view)
    var darkness = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            var value = [Int](repeating: 0, count: 4)
            rep.getPixel(&value, atX: x, y: y)
            darkness += 255 - value[0]
        }
    }
    return darkness
}

@MainActor let listRowTests = Suite("Panel list rows", [
    test("a section for every shape a where picks shows for those shapes only, over the whole record, and writes through it") {
        let editor = try gadgetEditor([PickingPlugin()], scheduler: TaskScheduler())
        let picked = editor.add(Gadget(gadgetFrame, name: "pick")), other = editor.add(Gadget(gadgetFrame, name: "other"))
        let box = editor.add(Box(gadgetFrame))
        expect(try editor.layout(picked).outline.contains("Gadget: main, Count, Choice"))
        expect(try !editor.layout(other).outline.contains("Gadget: main, Count, Choice"))
        expect(try !editor.layout(box).outline.contains("Gadget: main, Count, Choice"))
        let panel = PanelWindow(editor)
        editor.selection = picked
        panel.window.spin { pickedBinding != nil }
        let binding = try require(pickedBinding)
        expectEqual(binding.shapeID, picked)
        binding.update { $0.box = CGRect(x: 1, y: 2, width: 3, height: 4) }
        expectEqual(editor.document[picked]?.box, CGRect(x: 1, y: 2, width: 3, height: 4))
        expectEqual(editor.undoHistory.undoName, "Change Choice")
        editor.undo()
        expectEqual(editor.document[picked]?.box, gadgetFrame)
        pickedBinding = nil
    },
    test("a section's shape stops being picked when it changes: the section goes with it") {
        let editor = try gadgetEditor([PickingPlugin()])
        let id = editor.add(Gadget(gadgetFrame, name: "pick"))
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.name = "no" } }
        expect(try !editor.layout(id).outline.contains("Gadget: main, Count, Choice"))
    },
    test("a checkbox in a labeled row reads \"Label [] Title\": the box in the control column, its title after it") {
        let editor = try gadgetEditor([FlagPlugin()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor)
        editor.selection = editor.add(Gadget(gadgetFrame))
        panel.window.spin { panel.checkboxes.count == 1 }
        let box = try require(panel.checkboxes.first).convert(try require(panel.checkboxes.first).bounds, to: panel.hosting)
        expectEqual(box.minX, 96, "after the 72 point label column and its spacing")
        let image = try require(panel.hosting.bitmapImageRepForCachingDisplay(in: panel.hosting.bounds))
        panel.hosting.cacheDisplay(in: panel.hosting.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / panel.hosting.bounds.width
        let titled = stride(from: box.maxX + 4, to: box.maxX + 40, by: 1).contains { x in
            stride(from: box.minY, to: box.maxY, by: 1).contains { y in pixel(image, at: CGPoint(x: x, y: y), scale: scale)[3] > 128 }
        }
        expect(titled, "ink just after the box: its title")
    },
    test("a shape row is a status line's height, grows by its lines (two at most), and a dimmed one is dimmed whole") {
        let plain = DetailShapeRow(symbol: "note", name: "Plan")
        let two = DetailShapeRow(symbol: "note", name: "Plan", detail: "Board", lines: ["one", "two"])
        let three = DetailShapeRow(symbol: "note", name: "Plan", detail: "Board", lines: ["one", "two", "three"])
        expectEqual(rowHeight(plain), DetailStyleProbe.listRowHeight)
        expect(rowHeight(two) > rowHeight(plain))
        expectEqual(rowHeight(three), rowHeight(two), "a third line isn't shown")
        let loud = ink(DetailShapeRow(symbol: "note", name: "Plan", detail: "Board", lines: ["one"]))
        let quiet = ink(DetailShapeRow(symbol: "note", name: "Plan", detail: "Board", lines: ["one"], dimmed: true))
        expect(loud > 0 && quiet > 0 && quiet < loud, "dimmed \(quiet) against \(loud)")
    },
    test("a group header is a section header's height, folds on a click, and shows its list's color as a dot") {
        let folds = Folds()
        let plain = NSHostingView(rootView: DetailGroupHeader("Inside", count: 2, isCollapsed: false) { folds.count += 1 }.frame(width: 228))
        expectEqual(plain.fittingSize.height, DetailStyleProbe.sectionHeaderHeight)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 228, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = plain
        window.settle()
        let buttons = plain.descendants(NSButton.self)
        expectEqual(buttons.count, 1, "the whole head is one button")
        buttons.first?.performClick(nil)
        window.settle()
        expectEqual(folds.count, 1)
        // The dot: pixels of the tint, which a head without one has none of.
        let tint = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        expect(magenta(DetailGroupHeader("Points To", count: 3, tint: tint, isCollapsed: true) {}) > 8, "a dot in the list's color")
        expectEqual(magenta(DetailGroupHeader("Inside", count: 3, isCollapsed: true) {}), 0)
    },
    test("a search field writes what's typed, as typed, and its button clears it") {
        let typed = Typed()
        let view = NSHostingView(rootView: SearchProbe(typed: typed).frame(width: 228))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 228, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        window.settle()
        let field = try require(view.descendants(NSTextField.self).first { $0.placeholderString == "Search" })
        expectEqual(view.descendants(NSButton.self).count, 0, "nothing to clear")
        window.focus(field)
        window.type("teh")
        window.settle()
        expectEqual(typed.text, "teh", "as typed: nothing corrected")
        let clear = try require(view.descendants(NSButton.self).first)
        clear.performClick(nil)
        window.settle()
        expectEqual(typed.text, "")
        expectEqual(view.descendants(NSButton.self).count, 0)
    },
])

/// How often a group header's button was clicked.
@MainActor private final class Folds { var count = 0 }

/// What a search field wrote.
@MainActor @Observable private final class Typed { var text = "" }

private struct SearchProbe: View {
    let typed: Typed
    var body: some View {
        DetailSearchField("Search", text: Binding(get: { typed.text }, set: { typed.text = $0 }))
    }
}

/// How many pixels of a group header are magenta: its dot's, where its tint is.
@MainActor private func magenta(_ header: DetailGroupHeader) -> Int {
    let view = NSHostingView(rootView: header.frame(width: 228).background(Color.white).environment(\.colorScheme, .light))
    view.frame = CGRect(origin: .zero, size: CGSize(width: 228, height: view.fittingSize.height))
    let rep = snapshot(view)
    var found = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            var value = [Int](repeating: 0, count: 4)
            rep.getPixel(&value, atX: x, y: y)
            if value[0] > 200, value[1] < 80, value[2] > 200 { found += 1 }
        }
    }
    return found
}

/// `DetailStyle.listRowHeight`, which is internal: a row is no shorter than a status line's.
enum DetailStyleProbe {
    static let listRowHeight: CGFloat = 22
    /// `DetailStyle.sectionHeaderHeight`: a group's head is as tall as a section's.
    static let sectionHeaderHeight: CGFloat = 20
}
