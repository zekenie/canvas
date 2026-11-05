import AppKit
import CanvasTesting
import Chrome
import DetailPanel
import SwiftUI
import TestKit

// A place in the panel: a shape row's address and the header's line under the name fold as every address does
// (`PlaceFold`), in the room they have, boards semibold; the header stays one line.

private let longPlace = [PlaceStep(name: "Shop", opensBoard: true), PlaceStep(name: "Payments and disputes"), PlaceStep(name: "Chargebacks in review"),
                         PlaceStep(name: "Disputes")]

/// `view` alone in an unshown window `width` wide.
@MainActor private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat = 40) -> NSBitmapImageRep {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading))
    hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
    window.contentView = hosting
    window.settle()
    return snapshot(hosting)
}

@MainActor private func differ<A: View, B: View>(_ a: A, _ b: B, width: CGFloat) -> Bool {
    changedPixels(render(a, width: width), render(b, width: width), in: CGRect(x: 0, y: 0, width: width, height: 40)) > 0
}

@MainActor let placeLineTests = Suite("Places in the panel", [
    test("the line folds in its room, as the pill's does: the whole place, the first and the nearest, the nearest alone") {
        let whole = DetailPlaceText.line(longPlace, room: 1000)
        expectEqual(whole.text, "Shop › Payments and disputes › Chargebacks in review › Disputes")
        expect(!whole.isShortened)
        let folded = DetailPlaceText.line(longPlace, room: 140)
        expect(folded.text.hasPrefix("Shop") && folded.text.contains("…") && folded.text.hasSuffix("Disputes"), "folded: \(folded.text)")
        expect(folded.isShortened)
        expect(folded.width <= 140, "in the room: \(folded.width)")
        expectEqual(DetailPlaceText.line(longPlace, lead: "Note · ", room: 1000).text, whole.text, "the lead is the caller's, not the line's")
        expect(!DetailPlaceText.line(longPlace, room: whole.width).isShortened, "fits exactly")
        expect(DetailPlaceText.line(longPlace, lead: "Note · ", room: whole.width).isShortened, "but not after a lead")
        expect(DetailPlaceText.line(longPlace, room: 10).isEmpty, "no room, no line")
    },
    test("a shape row with a place folds it once the row's width is read; the name keeps the room it needs") {
        let row = { (place: [PlaceStep]) in
            DetailShapeRow(symbol: "note.text", name: "Checkout", detail: place.map(\.name).joined(separator: " › "), place: place).padding(.horizontal, 8)
        }
        expect(differ(row(longPlace), row([]), width: 600), "the place shows")
        // Narrow: the middle is folded away, so a change to it isn't seen; wide, it is.
        var other = longPlace
        other[1] = PlaceStep(name: "Xayments and disputes")
        expect(!differ(row(longPlace), row(other), width: 260), "folded: the middle isn't there")
        expect(differ(row(longPlace), row(other), width: 700), "with the room, it is")
        var near = longPlace
        near[3] = PlaceStep(name: "Xisputes")
        expect(differ(row(longPlace), row(near), width: 260), "the nearest always is")
        var board = longPlace
        board[0] = PlaceStep(name: "Shop")
        expect(differ(row(longPlace), row(board), width: 700), "a board is in semibold")
    },
    test("the header's line under the name folds at its width and stays one line; its help has the whole") {
        let header = { (place: [PlaceStep]) in
            DetailHeaderLabel(subtitle: "Note · " + place.map(\.name).joined(separator: " › "), systemImage: "note.text", place: place, lead: "Note · ") { Text("Checkout") }
        }
        let narrow = NSHostingView(rootView: header(longPlace).frame(width: 220))
        let wide = NSHostingView(rootView: header(longPlace).frame(width: 700))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = wide
        window.settle()
        let wideHeight = wide.fittingSize.height
        window.contentView = narrow
        window.settle()
        expectEqual(narrow.fittingSize.height, wideHeight, "one line at either width")
        var other = longPlace
        other[1] = PlaceStep(name: "Xayments and disputes")
        expect(!differ(header(longPlace), header(other), width: 220), "folded: the middle isn't said")
        expect(differ(header(longPlace), header(other), width: 700), "with the room it is")
    },
])
