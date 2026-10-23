import AppKit
import Canvas
import CanvasRPC
import Draw
import DrawScript
import Foundation
import UniformTypeIdentifiers

// `canvas capture`: a picture of a board, or of part of one, in a PNG file, so whoever draws on a
// board can look at what it made. The core's `BoardPicture` draws it as the canvas draws the board,
// with nothing selected, apart from the window (as Edit › Copy as Image does): nothing moves on
// screen, the window needn't be in view, and nothing on any board changes, so it's no undo step.
// With no shapes named it's the whole board, fitted; with shapes (titles, as a script names them, or
// ids for shapes with none) it's fitted to those, as `draw --reveal` fits what it drew, with what's
// around them drawn too; with a zoom, it's at that zoom, centered on them (or on the whole board).

/// What `canvas capture` takes.
struct CaptureParams: SchemaDefined {
    static let properties = Properties<CaptureParams>(title: "capture") {
        Property("file", \.file).required()
            .keywords(["x-path": true, "x-value-name": "file", "x-timeout": .number(CaptureStyle.wait)])
            .description("The PNG file to write (a name without .png gets it). A file there already is replaced.")
        Property("shape", \.shapes).keywords(["x-value-name": "name"])
            .description("A shape to look at: its title, or #<id> for one with none. The picture is fitted to the shapes given, with what's around them. Give it again for each.")
        Property("zoom", \.zoom).minimum(CaptureStyle.zooms.lowerBound).maximum(CaptureStyle.zooms.upperBound)
            .description("Take it at this zoom, in percent (100 is actual size), centered on the shapes given, or on the whole board, rather than fitted.")
        Property("in", \.inside).keywords(["x-value-name": "name"])
            .description("Picture the board a subboard holds, by its title (or #<id>), rather than the one the window shows.")
        Property("root", \.root).description("Picture the board at the top of the file.")
        Property("size", \.size).keywords(["x-value-name": "width,height"])
            .description("The picture's size in points. Default: the whole board's at 100%, at most \(CaptureStyle.said(CaptureStyle.limit)); \(CaptureStyle.said(CaptureStyle.view)) with --shape or --zoom.")
        Property("scale", \.scale).minimum(1).maximum(CaptureStyle.largestScale).description("Pixels to a point.")
        Property("dark", \.dark).description("In the dark appearance, rather than the light.")
    }

    var file = ""
    var shapes: [String] = []
    var zoom: Double?
    var inside: String?
    var root = false
    var size: CGSize?
    var scale: Double = 1
    var dark = false
}

/// A picture taken: where it is, how big, and what of the board it shows.
struct CaptureResult: Encodable, Sendable {
    struct Shown: Encodable, Sendable {
        var shows: String
        var showsPath: [String]
    }

    /// The board pictured, as `boards` says what a window shows (the server adds the file's id and
    /// name): the one the window shows, or the one the shapes, `--in` or `--root` say.
    var board: Shown
    /// The PNG written, by its whole path.
    var file: String
    /// Its size in pixels.
    var width: Int
    var height: Int
    /// The zoom it's at, in percent.
    var zoom: Double
    /// The part of the board in it, in world units: `[[x, y], [width, height]]`, as a draw's `at`
    /// says where a shape is.
    var region: CGRect
    var warnings: [String]?
}

/// What a capture is when the command line doesn't say, and how far it may go.
enum CaptureStyle {
    /// The most a picture of the whole board is, in points: as big as Quick Look's preview gets. A
    /// board that doesn't fit this at 100% is drawn as close as fits it.
    static let limit = CGSize(width: 1600, height: 1200)
    /// A picture of shapes, or at a zoom, in points: a window's worth of the board around them.
    static let view = CGSize(width: 1200, height: 800)
    /// The margin, in all, a picture fitted to shapes leaves around them: what `draw --reveal`
    /// leaves around what it drew.
    static let shapesInset: CGFloat = 100
    /// The zooms `--zoom` takes, in percent: as far out as a picture of a board goes, and as close
    /// as the canvas.
    static let zooms: ClosedRange<Double> = 1...800
    /// The smallest a side of a picture is, in points.
    static let smallestSide: CGFloat = 16
    /// The most pixels a side of a picture has: its size in points times its scale.
    static let largestSide: CGFloat = 8192
    /// The most pixels to a point.
    static let largestScale: Double = 4
    /// How long `canvas` waits for a picture, in seconds: the file is read whole, as opening it
    /// does, and the previews its cards show are built (up to 5 s) before it's drawn.
    static let wait: Double = 30

    /// A size as `--size` takes it: `1200,800`.
    static func said(_ size: CGSize) -> String { "\(Int(size.width)),\(Int(size.height))" }
}

@MainActor
func capture(_ params: CaptureParams, in context: AutomationContext) throws(AutomationError) -> CaptureResult {
    let editor = try context.board()
    let file = try pictureFile(params.file)
    let subject = try CaptureSubject(params, in: editor)
    let picture = BoardPicture(file: editor.file, registry: editor.registry, board: subject.board)
    guard !picture.isEmpty else {
        throw AutomationError("\(FileNames.named(subject.board, in: editor, naming: editor.registry.drawNaming)) has nothing on it to picture",
                              reason: "empty_board", hint: "draw something on it first")
    }
    if !subject.shapes.isEmpty {
        picture.focus = Set(subject.shapes)
        picture.inset = CaptureStyle.shapesInset
    }
    picture.zoom = params.zoom.map { CGFloat($0) / 100 }
    let size: CGSize
    if let asked = params.size {
        guard asked.width >= CaptureStyle.smallestSide, asked.height >= CaptureStyle.smallestSide else {
            throw invalidParams("--size is at least \(Int(CaptureStyle.smallestSide)) points a side, and \(CaptureStyle.said(asked)) isn't")
        }
        size = asked
    } else if subject.shapes.isEmpty, params.zoom == nil {
        size = picture.size(within: CaptureStyle.limit)
    } else {
        size = CaptureStyle.view
    }
    let scale = CGFloat(params.scale)
    let width = (size.width * scale).rounded(), height = (size.height * scale).rounded()
    guard width <= CaptureStyle.largestSide, height <= CaptureStyle.largestSide else {
        throw invalidParams("a picture is at most \(Int(CaptureStyle.largestSide)) pixels a side, and \(CaptureStyle.said(size)) at \(said(params.scale))× is \(Int(width)) × \(Int(height))",
                            hint: "a smaller --size, or --scale")
    }
    guard let appearance = NSAppearance(named: params.dark ? .darkAqua : .aqua), let framing = picture.framing(in: size),
          let png = picture.pngData(size: size, scale: scale, appearance: appearance) else {
        throw AutomationError("the picture couldn't be drawn", reason: "internal")
    }
    do {
        try png.write(to: file, options: .atomic)
    } catch {
        throw AutomationError("\(file.path) couldn't be written: \(error.localizedDescription)", reason: "cannot_save")
    }
    let percent = (Double(framing.zoom) * 1000).rounded() / 10
    var warnings: [String] = []
    // A point of slack: what's fitted touches the margin it's fitted with, and the arithmetic may round past it.
    if !framing.region.insetBy(dx: -1, dy: -1).contains(framing.about) {
        warnings.append(subject.shapes.isEmpty
            ? "at \(said(percent))%, only part of the board is in the picture: \(params.zoom == nil ? "a larger --size" : "a smaller --zoom, or a larger --size,") shows more of it"
            : "at \(said(percent))%, only part of the shapes given is in the picture: \(params.zoom == nil ? "a larger --size" : "a smaller --zoom, or a larger --size,") shows all of them")
    }
    if framing.drawsSkeletons {
        warnings.append("at \(said(percent))%, shapes are drawn as skeletons, without their words: zoom in (--zoom), or picture fewer of them (--shape), to read them")
    }
    let path = editor.file.path(to: subject.board) ?? [subject.board]
    return CaptureResult(board: CaptureResult.Shown(shows: subject.board.description, showsPath: path.map(\.description)),
                         file: file.path, width: Int(width), height: Int(height), zoom: percent, region: framing.region.integral,
                         warnings: warnings.isEmpty ? nil : warnings)
}

/// What a capture pictures: a board, and the shapes on it the view is fitted to, or centered on
/// (none: the whole board). The board is the one `--in` or `--root` names, else the one the first
/// shape is on (a title found as a script finds one: the board shown's first), else the one the
/// window shows; every shape must be on it, and a title is looked for there alone once it's known.
@MainActor
private struct CaptureSubject {
    let board: BoardID
    let shapes: [ShapeID]

    init(_ params: CaptureParams, in editor: CanvasEditor) throws(AutomationError) {
        let lookup = CaptureLookup(editor)
        var board: BoardID?
        switch (params.inside, params.root) {
        case (nil, false): board = nil
        case (nil, true): board = .root
        case (let written?, false): board = try lookup.board(heldBy: written)
        case (.some, true): throw invalidParams("--in and --root each say which board to picture: give one")
        }
        var shapes: [ShapeID] = []
        for written in params.shapes {
            let (id, on) = try lookup.shape(written, on: board)
            board = board ?? on
            if !shapes.contains(id) { shapes.append(id) }
        }
        self.board = board ?? editor.board
        self.shapes = shapes
    }
}

/// Finds what `--shape` and `--in` name as a script names a shape the file has: by its title
/// (folded as the plugin that names shapes folds one), or `#<id>` for a shape with none (any shape:
/// a picture can be of an arrow). Text that starts with `#` and isn't an id is a title.
@MainActor
private final class CaptureLookup {
    private let editor: CanvasEditor
    /// The file's names, read the first time a title asks.
    private var names: FileNames?

    init(_ editor: CanvasEditor) {
        self.editor = editor
    }

    /// The shape `written` names, and its board: on `board` alone when it's known.
    func shape(_ written: String, on board: BoardID?) throws(AutomationError) -> (ShapeID, BoardID) {
        if let id = Self.id(written) {
            guard let on = editor.file.board(containing: id), let record = editor.file.record(id), editor.canShow(on), !record.isOpaque else {
                throw AutomationError("there's no shape with the id \(written)", reason: ScriptError.Reason.unknownID.rawValue,
                                      hint: "it may have been deleted, or be on a board the app can't show: run the query that gave it again")
            }
            if let board, on != board { throw elsewhere(written, on: on, board: board) }
            return (id, on)
        }
        let name = try Self.name(written)
        let (said, found): (String, FileNames.Found)
        if case .path(let path)? = name {
            let (names, folded) = try fold(path)
            (said, found) = (folded.written, names.shape(path: folded, on: board))
        } else {
            let (title, names) = try fold(name?.title ?? written)
            (said, found) = (quoted(title), names.shape(called: title, on: board))
        }
        switch found {
        case .shape(let id, on: let on):
            return (id, on)
        case .none(let like):
            let here = board.map { " on \(named($0))" } ?? ""
            let guess: String? = like.isEmpty ? nil : "did you mean \(oneOf(like.prefix(3).map(quoted)))?"
            let idHint: String? = written.first == ShapeName.idMark
                ? "an id is 32 hex digits in groups of 8, 4, 4, 4 and 12 after the #, as a query's row gives it" : nil
            throw AutomationError("there's no shape called \(said)\(here)", reason: ScriptError.Reason.unknownTitle.rawValue,
                                  hint: idHint ?? guess ?? "\(RPC.commandName) query '[title]' lists the file's titles")
        case .elsewhere(let other):
            throw elsewhere(said, on: other, board: board ?? other)
        case .ambiguous(let message, let hint):
            throw AutomationError(message, reason: ScriptError.Reason.ambiguousTitle.rawValue, hint: hint)
        }
    }

    /// The name `written` is when it is spelled as a script spells one (a quoted title, `#<id> > …`, a path); nil for a bare title.
    /// A name that isn't one is refused with the parser's words.
    private static func name(_ written: String) throws(AutomationError) -> ShapeName? {
        guard ShapeName.isScriptSpelling(written) else { return nil }
        do throws(ScriptError) {
            return try ShapeName(parsing: written)
        } catch {
            throw AutomationError(error.message, reason: error.reason == .syntax ? "invalid_params" : error.reason.rawValue, hint: error.hint,
                                  invalidParams: error.reason == .syntax)
        }
    }

    /// A path folded as the plugin that names shapes folds one, and the file's names to look it up in.
    private func fold(_ path: ShapePath) throws(AutomationError) -> (FileNames, ShapePath) {
        guard let naming = editor.registry.drawNaming else {
            throw AutomationError("nothing here gives shapes names, so none can be found by its path", reason: ScriptError.Reason.noNames.rawValue,
                                  hint: "name shapes by their #id, which a query's row gives")
        }
        let read = names ?? FileNames(editor, naming: naming)
        names = read
        guard let folded = read.folded(path) else { throw invalidParams("a title can't be blank") }
        return (read, folded)
    }

    /// The board the shape `written` names holds (a subboard's).
    func board(heldBy written: String) throws(AutomationError) -> BoardID {
        let canvas = RPC.commandName
        if let id = Self.id(written) {
            guard let record = editor.file.record(id), let on = editor.file.board(containing: id), editor.canShow(on), !record.isOpaque else {
                throw AutomationError("there's no shape with the id \(written)", reason: ScriptError.Reason.unknownID.rawValue,
                                      hint: "\(canvas) query 'subboard' lists the subboards, every board's")
            }
            guard editor.registry.boardOwningKinds.contains(record.kind), editor.canShow(BoardID(owner: id)) else {
                throw holdsNoBoard(written, record)
            }
            return BoardID(owner: id)
        }
        let name = try Self.name(written)
        let said: String, container: FileNames.Container
        if case .path(let path)? = name {
            let (names, folded) = try fold(path)
            (said, container) = (folded.written, names.container(path: folded, boards: true, board: editor.board))
        } else {
            let (title, names) = try fold(name?.title ?? written)
            (said, container) = (quoted(title), names.container(called: title, boards: true))
        }
        switch container {
        case .board(let board), .shape(_, on: let board):       // (never a frame, with boards alone)
            return board
        case .none:
            throw AutomationError("there's no shape called \(said)", reason: ScriptError.Reason.unknownTitle.rawValue,
                                  hint: "\(canvas) query 'subboard' lists the subboards, every board's")
        case .holdsNone(let record):
            throw holdsNoBoard(said, record)
        case .ambiguous(let boards, let listing, let hint):
            throw AutomationError("\(boards.count) shapes that hold boards are called \(said): \(listing)", reason: ScriptError.Reason.ambiguousTitle.rawValue,
                                  hint: hint)
        }
    }

    /// `written` folded as a title, and the file's names to look it up in.
    private func fold(_ written: String) throws(AutomationError) -> (String, FileNames) {
        guard let naming = editor.registry.drawNaming else {
            throw AutomationError("nothing here gives shapes names, so none can be found by its title", reason: ScriptError.Reason.noNames.rawValue,
                                  hint: "name shapes by their #id, which a query's row gives")
        }
        guard let title = naming.fold(written) else { throw invalidParams("a title can't be blank") }
        if let names { return (title, names) }
        let read = FileNames(editor, naming: naming)
        names = read
        return (title, read)
    }

    /// `"Twin" is on "Q"'s board, and the picture is of "P"'s board`: a picture is of one board.
    private func elsewhere(_ said: String, on other: BoardID, board: BoardID) -> AutomationError {
        AutomationError("\(said) is on \(named(other)), and the picture is of \(named(board))", reason: ScriptError.Reason.severalBoards.rawValue,
                        hint: "a picture is of one board: --in or --root says which, else the board of the first --shape")
    }

    private func holdsNoBoard(_ said: String, _ record: AnyShapeRecord) -> AutomationError {
        AutomationError("\(said) is \(indefinite(record.kind)), which holds no board", reason: ScriptError.Reason.cannotContain.rawValue,
                        hint: "--in names a subboard; --shape \(said) pictures the shape itself, with what's around it")
    }

    private func named(_ board: BoardID) -> String { FileNames.named(board, in: editor, naming: editor.registry.drawNaming) }

    /// The id `#<id>` spells, as a query's row gives it; nil for anything else (a title).
    private static func id(_ written: String) -> ShapeID? {
        guard written.first == ShapeName.idMark else { return nil }
        let text = written.dropFirst()
        guard ShapeName.isID(text), let uuid = UUID(uuidString: String(text)) else { return nil }
        return ShapeID(uuid)
    }
}

/// The file a picture goes in: named whole, from `/`, as `canvas` sends a file (`x-path`), `.png`
/// added to a name without a known type's extension, as the Save panel adds one (`v1.2` is
/// `v1.2.png`); refused for another type's file (`.jpg`), for a folder, and in a folder that isn't
/// there.
private func pictureFile(_ written: String) throws(AutomationError) -> URL {
    let canvas = RPC.commandName
    guard written.hasPrefix("/") else {
        throw invalidParams("a picture's file is named by its whole path, from /, and \(written.isEmpty ? "none was given" : "\(written) isn't one")")
    }
    let given = URL(fileURLWithPath: written).standardizedFileURL
    guard !isFolder(given) else { throw invalidParams("\(given.path) is a folder", hint: "name a file inside it: \(shellQuoted(given.appendingPathComponent("board.png").path))") }
    var file = given
    if given.pathExtension.lowercased() != "png" {
        let other = given.pathExtension
        if !other.isEmpty, let type = UTType(filenameExtension: other), !type.isDynamic {
            throw invalidParams("a picture is a PNG file, and \(given.lastPathComponent) is a .\(other) file",
                                hint: "\(canvas) capture \(shellQuoted(given.deletingPathExtension().appendingPathExtension("png").path))")
        }
        var name = given.lastPathComponent
        while name.hasSuffix(".") { name.removeLast() }
        file = given.deletingLastPathComponent().appendingPathComponent("\(name).png")
        guard !isFolder(file) else { throw invalidParams("\(file.path) is a folder", hint: "name a file inside it, or another file") }
    }
    let folder = file.deletingLastPathComponent()
    guard isFolder(folder) else {
        throw AutomationError("there's no folder \(folder.path)", reason: "no_folder", hint: "make it first: mkdir -p \(shellQuoted(folder.path))")
    }
    return file
}

private func isFolder(_ url: URL) -> Bool {
    var isFolder: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
}

/// A path as a shell takes it: in single quotes when it holds anything a shell reads.
private func shellQuoted(_ path: String) -> String {
    path.contains(where: { $0.isWhitespace || "'\"$`\\".contains($0) }) ? "'\(path.replacingOccurrences(of: "'", with: #"'\''"#))'" : path
}

/// A number as a message says it: whole, or to the tenth.
private func said(_ number: Double) -> String {
    number.rounded() == number ? String(Int(number)) : String(number)
}

/// `"A"`, `"A" or "B"`, `"A", "B" or "C"`.
private func oneOf(_ items: [String]) -> String {
    guard let last = items.last else { return "" }
    return items.count == 1 ? last : "\(items.dropLast().joined(separator: ", ")) or \(last)"
}

private func invalidParams(_ message: String, hint: String = "`\(RPC.commandName) help capture` says what it takes.") -> AutomationError {
    AutomationError(message, reason: "invalid_params", hint: hint, invalidParams: true)
}
