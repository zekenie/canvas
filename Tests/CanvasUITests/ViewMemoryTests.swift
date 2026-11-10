import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import TestKit

// The view memory keeps plugins' view values (`editor.viewValues`: LineRows' folds) with each file's view, and reads a view
// remembered before it kept them as having none.

@MainActor let viewMemoryTests = Suite("View memory", [
    test("a view's values are remembered with it and read back as they were") {
        let suite = "ViewMemoryTests-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = BoardViewMemory(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/folded.canvasboard")
        var view = BoardViewMemory.View(x: 1, y: 2, zoom: 1, showsDetails: false)
        view.values = ["line-rows.folds": Data("[1,2]".utf8)]
        memory.remember(view, for: url)
        expectEqual(memory.recall(for: url)?.values, ["line-rows.folds": Data("[1,2]".utf8)])
    },
    test("a view remembered before values were kept reads as having none") {
        let suite = "ViewMemoryTests-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = #"[{ "path" : "/tmp/old.canvasboard", "view" : { "x" : 1, "y" : 2, "zoom" : 3, "showsDetails" : false } }]"#
        defaults.set(Data(old.utf8), forKey: "BoardViews")
        let memory = BoardViewMemory(defaults: defaults)
        let view = try require(memory.recall(for: URL(fileURLWithPath: "/tmp/old.canvasboard")))
        expectEqual(view.values, nil)
    },
])
