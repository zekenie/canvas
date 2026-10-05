import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Selection
import SwiftUI
import TestKit

// Sections for every shape a `where` picks, DetailCheckbox and DetailShapeRow: generic pieces, on the
// fixture gadget.

/// The binding a picked section was built with, for a test to write through.
@MainActor var pickedBinding: ShapeBinding<AnyShapeRecord>?

struct PickingPlugin: CanvasPlugin {
    var id: PluginID { "picking" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.detailsForEveryShape(where: { $0.typed(as: Gadget.self)?.props.name == "pick" }) {
            DetailSection("Choice", in: GadgetTab.self) { $shape in
                let _ = (pickedBinding = $shape)
                Text("Picked")
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
])

/// `DetailStyle.listRowHeight`, which is internal: a row is no shorter than a status line's.
enum DetailStyleProbe { static let listRowHeight: CGFloat = 22 }
