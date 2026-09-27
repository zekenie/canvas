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
//   - a module writes another module's ShapeKind, PluginID or ToolID as a string literal without
//     depending on that module.
// The graph keeps the core from naming a plugin's types (a module compiles against only its
// dependency closure, with MemberImportVisibility, and the import check rejects undeclared
// imports); the id check keeps any module from writing another module's kind, tool or plugin id
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

        .target(name: "Selection", dependencies: ["Canvas", "Geometry"]),                     // layer: horizontal
        .target(name: "Validation", dependencies: ["Canvas"]),                                // layer: horizontal
        .target(name: "DetailPanel", dependencies: ["Canvas", "Selection"]),                  // layer: horizontal
        .target(name: "Checklists", dependencies: ["Canvas", "DetailPanel"]),                 // layer: horizontal

        .target(name: "Arrows", dependencies: ["Canvas", "Geometry", "Selection"]),           // layer: vertical
        .target(name: "StickyNotes", dependencies: ["Canvas", "Checklists", "Selection", "Validation"]), // layer: vertical
        .target(name: "Ellipses", dependencies: ["Canvas"]),                                  // layer: vertical
        .target(name: "TaskCards", dependencies: ["Canvas", "Checklists", "DetailPanel", "Validation"]), // layer: vertical

        .target(name: "ValidationDetails", dependencies: ["Canvas", "DetailPanel", "Validation"]), // layer: bridge

        // Examples: the smallest plugin for each pattern (see docs/plugin-system.md).
        .target(name: "Titles", dependencies: ["Canvas", "Geometry", "Selection"], path: "Examples/Titles"),            // layer: horizontal
        .target(name: "Rectangles", dependencies: ["Canvas"], path: "Examples/Rectangles"),                             // layer: vertical
        .target(name: "Eraser", dependencies: ["Canvas"], path: "Examples/Eraser"),                                     // layer: vertical
        .target(name: "EllipseTitles", dependencies: ["Canvas", "Ellipses", "Titles"], path: "Examples/EllipseTitles"), // layer: bridge

        .target(name: "Composition", dependencies: ["Arrows", "Canvas", "Checklists", "DetailPanel", "EllipseTitles", "Ellipses", "Eraser", "Rectangles", "Selection", "StickyNotes", "TaskCards", "Titles", "Validation", "ValidationDetails"]), // layer: composition
        .executableTarget(name: "InfiniteCanvas", dependencies: ["Canvas", "CanvasUI", "Composition"]),           // layer: app

        .target(name: "TestKit", dependencies: [], path: "Tests/TestKit"),                                        // layer: testsupport
        .target(name: "CanvasTesting", dependencies: ["Canvas", "Geometry", "TestKit"], path: "Tests/CanvasTesting"), // layer: testsupport
        .executableTarget(name: "CanvasTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "TestKit"], path: "Tests/CanvasTests"), // layer: test
        .executableTarget(name: "SelectionTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "Selection", "TestKit"], path: "Tests/SelectionTests"), // layer: test
        .executableTarget(name: "ArrowsTests", dependencies: ["Arrows", "Canvas", "CanvasTesting", "Geometry", "Selection", "TestKit"], path: "Tests/ArrowsTests"), // layer: test
        .executableTarget(name: "ValidationTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "TestKit", "Validation"], path: "Tests/ValidationTests"), // layer: test
        .executableTarget(name: "DetailPanelTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Selection", "TestKit"], path: "Tests/DetailPanelTests"), // layer: test
        .executableTarget(name: "ValidationDetailsTests", dependencies: ["Canvas", "CanvasTesting", "DetailPanel", "TestKit", "Validation", "ValidationDetails"], path: "Tests/ValidationDetailsTests"), // layer: test
        .executableTarget(name: "ChecklistsTests", dependencies: ["Canvas", "CanvasTesting", "Checklists", "DetailPanel", "Geometry", "Selection", "TestKit"], path: "Tests/ChecklistsTests"), // layer: test
        .executableTarget(name: "TaskCardsTests", dependencies: ["Canvas", "CanvasTesting", "Checklists", "DetailPanel", "Selection", "TaskCards", "TestKit", "Validation"], path: "Tests/TaskCardsTests"), // layer: test
        .executableTarget(name: "StickyNotesTests", dependencies: ["Canvas", "CanvasTesting", "Checklists", "DetailPanel", "Selection", "StickyNotes", "TestKit", "Validation"], path: "Tests/StickyNotesTests"), // layer: test
        .executableTarget(name: "ExamplesTests", dependencies: ["Arrows", "Canvas", "CanvasTesting", "EllipseTitles", "Ellipses", "Eraser", "Rectangles", "Selection", "TestKit", "Titles"], path: "Tests/ExamplesTests"), // layer: test
        .executableTarget(name: "CompositionTests", dependencies: ["Arrows", "Canvas", "CanvasTesting", "CanvasUI", "Checklists", "Composition", "DetailPanel", "Geometry", "Selection", "StickyNotes", "TaskCards", "TestKit", "Validation"], path: "Tests/CompositionTests"), // layer: test
    ],
    swiftLanguageModes: [.v6]
)

// build.sh passes the same to swiftc: without it, members of modules a file doesn't import leak
// into scope and the import audit would miss real dependencies.
for target in package.targets {
    target.swiftSettings = [.enableUpcomingFeature("MemberImportVisibility")]
}
