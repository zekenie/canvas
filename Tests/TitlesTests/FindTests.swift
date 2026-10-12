import Adornments
import AppKit
import Canvas
import CanvasTesting
import Find
import Geometry
import TestKit
import Titles

// Titles for Find (`TitleFindPlugin`): a named title and a derived one, the pill ringed in full,
// the cover tinted zoomed out.

/// Titles' fixtures with Find and its titles, cards titled by their text, on a scheduler a test
/// drives.
@MainActor private func findEditor() throws -> (CanvasEditor, ManualScheduler) {
    let scheduler = ManualScheduler()
    return (try titleEditor([CardsPlugin(), CardTitlesPlugin(), FindPlugin(), TitleFindPlugin()], scheduler: scheduler), scheduler)
}

@MainActor private func search(_ query: String, in editor: CanvasEditor, _ scheduler: ManualScheduler) throws -> FindState {
    let find = try require(editor.find)
    if !find.isActive { find.open() }
    find.query = query
    while find.isIndexing { scheduler.advance(by: .zero) }
    _ = try awaitResult { await find.settled() }
    return find
}

@MainActor let titleFindTests = Suite("Titles for Find", [
    test("a named title and a derived one are found; a kind with neither isn't searched") {
        let (editor, scheduler) = try findEditor()
        let plaque = editor.add(Plaque(plaqueFrame), named: "Front desk")
        let card = editor.add(Card(CGRect(x: 300, y: 100, width: 80, height: 60), text: "Desk lamp"))
        _ = editor.add(Box(CGRect(x: 0, y: 250, width: 40, height: 40)))
        let find = try search("desk", in: editor, scheduler)
        expectEqual(find.results.map(\.id), [plaque, card])
        expectEqual(find.texts(of: plaque), ["Front desk"])
        expectEqual(find.texts(of: card), ["Desk lamp"])
        expectEqual(find.indexedShapes, 2)
    },
    test("in full a hit is the whole pill, ringed, as Adornments lays it out at this zoom") {
        let (editor, scheduler) = try findEditor()
        let plaque = editor.add(Plaque(plaqueFrame), named: "Front desk")
        let find = try search("desk", in: editor, scheduler)
        let pill = try require(editor.adornmentFrames(of: plaque).first { $0.adornment == .of(TitlePill.self) }?.rect)
        let hit = try require(find.currentHit?.hit)
        expectEqual(find.rects(of: hit, in: plaque), [pill])
        let ringed = render(editor)
        find.close()
        let plain = render(editor)
        // The ring stands a point and a half out from the capsule, two points wide.
        let spot = CGPoint(x: pill.midX, y: pill.minY - 2)
        expect(pixel(ringed, at: spot) != pixel(plain, at: spot), "ringed above the pill: \(pixel(ringed, at: spot))")
        expectEqual(pixel(ringed, at: CGPoint(x: pill.midX, y: pill.midY)), pixel(plain, at: CGPoint(x: pill.midX, y: pill.midY)),
                    "the pill itself as it was")
        editor.camera = Camera(origin: .zero, zoom: 2)
        find.open()
        _ = try awaitResult { await find.settled() }
        let closer = try require(editor.adornmentFrames(of: plaque).first { $0.adornment == .of(TitlePill.self) }?.rect)
        expectEqual(find.rects(of: hit, in: plaque), [closer], "laid out again at another zoom")
    },
    test("zoomed out, the cover is tinted, not the whole shape") {
        let (editor, scheduler) = try findEditor()
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        let plaque = editor.add(Plaque(world(plaqueFrame, atZoom: 0.3)), named: "Front desk")
        let find = try search("front", in: editor, scheduler)
        let cover = try require(editor.titleCover(of: plaque)?.rect)
        let tinted = render(editor)
        find.close()
        let plain = render(editor)
        let inCover = editor.camera.toView(CGPoint(x: cover.minX + 1, y: cover.midY))
        let below = editor.camera.toView(CGPoint(x: cover.midX, y: cover.maxY + (world(plaqueFrame, atZoom: 0.3).maxY - cover.maxY) / 2))
        let a = pixel(tinted, at: inCover), b = pixel(plain, at: inCover)
        expect(a[0] - a[2] > b[0] - b[2] + 30, "the cover tinted: \(a) against \(b)")
        expectEqual(pixel(tinted, at: below), pixel(plain, at: below), "the rest of the shape as it was")
    },
    test("a shape whose pill a look hides gives Find no title text, and the text comes back when the look stops hiding") {
        let scheduler = ManualScheduler()
        let hider = looks(id: "hider") { shape, _ in shape[Starred.self] == true ? TitlePillLook(hidesPill: true) : nil }
        let editor = try titleEditor([starPlugin, hider, CardsPlugin(), CardTitlesPlugin(), FindPlugin(), TitleFindPlugin()], scheduler: scheduler)
        let plaque = editor.add(Plaque(plaqueFrame), named: "Front desk")
        let card = editor.add(Card(CGRect(x: 300, y: 100, width: 80, height: 60), text: "Desk lamp"))
        editor.star(plaque)
        let find = try search("desk", in: editor, scheduler)
        expectEqual(find.results.map(\.id), [card], "the hidden pill's title is not found")
        expectEqual(find.texts(of: plaque), [])
        editor.star(plaque, nil)
        let again = try search("front", in: editor, scheduler)
        expectEqual(again.results.map(\.id), [plaque], "found again once the look stops hiding, with no other change")
        expectEqual(again.texts(of: plaque), ["Front desk"])
    },
])
