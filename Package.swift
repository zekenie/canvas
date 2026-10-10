// swift-tools-version: 6.0
import PackageDescription

// THE MODULE GRAPH, AND WHAT SHIPS. This file is the only place module dependencies are written
// down, and the only list of the plugins the product is made of (the table before the targets).
// build.sh reads it as a table, so every target stays on ONE line, in exactly this form:
//     .target(name: "X", dependencies: ["A", "B"]),                          // layer: <layer>
//     .target(name: "X", dependencies: ["A"], path: "Examples/X"),          // layer: <layer>
//     .executableTarget(name: "X", dependencies: ["A"], path: "Tests/X"),   // layer: <layer>
//     .executableTarget(name: "X", dependencies: ["A"] + shipped),          // layer: <layer>
// Modules live in Sources/X or Examples/X; test and testsupport modules in Tests/X.
//
// Layers, and what each may depend on:
//     wire         -> wire                               what the app and its command line say to
//                                                        each other; knows no canvas, plugin or AppKit
//     foundation   -> foundation, wire                   the core, what the host takes from the plugins
//                                                        (HostSlots, which names the wire's types for
//                                                        the commands the app's server runs), and pure
//                                                        libraries beneath the plugins (DrawScript):
//                                                        knows no plugin
//     ui           -> foundation, wire                   the AppKit/SwiftUI shell around the core, and
//                                                        the app's end of the command line
//   the plugins any kind can opt into (horizontals) are four layers:
//     surface      -> foundation, surface                what the others show themselves on or build
//                                                        on (keys, the selection, the panel, menus, the
//                                                        table of contents, adornments, slash commands,
//                                                        the graph, the lights on a hovered shape's
//                                                        neighbors, the language model, prose maps, the
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
//     app          -> foundation, ui, wire               names no plugin: its plugins are the list's,
//                                                        made by name (`+ shipped`)
//     appex        -> foundation, ui                     an app extension, an executable the app
//                                                        carries that macOS runs on its own (Quick
//                                                        Look's preview and thumbnail of a board file);
//                                                        `+ shipped`, as the app is
//     cli          -> wire                               the command line (`canvas`), an executable:
//                                                        knows only the wire, never the app
//     testsupport  -> foundation, testsupport            and, for the one that is the tests' way to the
//                                                        product's plugins (`+ shipped`), what ships
//     test         -> anything but app, appex, cli and test; a test named <M>Tests may use only M, M's
//                     dependencies, and testsupport and ui modules, and so may one named after a
//                     plugin of M that says so: `// layer: test of M` (TitleQueriesTests)
//
// `+ shipped` after a line's dependencies makes it the product, or the tests of it: every module the
// list names links into it, whether or not it imports them. Only the app, its extension, and the
// tests of what ships and their support may say it. The app and its extension import none of those
// modules (and compile against none); the tests and their support import the ones they call. What
// depends on a library that says it says it too.
//
// So an edge between two horizontals goes the way their layers say, and within a layer from the module
// that owns a meaning to the one it builds on (Mentions imports Titles, whose names its pills show). A
// face a plugin list should be able to leave out (Validation's Issues tab) is a plugin value of its own
// in its owner's module, never a module that joins two others: only a lexicon joins modules, and only
// a language to concerns.
//
// build.sh refuses to build when:
//   - the graph has a cycle, or an edge the layers above forbid;
//   - the list names something that isn't a public struct of that module that can be made with no
//     arguments (a ListedPlugin), names a plugin twice, or isn't in the form its comment says;
//   - the app or its extension imports a module the list names;
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
// may import; loading the list whole, with the plugins that reach outside the process as the product
// has them, is @_spi(Product), which only the app and its extension may.
// Audit it:  ./build.sh graph | dot | audit | api <Module>

// WHAT SHIPS. The plugins the product is made of, each as `Module.Type`, in order: the toolbar's
// order, the order overlays draw in, and each after the plugins whose points it fills (the registry
// refuses a contribution whose point's owner isn't installed). This table is the only list of them.
// build.sh puts it, as text, in every executable that is the product, and the core makes each
// plugin there by its name (Canvas's ShippedList), so no module imports the plugins to list them.
// Each is a public struct that can be made with no arguments (a ListedPlugin).
//
// A target line that ends `+ shipped` is the product, or the tests of it: the list's modules link
// into it though nothing need import them. The app and its extension import none (they name no
// plugin); the tests of what ships, and their support, import the ones they call.
//
// build.sh reads this table as text, as it reads the targets, so it stays in this form: the opening
// line, lines of strings each followed by a comma, comments on lines of their own, and `]`.
let ships = [
    // First: every key is registered with Keyboard; the others build on Selection, and its
    // handles draw below their view overlays.
    "Keyboard.KeyboardPlugin", "Selection.SelectionPlugin",
    // What connects to what (arrows, mentions), for the whole file: its index hears each
    // commit before the services that read it (the table of contents', Mentions').
    "Topology.TopologyPlugin",
    // The kinds. Frames beside subboards, the two ways of grouping shapes (a region of this
    // board, a board of its own), after notes: the toolbar's Note, Subboard, Frame, Schema, Reference.
    "Connections.ArrowsPlugin", "StickyNotes.StickyNotesPlugin", "Subboards.SubboardsPlugin", "Frames.FramesPlugin", "Schemas.SchemasPlugin", "References.ReferencesPlugin",
    // After Validation: what's shown on shapes draws over its outline.
    "Validation.ValidationPlugin", "Adornments.AdornmentsPlugin", "DetailPanel.DetailPanelPlugin", "ContextMenus.ContextMenusPlugin",
    // Slash commands: the list at a `/` in the text views Mentions hosts it in. Titles offers `/title`, Locking `/lock`.
    "SlashCommands.SlashCommandsPlugin",
    // The table of contents, and its list in the detail panel where the panel has no one shape to show.
    "TableOfContents.TableOfContentsPlugin", "TableOfContents.ContentsOverviewPlugin",
    "Titles.TitlesPlugin",
    // After Titles, whose names its pills show, and the table of contents, whose rows it names.
    "Mentions.MentionsPlugin",
    // Getting around a file's boards (a subboard's): opening one, ⌘↑, the path. Then the board shown's
    // name over the table of contents, with the way up.
    "Boards.BoardsPlugin", "Boards.BoardContentsPlugin",
    // Finding text on the board shown and every board under it (⌘F, ⌘G): after Adornments, so a
    // hit's ring draws over a title's pill, and Topology, whose walk of the file orders the hits. Then
    // its panel in the detail panel's place while it's open, and Boards' names over each board's rows.
    "Find.FindPlugin", "Find.FindPanelPlugin", "Boards.BoardFindPlugin",
    // What Find searches, from the plugins that draw it, each after Find and its owner: titles,
    // mention text (a note's, a schema card's description), arrows' labels.
    "Titles.TitleFindPlugin", "Mentions.MentionFindPlugin", "Connections.ArrowFindPlugin",
    // Jump To (⌘K): goes to a shape by its title and where it is. After Titles, whose titles it
    // lists, and Boards, whose way of following a shape it takes.
    "JumpTo.JumpToPlugin",
    // Turning shapes into other kinds: a frame into a subboard, from its menu.
    "Transform.TransformPlugin",
    "Validation.ValidationDetailsPlugin", "Validation.ValidationContentsPlugin", "Mentions.MentionValidationPlugin", "Titles.TitleValidationPlugin",
    "Clipboard.ClipboardPlugin",
    "Locking.LockingPlugin",
    // Public shapes, the ones another shape may stand for; its chip sits beside the lock's.
    "Publishing.PublishingPlugin",
    // What a drag moves snaps to the shapes in view: their edges, their middles and the spaces
    // between them.
    "Snapping.SnappingPlugin",
    // Ports, whose arrows `ArrowPortsPlugin` draws. After Adornments: a shape's dots draw
    // above its adornments (the lock chip among them), and are found before them.
    "Connections.PortsPlugin", "Connections.ArrowPortsPlugin",
    "LanguageModels.LanguageModelsPlugin",
    // What words say of what's lower level, asked of the model: a schema card's highlights.
    "ProseMaps.ProseMapsPlugin",
    // The command line's commands, and what `canvas draw` takes from the plugins that own a
    // concern: titles for names, ports' connections for edges, validity for its warnings, and
    // mentions for text (`@[Title]` in a note's text names the shape called that).
    "Automation.AutomationPlugin", "DrawLexicon.TitleNamesPlugin", "DrawLexicon.PortEdgesPlugin", "DrawLexicon.ValidationChecksPlugin", "DrawLexicon.MentionTextsPlugin",
    // Reading the file: `canvas query`, and what queries take from the plugins that own a concern:
    // titles for names, boards' names, mentions for text and relations, validity and the selection
    // for their words. The translator of English into queries reads its prompt from the product's
    // own files (Shipped/ask-prompt.txt, in the binary).
    "Queries.QueriesPlugin", "QueryTranslation.QueryTranslationPlugin", "QueryLexicon.TitleQueriesPlugin", "QueryLexicon.BoardQueriesPlugin", "QueryLexicon.MentionQueriesPlugin", "QueryLexicon.ValidationQueriesPlugin",
    "QueryLexicon.SelectionQueriesPlugin",
    "QueryCommands.QueryCommandsPlugin",
    // Hover a shape, on the canvas or by its row in the table of contents, and what it connects to is outlined by how: after the
    // query plugins, whose engine it asks, and Selection and the table of contents, whose hovers it follows. Then the lights,
    // from the plugins that own the edges, in the order a shape's rings go: arrows' (points to, pointed to by), then
    // mentions' (mentions, mentioned by).
    "Neighbors.NeighborsPlugin", "Connections.ArrowLightsPlugin", "Mentions.MentionLightsPlugin",
    // `/move-to` and `/move-near`: a shape moved into a frame, onto a subboard's board or beside a shape, on any board,
    // placed as `canvas draw` places one. After every plugin whose every-shape commands a note lists before them.
    "Moving.MovingPlugin",
    // The example (Examples/): one line here; delete it to leave it out.
    "Reordering.ReorderingPlugin",
]
// The modules those plugins are in, once each, in the list's order: what `+ shipped` links.
let shipped = ships.reduce(into: [String]()) { modules, plugin in
    let module = String(plugin.prefix { $0 != "." })
    if !modules.contains(module) { modules.append(module) }
}.map { Target.Dependency(stringLiteral: $0) }

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
        // What a window puts around its canvas, and what the app takes from the plugins besides, said by plugins and placed by
        // the host, neither of which may import the other: the one foundation module that imports SwiftUI, since its slots hold
        // views, and the wire, whose types the commands the app's server runs are said in.
        .target(name: "HostSlots", dependencies: ["Canvas", "CanvasRPC"]),                                 // layer: foundation
        .target(name: "CanvasRPC", dependencies: []),                                         // layer: wire
        .target(name: "CanvasUI", dependencies: ["Canvas", "CanvasRPC", "Geometry", "HostSlots"]), // layer: ui

        .target(name: "Keyboard", dependencies: ["Canvas", "HostSlots"]),                     // layer: surface
        .target(name: "Selection", dependencies: ["Canvas", "Geometry", "Keyboard"]),         // layer: surface
        .target(name: "DetailPanel", dependencies: ["Canvas", "FuzzyMatching", "HostSlots", "Selection", "TextEditing"]),   // layer: surface
        .target(name: "ContextMenus", dependencies: ["Canvas", "Selection"]),                 // layer: surface
        .target(name: "SlashCommands", dependencies: ["Canvas", "FuzzyMatching", "TextEditing"]), // layer: surface
        .target(name: "TableOfContents", dependencies: ["Canvas", "DetailPanel", "Selection"]), // layer: surface
        .target(name: "Adornments", dependencies: ["Canvas", "Geometry", "Selection"]),       // layer: surface
        .target(name: "LanguageModels", dependencies: ["Canvas", "HostSlots"]),               // layer: surface
        .target(name: "ProseMaps", dependencies: ["Canvas", "LanguageModels"]),               // layer: surface
        .target(name: "Topology", dependencies: ["Canvas"]),                                  // layer: surface
        .target(name: "Find", dependencies: ["Canvas", "DetailPanel", "FuzzyMatching", "Geometry", "Keyboard", "Selection", "Topology"]), // layer: surface
        // Neighbors: a surface an edge's owner shows its edges on. Hovering a shape, on the canvas or by its row in the table of contents
        // (Selection's `hovered`, and `hoveredElsewhere` for a row of another board), outlines every shape connected to it in a color for each
        // way, through the core's tinted outlines. What counts as connected is a light, a color and a query, which the plugin that owns the edges
        // contributes (Connections' arrows, Mentions' mentions) and Queries answers; the file says where a shape on another board is drawn, and
        // Topology when the hovered shape's edges change.
        .target(name: "Neighbors", dependencies: ["Canvas", "Queries", "Selection", "Topology"]), // layer: surface

        .target(name: "Validation", dependencies: ["Canvas", "DetailPanel", "TableOfContents"]), // layer: concern
        .target(name: "Clipboard", dependencies: ["Canvas", "ContextMenus", "Geometry", "Keyboard", "Selection"]), // layer: concern
        .target(name: "Titles", dependencies: ["Adornments", "Canvas", "DetailPanel", "Find", "SlashCommands", "TableOfContents", "Validation"]),  // layer: concern
        .target(name: "Locking", dependencies: ["Adornments", "Canvas", "ContextMenus", "SlashCommands", "TableOfContents"]), // layer: concern
        .target(name: "Connections", dependencies: ["Canvas", "Find", "Geometry", "Neighbors", "Publishing", "Selection", "TableOfContents", "TextEditing", "Topology"]), // layer: concern
        .target(name: "Mentions", dependencies: ["Canvas", "ContextMenus", "DetailPanel", "Find", "FuzzyMatching", "Neighbors", "Selection", "SlashCommands", "TableOfContents", "TextEditing", "Titles", "Topology", "Validation"]), // layer: concern
        .target(name: "Publishing", dependencies: ["Adornments", "Canvas", "ContextMenus", "DetailPanel", "Selection", "SlashCommands", "TableOfContents", "Titles", "Topology"]), // layer: concern
        .target(name: "Boards", dependencies: ["Canvas", "ContextMenus", "DetailPanel", "Find", "HostSlots", "Keyboard", "Selection", "TableOfContents", "Titles"]), // layer: concern
        .target(name: "Snapping", dependencies: ["Canvas", "Geometry"]),                      // layer: concern
        .target(name: "Transform", dependencies: ["Canvas", "ContextMenus", "SlashCommands"]), // layer: concern

        .target(name: "Automation", dependencies: ["Adornments", "Canvas", "CanvasRPC", "DrawScript", "Geometry", "HostSlots", "Queries", "QueryLanguage", "Topology"]), // layer: language
        .target(name: "Queries", dependencies: ["Canvas", "DrawScript", "QueryLanguage", "Topology"]), // layer: surface
        .target(name: "QueryTranslation", dependencies: ["Canvas", "LanguageModels", "Queries", "QueryLanguage"]), // layer: surface
        .target(name: "QueryCommands", dependencies: ["Automation", "Canvas", "CanvasRPC", "LanguageModels", "Queries", "QueryLanguage", "QueryTranslation"]), // layer: language

        .target(name: "QueryLexicon", dependencies: ["Boards", "Canvas", "Mentions", "Queries", "Selection", "Titles", "Topology", "Validation"]), // layer: lexicon
        .target(name: "DrawLexicon", dependencies: ["Automation", "Canvas", "Connections", "Mentions", "Titles", "Validation"]), // layer: lexicon

        .target(name: "StickyNotes", dependencies: ["Canvas", "Connections", "DetailPanel", "HostSlots", "Keyboard", "Mentions", "Selection", "TableOfContents", "TextEditing", "Titles"]), // layer: vertical
        .target(name: "Schemas", dependencies: ["Canvas", "Connections", "DetailPanel", "Keyboard", "LanguageModels", "Mentions", "ProseMaps", "Selection", "TableOfContents", "TextEditing", "Titles", "Validation"]), // layer: vertical
        .target(name: "Subboards", dependencies: ["Boards", "Canvas", "Connections", "DetailPanel", "Keyboard", "Mentions", "TableOfContents", "Titles", "Transform"]), // layer: vertical
        .target(name: "Frames", dependencies: ["Canvas", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "Mentions", "Selection", "TableOfContents", "Titles", "Transform"]), // layer: vertical
        // Jump To (⌘K): a feature no kind opts into and nothing imports, as Reordering is one: a vertical, which
        // lists the titled shapes Titles names (each tinted as its kind is, the core's `registry.label(of:)`), goes to one as Boards' crumbs do
        // (Boards' `follow`), and shows its list in TextEditing's caret list, its palette over the canvas in one of the host's slots.
        .target(name: "JumpTo", dependencies: ["Boards", "Canvas", "FuzzyMatching", "Geometry", "HostSlots", "Keyboard", "TextEditing", "Titles", "Topology"]), // layer: vertical
        .target(name: "References", dependencies: ["Canvas", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "LanguageModels", "Mentions", "Publishing", "Queries", "QueryLanguage", "QueryTranslation", "Selection", "TableOfContents", "TextEditing", "Topology", "Validation"]), // layer: vertical
        // Moving (`/move-to`, `/move-near`): a feature no kind opts into and nothing imports, as Jump To and Reordering are: two slash
        // commands that move a shape into a frame, onto a subboard's board or beside a shape, placed as `canvas draw` places one (DrawScript),
        // and the table of contents' drops that move shapes into a frame, onto a subboard's board or out of frames (`ContentsMoves`).
        .target(name: "Moving", dependencies: ["Canvas", "DrawScript", "Geometry", "SlashCommands", "TableOfContents"]), // layer: vertical

        // Examples: the smallest plugin for each pattern (see docs/plugin-system.md).
        .target(name: "Reordering", dependencies: ["Canvas", "ContextMenus"], path: "Examples/Reordering"),             // layer: vertical

        .executableTarget(name: "InfiniteCanvas", dependencies: ["Canvas", "CanvasUI", "HostSlots"] + shipped),  // layer: app
        .executableTarget(name: "CanvasQuickLook", dependencies: ["Canvas", "CanvasUI"] + shipped),              // layer: appex
        .executableTarget(name: "CanvasCLI", dependencies: ["CanvasRPC"]),                                        // layer: cli

        .target(name: "TestKit", dependencies: [], path: "Tests/TestKit"),                                        // layer: testsupport
        .target(name: "CanvasTesting", dependencies: ["Canvas", "Geometry", "TestKit"], path: "Tests/CanvasTesting"), // layer: testsupport
        // The tests' way to the product's plugins: the list, with a pasteboard and a model of the test's own.
        .target(name: "ShippedTesting", dependencies: ["Canvas"] + shipped, path: "Tests/ShippedTesting"),  // layer: testsupport
        .executableTarget(name: "CanvasTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "TestKit"], path: "Tests/CanvasTests"), // layer: test
        .executableTarget(name: "CanvasRPCTests", dependencies: ["CanvasRPC", "TestKit"], path: "Tests/CanvasRPCTests"), // layer: test
        .executableTarget(name: "DrawScriptTests", dependencies: ["DrawScript", "Geometry", "TestKit"], path: "Tests/DrawScriptTests"), // layer: test
        .executableTarget(name: "QueryLanguageTests", dependencies: ["QueryLanguage", "TestKit"], path: "Tests/QueryLanguageTests"), // layer: test
        .executableTarget(name: "CanvasCLITests", dependencies: ["CanvasRPC", "TestKit"], path: "Tests/CanvasCLITests"), // layer: test
        .executableTarget(name: "HostSlotsTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "HostSlots", "TestKit"], path: "Tests/HostSlotsTests"), // layer: test
        .executableTarget(name: "KeyboardTests", dependencies: ["Canvas", "CanvasTesting", "HostSlots", "Keyboard", "TestKit"], path: "Tests/KeyboardTests"), // layer: test
        .executableTarget(name: "CanvasUITests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "Geometry", "HostSlots", "TestKit"], path: "Tests/CanvasUITests"), // layer: test
        .executableTarget(name: "SelectionTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/SelectionTests"), // layer: test
        .executableTarget(name: "ArrowsTests", dependencies: ["Canvas", "CanvasTesting", "Connections", "Find", "Geometry", "Keyboard", "Selection", "TableOfContents", "TestKit", "TextEditing"], path: "Tests/ArrowsTests"), // layer: test of Connections
        .executableTarget(name: "ValidationTests", dependencies: ["Canvas", "CanvasTesting", "DetailPanel", "Geometry", "TableOfContents", "TestKit", "Validation"], path: "Tests/ValidationTests"), // layer: test
        .executableTarget(name: "DetailPanelTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "HostSlots", "Keyboard", "Selection", "TestKit", "TextEditing"], path: "Tests/DetailPanelTests"), // layer: test
        .executableTarget(name: "TextEditingTests", dependencies: ["CanvasTesting", "TestKit", "TextEditing"], path: "Tests/TextEditingTests"), // layer: test
        .executableTarget(name: "FuzzyMatchingTests", dependencies: ["FuzzyMatching", "TestKit"], path: "Tests/FuzzyMatchingTests"), // layer: test
        .executableTarget(name: "ContextMenusTests", dependencies: ["Canvas", "CanvasTesting", "ContextMenus", "Keyboard", "Selection", "TestKit"], path: "Tests/ContextMenusTests"), // layer: test
        .executableTarget(name: "SlashCommandsTests", dependencies: ["Canvas", "CanvasTesting", "SlashCommands", "TestKit", "TextEditing"], path: "Tests/SlashCommandsTests"), // layer: test
        .executableTarget(name: "TableOfContentsTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Geometry", "Keyboard", "Selection", "TableOfContents", "TestKit"], path: "Tests/TableOfContentsTests"), // layer: test
        .executableTarget(name: "AdornmentsTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/AdornmentsTests"), // layer: test
        .executableTarget(name: "ClipboardTests", dependencies: ["Canvas", "CanvasTesting", "Clipboard", "ContextMenus", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/ClipboardTests"), // layer: test
        .executableTarget(name: "StickyNotesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Connections", "ContextMenus", "DetailPanel", "Geometry", "HostSlots", "Keyboard", "Mentions", "Selection", "SlashCommands", "StickyNotes", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology"], path: "Tests/StickyNotesTests"), // layer: test
        .executableTarget(name: "LockingTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "Geometry", "Keyboard", "Locking", "Selection", "SlashCommands", "TableOfContents", "TestKit"], path: "Tests/LockingTests"), // layer: test
        .executableTarget(name: "PublishingTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "Publishing", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology"], path: "Tests/PublishingTests"), // layer: test
        .executableTarget(name: "SchemasTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "CanvasUI", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "LanguageModels", "Mentions", "ProseMaps", "Schemas", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Validation"], path: "Tests/SchemasTests"), // layer: test
        .executableTarget(name: "LanguageModelsTests", dependencies: ["Canvas", "CanvasTesting", "HostSlots", "LanguageModels", "TestKit"], path: "Tests/LanguageModelsTests"), // layer: test
        .executableTarget(name: "ProseMapsTests", dependencies: ["Canvas", "CanvasTesting", "LanguageModels", "ProseMaps", "TestKit"], path: "Tests/ProseMapsTests"), // layer: test
        .executableTarget(name: "TitlesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Find", "Geometry", "Keyboard", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Validation"], path: "Tests/TitlesTests"), // layer: test
        .executableTarget(name: "PortsTests", dependencies: ["Canvas", "CanvasTesting", "Connections", "Geometry", "Keyboard", "Selection", "TestKit", "Topology"], path: "Tests/PortsTests"), // layer: test of Connections
        .executableTarget(name: "ArrowPortsTests", dependencies: ["Canvas", "CanvasTesting", "Connections", "Geometry", "Keyboard", "Neighbors", "Selection", "TableOfContents", "TestKit", "Topology"], path: "Tests/ArrowPortsTests"), // layer: test of Connections
        .executableTarget(name: "MentionsTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "CanvasUI", "ContextMenus", "DetailPanel", "Find", "Geometry", "Keyboard", "Mentions", "Neighbors", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Validation"], path: "Tests/MentionsTests"), // layer: test
        .executableTarget(name: "BoardsTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Find", "HostSlots", "Keyboard", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles"], path: "Tests/BoardsTests"), // layer: test
        .executableTarget(name: "SubboardsTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "CanvasUI", "Connections", "ContextMenus", "DetailPanel", "Keyboard", "Mentions", "Selection", "SlashCommands", "Subboards", "TableOfContents", "TestKit", "Titles", "Topology", "Transform"], path: "Tests/SubboardsTests"), // layer: test
        .executableTarget(name: "FramesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Frames", "Geometry", "Keyboard", "Mentions", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Transform"], path: "Tests/FramesTests"), // layer: test
        .executableTarget(name: "JumpToTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "CanvasUI", "ContextMenus", "DetailPanel", "Geometry", "HostSlots", "JumpTo", "Keyboard", "Selection", "SlashCommands", "TestKit", "TextEditing", "Titles", "Topology"], path: "Tests/JumpToTests"), // layer: test
        .executableTarget(name: "ReferencesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "LanguageModels", "Mentions", "Publishing", "Queries", "QueryTranslation", "References", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Validation"], path: "Tests/ReferencesTests"), // layer: test
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
        .executableTarget(name: "AutomationTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "Geometry", "HostSlots", "Queries", "TestKit", "Topology"], path: "Tests/AutomationTests"), // layer: test
        .executableTarget(name: "TitleNamesTests", dependencies: ["Adornments", "Automation", "Canvas", "CanvasRPC", "CanvasTesting", "DrawLexicon", "Keyboard", "Selection", "SlashCommands", "TestKit", "Titles"], path: "Tests/TitleNamesTests"), // layer: test of DrawLexicon
        .executableTarget(name: "PortEdgesTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "Connections", "DrawLexicon", "Keyboard", "Selection", "TestKit", "Topology"], path: "Tests/PortEdgesTests"), // layer: test of DrawLexicon
        .executableTarget(name: "MentionTextsTests", dependencies: ["Adornments", "Automation", "Canvas", "CanvasRPC", "ContextMenus", "DetailPanel", "DrawLexicon", "Keyboard", "Mentions", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Validation"], path: "Tests/MentionTextsTests"), // layer: test of DrawLexicon
        .executableTarget(name: "ValidationChecksTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "DrawLexicon", "TestKit", "Validation"], path: "Tests/ValidationChecksTests"), // layer: test of DrawLexicon
        .executableTarget(name: "ExamplesTests", dependencies: ["Canvas", "CanvasTesting", "Connections", "ContextMenus", "Keyboard", "Reordering", "Selection", "TableOfContents", "TestKit"], path: "Tests/ExamplesTests"), // layer: test
        .executableTarget(name: "CompositionTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "DrawScript", "Geometry", "HostSlots", "QueryLanguage", "ShippedTesting", "TestKit", "TextEditing"] + shipped, path: "Tests/CompositionTests"), // layer: test
        .executableTarget(name: "BenchmarkTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Geometry", "HostSlots", "QueryLanguage", "ShippedTesting", "TestKit"] + shipped, path: "Tests/BenchmarkTests"), // layer: test
    ],
    swiftLanguageModes: [.v6]
)

// build.sh passes the same to swiftc: without it, members of modules a file doesn't import leak
// into scope and the import audit would miss real dependencies.
for target in package.targets {
    target.swiftSettings = [.enableUpcomingFeature("MemberImportVisibility")]
}
