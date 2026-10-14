// swift-tools-version: 6.0
import PackageDescription

// THE MODULE GRAPH, AND WHAT SHIPS. This file is the only place module dependencies are written
// down, and the only list of the plugins the product is made of (the table before the targets). The
// parts a large module is split into, and what each uses, are a table of their own after that one.
// build.sh reads it as a table, so every target stays on ONE line, in exactly this form:
//     .target(name: "X", dependencies: ["A", "B"]),                          // layer: <layer>
//     .target(name: "X", dependencies: ["A"], path: "Examples/X"),          // layer: <layer>
//     .executableTarget(name: "X", dependencies: ["A"], path: "Tests/X"),   // layer: <layer>
//     .executableTarget(name: "X", dependencies: ["A"] + shipped),          // layer: <layer>
// Modules live in Sources/X or Examples/X; test and testsupport modules in Tests/X.
//
// Layers: each answers one question, may depend on the layers it lists, and says how to tell a module
// belongs (the audit holds the tests marked *):
//     wire         -> wire                               what the app and its command line say to
//                                                        each other, so `canvas` builds without the
//                                                        app; * imports nothing but the wire
//     foundation   -> foundation, wire                   what every plugin stands on and no plugin
//                                                        shapes: the core (Canvas, which holds the
//                                                        host slots, what the host takes from the
//                                                        plugins, and so names SwiftUI's views and
//                                                        the wire's types for the commands the app's
//                                                        server runs), and pure libraries beneath
//                                                        it (DrawScript); * knows no plugin
//     ui           -> foundation, wire                   the window around the canvas, so no plugin
//                                                        reaches the window and the window reaches
//                                                        no plugin; also the app's end of the
//                                                        command line
//   the plugins that cut across kinds (horizontals) are four layers, and the verticals are the kinds:
//     surface      -> foundation, surface                something other plugins build on or show
//                                                        themselves on, so anything can appear on it
//                                                        without it knowing (the draw engine, the
//                                                        query engine and English-to-query
//                                                        translation are surfaces every plugin may
//                                                        run); * declares an extension point or
//                                                        another plugin imports it; knows no concern
//     concern      -> foundation, surface, concern       a meaning shapes carry or kinds opt into,
//                                                        shown on the surfaces it imports; * declares
//                                                        an extension point or a property
//                                                        (PropertyKey); may own the one kind it's
//                                                        drawn as (Connections' arrow); knows no
//                                                        language
//     feature      -> foundation, surface, concern       a cross-cutting behavior the person uses (a
//                                                        palette, a command, a gesture) that nothing
//                                                        builds on: horizontal in reach, a leaf in
//                                                        the graph; * declares no ShapeKind, no
//                                                        extension point and no PropertyKey, and no
//                                                        plugin imports it
//     language     -> foundation, surface, language,     where an agent's request arrives over the
//                     wire                               wire and is answered (the command line, and
//                                                        `canvas draw` and `canvas query` over their
//                                                        engines): the only plugin layer that speaks
//                                                        the wire; what it says of a concern comes
//                                                        through its engine's points; * knows no
//                                                        concern
//     vertical     -> foundation, surface, concern       a shape kind: its props, definition, tool
//                                                        and opt-ins to concerns; * declares a
//                                                        ShapeKind and no plugin imports it; knows no
//                                                        other vertical, and no language
//     app          -> foundation, ui, wire               the product's executables, the one place the
//                                                        shipped list is composed: the app, and what
//                                                        it carries (`of` the app: an extension macOS
//                                                        runs on its own, packaged into the app's
//                                                        bundle, as Quick Look's preview and
//                                                        thumbnail of a board file are); * names no
//                                                        plugin: its plugins are the list's, made by
//                                                        name (`+ shipped`)
//     cli          -> wire                               the command line (`canvas`), an executable:
//                                                        * knows only the wire, never the app
//     testsupport  -> foundation, testsupport            and, for the one that is the tests' way to the
//                                                        product's plugins (`+ shipped`), what ships
//     test         -> anything but app, cli and test; a test named <M>Tests may use only M, M's
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
// in its owner's module, and no module joins two others. A language imports no concern, and a concern
// fills the engine's points: a word in a language is given by the module that owns its meaning, as a
// plugin value of its own, through the engine's points (Titles gives queries its names and `canvas
// draw` its titles, Boards queries its boards' names); when the owner sits below the engine, the
// engine's module gives it (Queries gives `:selected`, Selection being below it).
//
// build.sh refuses to build when:
//   - the graph has a cycle, or an edge the layers above forbid;
//   - the list names something that isn't a public struct of that module that can be made with no
//     arguments (a ListedPlugin), names a plugin twice, or isn't in the form its comment says;
//   - the app or its extension imports a module the list names;
//   - a line says `of` where its layer doesn't allow it: any layer but test and app, a test of a
//     module it doesn't depend on, an app of anything but the app itself (an app needn't depend on
//     its subject);
//   - SwiftPM, evaluating this file, sees other targets or dependencies than the one-line table
//     (so code below the targets can't change the graph);
//   - a module's imports, as the compiler parses them, aren't exactly its dependencies here;
//   - an import sits inside #if or carries @_exported, @_implementationOnly or @testable, or code
//     asks canImport(<a module here>);
//   - a public type is named like a module, or Task or Span (either would shadow Swift's in every
//     importer);
//   - a surface, concern, feature or vertical lacks what its layer is for (the tests marked * above):
//     a vertical declares no ShapeKind, a feature declares a ShapeKind, an extension point or a
//     PropertyKey, a concern declares neither a point nor a PropertyKey, a surface declares no point
//     and no plugin imports it;
//   - a module writes another module's ShapeKind, PluginID, ToolID, PropertyKey, ChannelID (a
//     Connections channel's) or EdgeTypeID (a Topology edge type's) as a string literal without
//     depending on that module;
//   - a part of a module (the table of parts, after what ships) names something of a part its line
//     doesn't say it uses.
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
    // board, a board of its own), after notes: the toolbar's Note, Subboard, Frame, Reference.
    "Connections.ArrowsPlugin", "StickyNotes.StickyNotesPlugin", "Subboards.SubboardsPlugin", "Frames.FramesPlugin", "References.ReferencesPlugin",
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
    // mention text (a note's, a type's words, an arrow's label).
    "Titles.TitleFindPlugin", "Mentions.MentionFindPlugin",
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
    // Types: a note that holds a JSON Schema, its words and its schema kept in step by the model.
    // After Mentions, Titles and Validation, and after every plugin whose every-shape commands
    // a note lists before `/is-a` (Publishing's `/public` among them); its rules and its panel.
    "Types.TypesPlugin", "Types.TypeValidationPlugin", "Types.TypeDetailsPlugin",
    // What ⌘F finds in a note that is one: its values. After Find and Types, its two owners.
    "Types.FieldFindPlugin",
    // Colors: the color a shape of a kind that opted in holds, and the book that says what every
    // color looks like. After every plugin whose every-shape commands a note lists before `/color`
    // (Types' `/is-a` among them); then its warning and its row in the panel.
    "Colors.ColorsPlugin", "Colors.ColorValidationPlugin", "Colors.ColorDetailsPlugin",
    // What a drag moves snaps to the shapes in view: their edges, their middles and the spaces
    // between them.
    "Snapping.SnappingPlugin",
    // Ports, whose arrows `ArrowPortsPlugin` draws. After Adornments: a shape's dots draw
    // above its adornments (the lock chip among them), and are found before them.
    "Connections.PortsPlugin", "Connections.ArrowPortsPlugin",
    "LanguageModels.LanguageModelsPlugin",
    // What words say of what's lower level, asked of the model: a type's highlights.
    "ProseMaps.ProseMapsPlugin",
    // The draw engine, then the command line's commands over it, and the words each plugin that
    // owns a meaning gives `canvas draw`, each after the engine, whose points they fill: titles for
    // names, ports' connections for edges, validity for its warnings, and mentions for text
    // (`@[Title]` in a note's text names the shape called that).
    "Draw.DrawPlugin", "Automation.AutomationPlugin", "Titles.TitleNamesPlugin", "Connections.PortEdgesPlugin", "Validation.ValidationChecksPlugin", "Mentions.MentionTextsPlugin", "Types.TypeNamesPlugin", "Types.FieldValuesPlugin", "Colors.ColorNamesPlugin",
    // Reading the file: `canvas query`, and the words each plugin that owns a meaning gives it:
    // titles for names, boards' names, mentions for text and relations, validity and the selection
    // for their words, each after Queries, whose points they fill. The translator of English into
    // queries reads its prompt from the product's own files (Shipped/ask-prompt.txt, in the
    // binary).
    "Queries.QueriesPlugin", "QueryTranslation.QueryTranslationPlugin", "Titles.TitleQueriesPlugin", "Boards.BoardQueriesPlugin", "Mentions.MentionQueriesPlugin", "Validation.ValidationQueriesPlugin", "Types.TypeQueriesPlugin", "Colors.ColorQueriesPlugin",
    "Queries.SelectionQueriesPlugin",
    "QueryCommands.QueryCommandsPlugin",
    // Hover a shape, on the canvas or by its row in the table of contents, and what it connects to is outlined by how: after the
    // query plugins, whose engine it asks, and Selection and the table of contents, whose hovers it follows. Then the lights,
    // from the plugins that own the edges, in the order a shape's rings go: arrows' (points to, pointed to by), then
    // mentions' (mentions, mentioned by). Then the same ways as lists in a shape's panel, its Connections tab, with what the shape is
    // inside and what it holds: after the detail panel, whose tab it is.
    "Neighbors.NeighborsPlugin", "Connections.ArrowLightsPlugin", "Mentions.MentionLightsPlugin", "Neighbors.NeighborDetailsPlugin",
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

// THE PARTS OF A MODULE. A module too large to hold in mind is split into parts, each a folder of its
// directory, with the same rule between them as between modules: a part uses only the parts its line
// names, and build.sh type-checks each with those sources alone, so naming anything else of the module
// doesn't compile. They are parts and not modules, since nothing must build without the others and
// what one shares with the next stays internal to the module. A line is `"Module/Part": [the parts
// it uses],`, the parts in an order they could be built in: a part uses only parts above it (so there
// is no cycle) and names all of what those use (so a line says everything its part compiles with).
// Every folder of a module that has parts is one; the sources beside the folders are the module's
// own (its plugins, which install every part) and may use them all.
//
// Types: the JSON a schema is read, completed and checked as; a type, and what a shape is (the two
// properties and the file's index of them); the fields a list of types gives a note, their kinds,
// values and one writer; the check of a note's values; the model keeping a type's words and schema
// in step; what a shape is, shown and changed (the commands, `/is-a`, the menu, the chips, the
// panel's tabs); the form a card and the panel hold; the rows on a note; and the words draw, queries
// and Find are given.
//
// build.sh reads this table as text, as it reads the targets, so it stays in this form: the opening
// line, a part a line, comments on lines of their own, and `]`. SwiftPM makes nothing of it.
let parts: KeyValuePairs<String, [String]> = [
    "Types/JSON": [],
    "Types/Type": ["JSON"],
    "Types/Fields": ["JSON", "Type"],
    "Types/Checks": ["JSON", "Type", "Fields"],
    "Types/Sync": ["JSON", "Type"],
    "Types/IsA": ["JSON", "Type", "Fields", "Sync"],
    "Types/Form": ["JSON", "Type", "Fields", "Checks", "Sync", "IsA"],
    "Types/Rows": ["JSON", "Type", "Fields", "Checks", "Sync", "IsA", "Form"],
    "Types/Engines": ["JSON", "Type", "Fields", "Checks", "Sync", "IsA", "Form", "Rows"],
]

let package = Package(
    name: "InfiniteCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Geometry", dependencies: []),                                          // layer: foundation
        .target(name: "DrawScript", dependencies: ["Geometry"]),                              // layer: foundation
        .target(name: "QueryLanguage", dependencies: []),                                     // layer: foundation
        .target(name: "TextEditing", dependencies: []),                                       // layer: foundation
        .target(name: "FuzzyMatching", dependencies: []),                                     // layer: foundation
        .target(name: "Palette", dependencies: []),                                           // layer: foundation
        .target(name: "Canvas", dependencies: ["CanvasRPC", "Geometry", "Palette"]),          // layer: foundation
        .target(name: "CanvasRPC", dependencies: []),                                         // layer: wire
        .target(name: "CanvasUI", dependencies: ["Canvas", "CanvasRPC", "Geometry", "Palette"]), // layer: ui

        .target(name: "Keyboard", dependencies: ["Canvas"]),                                  // layer: surface
        .target(name: "Selection", dependencies: ["Canvas", "Geometry", "Keyboard", "Palette"]), // layer: surface
        .target(name: "DetailPanel", dependencies: ["Canvas", "FuzzyMatching", "Selection", "TextEditing"]), // layer: surface
        .target(name: "ContextMenus", dependencies: ["Canvas", "Selection"]),                 // layer: surface
        .target(name: "SlashCommands", dependencies: ["Canvas", "FuzzyMatching", "TextEditing"]), // layer: surface
        .target(name: "TableOfContents", dependencies: ["Canvas", "DetailPanel", "Selection"]), // layer: surface
        .target(name: "Adornments", dependencies: ["Canvas", "Geometry", "Palette", "Selection"]),       // layer: surface
        .target(name: "LanguageModels", dependencies: ["Canvas"]),                            // layer: surface
        .target(name: "ProseMaps", dependencies: ["Canvas", "LanguageModels"]),               // layer: surface
        .target(name: "Topology", dependencies: ["Canvas"]),                                  // layer: surface
        .target(name: "Find", dependencies: ["Canvas", "DetailPanel", "FuzzyMatching", "Geometry", "Keyboard", "Selection", "Topology"]), // layer: surface
        // Neighbors: a surface an edge's owner shows its edges on. Hovering a shape, on the canvas or by its row in the table of contents
        // (Selection's `hovered`, and `hoveredElsewhere` for a row of another board), outlines every shape connected to it in a color for each
        // way, through the core's tinted outlines, and a shape's panel lists them by the same ways, then what it's inside and what it holds
        // (a tab of the detail panel's, its lists searched with FuzzyMatching's matcher, a shape with no title called what the table of
        // contents calls it). What counts as connected is a light, a title, a color
        // and a query, which the plugin that owns the edges contributes (Connections' arrows, Mentions' mentions) and Queries answers; the file
        // says where a shape on another board is drawn, and Topology when the edges change.
        .target(name: "Neighbors", dependencies: ["Canvas", "DetailPanel", "FuzzyMatching", "Palette", "Queries", "Selection", "TableOfContents", "Topology"]), // layer: surface

        .target(name: "Validation", dependencies: ["Canvas", "DetailPanel", "Draw", "Queries", "TableOfContents"]), // layer: concern
        .target(name: "Clipboard", dependencies: ["Canvas", "ContextMenus", "Geometry", "Keyboard", "Selection"]), // layer: concern
        .target(name: "Titles", dependencies: ["Adornments", "Canvas", "DetailPanel", "Draw", "Find", "Queries", "SlashCommands", "TableOfContents", "Validation"]),  // layer: concern
        .target(name: "Locking", dependencies: ["Adornments", "Canvas", "ContextMenus", "SlashCommands", "TableOfContents"]), // layer: concern
        .target(name: "Connections", dependencies: ["Canvas", "Colors", "Draw", "Geometry", "Mentions", "Neighbors", "Palette", "Publishing", "Selection", "TableOfContents", "TextEditing", "Topology", "Types"]), // layer: concern
        .target(name: "Mentions", dependencies: ["Canvas", "ContextMenus", "DetailPanel", "Draw", "Find", "FuzzyMatching", "Neighbors", "Queries", "Selection", "SlashCommands", "TableOfContents", "TextEditing", "Titles", "Topology", "Validation"]), // layer: concern
        .target(name: "Publishing", dependencies: ["Adornments", "Canvas", "ContextMenus", "DetailPanel", "Neighbors", "Selection", "SlashCommands", "TableOfContents", "Titles", "Topology"]), // layer: concern
        .target(name: "Boards", dependencies: ["Canvas", "ContextMenus", "DetailPanel", "Find", "Keyboard", "Queries", "Selection", "TableOfContents", "Titles"]), // layer: concern
        .target(name: "Snapping", dependencies: ["Canvas", "Geometry"]),                      // layer: feature
        .target(name: "Transform", dependencies: ["Canvas", "ContextMenus", "SlashCommands"]), // layer: concern
        .target(name: "Colors", dependencies: ["Canvas", "ContextMenus", "DetailPanel", "Draw", "Palette", "Queries", "SlashCommands", "Validation"]), // layer: concern
        .target(name: "Types", dependencies: ["Adornments", "Canvas", "Colors", "ContextMenus", "DetailPanel", "Draw", "Find", "LanguageModels", "Mentions", "Palette", "ProseMaps", "Queries", "Selection", "SlashCommands", "TextEditing", "Titles", "Topology", "Validation"]), // layer: concern

        .target(name: "Draw", dependencies: ["Adornments", "Canvas", "DrawScript", "Geometry", "Queries", "QueryLanguage", "Topology"]), // layer: surface
        .target(name: "Automation", dependencies: ["Canvas", "CanvasRPC", "Draw", "DrawScript"]), // layer: language
        .target(name: "Queries", dependencies: ["Canvas", "DrawScript", "QueryLanguage", "Selection", "Topology"]), // layer: surface
        .target(name: "QueryTranslation", dependencies: ["Canvas", "LanguageModels", "Queries", "QueryLanguage"]), // layer: surface
        .target(name: "QueryCommands", dependencies: ["Automation", "Canvas", "CanvasRPC", "LanguageModels", "Queries", "QueryLanguage", "QueryTranslation"]), // layer: language

        .target(name: "StickyNotes", dependencies: ["Canvas", "Colors", "Connections", "DetailPanel", "Keyboard", "Mentions", "Palette", "Selection", "TableOfContents", "TextEditing", "Titles", "Types"]), // layer: vertical
        .target(name: "Subboards", dependencies: ["Boards", "Canvas", "Colors", "Connections", "DetailPanel", "Keyboard", "Mentions", "Palette", "TableOfContents", "Titles", "Transform"]), // layer: vertical
        .target(name: "Frames", dependencies: ["Canvas", "Colors", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "Mentions", "Palette", "Selection", "TableOfContents", "Titles", "Transform"]), // layer: vertical
        // Jump To (⌘K): a feature no kind opts into and nothing imports: it lists
        // the titled shapes Titles names (each tinted as its kind is, the core's `registry.label(of:)`), goes to one as Boards' crumbs do (Boards'
        // `follow`), and shows its list in TextEditing's caret list, its palette over the canvas in one of the host's slots.
        .target(name: "JumpTo", dependencies: ["Boards", "Canvas", "FuzzyMatching", "Geometry", "Keyboard", "TextEditing", "Titles", "Topology"]), // layer: feature
        .target(name: "References", dependencies: ["Boards", "Canvas", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "LanguageModels", "Mentions", "Palette", "Publishing", "Queries", "QueryLanguage", "QueryTranslation", "Selection", "TableOfContents", "TextEditing", "Topology", "Validation"]), // layer: vertical
        // Moving (`/move-to`, `/move-near`): a feature no kind opts into and nothing imports: two slash
        // commands that move a shape into a frame, onto a subboard's board or beside a shape, placed as `canvas draw` places one (Draw's
        // placement for plugins, `Surroundings`),
        // and the table of contents' drops that move shapes into a frame, onto a subboard's board or out of frames (`ContentsMoves`).
        .target(name: "Moving", dependencies: ["Canvas", "Draw", "SlashCommands", "TableOfContents"]), // layer: feature

        // Examples: the smallest plugin for each pattern (see docs/plugin-system.md).
        .target(name: "Reordering", dependencies: ["Canvas", "ContextMenus"], path: "Examples/Reordering"),             // layer: feature

        .executableTarget(name: "InfiniteCanvas", dependencies: ["Canvas", "CanvasUI"] + shipped),               // layer: app
        .executableTarget(name: "CanvasQuickLook", dependencies: ["Canvas", "CanvasUI"] + shipped),              // layer: app of InfiniteCanvas
        .executableTarget(name: "CanvasCLI", dependencies: ["CanvasRPC"]),                                        // layer: cli

        .target(name: "TestKit", dependencies: [], path: "Tests/TestKit"),                                        // layer: testsupport
        .target(name: "CanvasTesting", dependencies: ["Canvas", "Geometry", "TestKit"], path: "Tests/CanvasTesting"), // layer: testsupport
        // The tests' way to the product's plugins: the list, with a pasteboard and a model of the test's own.
        .target(name: "ShippedTesting", dependencies: ["Canvas"] + shipped, path: "Tests/ShippedTesting"),  // layer: testsupport
        .executableTarget(name: "CanvasTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "Geometry", "TestKit"], path: "Tests/CanvasTests"), // layer: test
        .executableTarget(name: "CanvasRPCTests", dependencies: ["CanvasRPC", "TestKit"], path: "Tests/CanvasRPCTests"), // layer: test
        .executableTarget(name: "DrawScriptTests", dependencies: ["DrawScript", "Geometry", "TestKit"], path: "Tests/DrawScriptTests"), // layer: test
        .executableTarget(name: "QueryLanguageTests", dependencies: ["QueryLanguage", "TestKit"], path: "Tests/QueryLanguageTests"), // layer: test
        .executableTarget(name: "CanvasCLITests", dependencies: ["CanvasRPC", "TestKit"], path: "Tests/CanvasCLITests"), // layer: test
        .executableTarget(name: "KeyboardTests", dependencies: ["Canvas", "CanvasTesting", "Keyboard", "TestKit"], path: "Tests/KeyboardTests"), // layer: test
        .executableTarget(name: "CanvasUITests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "Geometry", "TestKit"], path: "Tests/CanvasUITests"), // layer: test
        .executableTarget(name: "SelectionTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/SelectionTests"), // layer: test
        .executableTarget(name: "ArrowsTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Colors", "Connections", "ContextMenus", "DetailPanel", "Find", "Geometry", "Keyboard", "Mentions", "Palette", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Types"], path: "Tests/ArrowsTests"), // layer: test of Connections
        .executableTarget(name: "ValidationTests", dependencies: ["Canvas", "CanvasTesting", "DetailPanel", "Geometry", "TableOfContents", "TestKit", "Validation"], path: "Tests/ValidationTests"), // layer: test
        .executableTarget(name: "DetailPanelTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Keyboard", "Selection", "TestKit", "TextEditing"], path: "Tests/DetailPanelTests"), // layer: test
        .executableTarget(name: "TextEditingTests", dependencies: ["CanvasTesting", "TestKit", "TextEditing"], path: "Tests/TextEditingTests"), // layer: test
        .executableTarget(name: "FuzzyMatchingTests", dependencies: ["FuzzyMatching", "TestKit"], path: "Tests/FuzzyMatchingTests"), // layer: test
        .executableTarget(name: "PaletteTests", dependencies: ["Palette", "TestKit"], path: "Tests/PaletteTests"), // layer: test
        .executableTarget(name: "ColorsTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Colors", "ContextMenus", "DetailPanel", "Draw", "Geometry", "Keyboard", "Palette", "Queries", "QueryLanguage", "Selection", "SlashCommands", "TestKit", "TextEditing", "Topology", "Validation"], path: "Tests/ColorsTests"), // layer: test
        .executableTarget(name: "ContextMenusTests", dependencies: ["Canvas", "CanvasTesting", "ContextMenus", "Keyboard", "Selection", "TestKit"], path: "Tests/ContextMenusTests"), // layer: test
        .executableTarget(name: "SlashCommandsTests", dependencies: ["Canvas", "CanvasTesting", "SlashCommands", "TestKit", "TextEditing"], path: "Tests/SlashCommandsTests"), // layer: test
        .executableTarget(name: "TableOfContentsTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Geometry", "Keyboard", "Selection", "TableOfContents", "TestKit"], path: "Tests/TableOfContentsTests"), // layer: test
        .executableTarget(name: "AdornmentsTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Geometry", "Keyboard", "Palette", "Selection", "TestKit"], path: "Tests/AdornmentsTests"), // layer: test
        .executableTarget(name: "ClipboardTests", dependencies: ["Canvas", "CanvasTesting", "Clipboard", "ContextMenus", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/ClipboardTests"), // layer: test
        .executableTarget(name: "StickyNotesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "CanvasUI", "Colors", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "LanguageModels", "Mentions", "Palette", "ProseMaps", "Selection", "SlashCommands", "StickyNotes", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Types"], path: "Tests/StickyNotesTests"), // layer: test
        .executableTarget(name: "LockingTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "Geometry", "Keyboard", "Locking", "Selection", "SlashCommands", "TableOfContents", "TestKit"], path: "Tests/LockingTests"), // layer: test
        .executableTarget(name: "PublishingTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "Neighbors", "Publishing", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology"], path: "Tests/PublishingTests"), // layer: test
        .executableTarget(name: "TypesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "CanvasUI", "Colors", "ContextMenus", "DetailPanel", "Draw", "Find", "Geometry", "Keyboard", "LanguageModels", "Mentions", "Palette", "ProseMaps", "Queries", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Types", "Validation"], path: "Tests/TypesTests"), // layer: test
        .executableTarget(name: "LanguageModelsTests", dependencies: ["Canvas", "CanvasTesting", "LanguageModels", "TestKit"], path: "Tests/LanguageModelsTests"), // layer: test
        .executableTarget(name: "ProseMapsTests", dependencies: ["Canvas", "CanvasTesting", "LanguageModels", "ProseMaps", "TestKit"], path: "Tests/ProseMapsTests"), // layer: test
        .executableTarget(name: "TitlesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Find", "Geometry", "Keyboard", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Validation"], path: "Tests/TitlesTests"), // layer: test
        .executableTarget(name: "PortsTests", dependencies: ["Canvas", "CanvasTesting", "Connections", "Geometry", "Keyboard", "Selection", "TestKit", "Topology"], path: "Tests/PortsTests"), // layer: test of Connections
        .executableTarget(name: "ArrowPortsTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Colors", "Connections", "ContextMenus", "DetailPanel", "Draw", "Geometry", "Keyboard", "Mentions", "Neighbors", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Types"], path: "Tests/ArrowPortsTests"), // layer: test of Connections
        .executableTarget(name: "MentionsTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "CanvasUI", "ContextMenus", "DetailPanel", "Find", "Geometry", "Keyboard", "Mentions", "Neighbors", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Validation"], path: "Tests/MentionsTests"), // layer: test
        .executableTarget(name: "BoardsTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Find", "Keyboard", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles"], path: "Tests/BoardsTests"), // layer: test
        .executableTarget(name: "SubboardsTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "CanvasUI", "Colors", "Connections", "ContextMenus", "DetailPanel", "Keyboard", "Mentions", "Palette", "Selection", "SlashCommands", "Subboards", "TableOfContents", "TestKit", "Titles", "Topology", "Transform"], path: "Tests/SubboardsTests"), // layer: test
        .executableTarget(name: "FramesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Colors", "ContextMenus", "DetailPanel", "Frames", "Geometry", "Keyboard", "Mentions", "Palette", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Transform"], path: "Tests/FramesTests"), // layer: test
        .executableTarget(name: "JumpToTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "CanvasUI", "ContextMenus", "DetailPanel", "Geometry", "JumpTo", "Keyboard", "Selection", "SlashCommands", "TestKit", "TextEditing", "Titles", "Topology"], path: "Tests/JumpToTests"), // layer: test
        .executableTarget(name: "ReferencesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Colors", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "LanguageModels", "Mentions", "Publishing", "Queries", "QueryTranslation", "References", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Types", "Validation"], path: "Tests/ReferencesTests"), // layer: test
        .executableTarget(name: "PlacingTests", dependencies: ["Canvas", "CanvasTesting", "Draw", "TestKit"], path: "Tests/PlacingTests"), // layer: test of Draw
        .executableTarget(name: "MovingTests", dependencies: ["Canvas", "CanvasTesting", "Keyboard", "Moving", "Selection", "SlashCommands", "TableOfContents", "TestKit"], path: "Tests/MovingTests"), // layer: test
        .executableTarget(name: "NeighborsTests", dependencies: ["Canvas", "CanvasTesting", "DetailPanel", "Keyboard", "Neighbors", "Queries", "Selection", "TableOfContents", "TestKit", "Topology"], path: "Tests/NeighborsTests"), // layer: test
        .executableTarget(name: "SnappingTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "Snapping", "TestKit"], path: "Tests/SnappingTests"), // layer: test
        .executableTarget(name: "TransformTests", dependencies: ["Canvas", "CanvasTesting", "ContextMenus", "Keyboard", "Selection", "SlashCommands", "TestKit", "Transform"], path: "Tests/TransformTests"), // layer: test
        .executableTarget(name: "FindTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Find", "Geometry", "Keyboard", "Selection", "TestKit", "Topology"], path: "Tests/FindTests"), // layer: test
        .executableTarget(name: "TopologyTests", dependencies: ["Canvas", "CanvasTesting", "TestKit", "Topology"], path: "Tests/TopologyTests"), // layer: test
        .executableTarget(name: "QueriesTests", dependencies: ["Canvas", "CanvasTesting", "Queries", "QueryLanguage", "TestKit", "Topology"], path: "Tests/QueriesTests"), // layer: test
        .executableTarget(name: "TypeQueriesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Keyboard", "LanguageModels", "Mentions", "ProseMaps", "Queries", "QueryLanguage", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Types", "Validation"], path: "Tests/TypeQueriesTests"), // layer: test of Types
        .executableTarget(name: "TitleQueriesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Keyboard", "Queries", "QueryLanguage", "Selection", "SlashCommands", "TestKit", "Titles", "Topology"], path: "Tests/TitleQueriesTests"), // layer: test of Titles
        .executableTarget(name: "BoardQueriesTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Keyboard", "Queries", "Selection", "SlashCommands", "TestKit", "Titles", "Topology"], path: "Tests/BoardQueriesTests"), // layer: test of Boards
        .executableTarget(name: "MentionQueriesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Keyboard", "Mentions", "Queries", "QueryLanguage", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology"], path: "Tests/MentionQueriesTests"), // layer: test of Mentions
        .executableTarget(name: "ValidationQueriesTests", dependencies: ["Canvas", "CanvasTesting", "Queries", "QueryLanguage", "TestKit", "Topology", "Validation"], path: "Tests/ValidationQueriesTests"), // layer: test of Validation
        .executableTarget(name: "SelectionQueriesTests", dependencies: ["Canvas", "CanvasTesting", "Keyboard", "Queries", "QueryLanguage", "Selection", "TestKit", "Topology"], path: "Tests/SelectionQueriesTests"), // layer: test of Queries
        .executableTarget(name: "QueryTranslationTests", dependencies: ["Canvas", "CanvasTesting", "LanguageModels", "Queries", "QueryLanguage", "QueryTranslation", "TestKit", "Topology"], path: "Tests/QueryTranslationTests"), // layer: test
        .executableTarget(name: "QueryCommandsTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "LanguageModels", "Queries", "QueryCommands", "QueryLanguage", "QueryTranslation", "TestKit", "Topology"], path: "Tests/QueryCommandsTests"), // layer: test
        .executableTarget(name: "AutomationTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "Draw", "DrawScript", "Geometry", "Queries", "TestKit", "Topology"], path: "Tests/AutomationTests"), // layer: test
        .executableTarget(name: "TitleNamesTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "Draw", "Keyboard", "Selection", "SlashCommands", "TestKit", "Titles"], path: "Tests/TitleNamesTests"), // layer: test of Titles
        .executableTarget(name: "TypeNamesTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "ContextMenus", "DetailPanel", "Draw", "Keyboard", "LanguageModels", "Mentions", "ProseMaps", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Types", "Validation"], path: "Tests/TypeNamesTests"), // layer: test of Types
        .executableTarget(name: "PortEdgesTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "Connections", "Draw", "Keyboard", "Selection", "TestKit", "Topology"], path: "Tests/PortEdgesTests"), // layer: test of Connections
        .executableTarget(name: "MentionTextsTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "ContextMenus", "DetailPanel", "Draw", "Keyboard", "Mentions", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Validation"], path: "Tests/MentionTextsTests"), // layer: test of Mentions
        .executableTarget(name: "ValidationChecksTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "Draw", "TestKit", "Validation"], path: "Tests/ValidationChecksTests"), // layer: test of Validation
        .executableTarget(name: "ExamplesTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Colors", "Connections", "ContextMenus", "Keyboard", "Mentions", "Reordering", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Types"], path: "Tests/ExamplesTests"), // layer: test
        .executableTarget(name: "CompositionTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "DrawScript", "Geometry", "Palette", "QueryLanguage", "ShippedTesting", "TestKit", "TextEditing"] + shipped, path: "Tests/CompositionTests"), // layer: test
        .executableTarget(name: "BenchmarkTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Geometry", "QueryLanguage", "ShippedTesting", "TestKit"] + shipped, path: "Tests/BenchmarkTests"), // layer: test
    ],
    swiftLanguageModes: [.v6]
)

// build.sh passes the same to swiftc: without it, members of modules a file doesn't import leak
// into scope and the import audit would miss real dependencies.
for target in package.targets {
    target.swiftSettings = [.enableUpcomingFeature("MemberImportVisibility")]
}
