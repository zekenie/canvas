import AppKit
import Canvas
import CanvasTesting
import Chrome
import DetailPanel
import Selection
import SwiftUI
import TestKit

// The panel in the window's inspector, whose sheet runs under the title bar and hands the panel the row (`PaneTitleRow`): its
// first line is the row's.

/// Cards with a header that renames them and says nothing under its title.
private struct TitledCards: CanvasPlugin {
    var id: PluginID { "titled" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.details(Card.self, header: { $card in DetailHeaderLabel { DetailHeaderField($card.text) } }) {}
    }
}

/// The row an inspector's sheet hands its panel: 52 tall, 16 in from its leading edge, ending 60 in from its trailing edge.
private let inspectorRow = PaneTitleRow(height: 52, leading: 16, trailing: 60)

/// Where a view of the panel is, in the panel's points from its top left.
@MainActor private func place(of view: NSView, in panel: PanelWindow) -> CGRect { view.convert(view.bounds, to: panel.hosting) }

@MainActor let titleRowPanelTests = Suite("The panel under a title bar", [
    test("its header is the title bar's row: the title on the row's line in the window's title's type, ending before the window's button, the room beside it the window's") {
        let editor = try gadgetEditor([CardsPlugin(), TitledCards()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor, titleRow: inspectorRow)
        editor.selection = editor.add(Card(gadgetFrame, text: "Hi"))
        panel.window.spin { panel.headerField != nil }
        let field = try require(panel.headerField), frame = place(of: field, in: panel)
        expectEqual(field.font, NSFont.systemFont(ofSize: 15, weight: .semibold), "the window's title's type")
        expect(abs(frame.midY - 26) < 1.5, "on the row's line: \(frame)")
        expect(frame.maxX <= DetailStyle.idealWidth - 60 + 0.5, "ending before the window's button: \(frame)")
        let beside = panel.hit(CGPoint(x: DetailStyle.idealWidth - 70, y: 26), in: panel.hosting)
        expect(beside is TitleRowDragView, "a press beside it is the window's: \(String(describing: beside))")
    },
    test("over a subtitle its title is in the window's title's two-line form, the two in the row") {
        let editor = try gadgetEditor([CardsPlugin(), RenamingCards()], scheduler: TaskScheduler())
        let panel = PanelWindow(editor, titleRow: inspectorRow)
        editor.selection = editor.add(Card(gadgetFrame, text: "Hi"))
        panel.window.spin { panel.headerField != nil }
        let field = try require(panel.headerField), frame = place(of: field, in: panel)
        expectEqual(field.font, NSFont.systemFont(ofSize: 13, weight: .bold))
        expect(frame.minY > 0 && frame.maxY < 52, "in the row: \(frame)")
    },
    test("a band over the panel takes the row, and the header under it is a header again until the band goes") {
        let model = BandModel()
        model.active = true
        let editor = try gadgetEditor([CardsPlugin(), TitledCards(), BandPlugin(model: model)], scheduler: TaskScheduler())
        let panel = PanelWindow(editor, titleRow: inspectorRow)
        editor.selection = editor.add(Card(gadgetFrame, text: "Hi"))
        panel.window.spin { panel.fields.contains { $0.stringValue == "Hi" } && panel.fields.contains { $0.placeholderString == "Band" } }
        let band = try require(panel.fields.first { $0.placeholderString == "Band" })
        let title = try require(panel.fields.first { $0.stringValue == "Hi" })
        let bandFrame = place(of: band, in: panel)
        expect(abs(bandFrame.midY - 26) < 1.5 && bandFrame.maxX <= DetailStyle.idealWidth - 60 + 0.5, "the band in the row: \(bandFrame)")
        expect(place(of: title, in: panel).minY >= 52, "the header under it: \(place(of: title, in: panel))")
        expectEqual(title.font, NSFont.systemFont(ofSize: 13, weight: .semibold), "in the header's type")
        model.active = false
        panel.window.spin { abs(place(of: title, in: panel).midY - 26) < 1.5 }
        expectEqual(title.font, NSFont.systemFont(ofSize: 15, weight: .semibold), "the band gone, the header has the row again")
    },
])
