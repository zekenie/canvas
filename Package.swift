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
// Layers: three rungs, each importing only from its own rung and those below it, and two kinds of test
// target, which say what a line is, not where it sits (the audit holds the tests marked *):
//     core         -> core                               the canvas and plain libraries: the core
//                                                        (Canvas, which holds the host slots, what the
//                                                        host takes from the plugins, and so names
//                                                        SwiftUI's views and the wire's types for the
//                                                        commands the app's server runs), the wire
//                                                        (CanvasRPC, what the app and its command line
//                                                        say to each other, whose JSON is the core's
//                                                        JSON value too), and pure libraries
//                                                        beneath them (DrawScript); * knows no plugin
//     core private -> core                               the core's own modules, which no plugin may
//                                                        import: * only another private module and a
//                                                        test may. The window (CanvasUI), the command
//                                                        line (`canvas`), and the product's
//                                                        executables, the one place the shipped list
//                                                        is composed: the app, and what it carries
//                                                        (`of` the app: an extension macOS runs on its
//                                                        own, packaged into the app's bundle, as Quick
//                                                        Look's preview and thumbnail of a board file
//                                                        are); * names no plugin: its plugins are the
//                                                        list's, made by name (`+ shipped`). * An
//                                                        executable on the core is private
//     platform     -> core, platform                     what every shape gets, whatever its kind:
//                                                        horizontals (the interfaces verticals plug
//                                                        into, something a shape shows up on in the
//                                                        window or has as a trait), things you do,
//                                                        engines, and what agents speak; a heading
//                                                        over each group below, which nothing checks
//     product      -> core, platform                     the verticals, shapes that hold something of
//                                                        their own (a note's text, an arrow's ends
//                                                        and label, a frame's region, a subboard's
//                                                        board); * declares a ShapeKind, and nothing
//                                                        imports it: products never know each other
//     testsupport  -> core, testsupport                  and, for the one that is the tests' way to the
//                                                        product's plugins (`+ shipped`), what ships
//     test         -> anything but an executable or a test; a test named <M>Tests may use only M, M's
//                     dependencies, testsupport modules and the window, and so may one named after a
//                     plugin of M that says so: `// layer: test of M` (TitleQueriesTests)
// Four rules hold of modules named, from layers there were before the rungs: the wire (CanvasRPC)
// imports nothing, and the command line (CanvasCLI) only the wire, so `canvas` builds without the app;
// the editor's host API is the window's and the tests' alone, and loading the list whole the app's and
// its extension's (below); and a plugin that ships is in a platform or a product module.
//
// `+ shipped` after a line's dependencies makes it the product, or the tests of it: every module the
// list names links into it, whether or not it imports them. Only the app, its extension, and the
// tests of what ships and their support may say it. The app and its extension import none of those
// modules (and compile against none); the tests and their support import the ones they call. What
// depends on a library that says it says it too.
//
// So an edge between two platform modules goes from the module that owns a meaning to the one it
// builds on or shows itself on (Mentions imports Titles, whose names its pills show), and the graph
// having no cycle holds it that way: Titles imports Queries, so Queries can never import Titles. A
// face a plugin list should be able to leave out (Validation's Issues tab) is a plugin value of its own
// in its owner's module, and no module joins two others. An engine knows no meaning a horizontal
// owns: a word in a language is given by the module that owns its meaning, as a plugin value of its
// own, through the engine's points (Titles gives queries its names and `canvas draw` its titles,
// Boards queries its boards' names); when the owner sits below the engine, the engine's module gives
// it (Queries gives `:selected`, Selection being below it).
//
// build.sh refuses to build when:
//   - the graph has a cycle, or an edge the layers above forbid, or the wire or the command line
//     imports more than the four rules above let it;
//   - the list names something that isn't a public struct of that module that can be made with no
//     arguments (a ListedPlugin), names a plugin twice, or isn't in the form its comment says;
//   - the app or its extension imports a module the list names;
//   - a module that is neither private nor a test imports a private one, `private` is on a layer
//     but the core, or an executable on the core isn't private;
//   - a line says `of` where its layer doesn't allow it: any line but a test and a private
//     executable, a test of a module it doesn't depend on, an extension carried by anything but the
//     app itself (an extension needn't depend on the app);
//   - SwiftPM, evaluating this file, sees other targets or dependencies than the one-line table
//     (so code below the targets can't change the graph);
//   - a module's imports, as the compiler parses them, aren't exactly its dependencies here;
//   - an import sits inside #if or carries @_exported, @_implementationOnly or @testable, or code
//     asks canImport(<a module here>);
//   - a public type is named like a module, or Task or Span (either would shadow Swift's in every
//     importer);
//   - a product declares no ShapeKind;
//   - a module writes another module's ShapeKind, PluginID, ToolID, PropertyKey, ChannelID (a
//     Connections channel's) or EdgeTypeID (a Topology edge type's) as a string literal without
//     depending on that module;
//   - a part of a module (the table of parts, after what ships) names something of a part its line
//     doesn't say it uses.
// The graph keeps the core from naming a plugin's types (a module compiles against only its
// dependency closure, with MemberImportVisibility, and the import check rejects undeclared
// imports); the id check keeps any module from writing another module's kind, tool, plugin, property,
// channel or edge type id as a literal. The editor's host API is @_spi(Host), which only the window
// (CanvasUI), testsupport and test modules may import; loading the list whole, with the plugins that
// reach outside the process as the product has them, is @_spi(Product), which only the app and its
// extension may.
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
    // What connects to what (arrows, mentions), for the whole file. A service that reads its
    // index as it hears a commit finds it up to date wherever it sits: looking it up has the index
    // hear the commit first.
    "Topology.TopologyPlugin",
    // The kinds. Frames beside subboards, the two ways of grouping shapes (a region of this
    // board, a board of its own), after notes: the toolbar's Note, Subboard, Frame, Reference.
    "Arrows.ArrowsPlugin", "StickyNotes.StickyNotesPlugin", "Subboards.SubboardsPlugin", "Frames.FramesPlugin", "References.ReferencesPlugin",
    // After Validation: what's shown on shapes draws over its outline.
    "Validation.ValidationPlugin", "Adornments.AdornmentsPlugin", "DetailPanel.DetailPanelPlugin", "ContextMenus.ContextMenusPlugin",
    // Slash commands: the list at a `/` in the text views Mentions hosts it in, and the bar `/` opens under the
    // selection (after Keyboard and Selection, whose points it fills). Titles offers `/title`, Locking `/lock`.
    "SlashCommands.SlashCommandsPlugin", "SlashCommands.SlashBarPlugin",
    // The table of contents, in the window's sidebar.
    "TableOfContents.TableOfContentsPlugin",
    "Titles.TitlesPlugin",
    // After Titles, whose names its pills show, and the table of contents, whose rows it names.
    "Mentions.MentionsPlugin",
    // Mentions' text as the command bar's field, so its pills are shapes a command takes (after the bar and Mentions).
    "Mentions.MentionSlashBarPlugin",
    // Getting around a file's boards (a subboard's): opening one, ⌘↑, the path. Then the board shown's
    // name over the table of contents, with the way up.
    "Boards.BoardsPlugin", "Boards.BoardContentsPlugin",
    // Then each board's name over its rows in the lists that group shapes by board (Find's).
    "Boards.BoardHeadingsPlugin",
    // Finding text on the board shown and every board under it (⌘F, ⌘G): after Adornments, so a
    // hit's ring draws over a title's pill, and Topology, whose walk of the file orders the hits. Then
    // its panel in the detail panel's place while it's open.
    "Find.FindPlugin", "Find.FindPanelPlugin",
    // What Find searches, from the plugins that draw it, each after Find and its owner: titles,
    // mention text (a note's, a type's words, an arrow's label).
    "Titles.TitleFindPlugin", "Mentions.MentionFindPlugin",
    // Jump To (⌘K): goes to a shape by its title and where it is. After Titles, whose titles it
    // lists, and Boards, whose way of following a shape it takes.
    "JumpTo.JumpToPlugin",
    // Turning shapes into other kinds: a frame into a subboard, from its menu.
    "Transform.TransformPlugin",
    "Validation.ValidationDetailsPlugin", "Validation.IssueWalkPlugin", "Validation.IssueWalkPanelPlugin", "Validation.ValidationContentsPlugin", "Mentions.MentionValidationPlugin", "Boards.PathValidationPlugin",
    // Groups, selected as one: after Selection, whose point says what selects together, and before
    // Locking, so Group and Ungroup come before Lock in a shape's menu (Keynote's Arrange menu has
    // them together); and before the clipboard, whose copies form groups of their own.
    "Grouping.GroupingPlugin",
    "Clipboard.ClipboardPlugin",
    "Locking.LockingPlugin",
    // Public shapes, the ones another shape may stand for; its chip sits beside the lock's.
    "Publishing.PublishingPlugin",
    // Types: a note that holds a JSON Schema, its words and its schema kept in step by the model.
    // After Mentions, Titles and Validation, and after every plugin whose every-shape commands
    // a note lists before `/is-a` (Publishing's `/public` among them); its rules and its panel, and then the
    // first value the issue walk's list ends a row in.
    "Types.TypesPlugin", "Types.TypeValidationPlugin", "Types.TypeDetailsPlugin", "Types.IssueRowValuesPlugin",
    // What ⌘F finds in a note that is one: its values. After Find and Types, its two owners.
    "Types.FieldFindPlugin",
    // Colors: the color a shape of a kind that opted in holds, and the book that says what every
    // color looks like. After every plugin whose every-shape commands a note lists before `/color`
    // (Types' `/is-a` among them); then its warning and its row in the panel.
    "Colors.ColorsPlugin", "Colors.ColorValidationPlugin", "Colors.ColorDetailsPlugin",
    // A shape of a type takes the color its type was given, where it holds none of its own. After
    // Colors and Types, its two owners.
    "Types.TypeColorsPlugin",
    // What a drag moves snaps to the shapes in view: their edges, their middles and the spaces
    // between them.
    "Snapping.SnappingPlugin",
    // Ports, whose arrows `ArrowPortsPlugin` draws. After Adornments: a shape's dots draw
    // above its adornments (the lock chip among them), and are found before them.
    "Connections.PortsPlugin", "Connections.ConnectMenuPlugin", "Connections.ConnectPickerPlugin", "Arrows.ArrowPortsPlugin",
    "LanguageModels.LanguageModelsPlugin",
    // Yes-or-no questions asked of a decision model (TypeSafe's Jev): its key's pane goes under the language model's.
    "DecisionModels.DecisionModelsPlugin",
    // Rules in English on types, checked by the decision model: after Types, whose directive it holds, Validation,
    // whose rule its warnings are, and the decision model it asks. Its words are a text file of the product's
    // (Shipped/rule-prompt.txt).
    "LanguageRules.LanguageRulesPlugin", "LanguageRules.RuleValidationPlugin", "LanguageRules.RuleDetailsPlugin",
    // What words say of what's lower level, asked of the model: a type's highlights.
    "ProseMaps.ProseMapsPlugin",
    // The draw engine, then the command line's commands over it, and the words each plugin that
    // owns a meaning gives `canvas draw`, each after the engine, whose points they fill: titles for
    // names, ports' connections for edges, validity for its warnings, mentions for text
    // (`@[Title]` in a note's text names the shape called that), and groups for `group` and `ungroup`.
    "Draw.DrawPlugin", "Automation.AutomationPlugin", "Titles.TitleNamesPlugin", "Connections.PortEdgesPlugin", "Validation.ValidationChecksPlugin", "Mentions.MentionTextsPlugin", "Types.TypeNamesPlugin", "Types.FieldValuesPlugin", "Colors.ColorNamesPlugin", "Grouping.GroupDrawPlugin",
    // What a program drew, kept by name so its next pass finds its shapes by key and anyone can ask what changed since: the
    // records `canvas apply` and `canvas draw --drawing` write, through the draw engine's point, so after it.
    "Drawings.DrawingsPlugin",
    // Reading the file: `canvas query`, and the words each plugin that owns a meaning gives it:
    // titles for names, boards' names, mentions for text and relations, validity and the selection
    // for their words, each after Queries, whose points they fill. The translator of English into
    // queries reads its prompt from the product's own files (Shipped/ask-prompt.txt, in the
    // binary).
    "Queries.QueriesPlugin", "QueryTranslation.QueryTranslationPlugin", "Titles.TitleQueriesPlugin", "Boards.BoardQueriesPlugin", "Mentions.MentionQueriesPlugin", "Validation.ValidationQueriesPlugin", "Types.TypeQueriesPlugin", "Colors.ColorQueriesPlugin", "Grouping.GroupQueriesPlugin",
    "Queries.SelectionQueriesPlugin",
    // What reads drawings: `:drawn-by("NAME")` and `:changed`, after the engine and the drawings they read.
    "Drawings.DrawingQueriesPlugin",
    "QueryCommands.QueryCommandsPlugin",
    // `canvas decide`: one yes-or-no question of the shapes a query finds, each with its state as a rule sees it. After
    // the commands, the queries and the checks it builds on.
    "DecisionCommands.DecisionCommandsPlugin",
    // `/query`: a question typed in the command bar, and the shapes it finds selected. After the bar, whose point it
    // fills, and the translator it asks.
    "QueryTranslation.QuerySlashPlugin",
    // Hover a shape, on the canvas or by its row in the table of contents, and what it connects to is outlined by how: after the
    // query plugins, whose engine it asks, and Selection and the table of contents, whose hovers it follows. Then the lights,
    // from the plugins that own the edges, in the order a shape's rings go: arrows' (points to, pointed to by), then
    // mentions' (mentions, mentioned by), then types' (instances). Then the same ways as lists in a shape's panel, its Connections
    // tab, with what the shape is inside and what it holds: after the detail panel, whose tab it is.
    "Neighbors.NeighborsPlugin", "Arrows.ArrowLightsPlugin", "Mentions.MentionLightsPlugin", "Types.TypeLightsPlugin", "Neighbors.NeighborDetailsPlugin",
    // `/move-to` and `/move-near`: a shape moved into a frame, onto a subboard's board or beside a shape, on any board,
    // placed as `canvas draw` places one. After every plugin whose every-shape commands a note lists before them.
    "Moving.MovingPlugin",
    // The example (Examples/): one line here; delete it to leave it out.
    "Reordering.ReorderingPlugin",
    // Rows written as lines, any kind's: after Draw, Find, Connections, Selection and Titles, whose points and field its
    // sessions use, and before the kinds that opt in.
    "LineRows.LineRowsPlugin",
    // The engineering kit, off in a file until File ▸ Kits ▸ Engineering turns it on: database tables, their enums and the
    // databases that hold them. After Draw, whose writers it gives, Titles, whose field names a new table, and every
    // plugin whose every-shape commands its kinds list before its own.
    "Engineering.EngineeringPlugin",
    // What Find finds in the kit's rows, after Find and the kit.
    "Engineering.EngineeringFindPlugin",
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
// in step, and filling a note's fields from its words; what a shape is, shown and changed (the commands, `/is-a`, the menu, the chips, the
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
    "Types/Sync": ["JSON", "Type", "Fields"],
    "Types/IsA": ["JSON", "Type", "Fields", "Sync"],
    "Types/Form": ["JSON", "Type", "Fields", "Checks", "Sync", "IsA"],
    "Types/Rows": ["JSON", "Type", "Fields", "Checks", "Sync", "IsA", "Form"],
    "Types/Engines": ["JSON", "Type", "Fields", "Checks", "Sync", "IsA", "Form", "Rows"],
    // LineRows: the line a row is typed in and the grammar its lines are read and printed in; the kinds written as lines
    // and the lines a shape shows (folds, peeks); rows moved as wholes (within a shape, into another, out into a new one) and
    // on the pasteboard; the session of a shape being edited, its stops, keys and commits; a row's card.
    "LineRows/Field": [],
    "LineRows/Folds": [],
    "LineRows/Moves": ["Folds"],
    "LineRows/Session": ["Field", "Folds", "Moves"],
    "LineRows/Card": ["Field", "Folds", "Moves", "Session"],
    // Engineering: the kinds' props, looks' constants and how a row is drawn on the paper, and the file's tables and enums
    // by name; the line grammars a column, an enum's values and an API's rows and server are written in, read and printed
    // (pure); the table, the enum and the database, drawn, placed and written; the API, the same.
    "Engineering/Model": [],
    "Engineering/Grammar": ["Model"],
    "Engineering/Tables": ["Model", "Grammar"],
    "Engineering/APIs": ["Model", "Grammar"],
    // The readers of what's pasted, each put down by Draw as a draw program: SQL's tables and enums; YAML (a subset, into Types'
    // ordered values) and OpenAPI's API and types, grouped by the Grammar part's one rule.
    "Engineering/Readers": ["Model", "Grammar"],
]

let package = Package(
    name: "InfiniteCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        // CORE: the canvas and plain libraries.
        .target(name: "Geometry", dependencies: []),                                          // layer: core
        .target(name: "DrawScript", dependencies: ["FuzzyMatching", "Geometry"]),             // layer: core
        .target(name: "QueryLanguage", dependencies: []),                                     // layer: core
        .target(name: "TextEditing", dependencies: ["Chrome"]),                               // layer: core
        .target(name: "FuzzyMatching", dependencies: []),                                     // layer: core
        .target(name: "Palette", dependencies: []),                                           // layer: core
        .target(name: "Chrome", dependencies: ["Palette"]),                                   // layer: core
        .target(name: "Canvas", dependencies: ["CanvasRPC", "Geometry", "Palette"]),          // layer: core
        .target(name: "CanvasRPC", dependencies: []),                                         // layer: core
        // Private to the core: the window and the programs. No plugin may import them.
        .target(name: "CanvasUI", dependencies: ["Canvas", "CanvasRPC", "Chrome", "FuzzyMatching", "Geometry", "Palette"]), // layer: core private
        .executableTarget(name: "InfiniteCanvas", dependencies: ["Canvas", "CanvasUI"] + shipped),               // layer: core private
        .executableTarget(name: "CanvasQuickLook", dependencies: ["Canvas"] + shipped),                          // layer: core private of InfiniteCanvas
        .executableTarget(name: "CanvasCLI", dependencies: ["CanvasRPC"]),                                        // layer: core private

        // PLATFORM: what every shape gets, whatever its kind.
        // Horizontals, in the window: the interfaces verticals plug into that a shape shows up on.
        .target(name: "Keyboard", dependencies: ["Canvas"]),                                  // layer: platform
        .target(name: "Selection", dependencies: ["Canvas", "Geometry", "Keyboard", "Palette"]), // layer: platform
        .target(name: "DetailPanel", dependencies: ["Canvas", "Chrome", "FuzzyMatching", "Keyboard", "Selection", "TextEditing"]), // layer: platform
        .target(name: "ContextMenus", dependencies: ["Canvas", "Keyboard", "Selection"]),                 // layer: platform
        .target(name: "SlashCommands", dependencies: ["Canvas", "FuzzyMatching", "Geometry", "Keyboard", "Selection", "TextEditing"]), // layer: platform
        .target(name: "TableOfContents", dependencies: ["Canvas", "Chrome", "Selection", "TextEditing"]), // layer: platform
        .target(name: "Adornments", dependencies: ["Canvas", "Geometry", "Palette", "Selection"]),       // layer: platform
        .target(name: "Find", dependencies: ["Canvas", "Chrome", "DetailPanel", "FuzzyMatching", "Geometry", "Keyboard", "Selection", "Topology"]), // layer: platform
        // Horizontals, shape traits: the interfaces verticals plug into that a shape has.
        .target(name: "Topology", dependencies: ["Canvas"]),                                  // layer: platform
        .target(name: "Validation", dependencies: ["Canvas", "DetailPanel", "Draw", "Keyboard", "Palette", "Queries", "Selection", "TableOfContents", "Titles", "Topology"]), // layer: platform
        .target(name: "Titles", dependencies: ["Adornments", "Canvas", "DetailPanel", "Draw", "Find", "Palette", "Queries", "SlashCommands", "TableOfContents", "TextEditing"]),  // layer: platform
        .target(name: "Locking", dependencies: ["Adornments", "Canvas", "ContextMenus", "Keyboard", "SlashCommands", "TableOfContents"]), // layer: platform
        .target(name: "Grouping", dependencies: ["Canvas", "ContextMenus", "Draw", "Keyboard", "Queries", "Selection"]), // layer: platform
        .target(name: "Connections", dependencies: ["Canvas", "CanvasRPC", "ContextMenus", "Draw", "Geometry", "Keyboard", "Mentions", "Selection", "TextEditing", "Topology"]), // layer: platform
        .target(name: "Mentions", dependencies: ["Boards", "Canvas", "CanvasRPC", "Chrome", "ContextMenus", "DetailPanel", "Draw", "Find", "FuzzyMatching", "Keyboard", "Neighbors", "Queries", "Selection", "SlashCommands", "TableOfContents", "TextEditing", "Titles", "Topology", "Validation"]), // layer: platform
        .target(name: "Publishing", dependencies: ["Adornments", "Canvas", "ContextMenus", "DetailPanel", "Neighbors", "Selection", "SlashCommands", "TableOfContents", "Topology"]), // layer: platform
        .target(name: "Boards", dependencies: ["Canvas", "Chrome", "ContextMenus", "DetailPanel", "FuzzyMatching", "Keyboard", "Queries", "Selection", "TableOfContents", "TextEditing", "Titles", "Topology", "Validation"]), // layer: platform
        .target(name: "Transform", dependencies: ["Canvas", "ContextMenus", "SlashCommands"]), // layer: platform
        .target(name: "Colors", dependencies: ["Canvas", "CanvasRPC", "ContextMenus", "DetailPanel", "Draw", "Palette", "Queries", "SlashCommands", "TextEditing", "Validation"]), // layer: platform
        .target(name: "Types", dependencies: ["Adornments", "Canvas", "CanvasRPC", "Colors", "ContextMenus", "DetailPanel", "Draw", "Find", "LanguageModels", "Mentions", "Neighbors", "Palette", "ProseMaps", "Queries", "Selection", "SlashCommands", "TextEditing", "Titles", "Topology", "Validation"]), // layer: platform
        // References: a pill that stands for any public shape, of a kind written after it too: what every shape gets, though it is a kind.
        .target(name: "References", dependencies: ["Boards", "Canvas", "CanvasRPC", "Chrome", "Colors", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "LanguageModels", "Mentions", "Palette", "Publishing", "Queries", "QueryLanguage", "QueryTranslation", "Selection", "TableOfContents", "TextEditing", "Topology", "Validation"]), // layer: platform
        // Things you do: a palette, a command, a gesture, that no kind opts into and nothing builds on (but Clipboard, whose paste readers a plugin may import it for).
        .target(name: "Clipboard", dependencies: ["Canvas", "ContextMenus", "Draw", "Geometry", "Grouping", "Keyboard", "LineRows", "Selection"]), // layer: platform
        .target(name: "Snapping", dependencies: ["Canvas", "Geometry"]),                      // layer: platform
        // Jump To (⌘K): it lists
        // the titled shapes Titles names (each tinted as its kind is, the core's `registry.label(of:)`), goes to one as Boards' crumbs do (Boards'
        // `follow`), and shows its list in TextEditing's caret list, its palette over the canvas in one of the host's slots.
        .target(name: "JumpTo", dependencies: ["Boards", "Canvas", "Chrome", "FuzzyMatching", "Geometry", "Keyboard", "TextEditing", "Titles", "Topology"]), // layer: platform
        // Moving (`/move-to`, `/move-near`): two slash
        // commands that move a shape into a frame, onto a subboard's board or beside a shape, placed as `canvas draw` places one (Draw's
        // placement for plugins, `Surroundings`),
        // and the table of contents' drops that move shapes into a frame, onto a subboard's board or out of frames (`ContentsMoves`);
        // each then goes where the shapes went, through Selection's going to shapes, one step back to where it began. A move keeps the
        // arrows that would cross boards through reference pills (Draw's `CrossingArrows`; Mentions names the pill).
        .target(name: "Moving", dependencies: ["Boards", "Canvas", "ContextMenus", "Draw", "Mentions", "Selection", "SlashCommands", "TableOfContents"]), // layer: platform
        // Rows written as lines (LineRows): a kind's rows typed a line each, one field moved to the row with the caret, a
        // grammar a role read and printed (TextEditing's caret list offering what fits, ranked by FuzzyMatching), each row
        // committed as the caret leaves it, one step the kind names; Titles' field for the title stop, Selection for Tab's
        // hops to the next shape of the kind; Connections for ⌘L in a row (its key, and the picker it opens on the row, which
        // imports no LineRows); Keyboard for ⌃⌘↑ and ⌃⌘↓, which fold and unfold, and Find for the rows a fold shows while they
        // hold its hits; Selection's items for rows selected on the canvas, ContextMenus for the take-out in the selection's
        // menu, and Topology for the arrows a row starts, which a copy of it carries. Its parts: Field, the line and its
        // grammar; Folds, the lines a shape shows; Moves, rows moved as wholes and on the pasteboard; Session, the stops, keys
        // and commits; Card, a row's card.
        .target(name: "LineRows", dependencies: ["Canvas", "Connections", "ContextMenus", "Find", "FuzzyMatching", "Keyboard", "Selection", "TextEditing", "Titles", "Topology"]), // layer: platform
        // Examples: the smallest plugin for each pattern (see docs/plugin-system.md).
        .target(name: "Reordering", dependencies: ["Canvas", "ContextMenus", "Keyboard", "SlashCommands"], path: "Examples/Reordering"), // layer: platform
        // Engines: what any plugin may run or ask.
        .target(name: "LanguageModels", dependencies: ["Canvas"]),                            // layer: platform
        .target(name: "DecisionModels", dependencies: ["Canvas", "CanvasRPC", "LanguageModels"]), // layer: platform
        .target(name: "LanguageRules", dependencies: ["Adornments", "Canvas", "CanvasRPC", "ContextMenus", "DecisionModels", "DetailPanel", "Mentions", "Palette", "Queries", "QueryLanguage", "QueryTranslation", "Selection", "TextEditing", "Titles", "Topology", "Types", "Validation"]), // layer: platform
        .target(name: "ProseMaps", dependencies: ["Canvas", "LanguageModels"]),               // layer: platform
        .target(name: "Queries", dependencies: ["Canvas", "CanvasRPC", "FuzzyMatching", "QueryLanguage", "Selection", "Topology"]), // layer: platform
        .target(name: "Draw", dependencies: ["Adornments", "Canvas", "CanvasRPC", "DrawScript", "FuzzyMatching", "Geometry", "Queries", "QueryLanguage", "Topology"]), // layer: platform
        .target(name: "Drawings", dependencies: ["Canvas", "CanvasRPC", "Draw", "Queries"]),                          // layer: platform
        .target(name: "QueryTranslation", dependencies: ["Canvas", "DetailPanel", "LanguageModels", "Queries", "QueryLanguage", "Selection", "SlashCommands"]), // layer: platform
        // Neighbors: an engine an edge's owner shows its edges on. Hovering a shape, on the canvas or by its row in the table of contents
        // (Selection's `hovered`, and `hoveredElsewhere` for a row of another board), outlines every shape connected to it in a color for each
        // way, through the core's tinted outlines, and a shape's panel lists them by the same ways, then what it's inside and what it holds
        // (a tab of the detail panel's, its lists searched with FuzzyMatching's matcher, a shape with no title called what the table of
        // contents calls it). What counts as connected is a light, a title, a color
        // and a query, which the plugin that owns the edges contributes (Arrows' arrows, Mentions' mentions) and Queries answers; the file
        // says where a shape on another board is drawn, and Topology when the edges change.
        .target(name: "Neighbors", dependencies: ["Canvas", "Chrome", "DetailPanel", "FuzzyMatching", "Palette", "Queries", "Selection", "TableOfContents", "Topology"]), // layer: platform
        // For agents: where an agent's request arrives over the wire and is answered.
        .target(name: "Automation", dependencies: ["Canvas", "CanvasRPC", "Draw", "DrawScript", "QueryLanguage"]), // layer: platform
        .target(name: "QueryCommands", dependencies: ["Automation", "Canvas", "CanvasRPC", "LanguageModels", "Queries", "QueryLanguage", "QueryTranslation"]), // layer: platform
        .target(name: "DecisionCommands", dependencies: ["Automation", "Canvas", "CanvasRPC", "DecisionModels", "LanguageRules", "Queries", "QueryLanguage"]), // layer: platform

        // PRODUCT: the verticals, shapes that hold something of their own.
        // Arrows: tldraw's arc arrows, a kind like any other, and the connector that makes them what ports draw.
        .target(name: "Arrows", dependencies: ["Adornments", "Canvas", "CanvasRPC", "Colors", "Connections", "ContextMenus", "Geometry", "LanguageRules", "Mentions", "Neighbors", "Palette", "Publishing", "Selection", "TableOfContents", "TextEditing", "Topology", "Types"]), // layer: product
        .target(name: "StickyNotes", dependencies: ["Canvas", "Clipboard", "Colors", "Connections", "DetailPanel", "Draw", "Keyboard", "LanguageRules", "Mentions", "Palette", "Selection", "SlashCommands", "TableOfContents", "TextEditing", "Titles", "Types"]), // layer: product
        .target(name: "Subboards", dependencies: ["Boards", "Canvas", "Colors", "Connections", "DetailPanel", "Keyboard", "Mentions", "Palette", "TableOfContents", "Titles", "Transform", "Types"]), // layer: product
        .target(name: "Frames", dependencies: ["Canvas", "Colors", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "Mentions", "Palette", "Selection", "TableOfContents", "Titles", "Transform", "Types"]), // layer: product
        .target(name: "Engineering", dependencies: ["Adornments", "Canvas", "CanvasRPC", "Clipboard", "Connections", "ContextMenus", "DetailPanel", "Draw", "Find", "Geometry", "LineRows", "Mentions", "Palette", "Selection", "SlashCommands", "TableOfContents", "TextEditing", "Titles", "Topology", "Transform", "Types"]), // layer: product

        .target(name: "TestKit", dependencies: [], path: "Tests/TestKit"),                                        // layer: testsupport
        .target(name: "CanvasTesting", dependencies: ["Canvas", "CanvasRPC", "Geometry", "TestKit"], path: "Tests/CanvasTesting"), // layer: testsupport
        // The tests' way to the product's plugins: the list, with a pasteboard and a model of the test's own.
        .target(name: "ShippedTesting", dependencies: ["Canvas", "CanvasTesting", "TestKit"] + shipped, path: "Tests/ShippedTesting"), // layer: testsupport
        // What the tests of the skills' tools share (canvas-digest, canvas-ingest): scratch git repositories, `ingest` and the lens
        // runner as an agent runs them. It imports no plugin, so SkillToolsTests, which needs no app, is rerun by no edit to one.
        .target(name: "SkillTesting", dependencies: ["CanvasRPC", "TestKit"], path: "Tests/SkillTesting"), // layer: testsupport
        .executableTarget(name: "CanvasTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "Geometry", "TestKit"], path: "Tests/CanvasTests"), // layer: test
        .executableTarget(name: "CanvasRPCTests", dependencies: ["CanvasRPC", "TestKit"], path: "Tests/CanvasRPCTests"), // layer: test
        .executableTarget(name: "DrawScriptTests", dependencies: ["DrawScript", "Geometry", "TestKit"], path: "Tests/DrawScriptTests"), // layer: test
        .executableTarget(name: "QueryLanguageTests", dependencies: ["QueryLanguage", "TestKit"], path: "Tests/QueryLanguageTests"), // layer: test
        .executableTarget(name: "CanvasCLITests", dependencies: ["CanvasRPC", "TestKit"], path: "Tests/CanvasCLITests"), // layer: test
        .executableTarget(name: "KeyboardTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "Keyboard", "TestKit"], path: "Tests/KeyboardTests"), // layer: test
        .executableTarget(name: "CanvasUITests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "Chrome", "Geometry", "TestKit"], path: "Tests/CanvasUITests"), // layer: test
        .executableTarget(name: "SelectionTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "Geometry", "Keyboard", "Selection", "TestKit"], path: "Tests/SelectionTests"), // layer: test
        .executableTarget(name: "ArrowsTests", dependencies: ["Adornments", "Arrows", "Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Colors", "Connections", "ContextMenus", "DetailPanel", "Find", "Geometry", "Keyboard", "LanguageRules", "Mentions", "Palette", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Types"], path: "Tests/ArrowsTests"), // layer: test
        .executableTarget(name: "ValidationTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "DetailPanel", "Geometry", "Keyboard", "Palette", "Queries", "Selection", "TableOfContents", "TestKit", "Topology", "Validation"], path: "Tests/ValidationTests"), // layer: test
        .executableTarget(name: "DetailPanelTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "Chrome", "DetailPanel", "Keyboard", "Selection", "TestKit", "TextEditing"], path: "Tests/DetailPanelTests"), // layer: test
        .executableTarget(name: "TextEditingTests", dependencies: ["CanvasTesting", "Chrome", "TestKit", "TextEditing"], path: "Tests/TextEditingTests"), // layer: test
        .executableTarget(name: "FuzzyMatchingTests", dependencies: ["FuzzyMatching", "TestKit"], path: "Tests/FuzzyMatchingTests"), // layer: test
        .executableTarget(name: "PaletteTests", dependencies: ["Palette", "TestKit"], path: "Tests/PaletteTests"), // layer: test
        .executableTarget(name: "ChromeTests", dependencies: ["Chrome", "TestKit"], path: "Tests/ChromeTests"), // layer: test
        .executableTarget(name: "ColorsTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Colors", "ContextMenus", "DetailPanel", "Draw", "Geometry", "Keyboard", "Palette", "Queries", "QueryLanguage", "Selection", "SlashCommands", "TestKit", "TextEditing", "Topology", "Validation"], path: "Tests/ColorsTests"), // layer: test
        .executableTarget(name: "ContextMenusTests", dependencies: ["Canvas", "CanvasTesting", "ContextMenus", "Keyboard", "Selection", "TestKit"], path: "Tests/ContextMenusTests"), // layer: test
        .executableTarget(name: "SlashCommandsTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "Geometry", "Keyboard", "Selection", "SlashCommands", "TestKit", "TextEditing"], path: "Tests/SlashCommandsTests"), // layer: test
        .executableTarget(name: "TableOfContentsTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "Chrome", "Geometry", "Keyboard", "Selection", "TableOfContents", "TestKit"], path: "Tests/TableOfContentsTests"), // layer: test
        .executableTarget(name: "AdornmentsTests", dependencies: ["Adornments", "Canvas", "CanvasTesting", "Geometry", "Keyboard", "Palette", "Selection", "TestKit"], path: "Tests/AdornmentsTests"), // layer: test
        .executableTarget(name: "ClipboardTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "Clipboard", "ContextMenus", "Draw", "Geometry", "Grouping", "Keyboard", "LineRows", "Selection", "TestKit"], path: "Tests/ClipboardTests"), // layer: test
        .executableTarget(name: "StickyNotesTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Clipboard", "Colors", "Connections", "ContextMenus", "DetailPanel", "Draw", "Geometry", "Keyboard", "LanguageModels", "LanguageRules", "Mentions", "Palette", "ProseMaps", "Selection", "SlashCommands", "StickyNotes", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Types"], path: "Tests/StickyNotesTests"), // layer: test
        .executableTarget(name: "GroupingTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "ContextMenus", "Draw", "Grouping", "Keyboard", "Queries", "QueryLanguage", "Selection", "TestKit", "Topology"], path: "Tests/GroupingTests"), // layer: test
        .executableTarget(name: "LockingTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "ContextMenus", "Geometry", "Keyboard", "Locking", "Selection", "SlashCommands", "TableOfContents", "TestKit"], path: "Tests/LockingTests"), // layer: test
        .executableTarget(name: "PublishingTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "Neighbors", "Publishing", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Topology"], path: "Tests/PublishingTests"), // layer: test
        .executableTarget(name: "TypesTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Colors", "ContextMenus", "DetailPanel", "Draw", "Find", "Geometry", "Keyboard", "LanguageModels", "Mentions", "Neighbors", "Palette", "ProseMaps", "Queries", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Types", "Validation"], path: "Tests/TypesTests"), // layer: test
        .executableTarget(name: "LanguageModelsTests", dependencies: ["Canvas", "CanvasTesting", "LanguageModels", "TestKit"], path: "Tests/LanguageModelsTests"), // layer: test
        .executableTarget(name: "DecisionModelsTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "DecisionModels", "LanguageModels", "TestKit"], path: "Tests/DecisionModelsTests"), // layer: test
        .executableTarget(name: "LanguageRulesTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "ContextMenus", "DecisionModels", "DetailPanel", "Geometry", "Keyboard", "LanguageModels", "LanguageRules", "Mentions", "ProseMaps", "Queries", "QueryTranslation", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Types", "Validation"], path: "Tests/LanguageRulesTests"), // layer: test
        .executableTarget(name: "ProseMapsTests", dependencies: ["Canvas", "CanvasTesting", "LanguageModels", "ProseMaps", "TestKit"], path: "Tests/ProseMapsTests"), // layer: test
        .executableTarget(name: "LineRowsTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "ContextMenus", "Find", "Geometry", "Keyboard", "LineRows", "Selection", "TestKit", "TextEditing"], path: "Tests/LineRowsTests"), // layer: test
        .executableTarget(name: "TitlesTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "DetailPanel", "Find", "Geometry", "Keyboard", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles"], path: "Tests/TitlesTests"), // layer: test
        .executableTarget(name: "PortsTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "Connections", "Geometry", "Keyboard", "Selection", "TestKit", "Topology"], path: "Tests/PortsTests"), // layer: test of Connections
        .executableTarget(name: "ArrowPortsTests", dependencies: ["Adornments", "Arrows", "Canvas", "CanvasTesting", "Colors", "Connections", "ContextMenus", "DetailPanel", "Draw", "Geometry", "Keyboard", "LanguageRules", "Mentions", "Neighbors", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Types"], path: "Tests/ArrowPortsTests"), // layer: test of Arrows
        .executableTarget(name: "MentionsTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Chrome", "ContextMenus", "DetailPanel", "Find", "Geometry", "Keyboard", "Mentions", "Neighbors", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Validation"], path: "Tests/MentionsTests"), // layer: test
        .executableTarget(name: "BoardsTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Keyboard", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Validation"], path: "Tests/BoardsTests"), // layer: test
        .executableTarget(name: "SubboardsTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Colors", "Connections", "ContextMenus", "DetailPanel", "Keyboard", "Mentions", "Palette", "Selection", "SlashCommands", "Subboards", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Transform", "Types"], path: "Tests/SubboardsTests"), // layer: test
        .executableTarget(name: "FramesTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "Colors", "Connections", "ContextMenus", "DetailPanel", "Frames", "Geometry", "Keyboard", "Mentions", "Palette", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Transform", "Types"], path: "Tests/FramesTests"), // layer: test
        .executableTarget(name: "JumpToTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "CanvasUI", "Chrome", "ContextMenus", "DetailPanel", "Geometry", "JumpTo", "Keyboard", "Selection", "SlashCommands", "TestKit", "TextEditing", "Titles", "Topology"], path: "Tests/JumpToTests"), // layer: test
        .executableTarget(name: "ReferencesTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "Chrome", "Colors", "Connections", "ContextMenus", "DetailPanel", "Geometry", "Keyboard", "LanguageModels", "Mentions", "Palette", "Publishing", "Queries", "QueryTranslation", "References", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Validation"], path: "Tests/ReferencesTests"), // layer: test
        .executableTarget(name: "PlacingTests", dependencies: ["Canvas", "CanvasTesting", "Draw", "TestKit"], path: "Tests/PlacingTests"), // layer: test of Draw
        .executableTarget(name: "MovingTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "ContextMenus", "Draw", "DrawScript", "Geometry", "Keyboard", "Moving", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology"], path: "Tests/MovingTests"), // layer: test
        .executableTarget(name: "NeighborsTests", dependencies: ["Canvas", "CanvasTesting", "Chrome", "DetailPanel", "Keyboard", "Neighbors", "Queries", "Selection", "TableOfContents", "TestKit", "Topology"], path: "Tests/NeighborsTests"), // layer: test
        .executableTarget(name: "SnappingTests", dependencies: ["Canvas", "CanvasTesting", "Geometry", "Snapping", "TestKit"], path: "Tests/SnappingTests"), // layer: test
        .executableTarget(name: "TransformTests", dependencies: ["Canvas", "CanvasTesting", "ContextMenus", "Keyboard", "Selection", "SlashCommands", "TestKit", "Transform"], path: "Tests/TransformTests"), // layer: test
        .executableTarget(name: "FindTests", dependencies: ["Canvas", "CanvasTesting", "CanvasUI", "DetailPanel", "Find", "Geometry", "Keyboard", "Selection", "TestKit", "Topology"], path: "Tests/FindTests"), // layer: test
        .executableTarget(name: "TopologyTests", dependencies: ["Canvas", "CanvasTesting", "TestKit", "Topology"], path: "Tests/TopologyTests"), // layer: test
        .executableTarget(name: "QueriesTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "Queries", "QueryLanguage", "TestKit", "Topology"], path: "Tests/QueriesTests"), // layer: test
        .executableTarget(name: "TypeQueriesTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "ContextMenus", "DetailPanel", "Keyboard", "LanguageModels", "Mentions", "ProseMaps", "Queries", "QueryLanguage", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Types", "Validation"], path: "Tests/TypeQueriesTests"), // layer: test of Types
        .executableTarget(name: "TitleQueriesTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "Keyboard", "Queries", "QueryLanguage", "Selection", "SlashCommands", "TestKit", "Titles", "Topology"], path: "Tests/TitleQueriesTests"), // layer: test of Titles
        .executableTarget(name: "BoardQueriesTests", dependencies: ["Adornments", "Boards", "Canvas", "CanvasTesting", "ContextMenus", "DetailPanel", "Keyboard", "Queries", "Selection", "SlashCommands", "TestKit", "Titles", "Topology"], path: "Tests/BoardQueriesTests"), // layer: test of Boards
        .executableTarget(name: "MentionQueriesTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "ContextMenus", "DetailPanel", "Keyboard", "Mentions", "Queries", "QueryLanguage", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology"], path: "Tests/MentionQueriesTests"), // layer: test of Mentions
        .executableTarget(name: "ValidationQueriesTests", dependencies: ["Canvas", "CanvasTesting", "Queries", "QueryLanguage", "TestKit", "Topology", "Validation"], path: "Tests/ValidationQueriesTests"), // layer: test of Validation
        .executableTarget(name: "SelectionQueriesTests", dependencies: ["Canvas", "CanvasTesting", "Keyboard", "Queries", "QueryLanguage", "Selection", "TestKit", "Topology"], path: "Tests/SelectionQueriesTests"), // layer: test of Queries
        .executableTarget(name: "QueryTranslationTests", dependencies: ["Canvas", "CanvasTesting", "Keyboard", "LanguageModels", "Queries", "QueryLanguage", "QueryTranslation", "Selection", "SlashCommands", "TestKit", "Topology"], path: "Tests/QueryTranslationTests"), // layer: test
        .executableTarget(name: "QueryCommandsTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "LanguageModels", "Queries", "QueryCommands", "QueryLanguage", "QueryTranslation", "TestKit", "Topology"], path: "Tests/QueryCommandsTests"), // layer: test
        .executableTarget(name: "AutomationTests", dependencies: ["Automation", "Canvas", "CanvasRPC", "CanvasTesting", "Draw", "DrawScript", "Geometry", "Queries", "TestKit", "Topology"], path: "Tests/AutomationTests"), // layer: test
        .executableTarget(name: "TitleNamesTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "Draw", "Keyboard", "Selection", "SlashCommands", "TestKit", "Titles"], path: "Tests/TitleNamesTests"), // layer: test of Titles
        .executableTarget(name: "TypeNamesTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "ContextMenus", "DetailPanel", "Draw", "Keyboard", "LanguageModels", "Mentions", "ProseMaps", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Types", "Validation"], path: "Tests/TypeNamesTests"), // layer: test of Types
        .executableTarget(name: "PortEdgesTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "Connections", "Draw", "Keyboard", "Selection", "TestKit", "Topology"], path: "Tests/PortEdgesTests"), // layer: test of Connections
        .executableTarget(name: "MentionTextsTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "ContextMenus", "DetailPanel", "Draw", "Keyboard", "Mentions", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Validation"], path: "Tests/MentionTextsTests"), // layer: test of Mentions
        .executableTarget(name: "ValidationChecksTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "Draw", "TestKit", "Validation"], path: "Tests/ValidationChecksTests"), // layer: test of Validation
        .executableTarget(name: "EngineeringTests", dependencies: ["Adornments", "Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Clipboard", "Connections", "ContextMenus", "DetailPanel", "Draw", "Engineering", "Find", "Geometry", "Keyboard", "LineRows", "Mentions", "Palette", "Selection", "SlashCommands", "TableOfContents", "TestKit", "TextEditing", "Titles", "Topology", "Transform", "Types"], path: "Tests/EngineeringTests"), // layer: test
        .executableTarget(name: "ExamplesTests", dependencies: ["Adornments", "Arrows", "Canvas", "CanvasTesting", "Colors", "ContextMenus", "Keyboard", "LanguageRules", "Mentions", "Reordering", "Selection", "SlashCommands", "TableOfContents", "TestKit", "Titles", "Topology", "Types"], path: "Tests/ExamplesTests"), // layer: test
        // The skills' tools where no app is needed: the canvas-digest tool's unit tests under jsc and the canvas-ingest tests that start no app.
        .executableTarget(name: "SkillToolsTests", dependencies: ["CanvasRPC", "SkillTesting", "TestKit"], path: "Tests/SkillToolsTests"), // layer: test
        .executableTarget(name: "CompositionTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Chrome", "DrawScript", "Geometry", "Palette", "QueryLanguage", "ShippedTesting", "SkillTesting", "TestKit", "TextEditing"] + shipped, path: "Tests/CompositionTests"), // layer: test
        .executableTarget(name: "BenchmarkTests", dependencies: ["Canvas", "CanvasRPC", "CanvasTesting", "CanvasUI", "Geometry", "QueryLanguage", "ShippedTesting", "TestKit"] + shipped, path: "Tests/BenchmarkTests"), // layer: test
    ],
    swiftLanguageModes: [.v6]
)

// build.sh passes the same to swiftc: without it, members of modules a file doesn't import leak
// into scope and the import audit would miss real dependencies.
for target in package.targets {
    target.swiftSettings = [.enableUpcomingFeature("MemberImportVisibility")]
}
