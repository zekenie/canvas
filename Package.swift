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
//   the plugins any kind can opt into (horizontals) are four layers:
//     surface      -> foundation, surface                what the others show themselves on or build
//                                                        on (keys, the selection, the panel, menus, the
//                                                        table of contents, adornments, slash commands,
//                                                        the graph, the language model, prose maps, the
//                                                        query engine and English-to-query translation: every
//                                                        plugin may run them); declares extension
//                                                        points; knows no concern
//     concern      -> foundation, surface, concern       a meaning a kind opts into (validity, titles,
//                                                        locks, publishing, connections, mentions, boards, the
//                                                        clipboard, snapping, transforms), shown on the surfaces it
//                                                        imports, and may own the kind it's drawn as (Connections'
//                                                        arrow); knows no language
//     language     -> foundation, surface, language,     what agents read and write the canvas in (the
//                     wire                               command line, draw, `canvas query` and the
//                                                        lexicon's words for it): what it says of a
//                                                        concern comes through its points; knows no
//                                                        concern
//     lexicon      -> foundation, surface, concern,      a language's words for the app's concerns
//                     language                           (DrawLexicon, QueryLexicon): the one place a
//                                                        language and the concerns meet
//     vertical     -> foundation, surface, concern       a feature (shape kinds, tools); knows no other
//                                                        vertical, and no language
//     composition  -> foundation, surface, concern, language, lexicon, vertical, wire   the shipped plugin list
//     app          -> foundation, ui, composition, wire
//     appex        -> foundation, ui, composition        an app extension, an executable the app
//                                                        carries that macOS runs on its own (Quick
//                                                        Look's preview and thumbnail of a board file)
//     cli          -> wire                               the command line (`canvas`), an executable:
//                                                        knows only the wire, never the app
//     testsupport  -> foundation, testsupport
//     test         -> anything but app, appex, cli and test; a test named <M>Tests may use only M, M's
//                     dependencies, and testsupport and ui modules, and so may one named after a
//                     plugin of M that says so: `// layer: test of M` (TitleQueriesTests)
//
// So an edge between two horizontals goes the way their layers say, and within a layer from the module
// that owns a meaning to the one it builds on (Mentions imports Titles, whose names its pills show). A
// face a plugin list should be able to leave out (Validation's Issues tab) is a plugin value of its own
// in its owner's module, never a module that joins two others: only a lexicon joins modules, and only
// a language to concerns.
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
        .target(name: "FuzzyMatching", dependencies: []),                                     // layer: foundation
        .target(name: "Canvas", dependencies: ["Geometry"]),                                  // layer: foundation
        .target(name: "CanvasRPC", dependencies: []),                                         // layer: wire
        .target(name: "CanvasUI", dependencies: ["Canvas", "CanvasRPC", "Geometry"]),         // layer: ui

        .target(name: "Keyboard", dependencies: ["Canvas"]),                                  // layer: surface
        .target(name: "Selection", dependencies: ["Canvas", "Geometry", "Keyboard"]),         // layer: surface
        .target(name: "DetailPanel", dependencies: ["Canvas", "FuzzyMatching", "Selection", "TextEditing"]),   // layer: surface
        .target(name: "ContextMenus", dependencies: ["Canvas", "Selection"]),                 // layer: surface
        .target(name: "SlashCommands", dependencies: ["Canvas", "FuzzyMatching", "TextEditing"]), // layer: surface
        .target(name: "TableOfContents", dependencies: ["Canvas", "Selection"]),              // layer: surface
        .target(name: "Adornments", dependencies: ["Canvas", "Geometry", "Selection"]),       // layer: surface
        .target(name: "LanguageModels", dependencies: ["Canvas"]),                            // layer: surface
        .target(name: "ProseMaps", dependencies: ["Canvas", "LanguageModels"]),               // layer: surface
        .target(name: "Topology", dependencies: ["Canvas"]),                                  // layer: surface
        .target(name: "Find", dependencies: ["Canvas", "DetailPanel", "FuzzyMatching", "Geometry", "Keyboard", "Selection", "Topology"]), // layer: surface

        .target(name: "Validation", dependencies: ["Canvas", "DetailPanel", "TableOfContents"]), // layer: concern
        .target(name: "Clipboard", dependencies: ["Canvas", "ContextMenus", "Geometry", "Keyboard", "Selection"]), // layer: concern
        .target(name: "Titles", dependencies: ["Adornments", "Canvas", "DetailPanel", "Find", "SlashCommands", "TableOfContents", "Validation"]),  // layer: concern
        .target(name: "Locking", dependencies: ["Adornments", "Canvas", "ContextMenus", "SlashCommands", "TableOfContents"]), // layer: concern
        .target(name: "Connections", dependencies: ["Canvas", "Geometry", "Mentions", "Publishing", "Selection", "TableOfContents", "TextEditing", "Topology"]), // layer: concern
        .target(name: "Mentions", dependencies: ["Canvas", "ContextMenus", "DetailPanel", "Find", "FuzzyMatching", "Selection", "SlashCommands", "TableOfContents", "TextEditing", "Titles", "Topology", "Validation"]), // layer: concern
        .target(name: "Publishing", dependencies: ["Adornments", "Canvas", "ContextMenus", "DetailPanel", "Selection", "SlashCommands", "TableOfContents", "Titles", "Topology"]), // layer: concern
        .target(name: "Boards", dependencies: ["Canvas", "ContextMenus", "DetailPanel", "Keyboard", "Selection", "TableOfContents", "Titles"]), // layer: concern
        .target(name: "Snapping", dependencies: ["Canvas", "Geometry"]),                      // layer: concern
        .target(name: "Transform", dependencies: ["Canvas", "ContextMenus", "SlashCommands"]), // layer: concern

        .target(name: "Automation", dependencies: ["Canvas", "CanvasRPC", "DrawScript", "Geometry", "Queries", "QueryLanguage", "Topology"]), // layer: language
        // Placing: where shapes land beside, in or anywhere on a board, placed as `canvas draw` places one (DrawScript's solver); Moving's
        // solver, moved out so any plugin that puts shapes down uses it.
        .target(name: "Placing", dependencies: ["Canvas", "DrawScript", "Geometry"]), // layer: surface
        .target(name: "Queries", dependencies: ["Canvas", "DrawScript", "QueryLanguage", "Topology"]), // layer: surface
        .target(name: "QueryTranslation", dependencies: ["Canvas", "LanguageModels", "Queries", "QueryLanguage"]), // layer: surface
        .target(name: "QueryCommands", dependencies: ["Automation", "Canvas", "CanvasRPC", "LanguageModels", "Queries", "QueryLanguage", "QueryTranslation"]), // layer: language

        .target(name: "QueryLexicon", dependencies: ["Boards", "Canvas", "Mentions", "Queries", "Selection", "Titles", "Topology", "Validation"]), // layer: lexicon
        .target(name: "DrawLexicon", dependencies: ["Automation", "Canvas", "Connections", "Mentions", "Titles", "Validation"]), // layer: lexicon

        .target(name: "StickyNotes", dependencies: ["Canvas", "Connections", "DetailPanel", "Keyboard", "Mentions", "Selection", "TableOfContents", "TextEditing", "Titles"]), // layer: vertical
        .target(name: "Schemas", dependencies: ["Canvas", "Connections", "DetailPanel", "Keyboard", "LanguageModels", "Mentions", "ProseMaps", "Selection", "TableOfContents", "TextEditing", "Titles", "Validation"]), // layer: vertical
        .target(name: "Subboards", dependencies: ["Boards", "Canvas", "Connections", "DetailPanel", "Keyboard", "Mentions", "TableOfContents", "Titles", "Transform"]), // layer: vertical
        .target(name: "Frames", dependencies: ["Canvas", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "Mentions", "Selection", "TableOfContents", "Titles", "Transform"]), // layer: vertical
        // Jump To (⌘K): a feature no kind opts into and nothing imports, as Reordering is one: a vertical, which
        // lists the titled shapes Titles names (their tint injected by Composition, from Mentions), goes to one as Boards' crumbs do
        // (Boards' `follow`), and shows its list in TextEditing's caret list.
        .target(name: "JumpTo", dependencies: ["Boards", "Canvas", "FuzzyMatching", "Geometry", "Keyboard", "TextEditing", "Titles", "Topology"]), // layer: vertical
        .target(name: "References", dependencies: ["Canvas", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "LanguageModels", "Mentions", "Publishing", "Queries", "QueryLanguage", "QueryTranslation", "Selection", "TableOfContents", "TextEditing", "Topology", "Validation"]), // layer: vertical
        // Moving (`/move-to`, `/move-near`): a feature no kind opts into and nothing imports, as Jump To and Reordering are: two slash
        // commands that move a shape into a frame, onto a subboard's board or beside a shape, placed as `canvas draw` places one (DrawScript),
        // and the table of contents' drops that move shapes into a frame, onto a subboard's board or out of frames (`ContentsMoves`).
        .target(name: "Moving", dependencies: ["Canvas", "Placing", "SlashCommands", "TableOfContents"]), // layer: vertical
        // Neighbors: a feature no kind opts into and nothing imports, as Jump To and Moving are: hovering a shape, on the canvas or by its row in
        // the table of contents (Selection's `hovered`, and `hoveredElsewhere` for a row of another board), outlines every shape connected to it in a
        // color for each way, through the core's tinted outlines. What counts as connected is a query, which Composition writes and Queries answers;
        // the file says where a shape on another board is drawn, and Topology when the hovered shape's edges change.
        .target(name: "Neighbors", dependencies: ["Canvas", "Queries", "Selection", "Topology"]), // layer: vertical


        // Examples: the smallest plugin for each pattern (see docs/plugin-system.md).
        .target(name: "Reordering", dependencies: ["Canvas", "ContextMenus"], path: "Examples/Reordering"),             // layer: vertical

        .target(name: "Composition", dependencies: ["Adornments", "Automation", "Boards", "Canvas", "CanvasRPC", "Clipboard", "Connections", "ContextMenus", "DetailPanel", "DrawLexicon", "Find", "Frames", "JumpTo", "Keyboard", "LanguageModels", "Locking", "Mentions", "Moving", "Neighbors", "ProseMaps", "Publishing", "Queries", "QueryCommands", "QueryLanguage", "QueryLexicon", "QueryTranslation", "References", "Reordering", "Schemas", "Selection", "SlashCommands", "Snapping", "StickyNotes", "Subboards", "TableOfContents", "Titles", "Topology", "Transform", "Validation"]), // layer: composition
        .executableTarget(name: "InfiniteCanvas", dependencies: ["Canvas", "CanvasUI", "Composition"]),           // layer: app
        .executableTarget(name: "CanvasQuickLook", dependencies: ["Canvas", "CanvasUI", "Composition"]),          // layer: appex
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
        .executableTarget(name: "ArrowsTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Connections", "ContextMenus", "DetailPanel", "Find", "Geometry", "Keyboard", "Mentions", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology"], path: "Tests/ArrowsTests"), // layer: test of Connections
        .executableTarget(name: "ValidationTests", dependencies: ["Canvas", "CanvasTesting", "DetailPanel", "Geometry", "TableOfContents", "TestKit", "Validation"], path: "Tests/ValidationTests"), // layer: test
        .executableTarget(name: "DetailPanelTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Keyboard", "Selection", "TestKit", "TextEditing"], path: "Tests/DetailPanelTests"), // layer: test
        .executableTarget(name: "TextEditingTests", dependencies: ["CanvasTesting", "TestKit", "TextEditing"], path: "Tests/TextEditingTests"), // layer: test
        .executableTarget(name: "FuzzyMatchingTests", dependencies: ["FuzzyMatching", "TestKit"], path: "Tests/FuzzyMatchingTests"), // layer: test
        .executableTarget(name: "ContextMenusTests", dependencies: ["Canvas", "CanvasTesting", "ContextMenus", "Keyboard", "Selection", "TestKit"], path: "Tests/ContextMenusTests"), // layer: test
        .executableTarget(name: "SlashCommandsTests", dependencies: ["Canvas", "CanvasTesting", "SlashCommands", "TestKit", "TextEditing"], path: "Tests/SlashCommandsTests"), // layer: test
        .executableTarget(name: "TableOfContentsTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "Geometry", "Keyboard", "Selection", "TableOfContents", "TestKit"], path: "Tests/TableOfContentsTests"), // layer: test
        .executableTarget(name: "AdornmentsTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/AdornmentsTests"), // layer: test
        .executableTarget(name: "ClipboardTests", dependencies: ["Canvas", "CanvasTesting", "Clipboard", "ContextMenus", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/ClipboardTests"), // layer: test
        .executableTarget(name: "StickyNotesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "Mentions", "Selection", "SlashCommands", "StickyNotes", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology"], path: "Tests/StickyNotesTests"), // layer: test
        .executableTarget(name: "LockingTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "Geometry", "Keyboard", "Locking", "Selection", "SlashCommands", "TableOfContents", "TestKit"], path: "Tests/LockingTests"), // layer: test
        .executableTarget(name: "PublishingTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "Publishing", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology"], path: "Tests/PublishingTests"), // layer: test
        .executableTarget(name: "SchemasTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "CanvasUI", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "LanguageModels", "Mentions", "ProseMaps", "Schemas", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Validation"], path: "Tests/SchemasTests"), // layer: test
        .executableTarget(name: "LanguageModelsTests", dependencies: ["Canvas", "CanvasTesting", "LanguageModels", "TestKit"], path: "Tests/LanguageModelsTests"), // layer: test
        .executableTarget(name: "ProseMapsTests", dependencies: ["Canvas", "CanvasTesting", "LanguageModels", "ProseMaps", "TestKit"], path: "Tests/ProseMapsTests"), // layer: test
        .executableTarget(name: "TitlesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Find", "Geometry", "Keyboard", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Validation"], path: "Tests/TitlesTests"), // layer: test
        .executableTarget(name: "PortsTests", dependencies: ["Canvas", "CanvasTesting", "Connections", "Geometry", "Keyboard", "Selection", "TestKit", "Topology"], path: "Tests/PortsTests"), // layer: test of Connections
        .executableTarget(name: "ArrowPortsTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Connections", "ContextMenus", "Geometry", "Keyboard", "Mentions", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology"], path: "Tests/ArrowPortsTests"), // layer: test of Connections
        .executableTarget(name: "MentionsTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "CanvasUI", "ContextMenus", "DetailPanel", "Find", "Geometry", "Keyboard", "Mentions", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Validation"], path: "Tests/MentionsTests"), // layer: test
        .executableTarget(name: "BoardsTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Keyboard", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles"], path: "Tests/BoardsTests"), // layer: test
        .executableTarget(name: "SubboardsTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "CanvasUI", "Connections", "ContextMenus", "DetailPanel", "Keyboard", "Mentions", "Selection", "SlashCommands", "Subboards", "TableOfContents", "TestKit", "Titles", "Topology", "Transform"], path: "Tests/SubboardsTests"), // layer: test
        .executableTarget(name: "FramesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Frames", "Geometry", "Keyboard", "Mentions", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Transform"], path: "Tests/FramesTests"), // layer: test
        .executableTarget(name: "JumpToTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "CanvasUI", "ContextMenus", "DetailPanel", "Geometry", "JumpTo", "Keyboard", "Selection", "SlashCommands", "TestKit", "TextEditing", "Titles", "Topology"], path: "Tests/JumpToTests"), // layer: test
        .executableTarget(name: "ReferencesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "LanguageModels", "Mentions", "Publishing", "Queries", "QueryTranslation", "References", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Validation"], path: "Tests/ReferencesTests"), // layer: test
        .executableTarget(name: "PlacingTests", dependencies: ["Canvas", "CanvasTesting", "Placing", "TestKit"], path: "Tests/PlacingTests"), // layer: test
        .executableTarget(name: "MovingTests", dependencies: ["Canvas", "CanvasTesting", "Keyboard", "Moving", "Selection", "SlashCommands", "TableOfContents", "TestKit"], path: "Tests/MovingTests"), // layer: test
        .executableTarget(name: "NeighborsTests", dependencies: ["Canvas", "CanvasTesting", "Keyboard", "Neighbors", "Queries", "Selection", "TestKit", "Topology"], path: "Tests/NeighborsTests"), // layer: test
        .executableTarget(name: "SnappingTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "Snapping", "TestKit"], path: "Tests/SnappingTests"), // layer: test
        .executableTarget(name: "TransformTests", dependencies: ["Canvas", "CanvasTesting", "ContextMenus", "Keyboard", "Selection", "SlashCommands", "TestKit", "Transform"], path: "Tests/TransformTests"), // layer: test
        .executableTarget(name: "FindTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Find", "Geometry", "Keyboard", "Selection", "TestKit", "Topology"], path: "Tests/FindTests"), // layer: test
        .executableTarget(name: "TopologyTests", dependencies: ["Canvas", "CanvasTesting", "TestKit", "Topology"], path: "Tests/TopologyTests"), // layer: test
        .executableTarget(name: "QueriesTests", dependencies: ["Canvas", "CanvasTesting", "Queries", "QueryLanguage", "TestKit", "Topology"], path: "Tests/QueriesTests"), // layer: test
        .executableTarget(name: "TitleQueriesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Keyboard", "Queries", "QueryLanguage", "QueryLexicon", "Selection", "SlashCommands", "TestKit", "Titles", "Topology"], path: "Tests/TitleQueriesTests"), // layer: test of QueryLexicon
        .executableTarget(name: "BoardQueriesTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Keyboard", "Queries", "QueryLexicon", "Selection", "SlashCommands", "TestKit", "Titles", "Topology"], path: "Tests/BoardQueriesTests"), // layer: test of QueryLexicon
        .executableTarget(name: "MentionQueriesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Keyboard", "Mentions", "Queries", "QueryLanguage", "QueryLexicon", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology"], path: "Tests/MentionQueriesTests"), // layer: test of QueryLexicon
        .executableTarget(name: "ValidationQueriesTests", dependencies: ["Canvas", "CanvasTesting", "Queries", "QueryLanguage", "QueryLexicon", "TestKit", "Topology", "Validation"], path: "Tests/ValidationQueriesTests"), // layer: test of QueryLexicon
        .executableTarget(name: "SelectionQueriesTests", dependencies: ["Canvas", "CanvasTesting", "Keyboard", "Queries", "QueryLanguage", "QueryLexicon", "Selection", "TestKit", "Topology"], path: "Tests/SelectionQueriesTests"), // layer: test of QueryLexicon
        .executableTarget(name: "QueryTranslationTests", dependencies: ["Canvas", "CanvasTesting", "LanguageModels", "Queries", "QueryLanguage", "QueryTranslation", "TestKit", "Topology"], path: "Tests/QueryTranslationTests"), // layer: test
        .executableTarget(name: "QueryCommandsTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "LanguageModels", "Queries", "QueryCommands", "QueryLanguage", "QueryTranslation", "TestKit", "Topology"], path: "Tests/QueryCommandsTests"), // layer: test
        .executableTarget(name: "AutomationTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "Geometry", "Queries", "TestKit", "Topology"], path: "Tests/AutomationTests"), // layer: test
        .executableTarget(name: "TitleNamesTests", dependencies: ["Adornments", "Automation", "Canvas", "CanvasRPC", "CanvasTesting", "DrawLexicon", "Keyboard", "Selection", "SlashCommands", "TestKit", "Titles"], path: "Tests/TitleNamesTests"), // layer: test of DrawLexicon
        .executableTarget(name: "PortEdgesTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "Connections", "DrawLexicon", "Keyboard", "Selection", "TestKit", "Topology"], path: "Tests/PortEdgesTests"), // layer: test of DrawLexicon
        .executableTarget(name: "MentionTextsTests", dependencies: ["Adornments", "Automation", "Canvas", "CanvasRPC", "ContextMenus", "DetailPanel", "DrawLexicon", "Keyboard", "Mentions", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Validation"], path: "Tests/MentionTextsTests"), // layer: test of DrawLexicon
        .executableTarget(name: "ValidationChecksTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "DrawLexicon", "TestKit", "Validation"], path: "Tests/ValidationChecksTests"), // layer: test of DrawLexicon
        .executableTarget(name: "ExamplesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Connections", "ContextMenus", "Keyboard", "Mentions", "Reordering", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology"], path: "Tests/ExamplesTests"), // layer: test
        .executableTarget(name: "CompositionTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Clipboard", "Composition", "Connections", "DetailPanel", "Find", "Frames", "Geometry", "JumpTo", "Keyboard", "LanguageModels", "Locking", "Mentions", "Neighbors", "Publishing", "Queries", "QueryLanguage", "QueryTranslation", "References", "Schemas", "Selection", "SlashCommands", "Snapping", "StickyNotes", "Subboards", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Transform", "Validation"], path: "Tests/CompositionTests"), // layer: test
        .executableTarget(name: "BenchmarkTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Composition", "Connections", "DetailPanel", "Find", "Frames", "Geometry", "JumpTo", "LanguageModels", "Locking", "Mentions", "Neighbors", "Publishing", "Queries", "QueryCommands", "QueryLanguage", "QueryTranslation", "References", "Schemas", "Selection", "Snapping", "StickyNotes", "Subboards", "TableOfContents", "TestKit", "Titles", "Topology", "Validation"], path: "Tests/BenchmarkTests"), // layer: test
    ],
    swiftLanguageModes: [.v6]
)

// build.sh passes the same to swiftc: without it, members of modules a file doesn't import leak
// into scope and the import audit would miss real dependencies.
for target in package.targets {
    target.swiftSettings = [.enableUpcomingFeature("MemberImportVisibility")]
}
