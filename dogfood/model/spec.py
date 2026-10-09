# What the code doesn't say about Infinite Canvas: the root's layer bands, each module's purpose, Canvas's folder
# boards, and how files group into frames. A group is (title, [files], [subgroups]); a file is its path inside the
# board's module (on a folder's board, inside the folder). A board with no groups lays its files out flat. Whatever
# a spec leaves out is worked out from the model (defaults.py).

BANDS = [
    ("Executables", ["InfiniteCanvas", "CanvasQuickLook", "CanvasCLI"]),
    ("Composition layer", ["Composition"]),
    ("UI layer", ["CanvasUI"]),
    ("Vertical layer", ["StickyNotes", "Subboards", "Frames", "JumpTo", "References", "Moving", "Neighbors", "Reordering"]),
    ("Lexicon layer", ["QueryLexicon", "DrawLexicon"]),
    ("Language layer", ["Automation", "QueryCommands"]),
    ("Concern layer", ["Validation", "Clipboard", "Titles", "Locking", "Connections", "Mentions", "Publishing", "Boards", "Snapping", "Transform", "Types"]),
    ("Surface layer", ["Keyboard", "Selection", "DetailPanel", "ContextMenus", "SlashCommands", "TableOfContents", "Adornments", "LanguageModels", "ProseMaps", "Topology", "Find", "Queries", "QueryTranslation"]),
    ("Wire layer", ["CanvasRPC"]),
    ("Foundation layer", ["Geometry", "Canvas", "DrawScript", "QueryLanguage", "TextEditing", "FuzzyMatching"]),
]

PURPOSES = {
    "Geometry": "Pure geometry: the camera's mapping between world and view, arcs, and point and rect helpers.",
    "Canvas": "The core: shapes, boards and files as values, the editor, plugins and their frozen registry, undo, drawing, and boards on disk. It knows no particular shape; its one tool is the hand.",
    "DrawScript": "The canvas draw language, pure: reading a script and the solver that places its shapes. It knows no canvas.",
    "QueryLanguage": "The canvas query language, pure: CSS-like selectors read and printed, its words, and its refusals. It knows no canvas.",
    "TextEditing": "EditingTextView and the one caret list, under every editable text in the app; spelling.",
    "FuzzyMatching": "FuzzyMatcher, which every list ranks typed text with; TextSearch, Find's, over folded texts; PathMatcher, Jump To's, over containment paths.",
    "CanvasRPC": "The wire: what the app and canvas say to each other, JSON-RPC on a Unix-domain socket. It knows no canvas, plugin or AppKit.",
    "CanvasUI": "The AppKit and SwiftUI shell around the core: board documents and windows, the canvas view, the minimap, the menus, Quick Look's picture, and the app's end of the command line.",
    "Keyboard": "Shortcuts and chords, how a key reaches the canvas, and the menu bar's items.",
    "Selection": "The select tool, handles and resizing, opening, Back, canvas buttons, going to shapes, faces, and the shake a refused change gives.",
    "ContextMenus": "Context menus: a shape's items, the canvas's items, right-clicks and Control-clicks.",
    "DetailPanel": "The detail panel: sections, tabs, status lines, headers, bindings, text boxes, and the code editor with its completions.",
    "SlashCommands": "Commands typed on a line of a shape's text.",
    "TableOfContents": "The table of contents: rows, marks, nesting, what's listed, hover, dragging rows, another board's outline.",
    "Adornments": "Pills and chips on shapes: placing them, their places, drawing and pointing.",
    "LanguageModels": "The language model plugins ask, the Anthropic key and Settings, and the model --ask uses.",
    "ProseMaps": "Prose maps: which words of a text say which part of a lower-level text.",
    "Topology": "Edges and edge types, stand-ins, provided answers, the one delivery of every change (follow), containment as one tree, and snapshots for other threads.",
    "Find": "⌘F: the FindableTexts point and its contributors, the index, the search off the main actor, the highlights and the panel.",
    "Queries": "The query engine: what a query sees, its plans and budgets, and running them off the main actor.",
    "QueryTranslation": "English to a query, by the language model: --ask, and a reference's words.",
    "Validation": "Rules and issues, the schema rule, what each commit re-checks, rings, and where issues show.",
    "Clipboard": "Cut, copy and paste; boards and containers copied whole; cut and paste as a move.",
    "Titles": "Named and derived titles, the pill, the cover zoomed out, TitleHeader, /title, shared titles.",
    "Locking": "Locked shapes, read-only, the chip, /lock.",
    "Connections": "Ports, channels and the connector; tldraw's arc arrows, their labels and binding rules.",
    "Mentions": "Mentions in text: pills, the @ picker, mention edges, Mentioned In, and mentions' warnings.",
    "Publishing": "Public shapes, what another shape may stand for: the two dials, the chip and its count, refusing while held, /public, Referenced In.",
    "Boards": "Opening boards, Enclosing Board, the path's crumbs and their menus.",
    "Snapping": "What a drag snaps to, and its guides.",
    "Types": "A shape that holds a JSON Schema is a type, named by its title: its words and its schema kept in step by the model; references, the Schema tab's JSON and completions, highlights.",
    "Transform": "Turning a shape into another kind through channels: sources and targets, the menu item and the command, frame into subboard.",
    "Automation": "The app's command-line commands: canvas draw (resolving, placing and committing a script), show, and the JSON bridge.",
    "QueryCommands": "canvas query and --ask: a query, or a question in English, from the command line.",
    "QueryLexicon": "The query language's words for the app's concerns: titles, boards, mentions, validation, the selection.",
    "DrawLexicon": "The draw language's words for the app's concerns: titles, connections, mentions, validation.",
    "StickyNotes": "The sticky note kind.",
    "Subboards": "A card that owns a board.",
    "Frames": "A region that holds shapes, and the Frame tool.",
    "JumpTo": "⌘K: a palette that goes to a shape by its title and where it is.",
    "References": "A pill that stands for a public shape: its props and writers, its look in every state, what it stands for, going to the original, its row and panel.",
    "Moving": "/move-to and /move-near: a shape moved into a frame, onto a subboard's board or beside a shape, on any board, placed as canvas draw places one.",
    "Neighbors": "Hovering a shape, on the canvas or by its row in the table of contents, outlines what's connected to it in a color for each way.",
    "Reordering": "The smallest plugin example (Examples/): restacking shapes from the context menu.",
    "Composition": "The shipped plugin list: every plugin, in order, and what joins them.",
    "InfiniteCanvas": "The app: its main and the document controller.",
    "CanvasQuickLook": "The Quick Look extension: a board file's preview and thumbnail in the Finder.",
    "CanvasCLI": "canvas, the command line. It knows only the wire, never the app.",
}

# Canvas's folders, as subboards of Canvas's board.
FOLDER_BOARDS = {"Canvas": ["Model", "Editor", "Shapes", "Plugins", "Tools", "Rendering", "Schema", "Persistence"]}
FOLDER_PURPOSES = {
    "Canvas/Model": "Shapes, boards and files as values: records, ids, stacking keys, added properties; transactions, change sets and deltas; containment and settling.",
    "Canvas/Editor": "CanvasEditor: document, camera, tools, sessions and input; services; boards shown and read; undo; the per-frame index.",
    "Canvas/Shapes": "ShapeDefinition, how a kind looks and behaves, and the capabilities a kind conforms to.",
    "Canvas/Plugins": "Plugin values, extension points, the core's own points, the property table, and the registry built from them and frozen.",
    "Canvas/Tools": "Tool and Session, the hand, placing a shape, and dragging shapes.",
    "Canvas/Rendering": "Drawing a frame: the canvas, overlays, outlines, the dot grid; zoomed out, silhouettes, greeked text and board previews.",
    "Canvas/Schema": "JSON Schemas: property lists (SchemaDefined), each kind's schema, the validator and the encoder.",
    "Canvas/Persistence": "Boards on disk: the codec, JSON values, the props of shapes kept aside, and migrations.",
}

# How Package.swift's layer tags read in an About note ("Canvas: foundation layer").
LAYER_NAMES = {'ui': 'UI', 'appex': 'app extension', 'cli': 'command line'}

GROUPS = {
    "Canvas/Model": [
        ("Shapes and their ids", ["Identity.swift", "ShapeRecord.swift", "ShapeMeta.swift", "StackingKey.swift", "AddedProperty.swift", "ShapeNaming.swift"], []),
        ("Documents and boards", ["CanvasDocument.swift", "CanvasFile.swift", "BoardID.swift"], [
            ("Containers", ["Containment.swift", "Enclosing.swift", "Settling.swift"], []),
        ]),
        ("Changing a document", ["Transaction.swift", "ChangeSet.swift", "DocumentDelta.swift"], []),
    ],
    "Canvas/Editor": [
        ("The editor", ["EditorService.swift", "UndoHistory.swift"], [
            ("CanvasEditor, in four files", ["CanvasEditor.swift", "CanvasEditor+Camera.swift", "CanvasEditor+Host.swift", "CanvasEditor+Undo.swift"], []),
        ]),
        ("Boards and the index", ["BoardReading.swift", "BoardSwitching.swift", "ShapeIndex.swift"], []),
        ("Input and motion", ["Input.swift", "EdgeScrolling.swift", "Glide.swift", "Scheduler.swift"], []),
        ("Popovers and text", ["Popovers.swift", "ReadsAsText.swift"], []),
    ],
    "Canvas/Rendering": [
        ("Drawing a frame", ["CanvasEditor+Drawing.swift", "Overlay.swift", "OutlineStandoff.swift", "TintedRings.swift", "DotGrid.swift", "ShapeShadows.swift"], []),
        ("Zoomed out", ["Silhouettes.swift", "BoardPreviews.swift"], [
            ("Greeked text", ["SkeletonText.swift", "SkeletonTextBars.swift"], []),
        ]),
    ],
    "Canvas/Schema": [
        ("JSON Schema", ["JSONSchema.swift", "SchemaValidator.swift", "JSONValueEncoder.swift"], []),
        ("Kinds' properties", ["SchemaDefined.swift", "KindSchema.swift", "ShapeSchemaChecking.swift"], []),
    ],
    "DrawScript": [
        ("Reading a script", ["DrawScript.swift", "Lexer.swift", "Parser.swift", "Syntax.swift"], []),
        ("Placing shapes", ["LayoutProblem.swift", "Solver.swift", "ObstacleGrid.swift"], []),
        ("Saying what's wrong", ["ScriptError.swift", "Suggestions.swift"], []),
    ],
    "QueryLanguage": [
        ("Reading a query", ["Lexer.swift", "Parser.swift", "Syntax.swift", "Words.swift"], []),
        ("Printing, limits and refusals", ["Printer.swift", "QueryLanguage.swift", "QueryError.swift", "KnownInventions.swift"], []),
    ],
    "TextEditing": [
        ("Text views", ["EditingTextView.swift", "TextHighlight.swift", "Spelling.swift", "StringDrawingLayout.swift", "TextEditingStyle.swift"], []),
        ("The caret list", ["CaretList.swift", "CaretListWindow.swift", "CaretListSubstitutions.swift"], []),
    ],
    "CanvasRPC": [
        ("Messages", ["Messages.swift", "JSON.swift", "Commands.swift", "Arguments.swift", "Help.swift"], []),
        ("Transport", ["Socket.swift", "Listener.swift", "Client.swift"], []),
    ],
    "CanvasUI": [
        ("Documents and windows", ["BoardDocument.swift", "BoardWindow.swift", "BoardWindowController.swift", "BoardMenus.swift", "SwiftUIBridge.swift"], []),
        ("The canvas view", ["CanvasView.swift", "PopoverView.swift", "ZoomIndicator.swift"], [
            ("Minimap", ["MinimapView.swift", "MinimapPicture.swift"], []),
        ]),
        ("Outside the window", ["BoardPicture.swift", "CommandServer.swift"], []),
    ],
    "Selection": [
        ("The select tool", ["SelectTool.swift", "SelectionState.swift", "SelectionHistory.swift", "Brush.swift", "Selection.swift"], []),
        ("Handles and resizing", ["Handles.swift", "Resizing.swift"], []),
        ("What kinds and plugins add", ["Buttons.swift", "Faces.swift", "Opening.swift", "Popovers.swift", "Labels.swift"], []),
        ("Going to shapes, and feedback", ["GoingTo.swift", "RefusalShake.swift", "SelectionStyle.swift"], []),
    ],
}

GROUPS.update({
    "Automation": [
        ("The command line's commands", ["Automation.swift", "Commands.swift", "Show.swift", "JSONBridge.swift"], []),
        ("canvas draw", ["Draw.swift", "Drawing.swift"], [
            ("Names, values and boards", ["DrawBoard.swift", "DrawPoints.swift", "DrawTexts.swift", "DrawVocabulary.swift", "DrawQueries.swift"], []),
            ("Placing, standing in, committing", ["DrawLayout.swift", "DrawObstacles.swift", "DrawStandIns.swift", "DrawCommit.swift"], []),
        ]),
    ],
    "Connections": [
        ("Ports and channels", ["Ports.swift", "PortTable.swift", "PortState.swift", "PortOverlay.swift", "Connectables.swift"], []),
        ("Arrows", ["ArrowModel.swift", "ArrowDefinition.swift", "ArrowStyle.swift"], [
            ("An arrow's geometry", ["ArrowGeometry.swift", "ArrowSkeleton.swift"], []),
            ("Binding and dragging", ["ArrowTargeting.swift", "ArrowConnecting.swift", "ArrowHandleDragSession.swift"], []),
            ("Arrow labels", ["ArrowLabel.swift", "ArrowLabelEditing.swift"], []),
        ]),
        ("Arrows in other surfaces", ["ArrowPorts.swift", "ArrowRow.swift"], []),
    ],
    "DetailPanel": [
        ("The panel", ["DetailPanel.swift", "DetailPanelState.swift", "DetailPanelView.swift", "DetailPanelPlugin.swift"], []),
        ("Controls and bindings", ["Controls.swift", "ListRows.swift", "ShapeBinding.swift"], []),
        ("Text boxes and the code editor", ["TextViews.swift", "CodeCompletions.swift"], []),
    ],
    "Find": [
        ("Searching", ["Find.swift", "FindIndex.swift", "FindSearch.swift", "FindState.swift"], []),
        ("Showing what's found", ["FindOverlay.swift", "FindPanel.swift", "FindStyle.swift"], []),
    ],
    "Frames": [
        ("The frame kind", ["Frames.swift", "FrameDefinition.swift", "FrameStyle.swift", "FrameSkeleton.swift"], []),
        ("A frame in the panel and the list", ["FrameHeader.swift", "FrameRow.swift"], []),
        ("Making frames", ["FrameTool.swift", "CreateFrame.swift"], []),
    ],
    "JumpTo": [
        ("Jump To's state", ["JumpTo.swift", "JumpToState.swift"], []),
        ("The catalog and its search", ["JumpToCatalog.swift", "JumpToSearch.swift"], []),
        ("The palette", ["JumpToPalette.swift", "JumpToRows.swift", "JumpToStyle.swift"], []),
    ],
    "LanguageModels": [
        ("The model plugins ask", ["LanguageModel.swift", "LanguageModelsPlugin.swift", "ModelAnswer.swift", "ScriptedLanguageModel.swift"], []),
        ("Anthropic", ["AnthropicModel.swift", "AnthropicKeyStore.swift", "AnthropicSettings.swift"], []),
    ],
    "Queries": [
        ("The engine", ["Queries.swift", "QueryState.swift", "QuerySnapshot.swift", "QueryBudget.swift", "MainFacts.swift"], []),
        ("Resolving a query", ["Resolution.swift", "QueryPlan.swift", "QueryVocabulary.swift", "QueryPoints.swift", "Hints.swift"], []),
        ("Answering it", ["Evaluation.swift", "Comparing.swift", "QueryResult.swift"], []),
    ],
    "SlashCommands": [
        ("Commands a shape offers", ["SlashCommands.swift", "SlashCommand.swift", "SlashCommandState.swift", "SlashArguments.swift"], []),
        ("Typing a command", ["SlashCommandTyping.swift", "SlashCommandLine.swift", "SlashCommandPicker.swift"], []),
    ],
    "Subboards": [
        ("The subboard kind", ["Subboards.swift", "SubboardDefinition.swift", "SubboardStyle.swift", "SubboardSkeleton.swift"], []),
        ("A subboard in the panel, the list and its ports", ["SubboardHeader.swift", "SubboardRow.swift", "SubboardLinks.swift"], []),
    ],
    "TableOfContents": [
        ("The list", ["TableOfContents.swift", "ContentsState.swift", "ContentsListing.swift", "TableOfContentsView.swift"], []),
        ("Dragging rows", ["ContentsDragging.swift", "ContentsPlace.swift"], []),
        ("Another board's outline", ["ContentsOutline.swift"], []),
    ],
    "Topology": [
        ("Edges and their types", ["Topology.swift", "EdgeTypes.swift", "EdgeSources.swift", "EdgeTables.swift"], []),
        ("Stand-ins and provided answers", ["Forwarding.swift", "Following.swift"], []),
        ("Per editor, and for other threads", ["TopologyIndex.swift", "TopologySnapshot.swift", "Containment.swift"], []),
    ],
    "Mentions": [
        ("The plugin and what it knows", ["Mentions.swift", "MentionState.swift", "Mentionable.swift", "MentionScope.swift", "MentionLabels.swift", "MentionCatalog.swift"], []),
        ("Mention text", ["MentionText.swift", "MentionTextFormat.swift"], [
            ("Pills", ["MentionPill.swift", "MentionDrawing.swift", "MentionFaces.swift", "MentionTextStyle.swift", "MentionStyle.swift"], []),
            ("Typing mentions", ["MentionTextView.swift", "MentionTextArea.swift", "MentionPicker.swift", "MentionMatching.swift"], []),
        ]),
        ("Where mentions show", ["MentionEdges.swift", "MentionBacklinks.swift", "MentionedIn.swift", "MentionRows.swift", "MentionFind.swift", "MentionMenus.swift"], []),
        ("Mentions' warnings", ["MentionProblems.swift", "MentionValidation.swift"], []),
    ],
    "Types": [
        ("Being a type", ["TypesPlugin.swift", "TypeSchema.swift", "TypeWords.swift", "TypeIndex.swift", "TypeCommands.swift"], []),
        ("Reading schemas", ["SchemaDocument.swift", "SchemaReadings.swift", "SchemaReferences.swift", "MetaSchema.swift", "JSONPointer.swift"], []),
        ("Kept in step by the model", ["TypeSync.swift", "SchemaPrompts.swift"], []),
        ("Highlights", ["SchemaHighlights.swift", "TypeHighlights.swift"], []),
        ("The panel's JSON", ["TypePanel.swift", "TypeCompletions.swift", "JSONCodeColors.swift"], [
            ("JSON text, half typed", ["JSONReader.swift", "JSONCaret.swift", "JSONCompleter.swift"], []),
        ]),
    ],
    "References": [
        ("The reference kind", ["References.swift", "ReferenceDefinition.swift", "ReferenceEdits.swift", "ReferenceStyle.swift"], []),
        ("What a reference stands for", ["ReferenceState.swift", "ReferenceCondition.swift", "ReferenceAnswers.swift", "ReferenceInterpreting.swift", "ReferenceMismatch.swift"], []),
        ("The pill and its field", ["ReferenceDrawing.swift", "ReferenceButtons.swift", "ReferenceEditing.swift", "ReferencePicker.swift"], []),
        ("A reference in the panel and the list", ["ReferencePanel.swift", "ReferenceRow.swift"], []),
    ],
})

# A file that uses so many others that it points at their modules instead, its pills split on both sides.
BY_MODULE = {("Composition", "ShippedPlugins.swift")}
