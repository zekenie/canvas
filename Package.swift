// swift-tools-version: 6.0
import PackageDescription

// THE MODULE GRAPH. This file is the only place module dependencies are written down.
// build.sh reads it as a table, so every target stays on ONE line, in exactly this form:
//     .target(name: "X", dependencies: ["A", "B"]),                          // layer: <layer>
//     .target(name: "X", dependencies: ["A"], path: "Examples/X"),          // layer: <layer>
//     .executableTarget(name: "X", dependencies: ["A"], path: "Tests/X"),   // layer: <layer>
// Modules live in Sources/X or Examples/X; test and testsupport modules in Tests/X.
//
// Layers, and what each may depend on:
//     foundation   -> foundation                         the core: knows no plugin
//     ui           -> foundation                         the AppKit/SwiftUI shell around the core
//     horizontal   -> foundation, horizontal             declares extension points that other
//                                                        plugins opt into; knows no vertical
//     vertical     -> foundation, horizontal             a feature (shape kinds, tools); knows no
//                                                        other vertical
//     bridge       -> foundation, horizontal, vertical   glue that connects a vertical to a
//                                                        horizontal, or two horizontals, without
//                                                        either knowing the other
//     composition  -> foundation, horizontal, vertical, bridge     the shipped plugin list
//     app          -> foundation, ui, composition
//     testsupport  -> foundation, testsupport
//     test         -> anything but app and test; a test named <M>Tests may use only M, M's
//                     dependencies, and testsupport and ui modules
//
// build.sh refuses to build when:
//   - the graph has a cycle, or an edge the layers above forbid;
//   - SwiftPM, evaluating this file, sees other targets or dependencies than the one-line table
//     (so code below the targets can't change the graph);
//   - a module's imports, as the compiler parses them, aren't exactly its dependencies here;
//   - an import sits inside #if or carries @_exported, @_implementationOnly or @testable, or code
//     asks canImport(<a module here>);
//   - a public type is named like a module, or Task (it would shadow Swift's in every importer);
//   - a module writes another module's ShapeKind, PluginID, ToolID or PropertyKey as a string
//     literal without depending on that module.
// The graph keeps the core from naming a plugin's types (a module compiles against only its
// dependency closure, with MemberImportVisibility, and the import check rejects undeclared
// imports); the id check keeps any module from writing another module's kind, tool, plugin or property id
// as a literal. The editor's host API is @_spi(Host), which only ui, testsupport and test modules
// may import.
// Audit it:  ./build.sh graph | dot | audit | api <Module>
let package = Package(
    name: "InfiniteCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Geometry", dependencies: []),                                          // layer: foundation
        .target(name: "Canvas", dependencies: ["Geometry"]),                                  // layer: foundation
        .target(name: "CanvasUI", dependencies: ["Canvas", "Geometry"]),                      // layer: ui

        .target(name: "Keyboard", dependencies: ["Canvas"]),                                  // layer: horizontal
        .target(name: "Selection", dependencies: ["Canvas", "Geometry", "Keyboard"]),         // layer: horizontal
        .target(name: "Validation", dependencies: ["Canvas"]),                                // layer: horizontal
        .target(name: "DetailPanel", dependencies: ["Canvas", "Selection"]),                  // layer: horizontal
        .target(name: "ContextMenus", dependencies: ["Canvas", "Selection"]),                 // layer: horizontal
        .target(name: "TableOfContents", dependencies: ["Canvas", "Geometry", "Selection"]),  // layer: horizontal
        .target(name: "Checklists", dependencies: ["Canvas", "ContextMenus", "DetailPanel"]), // layer: horizontal
        .target(name: "Clipboard", dependencies: ["Canvas", "ContextMenus", "Geometry", "Keyboard", "Selection"]), // layer: horizontal
        .target(name: "Titles", dependencies: ["Canvas", "DetailPanel", "TableOfContents"]),  // layer: horizontal
        .target(name: "Locking", dependencies: ["Canvas", "ContextMenus", "Geometry", "Selection"]), // layer: horizontal

        .target(name: "Arrows", dependencies: ["Canvas", "Geometry", "Keyboard", "Selection", "TableOfContents"]), // layer: vertical
        .target(name: "StickyNotes", dependencies: ["Canvas", "Checklists", "DetailPanel", "Keyboard", "Selection", "TableOfContents", "Titles", "Validation"]), // layer: vertical
        .target(name: "Ellipses", dependencies: ["Canvas", "Keyboard"]),                      // layer: vertical
        .target(name: "TaskCards", dependencies: ["Canvas", "Checklists", "ContextMenus", "DetailPanel", "Keyboard", "TableOfContents", "Titles", "Validation"]), // layer: vertical

        .target(name: "ValidationDetails", dependencies: ["Canvas", "DetailPanel", "Validation"]), // layer: bridge
        .target(name: "ValidationContents", dependencies: ["Canvas", "TableOfContents", "Validation"]), // layer: bridge

        // Examples: the smallest plugin for each pattern (see docs/plugin-system.md).
        .target(name: "Rectangles", dependencies: ["Canvas", "Keyboard"], path: "Examples/Rectangles"),                 // layer: vertical
        .target(name: "Eraser", dependencies: ["Canvas", "Keyboard"], path: "Examples/Eraser"),                         // layer: vertical
        .target(name: "Polylines", dependencies: ["Canvas", "Geometry", "Keyboard"], path: "Examples/Polylines"),       // layer: vertical
        .target(name: "Reordering", dependencies: ["Canvas", "ContextMenus"], path: "Examples/Reordering"),             // layer: vertical
        .target(name: "EllipseTitles", dependencies: ["Canvas", "Ellipses", "Titles"], path: "Examples/EllipseTitles"), // layer: bridge

        .target(name: "Composition", dependencies: ["Arrows", "Canvas", "Checklists", "Clipboard", "ContextMenus", "DetailPanel", "EllipseTitles", "Ellipses", "Eraser", "Keyboard", "Locking", "Polylines", "Rectangles", "Reordering", "Selection", "StickyNotes", "TableOfContents", "TaskCards", "Titles", "Validation", "ValidationContents", "ValidationDetails"]), // layer: composition
        .executableTarget(name: "InfiniteCanvas", dependencies: ["Canvas", "CanvasUI", "Composition"]),           // layer: app

        .target(name: "TestKit", dependencies: [], path: "Tests/TestKit"),                                        // layer: testsupport
        .target(name: "CanvasTesting", dependencies: ["Canvas", "Geometry", "TestKit"], path: "Tests/CanvasTesting"), // layer: testsupport
        .executableTarget(name: "CanvasTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "TestKit"], path: "Tests/CanvasTests"), // layer: test
        .executableTarget(name: "KeyboardTests", dependencies: ["Canvas", "CanvasTesting", "Keyboard", "TestKit"], path: "Tests/KeyboardTests"), // layer: test
        .executableTarget(name: "CanvasUITests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "Geometry", "TestKit"], path: "Tests/CanvasUITests"), // layer: test
        .executableTarget(name: "SelectionTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/SelectionTests"), // layer: test
        .executableTarget(name: "ArrowsTests", dependencies: ["Arrows", "Canvas", "CanvasTesting", "Geometry", "Keyboard", "Selection", "TableOfContents", "TestKit"], path: "Tests/ArrowsTests"), // layer: test
        .executableTarget(name: "ValidationTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "TestKit", "Validation"], path: "Tests/ValidationTests"), // layer: test
        .executableTarget(name: "DetailPanelTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Keyboard", "Selection", "TestKit"], path: "Tests/DetailPanelTests"), // layer: test
        .executableTarget(name: "ContextMenusTests", dependencies: ["Canvas", "CanvasTesting", "ContextMenus", "Keyboard", "Selection", "TestKit"], path: "Tests/ContextMenusTests"), // layer: test
        .executableTarget(name: "TableOfContentsTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "Geometry", "Keyboard", "Selection", "TableOfContents", "TestKit"], path: "Tests/TableOfContentsTests"), // layer: test
        .executableTarget(name: "ValidationDetailsTests", dependencies: ["Canvas", "CanvasTesting", "DetailPanel", "TestKit", "Validation", "ValidationDetails"], path: "Tests/ValidationDetailsTests"), // layer: test
        .executableTarget(name: "ValidationContentsTests", dependencies: ["Canvas", "CanvasTesting", "TableOfContents", "TestKit", "Validation", "ValidationContents"], path: "Tests/ValidationContentsTests"), // layer: test
        .executableTarget(name: "ClipboardTests", dependencies: ["Canvas", "CanvasTesting", "Clipboard", "ContextMenus", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/ClipboardTests"), // layer: test
        .executableTarget(name: "ChecklistsTests", dependencies: ["Canvas", "CanvasTesting", "Checklists", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/ChecklistsTests"), // layer: test
        .executableTarget(name: "TaskCardsTests", dependencies: ["Canvas", "CanvasTesting", "Checklists", "ContextMenus", "DetailPanel", "Keyboard", "Selection", "TableOfContents", "TaskCards", "TestKit", "Titles", "Validation"], path: "Tests/TaskCardsTests"), // layer: test
        .executableTarget(name: "StickyNotesTests", dependencies: ["Canvas", "CanvasTesting", "Checklists", "ContextMenus", "DetailPanel", "Keyboard", "Selection", "StickyNotes", "TableOfContents", "TestKit", "Titles", "Validation"], path: "Tests/StickyNotesTests"), // layer: test
        .executableTarget(name: "LockingTests", dependencies: ["Canvas", "CanvasTesting", "ContextMenus", "Geometry", "Keyboard", "Locking", "Selection", "TestKit"], path: "Tests/LockingTests"), // layer: test
        .executableTarget(name: "TitlesTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Geometry", "Keyboard", "Selection", "TableOfContents", "TestKit", "Titles"], path: "Tests/TitlesTests"), // layer: test
        .executableTarget(name: "RectanglesTests", dependencies: ["Canvas", "CanvasTesting", "Keyboard", "Rectangles", "TestKit"], path: "Tests/RectanglesTests"), // layer: test
        .executableTarget(name: "ExamplesTests", dependencies: ["Arrows", "Canvas", "CanvasTesting", "ContextMenus", "EllipseTitles", "Ellipses", "Eraser", "Keyboard", "Polylines", "Rectangles", "Reordering", "Selection", "TableOfContents", "TestKit", "Titles"], path: "Tests/ExamplesTests"), // layer: test
        .executableTarget(name: "CompositionTests", dependencies: ["Arrows", "Canvas", "CanvasTesting", "CanvasUI", "Checklists", "Clipboard", "Composition", "DetailPanel", "Geometry", "Keyboard", "Locking", "Selection", "StickyNotes", "TableOfContents", "TaskCards", "TestKit", "Titles", "Validation", "ValidationDetails"], path: "Tests/CompositionTests"), // layer: test
        .executableTarget(name: "BenchmarkTests", dependencies: ["Arrows", "Canvas", "CanvasTesting", "CanvasUI", "Checklists", "Composition", "Ellipses", "Geometry", "Locking", "StickyNotes", "TableOfContents", "TaskCards", "TestKit", "Titles", "Validation"], path: "Tests/BenchmarkTests"), // layer: test
    ],
    swiftLanguageModes: [.v6]
)

// build.sh passes the same to swiftc: without it, members of modules a file doesn't import leak
// into scope and the import audit would miss real dependencies.
for target in package.targets {
    target.swiftSettings = [.enableUpcomingFeature("MemberImportVisibility")]
}
