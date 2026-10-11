import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import Foundation
import Geometry
import LanguageModels
import Mentions
import ProseMaps
import Selection
import SlashCommands
import StickyNotes
import TestKit
import TextEditing
import Types

// The gallery: a test-only tool that renders states of the app's look offscreen, light and dark, named
// for the board panel each answers, so a file can be laid beside the board it came from. It is a tool,
// not the tests: what each state must show is held by the slices' own suites. With `GALLERY_DIR` set
// (`GALLERY_DIR=/some/dir TEST_FILTER=Gallery ./test.sh`) every state is rendered and written, with an
// `index.txt`; with it unset the suite is one quick test (a state in both appearances, in memory), so
// `./test.sh` stays as fast as it is. Other tracks add their states beside `galleryTypesLookStates`.
//
// Not drawn offscreen, so not here: window chrome, a list's material blur, the caret and selection,
// SwiftUI hover and a menu's own pixels (a menu is its `outline`, a text file). The on-screen look is
// the owner's to see in the app.

/// Where the gallery writes, `GALLERY_DIR`; nil: nothing is written.
let galleryDirectory: URL? = ProcessInfo.processInfo.environment["GALLERY_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

/// What a state makes: a picture, or text (a menu's outline).
enum GalleryOutput {
    case image(NSBitmapImageRep)
    case text(String)
}

/// One state: the file it is written to (before `-light`/`-dark`/`.txt`), the board panel it answers and
/// what that panel draws there, and how to make it. Pictures are made once for each appearance.
struct GalleryState {
    let file: String
    /// "Flow2 p1", or "-" for a state no board draws.
    let answers: String
    let draws: String
    /// The stage's size, view points.
    let size: CGSize
    /// Made as text (a menu's outline), once, not as a picture in both appearances.
    let isText: Bool
    let make: @MainActor (GalleryStage) throws -> GalleryOutput

    init(_ file: String, answers: String = "-", _ draws: String, size: CGSize = CGSize(width: 560, height: 360), isText: Bool = false,
         make: @escaping @MainActor (GalleryStage) throws -> GalleryOutput) {
        self.file = file
        self.answers = answers
        self.draws = draws
        self.size = size
        self.isText = isText
        self.make = make
    }

    /// The files it writes.
    var files: [String] { isText ? [file + ".txt"] : [file + "-light.png", file + "-dark.png"] }
}

/// The shipped app's editor in an unshown window, its model scripted (it answers a type's highlights,
/// and nothing else), its pasteboard private, and a way to draw it as the canvas does.
@MainActor
final class GalleryStage {
    let dark: Bool
    let size: CGSize
    let pasteboard = NSPasteboard.withUniqueName()
    let model = ScriptedLanguageModel()
    let scheduler = ManualScheduler()
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView

    /// Runs `body` on a stage, and lets go of its pasteboard.
    static func with<T>(dark: Bool, size: CGSize, _ body: (GalleryStage) throws -> T) rethrows -> T {
        let stage = GalleryStage(dark: dark, size: size)
        defer { stage.pasteboard.releaseGlobally() }
        return try body(stage)
    }

    private init(dark: Bool, size: CGSize) {
        self.dark = dark
        self.size = size
        ProseMapService.forgetEveryAnswer()
        ProseHighlights.forgetEverything()
        model.fallback = { request in
            guard let message = request.messages.first?.text, message.hasPrefix("<prose>") else {
                return .failure(.server(status: 0, message: "the gallery answers highlights only"))
            }
            for (words, map) in galleryHighlightMaps where message.contains(words) { return .success(ModelResponse(text: map)) }
            return .success(ModelResponse(text: "[]"))
        }
        editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, pasteboard: pasteboard, model: model)
        (window, canvas) = windowed(editor)
        window.setContentSize(NSSize(width: size.width, height: size.height))
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        editor.viewportDidResize(to: size)
    }

    /// The run loop for a while, and the scheduler's due actions.
    func spin(_ seconds: Double = 0.1) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
        scheduler.advance(by: .zero)
    }

    /// Waits for every highlights call to land, drawing as the canvas does so the shapes in view ask.
    func landHighlights() {
        for _ in 0..<3 {
            _ = picture()
            spinRunLoop(until: { self.editor.proseMaps.map { $0.callsOut == 0 && $0.callsWaiting == 0 } ?? true })
            spin(0.05)
        }
    }

    /// The camera at `zoom`, its top-left at `origin` (world units).
    func look(at origin: CGPoint, zoom: CGFloat = 1) {
        editor.camera = Camera(origin: origin, zoom: zoom)
    }

    /// The canvas as its window would draw it, editing view and all, at 2x, in this appearance.
    func picture() -> NSBitmapImageRep {
        let scale: CGFloat = 2
        canvas.frame = CGRect(origin: .zero, size: size)
        canvas.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        appearance.performAsCurrentDrawingAppearance { canvas.cacheDisplay(in: canvas.bounds, to: rep) }
        return rep
    }

    var appearance: NSAppearance { NSAppearance(named: dark ? .darkAqua : .aqua)! }

    /// The canvas at `origin` and `zoom`, once the highlights have landed.
    func render(at origin: CGPoint, zoom: CGFloat = 1) -> NSBitmapImageRep {
        look(at: origin, zoom: zoom)
        landHighlights()
        return picture()
    }

    // MARK: Editing and lists

    /// Begins editing a shape, the caret at the end of its words, and returns its text view.
    func edit(_ id: ShapeID) throws -> MentionTextView<AnyMentionable> {
        editor.selection = id
        expect(editor.beginEditing(id))
        let view = try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the editor has the keyboard")
        view.setSelectedRange(NSRange(location: view.textStorage?.length ?? 0, length: 0))
        return view
    }

    /// A new line, and `text` typed on it, as a person types it.
    func typeLine(_ text: String) {
        window.pressReturn()
        window.type(text)
    }

    /// The open list's visible rows, as a picture in this appearance (the part its scroll view shows, in points
    /// with its size), nil with none open.
    func listRows(of view: MentionTextView<AnyMentionable>) -> (image: CGImage, size: CGSize)? {
        guard let list = view.slashCommands?.window, let rows = list.contentView?.descendants.first(where: { $0.accessibilityRole() == .list }),
              let rep = rows.bitmapImageRepForCachingDisplay(in: rows.bounds) else { return nil }
        // The list's own appearance is the window's vibrant one, which draws a translucent line (the
        // separator) as the material's blend and not as a color: set to the plain one, it is the line
        // as it would sit on the panel drawn under it.
        rows.appearance = appearance
        appearance.performAsCurrentDrawingAppearance { rows.cacheDisplay(in: rows.bounds, to: rep) }
        var visible = rows.visibleRect
        if visible.isEmpty { visible = rows.bounds }
        guard let whole = rep.cgImage else { return nil }
        let scale = CGFloat(whole.width) / rows.bounds.width
        // A flipped view's rect is from the top, as the image is; else from the bottom.
        let top = rows.isFlipped ? visible.minY : rows.bounds.height - visible.maxY
        let crop = CGRect(x: visible.minX * scale, y: top * scale, width: visible.width * scale, height: visible.height * scale)
        guard let image = whole.cropping(to: crop) else { return nil }
        return (image, visible.size)
    }

    /// The canvas with the open list drawn under the caret, as the list's window would sit: on the
    /// window's background with a hairline round it (its material blur is not drawn offscreen).
    func pictureWithList(of view: MentionTextView<AnyMentionable>) throws -> NSBitmapImageRep {
        look(at: editor.camera.origin, zoom: editor.camera.zoom)
        landHighlights()
        let base = picture()
        let listed = try require(listRows(of: view), "a list is open")
        let caret = view.firstRect(forCharacterRange: NSRange(location: view.selectedRange().location, length: 0), actualRange: nil)
        let inWindow = window.convertFromScreen(caret)
        var at = canvas.convert(inWindow, from: nil)
        if !canvas.isFlipped { at.origin.y = size.height - at.maxY }
        let rowSize = listed.size
        var origin = CGPoint(x: at.minX, y: at.maxY + 4)
        origin.x = min(max(origin.x, 4), size.width - rowSize.width - 4)
        origin.y = min(origin.y, size.height - rowSize.height - 4)
        let frame = CGRect(origin: origin, size: rowSize)
        let image = listed.image
        guard let graphics = NSGraphicsContext(bitmapImageRep: base) else { throw GalleryFailure("no context to draw the list in") }
        let context = graphics.cgContext
        // The bitmap's context is in points (the rep's size), y up.
        let box = CGRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height)
        appearance.performAsCurrentDrawingAppearance {
            context.saveGState()
            let panel = CGPath(roundedRect: box.insetBy(dx: -1, dy: -1), cornerWidth: 6, cornerHeight: 6, transform: nil)
            context.addPath(panel)
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fillPath()
            context.addPath(panel)
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.setLineWidth(0.5)
            context.strokePath()
            context.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil))
            context.clip()
            context.draw(image, in: box)
            context.restoreGState()
        }
        graphics.flushGraphics()
        return base
    }

    // MARK: Pointer and menus

    /// The pointer over a view point.
    func hover(at point: CGPoint) {
        editor.pointerMoved(PointerEvent(location: point, timestamp: 1, clickCount: 0))
    }

    /// The pointer pressed on a view point, and held.
    func press(at point: CGPoint) {
        hover(at: point)
        editor.pointerDown(PointerEvent(location: point, timestamp: 2, clickCount: 1))
    }

    func release(at point: CGPoint) {
        editor.pointerUp(PointerEvent(location: point, timestamp: 3, clickCount: 1))
    }

    /// The outline of the menu a secondary click at a view point opens.
    func menuOutline(at point: CGPoint) -> [String] {
        canvas.menu(for: window.mouse(.rightMouseDown, at: point, time: 1))?.outline ?? ["(no menu)"]
    }

    /// A view point of a world point, at the camera now.
    func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - editor.camera.origin.x) * editor.camera.zoom, y: (point.y - editor.camera.origin.y) * editor.camera.zoom)
    }
}

/// What the model answers to a type's words, by words the prompt holds: where in the schema each says.
let galleryHighlightMaps: [(words: String, map: String)] = [
    ("A person has", #"[{"text": "a name", "address": "/properties/name"}, {"text": "an email", "address": "/properties/email"}]"#),
    ("An employee has", #"[{"text": "a name", "address": "/properties/name"}, {"text": "a role", "address": "/properties/role"}, {"text": "a start date", "address": "/properties/startDate"}]"#),
    ("A speaker has", #"[{"text": "a talk", "address": "/properties/talk"}]"#),
]

/// Whether a picture says almost nothing: no colour but one fills more than `share` of its pixels'
/// complement, sampled.
@MainActor
func isBlank(_ rep: NSBitmapImageRep, share: Double = 0.01) -> Bool {
    var counts: [UInt32: Int] = [:]
    var total = 0
    var pixel = [Int](repeating: 0, count: 4)
    for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            rep.getPixel(&pixel, atX: x, y: y)
            let key = UInt32(pixel[0] & 0xFF) << 24 | UInt32(pixel[1] & 0xFF) << 16 | UInt32(pixel[2] & 0xFF) << 8 | UInt32(pixel[3] & 0xFF)
            counts[key, default: 0] += 1
            total += 1
        }
    }
    guard total > 0, let common = counts.values.max() else { return true }
    return Double(total - common) / Double(total) < share
}

/// What the gallery has written this run, for `index.txt`.
@MainActor private var galleryWritten: [(file: String, state: GalleryState)] = []

/// Writes a state's files, or checks them in memory, and fails the test for a blank picture or a file
/// that can't be written.
@MainActor
func renderGalleryState(_ state: GalleryState, write: Bool) throws -> [(name: String, output: GalleryOutput)] {
    var made: [(name: String, output: GalleryOutput)] = []
    let first = try GalleryStage.with(dark: false, size: state.size) { try state.make($0) }
    switch first {
    case .text(let text):
        made.append((state.file + ".txt", .text(text)))
    case .image(let light):
        let dark = try GalleryStage.with(dark: true, size: state.size) { try state.make($0) }
        guard case .image(let darkRep) = dark else { throw GalleryFailure("\(state.file): the dark state is not a picture") }
        made.append((state.file + "-light.png", .image(light)))
        made.append((state.file + "-dark.png", .image(darkRep)))
    }
    for (name, output) in made {
        if case .image(let rep) = output { expect(!isBlank(rep), "\(name) is blank") }
        guard write, let directory = galleryDirectory else { continue }
        do {
            let data: Data
            switch output {
            case .image(let rep): data = try require(rep.representation(using: .png, properties: [:]), "\(name) has no PNG")
            case .text(let text): data = Data(text.utf8)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
        } catch {
            expect(false, "\(name) can't be written: \(error)")
        }
    }
    if write { galleryWritten.append((state.file, state)) }
    return made
}

struct GalleryFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// `index.txt`: each file, the board and panel it answers, and what that draws there.
@MainActor
func writeGalleryIndex() {
    guard let directory = galleryDirectory else { return }
    var lines = ["Gallery: every file is light and dark (-light.png, -dark.png) unless it is a .txt (a menu's outline).",
                 "Board and panel: the plan's wireframes (plan-cut/Main.png, Flow1.png, Flow2.png, Flow4.png). \"-\": no board draws it.", ""]
    for (_, state) in galleryWritten {
        lines.append("\(state.file)  [\(state.answers)]  \(state.draws)")
    }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("index.txt"), atomically: true, encoding: .utf8)
    } catch {
        expect(false, "index.txt can't be written: \(error)")
    }
}
