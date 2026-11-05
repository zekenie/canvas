import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import CoreGraphics
import DetailPanel
import Foundation
import Frames
import Mentions
import Palette
import Selection
import StickyNotes
import Subboards
import SwiftUI
import TestKit
import Titles
import Types

// Colors: the states of one track, added to `galleryStates` (GalleryTypesLook.swift) as `colorStates`.
// One small board with every kind that has a color, the panel's row and its grid, `/color`'s list,
// a type whose color was chosen, and the notes of a type in its color.

private let colorSchema = #"{"type": "object", "properties": {"name": {"type": "string"}}}"#

extension GalleryStage {
    /// A SwiftUI view alone, on the window's ground, as an unshown window draws it at 2x in this appearance.
    func viewPicture(_ view: some View, size: CGSize) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let viewWindow = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        viewWindow.contentView = host
        viewWindow.appearance = appearance
        viewWindow.settle()
        spin(0.1)
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        appearance.performAsCurrentDrawingAppearance {
            if let graphics = NSGraphicsContext(bitmapImageRep: rep) {
                graphics.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
                graphics.cgContext.fill(CGRect(origin: .zero, size: size))
                graphics.flushGraphics()
            }
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        return rep
    }

    /// A note saying `text` at `frame`, in `color` if given.
    @discardableResult
    func coloredNote(_ text: String, _ frame: CGRect, _ color: ShapeColor? = nil, title: String? = nil) -> ShapeID {
        let props = StickyNote(frame: frame, text: MentionText(plain: text))
        let id = title.map { editor.add(props, title: $0) } ?? editor.add(props)
        if let color { editor.setColor(color, of: [id]) }
        return id
    }
}

/// The board of the track: a note in each built-in color, then a blue frame holding two notes, a
/// green subboard, and two plain notes with a red arrow that says something between them.
@MainActor
private func colorBoard(_ stage: GalleryStage) {
    let editor = stage.editor
    for (index, color) in BuiltInColors.all.enumerated() {
        let frame = CGRect(x: 30 + CGFloat(index % 5) * 172, y: 30 + CGFloat(index / 5) * 130, width: 152, height: 110)
        stage.coloredNote(color.name.prefix(1).uppercased() + color.name.dropFirst(), frame, color.color)
    }
    let frame = editor.add(Frame(frame: CGRect(x: 30, y: 320, width: 300, height: 220)), title: "Sprint 3")
    editor.setColor(.blue, of: [frame])
    stage.coloredNote("Plan", CGRect(x: 50, y: 380, width: 120, height: 100), .teal)
    stage.coloredNote("Ship", CGRect(x: 190, y: 380, width: 120, height: 100))
    let subboard = editor.add(Subboard(frame: CGRect(x: 360, y: 350, width: 220, height: 150)), title: "Payments")
    editor.setColor(.green, of: [subboard])
    let from = stage.coloredNote("Risk", CGRect(x: 620, y: 320, width: 120, height: 100), .value(RGB(hex: 0x7FFFD4)))
    let to = stage.coloredNote("Fix", CGRect(x: 760, y: 450, width: 120, height: 100))
    func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
    let arrow = editor.add(Arrow(start: bound(from), end: bound(to), bend: 30, text: "blocks"))
    editor.setColor(.red, of: [arrow])
    editor.selection = nil
}

private let boardSize = CGSize(width: 910, height: 570)

/// A type's id, fixed, so the color it says is the same every run: Employee's indigo, Company's purple.
private func typeID(_ uuid: String) -> ShapeID { ShapeID(UUID(uuidString: uuid)!) }

/// A type given blue and the notes of it, one in its blue and one red of its own; a type built on it, holding no
/// color, and a note of that one; a type that holds no color, and a note of it.
@MainActor
private func typeNotes(_ stage: GalleryStage) {
    let editor = stage.editor
    let person = editor.addTypeNote(colorSchema, text: MentionText(plain: "A person: their name"), title: "Person",
                                    frame: CGRect(x: 40, y: 40, width: 320, height: 160))
    editor.setColor(.blue, of: [person])
    let employee = editor.addTypeNote(colorSchema, text: MentionText(plain: "Someone who works here"), title: "Employee",
                                      frame: CGRect(x: 720, y: 40, width: 320, height: 160), id: typeID("00000001-0000-0000-0000-000000000000"))
    editor.addTypeLink(person, to: employee)
    let company = editor.addTypeNote(colorSchema, text: MentionText(plain: "A company: its name"), title: "Company",
                                     frame: CGRect(x: 1060, y: 40, width: 320, height: 160), id: typeID("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
    for (name, x, type, color) in [("Ann Lee", 40, person, nil), ("Bo Park", 380, person, ShapeColor.red), ("Cy Ng", 720, employee, nil),
                                   ("Acme", 1060, company, nil)] as [(String, CGFloat, ShapeID, ShapeColor?)] {
        let note = stage.coloredNote(name, CGRect(x: x, y: 330, width: 320, height: 160), color)
        editor.addTypeLink(type, to: note)
    }
    editor.selection = nil
}

private let typeNotesSize = CGSize(width: 1420, height: 560)

@MainActor let colorStates: [GalleryState] = [
    GalleryState("colors-board", "a note in each built-in color; a blue frame holding a teal note and a plain one; a green subboard; a note in a hex value and a red arrow that says blocks", size: boardSize) { stage in
        colorBoard(stage)
        return .image(stage.render(at: .zero))
    },
    GalleryState("colors-board-zoomed-out", "the same board at 30%: every shape its skeleton, in its color", size: CGSize(width: 300, height: 190)) { stage in
        colorBoard(stage)
        return .image(stage.render(at: .zero, zoom: 0.3))
    },
    GalleryState("colors-panel-plain-note", "a plain note's panel, its Style tab: the Color row says Yellow, dimmed (its kind's default)") { stage in
        let id = stage.coloredNote("A plain note", CGRect(x: 40, y: 40, width: 200, height: 200))
        return .image(try stage.panelPicture(of: id, tab: .of(StyleTab.self), size: CGSize(width: 300, height: 150)))
    },
    GalleryState("colors-panel-blue-note", "a blue note's panel: the Color row says Blue") { stage in
        let id = stage.coloredNote("A blue note", CGRect(x: 40, y: 40, width: 200, height: 200), .blue)
        return .image(try stage.panelPicture(of: id, tab: .of(StyleTab.self), size: CGSize(width: 300, height: 150)))
    },
    GalleryState("colors-panel-frame", "a frame's panel: the Color row says None, dimmed") { stage in
        let id = stage.editor.add(Frame(frame: CGRect(x: 40, y: 40, width: 300, height: 200)), title: "Sprint 3")
        return .image(try stage.panelPicture(of: id, tab: .of(StyleTab.self), size: CGSize(width: 300, height: 150)))
    },
    GalleryState("colors-grid", "the row's grid for a blue note in a file with two colors of its own: the built-in dots, Blue ringed, the file's under them, then None and Other…") { stage in
        let id = stage.coloredNote("A blue note", CGRect(x: 40, y: 40, width: 200, height: 200), .blue)
        expect(stage.editor.defineColor(named: "Brand", value: RGB(hex: 0x0055FF)))
        expect(stage.editor.defineColor(named: "Ink", value: RGB(hex: 0x1F2937)))
        let model = ColorRowModel(record: try require(stage.editor.document[id]), book: try require(stage.editor.colors))
        return .image(stage.viewPicture(ColorGrid(model: model) { _ in }, size: CGSize(width: 190, height: 150)))
    },
    GalleryState("colors-grid-value", "the grid for a note that holds a hex value: no dot ringed, and Name… under Other…") { stage in
        let id = stage.coloredNote("A picked color", CGRect(x: 40, y: 40, width: 200, height: 200), .value(RGB(hex: 0x7FFFD4)))
        let model = ColorRowModel(record: try require(stage.editor.document[id]), book: try require(stage.editor.colors))
        return .image(stage.viewPicture(ColorGrid(model: model) { _ in }, size: CGSize(width: 190, height: 150)))
    },
    GalleryState("colors-slash-list", "`/color ` in a note: the named colors, each a chip in its color", size: CGSize(width: 420, height: 400)) { stage in
        let id = stage.coloredNote("Ship the beta", CGRect(x: 40, y: 40, width: 200, height: 200))
        let view = try stage.edit(id)
        stage.typeLine("/color ")
        stage.window.settle()
        return .image(try stage.pictureWithList(of: view))
    },
    GalleryState("colors-slash-list-typed", "`/color p`: purple and pink", size: CGSize(width: 420, height: 400)) { stage in
        let id = stage.coloredNote("Ship the beta", CGRect(x: 40, y: 40, width: 200, height: 200))
        let view = try stage.edit(id)
        stage.typeLine("/color p")
        stage.window.settle()
        return .image(try stage.pictureWithList(of: view))
    },
    GalleryState("colors-slash-list-hex", "`/color #46e`: the one row #4466EE", size: CGSize(width: 420, height: 400)) { stage in
        let id = stage.coloredNote("Ship the beta", CGRect(x: 40, y: 40, width: 200, height: 200))
        let view = try stage.edit(id)
        stage.typeLine("/color #46e")
        stage.window.settle()
        return .image(try stage.pictureWithList(of: view))
    },
    GalleryState("colors-type-notes", "a type given blue and its notes: Ann blue, as her type is; Bo red, his own; Cy, an Employee, blue from Person, which Employee is built on, Employee's pill in its id's color; Acme, a Company, which holds no color, in the color Company's id says, as its pill is", size: typeNotesSize) { stage in
        typeNotes(stage)
        return .image(stage.render(at: .zero))
    },
    GalleryState("colors-type-notes-zoomed-out", "the same at 30%: each note's skeleton in the color it's drawn in, the types white", size: CGSize(width: 426, height: 168)) { stage in
        typeNotes(stage)
        return .image(stage.render(at: .zero, zoom: 0.3))
    },
    GalleryState("colors-type", "a type whose note was given green: its pill solid green, and a note that is one green paper, its chip light green; beside it a type with no color, in its id's", size: CGSize(width: 1000, height: 300)) { stage in
        let person = stage.editor.addTypeNote(colorSchema, text: MentionText(plain: "A person: their name"), title: "Person",
                                              frame: CGRect(x: 40, y: 60, width: 200, height: 160))
        stage.editor.setColor(.green, of: [person])
        let ann = stage.coloredNote("Ann Lee", CGRect(x: 390, y: 60, width: 160, height: 160))
        stage.editor.addTypeLink(person, to: ann)
        _ = stage.editor.addTypeNote(colorSchema, text: MentionText(plain: "A company: its name"), title: "Company",
                                     frame: CGRect(x: 740, y: 60, width: 160, height: 160))
        stage.editor.selection = nil
        return .image(stage.render(at: .zero))
    },
    GalleryState("colors-menu", "a note's context menu, with Color ▸", isText: true) { stage in
        let id = stage.coloredNote("A blue note", CGRect(x: 40, y: 40, width: 200, height: 200), .blue)
        stage.editor.selection = id
        return .text(stage.menuOutline(at: CGPoint(x: 140, y: 140)).joined(separator: "\n"))
    },
]
