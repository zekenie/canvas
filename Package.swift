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
//     wire         -> wire                               what the app and its command line say to
//                                                        each other; knows no canvas, plugin or AppKit
//     foundation   -> foundation                         the core, and pure libraries beneath the
//                                                        plugins (DrawScript): knows no plugin
//     ui           -> foundation, wire                   the AppKit/SwiftUI shell around the core, and
//                                                        the app's end of the command line
//     horizontal   -> foundation, horizontal, wire       declares extension points that other
//                                                        plugins opt into; knows no vertical
//     vertical     -> foundation, horizontal             a feature (shape kinds, tools); knows no
//                                                        other vertical
//     bridge       -> foundation, horizontal, vertical   glue that connects a vertical to a
//                                                        horizontal, or two horizontals, without
//                                                        either knowing the other
//     composition  -> foundation, horizontal, vertical, bridge, wire   the shipped plugin list
//     app          -> foundation, ui, composition, wire
//     cli          -> wire                               the command line (`canvas`), an executable:
//                                                        knows only the wire, never the app
//     testsupport  -> foundation, testsupport
//     test         -> anything but app, cli and test; a test named <M>Tests may use only M, M's
//                     dependencies, and testsupport and ui modules
//
// build.sh refuses to build when:
//   - the graph has a cycle, or an edge the layers above forbid;
//   - SwiftPM, evaluating this file, sees other targets or dependencies than the one-line table
//     (so code below the targets can't change the graph);
//   - a module's imports, as the compiler parses them, aren't exactly its dependencies here;
//   - an import sits inside #if or carries @_exported, @_implementationOnly or @testable, or code
//     asks canImport(<a module here>);
//   - a public type is named like a module, or Task or Span (either would shadow Swift's in every
//     importer);
//   - a module writes another module's ShapeKind, PluginID, ToolID, PropertyKey, ChannelID (a
//     Connections channel's) or EdgeTypeID (a Topology edge type's) as a string literal without
//     depending on that module.
// The graph keeps the core from naming a plugin's types (a module compiles against only its
// dependency closure, with MemberImportVisibility, and the import check rejects undeclared
// imports); the id check keeps any module from writing another module's kind, tool, plugin, property,
// channel or edge type id as a literal. The editor's host API is @_spi(Host), which only ui, testsupport and test modules
// may import.
// Audit it:  ./build.sh graph | dot | audit | api <Module>
let package = Package(
    name: "InfiniteCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Geometry", dependencies: []),                                          // layer: foundation
        .target(name: "DrawScript", dependencies: ["Geometry"]),                              // layer: foundation
        .target(name: "QueryLanguage", dependencies: []),                                     // layer: foundation
        .target(name: "TextEditing", dependencies: []),                                       // layer: foundation
        .target(name: "Canvas", dependencies: ["Geometry"]),                                  // layer: foundation
        .target(name: "CanvasRPC", dependencies: []),                                         // layer: wire
        .target(name: "CanvasUI", dependencies: ["Canvas", "CanvasRPC", "Geometry"]),         // layer: ui

        .target(name: "Keyboard", dependencies: ["Canvas"]),                                  // layer: horizontal
        .target(name: "Selection", dependencies: ["Canvas", "Geometry", "Keyboard"]),         // layer: horizontal
        .target(name: "Validation", dependencies: ["Canvas", "DetailPanel", "TableOfContents"]), // layer: horizontal
        .target(name: "DetailPanel", dependencies: ["Canvas", "Selection", "TextEditing"]),   // layer: horizontal
        .target(name: "ContextMenus", dependencies: ["Canvas", "Selection"]),                 // layer: horizontal
        .target(name: "SlashCommands", dependencies: ["Canvas", "TextEditing"]),              // layer: horizontal
        .target(name: "TableOfContents", dependencies: ["Canvas", "Selection"]),              // layer: horizontal
        .target(name: "Adornments", dependencies: ["Canvas", "Geometry", "Selection"]),       // layer: horizontal
        .target(name: "Clipboard", dependencies: ["Canvas", "ContextMenus", "Geometry", "Keyboard", "Selection"]), // layer: horizontal
        .target(name: "Titles", dependencies: ["Adornments", "Canvas", "DetailPanel", "SlashCommands", "TableOfContents", "Validation"]),  // layer: horizontal
        .target(name: "Locking", dependencies: ["Adornments", "Canvas", "ContextMenus", "Selection", "SlashCommands", "TableOfContents"]), // layer: horizontal
        .target(name: "Connections", dependencies: ["Canvas", "Geometry", "Selection", "TableOfContents", "TextEditing", "Topology"]), // layer: horizontal
        .target(name: "Automation", dependencies: ["Canvas", "CanvasRPC", "DrawScript", "Geometry"]), // layer: horizontal
        .target(name: "LanguageModels", dependencies: ["Canvas"]),                            // layer: horizontal
        .target(name: "Mentions", dependencies: ["Canvas", "ContextMenus", "DetailPanel", "Selection", "SlashCommands", "TableOfContents", "TextEditing", "Titles", "Topology", "Validation"]), // layer: horizontal
        .target(name: "Boards", dependencies: ["Canvas", "ContextMenus", "DetailPanel", "Keyboard", "Selection", "TableOfContents", "Titles"]), // layer: horizontal
        .target(name: "Snapping", dependencies: ["Canvas", "Geometry"]),                      // layer: horizontal
        .target(name: "Topology", dependencies: ["Canvas"]),                                  // layer: horizontal
        .target(name: "Queries", dependencies: ["Canvas", "DrawScript", "QueryLanguage", "Topology"]), // layer: horizontal
        .target(name: "QueryCommands", dependencies: ["Automation", "Canvas", "CanvasRPC", "LanguageModels", "Queries", "QueryLanguage"]), // layer: horizontal
        .target(name: "QueryLexicon", dependencies: ["Boards", "Canvas", "Mentions", "Queries", "Selection", "Titles", "Topology", "Validation"]), // layer: horizontal
        .target(name: "DrawLexicon", dependencies: ["Automation", "Canvas", "Connections", "Titles", "Validation"]), // layer: horizontal

        .target(name: "StickyNotes", dependencies: ["Canvas", "Connections", "DetailPanel", "Keyboard", "Mentions", "Selection", "TableOfContents", "TextEditing", "Titles"]), // layer: vertical
        .target(name: "Schemas", dependencies: ["Canvas", "Connections", "DetailPanel", "Keyboard", "LanguageModels", "Mentions", "Selection", "TableOfContents", "TextEditing", "Titles", "Validation"]), // layer: vertical
        .target(name: "Subboards", dependencies: ["Boards", "Canvas", "DetailPanel", "Keyboard", "Mentions", "TableOfContents", "Titles"]), // layer: vertical
        .target(name: "Frames", dependencies: ["Canvas", "DetailPanel", "Geometry", "Keyboard", "Mentions", "Selection", "TableOfContents", "Titles"]), // layer: vertical


        // Examples: the smallest plugin for each pattern (see docs/plugin-system.md).
        .target(name: "Reordering", dependencies: ["Canvas", "ContextMenus"], path: "Examples/Reordering"),             // layer: vertical

        .target(name: "Composition", dependencies: ["Adornments", "Automation", "Boards", "Canvas", "CanvasRPC", "Clipboard", "Connections", "ContextMenus", "DetailPanel", "DrawLexicon", "Frames", "Keyboard", "LanguageModels", "Locking", "Mentions", "Queries", "QueryCommands", "QueryLanguage", "QueryLexicon", "Reordering", "Schemas", "Selection", "SlashCommands", "Snapping", "StickyNotes", "Subboards", "TableOfContents", "Titles", "Topology", "Validation"]), // layer: composition
        .executableTarget(name: "InfiniteCanvas", dependencies: ["Canvas", "CanvasUI", "Composition"]),           // layer: app
        .executableTarget(name: "CanvasCLI", dependencies: ["CanvasRPC"]),                                        // layer: cli

        .target(name: "TestKit", dependencies: [], path: "Tests/TestKit"),                                        // layer: testsupport
        .target(name: "CanvasTesting", dependencies: ["Canvas", "Geometry", "TestKit"], path: "Tests/CanvasTesting"), // layer: testsupport
        .executableTarget(name: "CanvasTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "TestKit"], path: "Tests/CanvasTests"), // layer: test
        .executableTarget(name: "CanvasRPCTests", dependencies: ["CanvasRPC", "TestKit"], path: "Tests/CanvasRPCTests"), // layer: test
        .executableTarget(name: "DrawScriptTests", dependencies: ["DrawScript", "Geometry", "TestKit"], path: "Tests/DrawScriptTests"), // layer: test
        .executableTarget(name: "QueryLanguageTests", dependencies: ["QueryLanguage", "TestKit"], path: "Tests/QueryLanguageTests"), // layer: test
        .executableTarget(name: "CanvasCLITests", dependencies: ["CanvasRPC", "TestKit"], path: "Tests/CanvasCLITests"), // layer: test
        .executableTarget(name: "KeyboardTests", dependencies: ["Canvas", "CanvasTesting", "Keyboard", "TestKit"], path: "Tests/KeyboardTests"), // layer: test
        .executableTarget(name: "CanvasUITests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "Geometry", "TestKit"], path: "Tests/CanvasUITests"), // layer: test
        .executableTarget(name: "SelectionTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/SelectionTests"), // layer: test
        .executableTarget(name: "ArrowsTests", dependencies: ["Canvas", "CanvasTesting", "Connections", "Geometry", "Keyboard", "Selection", "TableOfContents", "TestKit", "TextEditing"], path: "Tests/ArrowsTests"), // layer: test
        .executableTarget(name: "ValidationTests", dependencies: ["Canvas", "CanvasTesting", "DetailPanel", "Geometry", "TableOfContents", "TestKit", "Validation"], path: "Tests/ValidationTests"), // layer: test
        .executableTarget(name: "DetailPanelTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Keyboard", "Selection", "TestKit", "TextEditing"], path: "Tests/DetailPanelTests"), // layer: test
        .executableTarget(name: "TextEditingTests", dependencies: ["CanvasTesting", "TestKit", "TextEditing"], path: "Tests/TextEditingTests"), // layer: test
        .executableTarget(name: "ContextMenusTests", dependencies: ["Canvas", "CanvasTesting", "ContextMenus", "Keyboard", "Selection", "TestKit"], path: "Tests/ContextMenusTests"), // layer: test
        .executableTarget(name: "SlashCommandsTests", dependencies: ["Canvas", "CanvasTesting", "SlashCommands", "TestKit", "TextEditing"], path: "Tests/SlashCommandsTests"), // layer: test
        .executableTarget(name: "TableOfContentsTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "Geometry", "Keyboard", "Selection", "TableOfContents", "TestKit"], path: "Tests/TableOfContentsTests"), // layer: test
        .executableTarget(name: "AdornmentsTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/AdornmentsTests"), // layer: test
        .executableTarget(name: "ClipboardTests", dependencies: ["Canvas", "CanvasTesting", "Clipboard", "ContextMenus", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/ClipboardTests"), // layer: test
        .executableTarget(name: "StickyNotesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "Mentions", "Selection", "SlashCommands", "StickyNotes", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology"], path: "Tests/StickyNotesTests"), // layer: test
        .executableTarget(name: "LockingTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "Geometry", "Keyboard", "Locking", "Selection", "SlashCommands", "TableOfContents", "TestKit"], path: "Tests/LockingTests"), // layer: test
        .executableTarget(name: "SchemasTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "CanvasUI", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "LanguageModels", "Mentions", "Schemas", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Validation"], path: "Tests/SchemasTests"), // layer: test
        .executableTarget(name: "LanguageModelsTests", dependencies: ["Canvas", "CanvasTesting", "LanguageModels", "TestKit"], path: "Tests/LanguageModelsTests"), // layer: test
        .executableTarget(name: "TitlesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Geometry", "Keyboard", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Validation"], path: "Tests/TitlesTests"), // layer: test
        .executableTarget(name: "PortsTests", dependencies: ["Canvas", "CanvasTesting", "Connections", "Geometry", "Keyboard", "Selection", "TestKit", "Topology"], path: "Tests/PortsTests"), // layer: test
        .executableTarget(name: "ArrowPortsTests", dependencies: ["Canvas", "CanvasTesting", "Connections", "Geometry", "Keyboard", "Selection", "TableOfContents", "TestKit", "Topology"], path: "Tests/ArrowPortsTests"), // layer: test
        .executableTarget(name: "MentionsTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "CanvasUI", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "Mentions", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Validation"], path: "Tests/MentionsTests"), // layer: test
        .executableTarget(name: "BoardsTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Keyboard", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles"], path: "Tests/BoardsTests"), // layer: test
        .executableTarget(name: "SubboardsTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "CanvasUI", "ContextMenus", "DetailPanel", "Keyboard", "Mentions", "Selection", "SlashCommands", "Subboards", "TableOfContents", "TestKit", "Titles", "Topology"], path: "Tests/SubboardsTests"), // layer: test
        .executableTarget(name: "FramesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Frames", "Geometry", "Keyboard", "Mentions", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology"], path: "Tests/FramesTests"), // layer: test
        .executableTarget(name: "SnappingTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "Snapping", "TestKit"], path: "Tests/SnappingTests"), // layer: test
        .executableTarget(name: "TopologyTests", dependencies: ["Canvas", "CanvasTesting", "TestKit", "Topology"], path: "Tests/TopologyTests"), // layer: test
        .executableTarget(name: "QueriesTests", dependencies: ["Canvas", "CanvasTesting", "Queries", "QueryLanguage", "TestKit", "Topology"], path: "Tests/QueriesTests"), // layer: test
        .executableTarget(name: "TitleQueriesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Keyboard", "Queries", "QueryLanguage", "QueryLexicon", "Selection", "SlashCommands", "TestKit", "Titles", "Topology"], path: "Tests/TitleQueriesTests"), // layer: test
        .executableTarget(name: "BoardQueriesTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Keyboard", "Queries", "QueryLexicon", "Selection", "SlashCommands", "TestKit", "Titles", "Topology"], path: "Tests/BoardQueriesTests"), // layer: test
        .executableTarget(name: "MentionQueriesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Keyboard", "Mentions", "Queries", "QueryLanguage", "QueryLexicon", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology"], path: "Tests/MentionQueriesTests"), // layer: test
        .executableTarget(name: "ValidationQueriesTests", dependencies: ["Canvas", "CanvasTesting", "Queries", "QueryLanguage", "QueryLexicon", "TestKit", "Topology", "Validation"], path: "Tests/ValidationQueriesTests"), // layer: test
        .executableTarget(name: "SelectionQueriesTests", dependencies: ["Canvas", "CanvasTesting", "Keyboard", "Queries", "QueryLanguage", "QueryLexicon", "Selection", "TestKit", "Topology"], path: "Tests/SelectionQueriesTests"), // layer: test
        .executableTarget(name: "QueryCommandsTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "LanguageModels", "Queries", "QueryCommands", "QueryLanguage", "TestKit", "Topology"], path: "Tests/QueryCommandsTests"), // layer: test
        .executableTarget(name: "AutomationTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "Geometry", "TestKit"], path: "Tests/AutomationTests"), // layer: test
        .executableTarget(name: "TitleNamesTests", dependencies: ["Adornments", "Automation", "Canvas", "CanvasRPC", "CanvasTesting", "DrawLexicon", "Keyboard", "Selection", "SlashCommands", "TestKit", "Titles"], path: "Tests/TitleNamesTests"), // layer: test
        .executableTarget(name: "PortEdgesTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "Connections", "DrawLexicon", "Keyboard", "Selection", "TestKit", "Topology"], path: "Tests/PortEdgesTests"), // layer: test
        .executableTarget(name: "ValidationChecksTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "DrawLexicon", "TestKit", "Validation"], path: "Tests/ValidationChecksTests"), // layer: test
        .executableTarget(name: "ExamplesTests", dependencies: ["Canvas", "CanvasTesting", "Connections", "ContextMenus", "Keyboard", "Reordering", "Selection", "TableOfContents", "TestKit"], path: "Tests/ExamplesTests"), // layer: test
        .executableTarget(name: "CompositionTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Clipboard", "Composition", "Connections", "DetailPanel", "Frames", "Geometry", "Keyboard", "LanguageModels", "Locking", "Mentions", "Queries", "QueryCommands", "QueryLanguage", "Schemas", "Selection", "SlashCommands", "Snapping", "StickyNotes", "Subboards", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Validation"], path: "Tests/CompositionTests"), // layer: test
        .executableTarget(name: "BenchmarkTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Composition", "Connections", "DetailPanel", "Frames", "Geometry", "LanguageModels", "Locking", "Mentions", "Queries", "QueryCommands", "QueryLanguage", "Schemas", "Selection", "Snapping", "StickyNotes", "Subboards", "TableOfContents", "TestKit", "Titles", "Topology", "Validation"], path: "Tests/BenchmarkTests"), // layer: test
    ],
    swiftLanguageModes: [.v6]
)

// build.sh passes the same to swiftc: without it, members of modules a file doesn't import leak
// into scope and the import audit would miss real dependencies.
for target in package.targets {
    target.swiftSettings = [.enableUpcomingFeature("MemberImportVisibility")]
}
