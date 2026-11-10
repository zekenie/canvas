import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// View values: what a plugin keeps of how a file is viewed on this Mac (LineRows' folds), never in the file. Setting one is
// no commit and no step; the host saves them all and hands them back before the canvas is made, and every service hears
// that.

/// What a service heard of view values being handed back.
@MainActor final class ViewValueLog {
    var restored = 0
}

@MainActor final class ViewValueListener: EditorService {
    let log: ViewValueLog
    init(log: ViewValueLog) { self.log = log }
    func viewValuesDidChange(in editor: CanvasEditor) { log.restored += 1 }
}

struct ViewValuePlugin: CanvasPlugin {
    let log: ViewValueLog
    var id: PluginID { "view-value-listener" }
    func register(into registrar: inout PluginRegistrar) {
        let log = log
        registrar.service { _ in ViewValueListener(log: log) }
    }
}

private struct Kept: Codable, Equatable, Sendable {
    var shapes: [String]
    var level: Int
}

private let keptKey = ViewValueKey<Kept>("test.kept")

@MainActor let viewValueTests = Suite("View values", [
    test("a view value is kept by key, no commit, no step, nothing edited; nil lets it go") {
        let h = try EditorHarness(plugins: [])
        let file = h.editor.file, revision = h.editor.revision
        expectEqual(h.editor.viewValue(keptKey), nil)
        h.editor.setViewValue(keptKey, Kept(shapes: ["a"], level: 2))
        expectEqual(h.editor.viewValue(keptKey), Kept(shapes: ["a"], level: 2))
        expectEqual(h.editor.revision, revision, "no commit")
        expectEqual(h.editor.undoHistory.undoName, nil, "no step")
        expect(h.editor.file == file, "nothing in the file")
        expectEqual(Set(h.editor.viewValues.keys), ["test.kept"])
        h.editor.setViewValue(keptKey, nil)
        expect(h.editor.viewValues.isEmpty, "let go")
    },
    test("values handed back replace what's kept, and every service hears it; one that no longer reads as its type is nil") {
        let log = ViewValueLog()
        let h = try EditorHarness(plugins: [ViewValuePlugin(log: log)])
        let saved = try JSONEncoder().encode(Kept(shapes: ["b"], level: 1))
        h.editor.setViewValue(keptKey, Kept(shapes: ["a"], level: 2))
        h.editor.restoreViewValues(["test.kept": saved, "other": Data("{}".utf8)])
        expectEqual(log.restored, 1, "services hear it")
        expectEqual(h.editor.viewValue(keptKey), Kept(shapes: ["b"], level: 1))
        expectEqual(h.editor.viewValue(ViewValueKey<Kept>("other")), nil, "a value that doesn't read as its type is none")
        expectEqual(h.editor.viewValues.count, 2, "kept as handed back, for the host to save again")
    },
])
