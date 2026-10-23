import Adornments
import AppKit
import Canvas
import CanvasTesting
import Geometry
import TestKit
import Titles

// A kind whose title is a tab (`titleTab`): its title on the shape's top edge in the colors it gives, at
// every zoom, where another kind has a pill above it and a cover zoomed out.

/// A corral's surface and edge, as a frame gives its own: white with a gray edge, or near black.
private let paleSurface = NSColor(white: 1, alpha: 1)
private let darkSurface = NSColor(white: 0.15, alpha: 1)
private let edge = NSColor(white: 0, alpha: 0.12)

/// Corrals (CanvasTesting's containers) with a title Titles keeps, said in a tab in `surface`.
@MainActor private func tabbedCorrals(surface: NSColor = paleSurface, placeholder: String? = nil) -> Contributor {
    Contributor(id: "corral-titles") { registrar in
        registrar.title(Corral.self, placeholderInPill: placeholder)
        registrar.titleTab(Corral.self) { _, _ in TitleTabLook(surface: surface, edge: edge) }
    }
}

@MainActor private func frames(_ editor: CanvasEditor, _ id: ShapeID) -> [AdornmentFrame] { editor.adornmentFrames(of: id) }

/// A color as it resolves in an appearance.
private func resolved(_ color: NSColor, in name: NSAppearance.Name) -> NSColor {
    var result = color
    NSAppearance(named: name)?.performAsCurrentDrawingAppearance { result = NSColor(cgColor: color.cgColor) ?? color }
    return result
}

@MainActor let titleTabTests = Suite("A title's tab", [
    test("a kind with a tab shows its title in a tab and no pill, at every zoom, and has no cover zoomed out") {
        let editor = try titleEditor([CorralsPlugin(), tabbedCorrals()])
        // Big enough on screen at 5% for its tab: 200 by 120 points there.
        let corral = editor.add(Corral(CGRect(x: 0, y: 0, width: 4000, height: 2400)))
        editor.rename(corral, "Lobby")
        for zoom in [1, 0.3, 0.05] as [CGFloat] {
            editor.camera = Camera(origin: .zero, zoom: zoom)
            let shown = frames(editor, corral)
            expectEqual(shown.map(\.adornment), [.of(TitleTab.self)], "at \(zoom)")
            expectEqual(shown.first?.label.text, "Lobby")
            expectEqual(editor.titlePillRect(of: corral), shown.first?.rect, "its pill's rect is its tab's at \(zoom)")
            expect(editor.titleCover(of: corral) == nil, "no cover at \(zoom)")
        }
        expect(editor.registry.report.contains("title tab → corral"), "the report says it")
    },
    test("the tab is in the shape's surface and edge, its words dark on a light surface and light on a dark one") {
        for (surface, light) in [(paleSurface, true), (darkSurface, false)] {
            let editor = try titleEditor([CorralsPlugin(), tabbedCorrals(surface: surface)])
            let corral = editor.add(Corral(plaqueFrame))
            editor.rename(corral, "Lobby")
            let tint = try require(frames(editor, corral).first?.label.tint)
            expect(tint.color === surface, "the surface")
            expect(tint.edge === edge, "the edge")
            let ink = resolved(tint.ink, in: .darkAqua).usingColorSpace(.sRGB)?.redComponent ?? -1
            expect(light ? ink < 0.5 : ink > 0.5, "ink on \(light ? "a light" : "a dark") surface: \(ink)")
            let again = editor.add(Corral(plaqueFrame.offsetBy(dx: 0, dy: 200)))
            editor.rename(again, "Hall")
            expect(frames(editor, again).first?.label.tint == tint, "the same tint for the same colors")
        }
    },
    test("an untitled shape's tab says its placeholder, dimmed, in full; zoomed out, none") {
        let editor = try titleEditor([CorralsPlugin(), tabbedCorrals(placeholder: "Pen")])
        let corral = editor.add(Corral(plaqueFrame))
        let label = try require(frames(editor, corral).first?.label)
        expectEqual(label.text, "Pen")
        expect(label.isPlaceholder, "dimmed")
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        expectEqual(frames(editor, corral).count, 0, "none zoomed out")
    },
    test("a look's tint wins over the tab's colors") {
        let red = AdornmentTint(.systemRed, style: .solid)
        let looks = Contributor(id: "red-looks") { $0.forShapes(holding: TitleProperty.self) { $0.titlePillLook { _, _ in TitlePillLook(tint: red) } } }
        let editor = try titleEditor([CorralsPlugin(), tabbedCorrals(), looks])
        let corral = editor.add(Corral(plaqueFrame))
        editor.rename(corral, "Lobby")
        expect(frames(editor, corral).first?.label.tint == red, "the look's")
    },
])
