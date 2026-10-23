import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import TestKit

// `canvas capture` over fixtures: Nest's boards (the root's tile Hub, 100 × 60 at (0, 0), and pockets P
// and Q below it; P's Deep, Hub and Twin in a row; Q's Twin), pictured apart from the window, each
// PNG read back.

/// A folder of the test's own for the pictures it takes, gone as the test ends.
@MainActor private func pictures() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    afterThisTest { try? FileManager.default.removeItem(at: folder) }
    return folder
}

/// What a capture says, as `canvas capture <arguments>` would.
@MainActor private func captured(_ arguments: [String], on editor: CanvasEditor) throws -> JSON {
    try run(["capture"] + arguments, on: editor).get()
}

/// Why a capture that should be refused was.
@MainActor private func refused(capturing arguments: [String], on editor: CanvasEditor) throws -> RPCError {
    switch try run(["capture"] + arguments, on: editor) {
    case .success(let result): throw CapturedAnyway(result: result)
    case .failure(let error): return error
    }
}

private struct CapturedAnyway: Error, CustomStringConvertible {
    let result: JSON
    var description: String { "the capture should have been refused, and said \(result.compactText)" }
}

/// The PNG at `path`.
@MainActor private func png(_ path: String) throws -> NSBitmapImageRep {
    try require(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: path))))
}

/// The file a capture says it wrote, for one named `path`.
private func written(_ path: String) -> JSON { .string(URL(fileURLWithPath: path).standardizedFileURL.path) }

/// Whether a pixel is a matte tile's gray, well darker than the canvas around it.
private func isTile(_ color: [Int]) -> Bool { color[0] < 190 && abs(color[0] - color[2]) < 20 }

/// The canvas's light background, a grid dot on it too.
private func isLightCanvas(_ color: [Int]) -> Bool { color[0...2].allSatisfy { $0 > 200 } }

/// How bright a picture's top-left corner is, 0 to 255: the mean of its channels over 12 points
/// square, so a grid dot there counts for little.
@MainActor private func cornerBrightness(_ picture: NSBitmapImageRep) -> Int {
    var total = 0, count = 0
    for x in 0..<12 {
        for y in 0..<12 {
            total += pixel(picture, at: CGPoint(x: x, y: y))[0...2].reduce(0, +)
            count += 3
        }
    }
    return total / count
}

@MainActor let captureTests = Suite("capture", [
    test("with no shapes it's the whole board the window shows, as big as it is at 100% with a first visit's margin; nothing changes") {
        let editor = try Nest().editor(), folder = try pictures()
        let revision = editor.revision
        let file = folder.appendingPathComponent("board.png").path
        let result = try captured([file], on: editor)
        // The root's shapes, 300 × 400 from (0, 0), with 32 of margin on each side: 364 × 464, the board from (32, 32).
        expectEqual(result["board"], ["shows": "root", "showsPath": ["root"]])
        expectEqual(result["file"], written(file))
        expectEqual(result["width"], 364)
        expectEqual(result["height"], 464)
        expectEqual(result["zoom"], 100)
        expectEqual(result["region"], [[-32, -32], [364, 464]])
        expectEqual(result["warnings"], nil)
        let picture = try png(file)
        expectEqual([picture.pixelsWide, picture.pixelsHigh], [364, 464])
        expect(isTile(pixel(picture, at: CGPoint(x: 82, y: 62))), "Hub, at (32, 32): \(pixel(picture, at: CGPoint(x: 82, y: 62)))")
        expect(isLightCanvas(pixel(picture, at: CGPoint(x: 82, y: 200))), "the canvas below it")
        expectEqual(editor.revision, revision, "nothing changed")
        expect(!editor.canUndo, "a picture is no step")
        expectEqual(editor.board, .root)
    },
    test("--shape fits the view to the shapes given, no closer than 100%, in 1200 × 800, with what's around them drawn too") {
        let editor = try Nest().editor(), file = try pictures().appendingPathComponent("hub.png").path
        tile("Near", CGRect(x: 200, y: 0, width: 100, height: 60), in: editor)
        let hub = try captured([file, "--shape", "Hub"], on: editor)
        // Hub's middle, (50, 30), in the picture's, (600, 400); Near beside it, at (750, 370).
        expectEqual(hub["width"], 1200)
        expectEqual(hub["height"], 800)
        expectEqual(hub["zoom"], 100)
        expectEqual(hub["region"], [[-550, -370], [1200, 800]])
        let picture = try png(file)
        expect(isTile(pixel(picture, at: CGPoint(x: 600, y: 400))), "Hub: \(pixel(picture, at: CGPoint(x: 600, y: 400)))")
        expect(isTile(pixel(picture, at: CGPoint(x: 800, y: 400))), "Near, beside it: \(pixel(picture, at: CGPoint(x: 800, y: 400)))")
        // Two: their bounds, 300 × 60 from (0, 0), centered.
        expectEqual(try captured([file, "--shape", "Hub", "--shape", "Near"], on: editor)["region"], [[-450, -370], [1200, 800]])
    },
    test("--zoom takes it at that zoom, centered on the shapes, or on the whole board; it warns where shapes are skeletons, or don't all fit") {
        let editor = try Nest().editor(), file = try pictures().appendingPathComponent("zoom.png").path
        let close = try captured([file, "--shape", "Hub", "--zoom", "200"], on: editor)
        expectEqual(close["zoom"], 200)
        expectEqual(close["region"], [[-250, -170], [600, 400]])
        expect(isTile(pixel(try png(file), at: CGPoint(x: 600, y: 400))), "Hub, at 200%")
        // The board's middle, (150, 200), in the picture's, at 50%.
        let board = try captured([file, "--zoom", "50"], on: editor)
        expectEqual(board["region"], [[-1050, -600], [2400, 1600]])
        expectEqual(board["warnings"], nil)
        expectEqual(try captured([file, "--zoom", "20"], on: editor)["warnings"],
                    ["at 20%, shapes are drawn as skeletons, without their words: zoom in (--zoom), or picture fewer of them (--shape), to read them"])
        expectEqual(try captured([file, "--shape", "Hub", "--zoom", "800", "--size", "200,200"], on: editor)["warnings"],
                    ["at 800%, only part of the shapes given is in the picture: a smaller --zoom, or a larger --size, shows all of them"])
        expectEqual(try captured([file, "--size", "100,100"], on: editor)["warnings"],
                    ["at 9%, shapes are drawn as skeletons, without their words: zoom in (--zoom), or picture fewer of them (--shape), to read them"],
                    "fitted at 9%, all of it fits")
    },
    test("--size and --scale say how big it is, in points and pixels to a point; --dark draws it in the dark appearance") {
        let editor = try Nest().editor(), file = try pictures().appendingPathComponent("sized.png").path
        let result = try captured([file, "--size", "400,300", "--scale", "2"], on: editor)
        // 300 × 400 of shapes fitted in 400 × 300 with 64 of margin: 236 / 400, 59%.
        expectEqual(result["width"], 800)
        expectEqual(result["height"], 600)
        expectEqual(result["zoom"], 59)
        let picture = try png(file)
        expectEqual([picture.pixelsWide, picture.pixelsHigh], [800, 600])
        expectEqual([picture.size.width, picture.size.height], [400, 300], "said in points by its resolution")
        expect(cornerBrightness(picture) > 200, "light, unless asked: \(cornerBrightness(picture))")
        _ = try captured([file, "--dark"], on: editor)
        let dark = cornerBrightness(try png(file))
        expect(dark < 70, "the dark canvas: \(dark)")
    },
    test("a shape on another board is pictured on its board, the window staying where it is; --in and --root say which board") {
        let n = Nest(), editor = try n.editor(), file = try pictures().appendingPathComponent("p.png").path
        let p = String(describing: n.p)
        let deep = try captured([file, "--shape", "Deep"], on: editor)
        expectEqual(deep["board"], ["shows": .string(p), "showsPath": ["root", .string(p)]])
        expectEqual(deep["region"], [[-550, -370], [1200, 800]])
        expectEqual(editor.board, .root, "the window stays where it is")
        // P's board: Deep, Hub and Twin in a row, 700 × 60 from (0, 0).
        let board = try captured([file, "--in", "P"], on: editor)
        expectEqual(board["board"]?["shows"], .string(p))
        expectEqual(board["region"], [[-32, -32], [764, 124]])
        // Hub on P's board, at (300, 0), not the root's.
        expectEqual(try captured([file, "--in", "P", "--shape", "Hub"], on: editor)["region"], [[-250, -370], [1200, 800]])
        // With the window on P: the board it shows, a title there first, or the root with --root.
        expect(editor.showBoard(BoardID(owner: n.p)))
        expectEqual(try captured([file], on: editor)["board"]?["shows"], .string(p))
        expectEqual(try captured([file, "--shape", "Hub"], on: editor)["region"], [[-250, -370], [1200, 800]])
        expectEqual(try captured([file, "--root"], on: editor)["board"], ["shows": "root", "showsPath": ["root"]])
        expectEqual(editor.board, BoardID(owner: n.p))
    },
    test("a title on two boards, neither shown, is ambiguous until --in says which; a picture's shapes are on one board") {
        let n = Nest(), editor = try n.editor(), file = try pictures().appendingPathComponent("twin.png").path
        expectEqual(try refused(capturing: [file, "--shape", "Twin"], on: editor).reason, "ambiguous_title")
        expectEqual(try captured([file, "--in", "Q", "--shape", "Twin"], on: editor)["board"]?["shows"], .string(String(describing: n.q)))
        let apart = try refused(capturing: [file, "--shape", "Hub", "--shape", "Deep"], on: editor)
        expectEqual(apart.reason, "several_boards")
        expectEqual(apart.message, #""Deep" is on "P"'s board, and the picture is of the root board"#)
        expectEqual(try refused(capturing: [file, "--in", "Q", "--shape", "Deep"], on: editor).reason, "several_boards")
    },
    test("#<id> names any shape, titled or not, on any board; an id no shape has is unknown, and # with no id is a title") {
        let n = Nest(), editor = try n.editor(), file = try pictures().appendingPathComponent("id.png").path
        let deep = try captured([file, "--shape", "#\(n.deep)"], on: editor)
        expectEqual(deep["board"]?["shows"], .string(String(describing: n.p)))
        expectEqual(deep["region"], [[-550, -370], [1200, 800]])
        let near = tile("Near", CGRect(x: 200, y: 0, width: 100, height: 60), in: editor)
        let wire = link(try require(editor.document[n.hub]), near, in: editor)
        expectEqual(try captured([file, "--shape", "#\(wire.id)"], on: editor)["board"]?["shows"], "root", "an arrow's id: any shape")
        expectEqual(try captured([file, "--in", "#\(n.p)"], on: editor)["board"]?["shows"], .string(String(describing: n.p)))
        expectEqual(try refused(capturing: [file, "--shape", "#\(ShapeID())"], on: editor).reason, "unknown_id")
        let short = try refused(capturing: [file, "--shape", "#123"], on: editor)
        expectEqual(short.reason, "unknown_title")
        expect(short.hint?.contains("32 hex digits") == true, short.hint ?? "no hint")
    },
    test("without what names shapes, a title can't be found, and an id still is") {
        let n = Nest(), editor = try makeEditor([PocketsPlugin()]), file = try pictures().appendingPathComponent("unnamed.png").path
        editor.replaceFile(with: n.file)
        expectEqual(try refused(capturing: [file, "--shape", "Hub"], on: editor).reason, "no_names")
        expectEqual(try captured([file, "--shape", "#\(n.hub)"], on: editor)["region"], [[-550, -370], [1200, 800]])
    },
    test("a name without .png gets it, and a file there already is replaced") {
        let editor = try Nest().editor(), folder = try pictures()
        let shot = folder.appendingPathComponent("shot").path
        expectEqual(try captured([shot], on: editor)["file"], written(shot + ".png"))
        expectEqual(try png(shot + ".png").pixelsWide, 364)
        expectEqual(try captured([shot + ".png", "--zoom", "50"], on: editor)["width"], 1200)
        expectEqual(try png(shot + ".png").pixelsWide, 1200, "replaced")
    },
    test("it refuses what it can't picture, and a file it can't write, writing nothing, and says why") {
        let editor = try Nest().editor(), folder = try pictures(), file = folder.appendingPathComponent("x.png").path
        let typo = try refused(capturing: [file, "--shape", "Hubb"], on: editor)
        expectEqual(typo.reason, "unknown_title")
        expectEqual(typo.hint, #"did you mean "Hub"?"#)
        expectEqual(try refused(capturing: [file, "--in", "Hub"], on: editor).reason, "cannot_contain")
        expectEqual(try refused(capturing: [file, "--in", "P", "--root"], on: editor).reason, "invalid_params")
        expectEqual(try refused(capturing: ["x.png"], on: editor).reason, "invalid_params", "a file not named from /, as an older canvas sends it")
        let jpeg = try refused(capturing: [folder.appendingPathComponent("x.jpg").path], on: editor)
        expectEqual(jpeg.reason, "invalid_params")
        expect(jpeg.hint?.hasSuffix("x.png") == true, jpeg.hint ?? "no hint")
        expectEqual(try refused(capturing: [folder.appendingPathComponent("gone/x.png").path], on: editor).reason, "no_folder")
        expectEqual(try refused(capturing: [folder.path], on: editor).reason, "invalid_params", "a folder")
        expectEqual(try refused(capturing: [file, "--size", "8000,100", "--scale", "2"], on: editor).reason, "invalid_params")
        expectEqual(try refused(capturing: [file, "--size", "10,10"], on: editor).reason, "invalid_params")
        expectEqual(try refused(capturing: [file, "--zoom", "0.5"], on: editor).reason, "invalid_params")
        expectEqual(try refused(capturing: [file, "--scale", "5"], on: editor).reason, "invalid_params")
        expectEqual(try refused(capturing: [file], on: try drawEditor()).reason, "empty_board")
        expect(!FileManager.default.fileExists(atPath: file), "nothing written")
    },
])
