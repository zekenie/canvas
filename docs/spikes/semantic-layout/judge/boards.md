
## Board "Selection" (34 notes, 88 links)

### Notes

- **Accessibility.swift**: Claims the order VoiceOver walks the board in and the parts of each shape (see above). extends CanvasEditor, PartRole, SelectionPlugin
- **Brush.swift**: Decides for itself whether the marquee selects it, instead of the default from its geometry (an edge of the outline crosses or touches the brush, or, for a closed shape, the brush lies inside the outline). public BrushHitTesting extends CanvasEditor, ShapeGeometry
- **Buttons.swift**: Buttons a plugin draws on the canvas, in an overlay (Adornments' clickable ones, the lock chip; a port's dot), which the select tool presses before anything else under the pointer: handles, shapes, the box around several. public CanvasButtons, CanvasButtonSource internal ButtonHit, PressingButtonSession extends CanvasEditor, PluginRegistrar
- **Faces.swift**: Parts of a shape's content that answer a click without taking the shape's press: a mention's pill in a note's text, a link, a checkbox drawn on a card. public ShapeFaces, ShapeFaceSource internal FaceHit extends CanvasEditor, PluginRegistrar
- **GoingTo.swift**: The zoom a kind's shapes read at, where its text is set smaller than a note's 16 points (11 points reads at 100%): going to one (`goTo`) brings it at least that close. public ReadableZoom, NavigationStart extends CanvasEditor, PluginRegistrar, ShapeRegistrar
- **Groups.swift**: Shapes that are selected as one: a plugin's groups (Grouping's), which the select tool takes whole, as tldraw's does. public SelectionGroups, SelectionGroupSource internal GroupFocusOverlay extends Array, CanvasEditor, PluginRegistrar, SelectionState, Sequence
- **Handles.swift**: What pressing a handle did. public HandlePress, HandleProviding, HandleLocation internal PointingHandleSession, HandlesOverlay extends CanvasEditor
- **Labels.swift**: A kind with a label: text set on part of the shape, not over all of it (an arrow's, as tldraw's arrow labels are). public LabeledShape extends CanvasEditor
- **Opening.swift**: What opening a shape does, for a kind whose shapes open as something other than editing in place (a board-owning kind shows its board). public ShapeOpening, ShapeOpener extends CanvasEditor, PluginRegistrar, ShapeRegistrar
- **Parts.swift**: What a shape draws that a click acts on, as the keys reach it: its chips and pills, buttons, handles and arrows, one level in from the shape (keyboard navigation's principles 1 and 3). public ShapeParts, PartRole, PartStep, ShapePart, ShapePartSource internal PartFocus, PartRing, PartFocusOverlay extends CanvasEditor, PluginRegistrar, ScopedRegistrar, SelectionState, ShapeRegistrar
- **Popovers.swift**: What part of a shape's content shows in a popover beside it while the pointer rests there (the core's `CanvasPopover`): a type's words, the part of its schema they say. public ShapePopovers, ShapePopoverSource extends CanvasEditor, PluginRegistrar
- **RefusalShake.swift**: The shake a shape gives when something tries to change it and it can't be, like a password field's. public RefusalShake
- **Resizing.swift**: Which box kinds' shapes are resized with handles, and how small they go: a kind opts in with `x.resizable(minimumSize:)`. public ShapeResizing, ResizeHandle internal ResizingSession extends CanvasEditor, PluginRegistrar, ShapeRegistrar, Transaction
- **SelectTool.swift**: The select tool (tldraw's). internal SelectTool, PointingShapeSession, PointingCanvasSession, PointingSelectionSession, BrushingSession extends CanvasEditor
- **Selection.swift**: Go's section of moving between shapes and boards: Back, Forward right after it, and Open Selection, with what's placed beside them (a board's way up, after Forward) and after them (where a mention goes). public NavigationSection, ShapeSelectability, DoubleClickPlacement, DecorationHits, DragCopies, SelectionObservers, SelectionPlugin internal CopyDraggingSession extends CanvasCommand, CanvasEditor
- **SelectionHistory.swift**: The way back through the places the person has been, and forward again, one per editor (VS Code's navigation history, over data-canvas's selection history, with a browser's Forward): each time they go somewhere (follow a link to… internal SelectionHistory
- **SelectionState.swift**: The selection, the way back through the places it was, the hovered shape, the shape hovered where the canvas doesn't show it, the hovered handle, and the canvas button hovered and pressed, one per editor. internal SelectionState, SelectableHit, Nudged extends CanvasEditor
- **SelectionStyle.swift**: The selection's UI constants. internal SelectionStyle
- **Stepping.swift**: Where a step goes (tldraw's `TLAdjacentDirection`): to the next or previous shape in reading order, or to the nearest in a direction. public AdjacentDirection, SelectionEnclosure internal StepTrail, Stop, StopOrder, StepScope, ReadingOrderKey extends CanvasEditor, SelectionState
- **Walking.swift**: A row of a walk: one shape on one board, and how many stops it has (Find's hits in a shape; an issue's one, or none once it is ignored or holds). public WalkRow, WalkPosition, WalkKept, WalkBoardRun, WalkArrival, WalkEntry, ShapeWalkSource, ShapeWalk
- **SelectionPlugin**: 
- **CanvasButtons**: Buttons a plugin draws on the canvas, in an overlay (Adornments' clickable ones, the lock chip; a port's dot), which the select tool presses before anything…
- **DecorationHits**: Something a plugin draws for a shape outside it (Adornments' pills and chips) that counts as the shape: `selectableShape(at:)`, and so the select tool's press,…
- **DoubleClickPlacement**: What a double-click on empty canvas with the select tool places.
- **DragCopies**: What dragging the selection with ⌥ held moves: copies of it, put down in place when the drag begins (tldraw's), in the step of the drag.
- **ReadableZoom**: The zoom a kind's shapes read at, where its text is set smaller than a note's 16 points (11 points reads at 100%): going to one (`goTo`) brings it at least…
- **SelectionGroups**: Shapes that are selected as one: a plugin's groups (Grouping's), which the select tool takes whole, as tldraw's does.
- **SelectionObservers**: What a plugin does when the selection changes, told as it has (after the change, the shapes it left and the shapes it holds now, in order): the arrow that…
- **ShapeFaces**: Parts of a shape's content that answer a click without taking the shape's press: a mention's pill in a note's text, a link, a checkbox drawn on a card.
- **ShapeOpening**: What opening a shape does, for a kind whose shapes open as something other than editing in place (a board-owning kind shows its board).
- **ShapeParts**: What a shape draws that a click acts on, as the keys reach it: its chips and pills, buttons, handles and arrows, one level in from the shape (keyboard…
- **ShapePopovers**: What part of a shape's content shows in a popover beside it while the pointer rests there (the core's `CanvasPopover`): a type's words, the part of its schema…
- **ShapeResizing**: Which box kinds' shapes are resized with handles, and how small they go: a kind opts in with `x.resizable(minimumSize:)`.
- **ShapeSelectability**: Whether a kind's shapes can be selected.

### Links (the first uses the second)

1. Brush.swift -> SelectionState.swift
2. Buttons.swift -> Selection.swift
3. Buttons.swift -> SelectionState.swift
4. CanvasButtons -> Buttons.swift
5. DecorationHits -> Selection.swift
6. DoubleClickPlacement -> Selection.swift
7. DragCopies -> Selection.swift
8. Faces.swift -> Groups.swift
9. Faces.swift -> Selection.swift
10. Faces.swift -> SelectionState.swift
11. GoingTo.swift -> Opening.swift
12. GoingTo.swift -> Selection.swift
13. GoingTo.swift -> SelectionHistory.swift
14. GoingTo.swift -> SelectionState.swift
15. GoingTo.swift -> SelectionStyle.swift
16. Groups.swift -> GoingTo.swift
17. Groups.swift -> Parts.swift
18. Groups.swift -> Selection.swift
19. Groups.swift -> SelectionState.swift
20. Groups.swift -> SelectionStyle.swift
21. Groups.swift -> Stepping.swift
22. Handles.swift -> Buttons.swift
23. Handles.swift -> Resizing.swift
24. Handles.swift -> Selection.swift
25. Handles.swift -> SelectionState.swift
26. Handles.swift -> SelectionStyle.swift
27. Opening.swift -> Selection.swift
28. Opening.swift -> SelectionState.swift
29. Opening.swift -> Stepping.swift
30. Parts.swift -> GoingTo.swift
31. Parts.swift -> Selection.swift
32. Parts.swift -> SelectionState.swift
33. Parts.swift -> SelectionStyle.swift
34. Parts.swift -> Stepping.swift
35. Popovers.swift -> Selection.swift
36. Popovers.swift -> SelectionState.swift
37. ReadableZoom -> GoingTo.swift
38. RefusalShake.swift -> SelectionStyle.swift
39. Resizing.swift -> GoingTo.swift
40. Resizing.swift -> Parts.swift
41. Resizing.swift -> Selection.swift
42. Resizing.swift -> SelectionState.swift
43. Resizing.swift -> SelectionStyle.swift
44. Selection.swift -> RefusalShake.swift
45. Selection.swift -> SelectionState.swift
46. Selection.swift -> SelectionStyle.swift
47. Selection.swift -> Stepping.swift
48. SelectionGroups -> Groups.swift
49. SelectionObservers -> Selection.swift
50. SelectionPlugin -> CanvasButtons
51. SelectionPlugin -> DecorationHits
52. SelectionPlugin -> DoubleClickPlacement
53. SelectionPlugin -> DragCopies
54. SelectionPlugin -> ReadableZoom
55. SelectionPlugin -> Selection.swift
56. SelectionPlugin -> SelectionGroups
57. SelectionPlugin -> SelectionObservers
58. SelectionPlugin -> ShapeFaces
59. SelectionPlugin -> ShapeOpening
60. SelectionPlugin -> ShapeParts
61. SelectionPlugin -> ShapePopovers
62. SelectionPlugin -> ShapeResizing
63. SelectionPlugin -> ShapeSelectability
64. SelectionState.swift -> SelectionHistory.swift
65. SelectionState.swift -> SelectionStyle.swift
66. SelectionState.swift -> Stepping.swift
67. SelectionStyle.swift -> Stepping.swift
68. SelectTool.swift -> Brush.swift
69. SelectTool.swift -> Buttons.swift
70. SelectTool.swift -> Faces.swift
71. SelectTool.swift -> Groups.swift
72. SelectTool.swift -> Handles.swift
73. SelectTool.swift -> Labels.swift
74. SelectTool.swift -> Opening.swift
75. SelectTool.swift -> Parts.swift
76. SelectTool.swift -> Resizing.swift
77. SelectTool.swift -> Selection.swift
78. SelectTool.swift -> SelectionState.swift
79. SelectTool.swift -> SelectionStyle.swift
80. ShapeFaces -> Faces.swift
81. ShapeOpening -> Opening.swift
82. ShapeParts -> Parts.swift
83. ShapePopovers -> Popovers.swift
84. ShapeResizing -> Resizing.swift
85. ShapeSelectability -> Selection.swift
86. Stepping.swift -> GoingTo.swift
87. Walking.swift -> GoingTo.swift
88. Walking.swift -> SelectionState.swift

## Board "Mentions" (45 notes, 123 links)

### Notes

- **MentionCatalog.swift**: Every mentionable shape on the boards of a file the editor can show, ready for the picker to match: each shape's appearance and board, and its label folded once (`FuzzyMatcher.Label`), the keys of every label back to back in one… internal MentionCatalog
- **MentionChoices.swift**: A candidate and where it is (`MentionState.place(ofShape:)`): the containers it is inside, or the name of its board when it is in none and that isn't the board shown; nil for a shape directly on the board shown. public MentionChoice extends MentionState
- **MentionCommands.swift**: The pill's menu, for the keys and the menu bar (keyboard navigation's principles 1 and 10): Go to Mention (⌥⌘↩) and Show What Mentions in Go, after Open Selection, Remove Mention in Edit, right after Select All.
- **MentionDrawing.swift**: Where a shape draws one mention text on the canvas: what it says, its box (world units), its style, and at most how many lines. public MentionTextPlacement, MentionTexts, MentionTextContribution, MentionPillFrame, MentionDrawingCounts internal MentionResolver, MentionTextMemo, MentionFrames, MentionTextLayout extends CanvasEditor, MentionStyle, PluginRegistrar, Registry, RenderContext, ShapeCapabi
- **MentionEdges.swift**: A mention, as an edge in Topology's graph: from the shape whose text holds it to the shape it names, in the slot of the property the text is in, counted once for each time the text mentions it. public MentionEdge
- **MentionFaces.swift**: A pill on the canvas, as a face (Selection's `ShapeFaces`): the shape whose text it's in, what it names, whether that's live, and its center (world units), from which a click edits the shape. internal MentionFace
- **MentionFind.swift**: Mention text, for Find: on every kind that draws some (`MentionTexts`: a note's text, a schema card's description, an arrow's label), each placement's text as it reads, each mention its target's live name (as its pill shows it)… public MentionFindPlugin internal MentionFind extends PluginID
- **MentionLabels.swift**: The names mentions show now, taken from Mentions' state in one step (`MentionState.labels`) and read anywhere, on any thread: for each shape mentioned anywhere in the file (or observed), the name its pills show while it's live. public MentionLabels
- **MentionLayout.swift**: The layout input Mentions sets. public MentionLayouts, MentionLayoutContribution, MentionLayout extends MentionState, ShapeContext, ShapeRegistrar
- **MentionLights.swift**: Mentions' lights for Neighbors: hover a shape with ⌃⌥ held and what its text mentions is outlined in teal, what mentions it in lavender (`mention` edges, from the shape whose text holds a mention to the shape it names); its panel… public MentionLightsPlugin extends MentionStyle, PluginID
- **MentionMatching.swift**: How well a query matches a label: its score (the tier's, up to `MentionRanking.exact`), and the label's matched characters, as ranges of `Character` offsets, for the picker to set in semibold. public MentionMatch, MentionRanking, MentionMatcher
- **MentionMenus.swift**: Mentions' items in the canvas's context menu: right after a kind's own items, as a feature's are. public MentionsMenuGroup
- **MentionParts.swift**: A selected note's live mentions as parts (Selection's `ShapeParts`, keyboard navigation's principles 1 and 3): "Go to <name>" for each, in text order, a target mentioned twice listed once, at its first pill.
- **MentionPicker.swift**: The `@` picker of a mention text view, while it's open: what's typed after its `@` (the query), the rows that lists, and which row is highlighted. public MentionPickerRow, MentionPicker extends MentionStyle
- **MentionPill.swift**: A mention as one character of text (U+FFFC): the pill. public MentionAttachment, MentionPillLayout
- **MentionPlaces.swift**: Where a shape is, as a list of shapes says it beside the shape's name: the names of the containers it is inside, outermost first, "Alpha › Beta" (`ShapePath`'s way of saying them, a container with no title by what its kind is… public MentionPlace extends MentionState
- **MentionProblems.swift**: Something wrong with the mentions in a shape's text: a mention of a shape that can't be mentioned, or not by that text (its scope), or text that looks like a mention but isn't one. public MentionProblem internal MentionProblemCopy extends Registry, Substring
- **MentionQueries.swift**: Mentions in queries, in Mentions: `:mentions(S)` is a shape whose text mentions a shape S matches, and `:mentioned-by(S)` one a shape S matches mentions: Topology's mention edges (`MentionEdge`), from the shape whose text holds… public MentionQueriesPlugin internal MentionedNames
- **MentionQuote.swift**: A quote of mention text around a mention, as a list of what mentions a shape shows it under a mentioner's name (`MentionState.quote(of:around:)`). internal MentionQuote
- **MentionRows.swift**: Rows of the table of contents that show mention text, with the names of the shapes it mentions as they're named now: a kind whose row reads its mention text names these as its `affected`, so a rename remakes the rows of the… public MentionRows extends ContentsContext
- **MentionScope.swift**: What a mention text may mention: its type's scope, `ScopedMentionText<Scope>`. public MentionScope, AnyMentionable, Only, DeclaredMentionScope, MentionScopes, MentionScopeDeclaration, MentionScopeJoins, MentionAdmission extends PluginRegistrar, Registry, ShapeRegistrar
- **MentionSlashBar.swift**: Mentions' text as the command bar's field (`SlashBarFields`), so what's typed there can name a shape: `/move-to @Roadmap` on the shapes selected moves them into it, as one block. public MentionSlashBarPlugin extends MentionStyle, PluginID
- **MentionState.swift**: What Mentions knows about an editor's file, one per editor: how each mentioned shape shows now, what mentions each shape, on any board (`mentioners(of:)`), the catalog of shapes that can be mentioned (what the `@` picker… public MentionState, MentionObservation, MentionCandidate, MentionCandidates internal PillCommandText extends CanvasEditor, MentionTextView
- **MentionStyle.swift**: Mentions' UI constants. internal MentionStyle extends MentionTextStyle
- **MentionText.swift**: Mention text that may mention any mentionable shape. public MentionRun, ScopedMentionText, MentionReading, MentionText internal MentionTextHolding, MentionGrammar
- **MentionTextArea.swift**: Mention text in the panel: a box of the panel's (`DetailTextBox`) over a `MentionTextView`, so a field of mention text edits there as it does on its shape, with pills, the `@` picker, copy and paste, each pill's click and… public MentionTextArea
- **MentionTextFormat.swift**: The stored form's shared pieces: its schema definition (`mentions.text`, which every mention text refers to, whatever its scope), each shipped migration step's escaper, frozen, and the bounds check the registry runs. public MentionTextFormat internal MentionBoundsError extends ScopedMentionText
- **MentionTextStyle.swift**: How mention text looks: one style shared by a kind's render and its editing view, as a note's attributes are, so the text is on the same lines in both. public MentionSurface, MentionTextStyle
- **MentionTextView.swift**: The text view for editable mention text (TextKit 2): its pills, the `@` picker, slash commands, copy and paste, accessibility, live labels. public MentionTextView, MentionAccessibility internal MentionTextViewHelper extends MentionStyle, NSPasteboard
- **MentionTexts.swift**: Draw's mention text, in Mentions: in any text a script writes whose schema says it's mention text (`MentionTextFormat.mediaType`: a note's `text:`, wherever one is inside a value), `\@[Title]` mentions the shape called Title, and… public MentionTextsPlugin
- **MentionValidation.swift**: Mentions' warnings, as Validation rules: a warning for each problem Mentions finds (`registry.mentionProblems(of:lookup:)`) in the mentions a shape's text holds, about the property the text is in: a mention of a shape that can't… public MentionValidationPlugin
- **Mentionable.swift**: How a kind's shapes are mentioned: one per kind, plus one for every kind (`mentionableEveryShape`), which a kind's own takes the place of. public ShapeMentions, MentionFollowing, MentionContribution, MentionAppearance, MentionResolution internal MentionKindDefaults extends CanvasEditor, PluginRegistrar, Registry, ShapeRegistrar
- **Mentions.swift**: Mentions' service, its edges (each mention, Topology's), its faces on the canvas (a click on a pill edits its shape from the pill, if its kind is `Editable`, and a double-click on a live one goes to what it names wherever no text… public MentionsPlugin extends CanvasCommand, PluginID
- **MentionsPlugin**: Mentions' service, its edges (each mention, Topology's), its faces on the canvas (a click on a pill edits its shape from the pill, if its kind is `Editable`,…
- **MentionSlashBarPlugin**: Mentions' text as the command bar's field (`SlashBarFields`), so what's typed there can name a shape: `/move-to @Roadmap` on the shapes selected moves them…
- **MentionFindPlugin**: Mention text, for Find: on every kind that draws some (`MentionTexts`: a note's text, a schema card's description, an arrow's label), each placement's text as…
- **MentionValidationPlugin**: Mentions' warnings, as Validation rules: a warning for each problem Mentions finds (`registry.mentionProblems(of:lookup:)`) in the mentions a shape's text…
- **MentionTextsPlugin**: Draw's mention text, in Mentions: in any text a script writes whose schema says it's mention text (`MentionTextFormat.mediaType`: a note's `text:`, wherever…
- **MentionQueriesPlugin**: Mentions in queries, in Mentions: `:mentions(S)` is a shape whose text mentions a shape S matches, and `:mentioned-by(S)` one a shape S matches mentions:…
- **MentionLightsPlugin**: Mentions' lights for Neighbors: hover a shape with ⌃⌥ held and what its text mentions is outlined in teal, what mentions it in lavender (`mention` edges, from…
- **MentionLayouts**: Which kinds lay out by the names their mention text shows now (`registrar.mentionLayout`): an arrow's label is measured for its geometry, which can't read what…
- **MentionScopeJoins**: Which kinds joined which declared scopes: one join per kind and scope.
- **MentionScopes**: The declared scopes, one declaration per type, from the plugin that owns what the scope means.
- **MentionTexts**: Where each kind draws mention text: one per kind.
- **ShapeMentions**: How a kind's shapes are mentioned: one per kind, plus one for every kind (`mentionableEveryShape`), which a kind's own takes the place of.

### Links (the first uses the second)

1. Mentionable.swift -> Mentions.swift
2. Mentionable.swift -> MentionStyle.swift
3. Mentionable.swift -> MentionTextFormat.swift
4. MentionCatalog.swift -> Mentionable.swift
5. MentionChoices.swift -> Mentionable.swift
6. MentionChoices.swift -> MentionPlaces.swift
7. MentionChoices.swift -> MentionState.swift
8. MentionCommands.swift -> Mentions.swift
9. MentionCommands.swift -> MentionState.swift
10. MentionCommands.swift -> MentionStyle.swift
11. MentionCommands.swift -> MentionTextView.swift
12. MentionDrawing.swift -> Mentionable.swift
13. MentionDrawing.swift -> MentionPill.swift
14. MentionDrawing.swift -> Mentions.swift
15. MentionDrawing.swift -> MentionStyle.swift
16. MentionDrawing.swift -> MentionText.swift
17. MentionDrawing.swift -> MentionTextFormat.swift
18. MentionDrawing.swift -> MentionTextStyle.swift
19. MentionEdges.swift -> MentionText.swift
20. MentionFaces.swift -> MentionDrawing.swift
21. MentionFaces.swift -> MentionState.swift
22. MentionFind.swift -> Mentionable.swift
23. MentionFind.swift -> MentionDrawing.swift
24. MentionFind.swift -> MentionState.swift
25. MentionFind.swift -> MentionText.swift
26. MentionFindPlugin -> MentionFind.swift
27. MentionLabels.swift -> Mentionable.swift
28. MentionLayout.swift -> Mentionable.swift
29. MentionLayout.swift -> Mentions.swift
30. MentionLayout.swift -> MentionState.swift
31. MentionLayout.swift -> MentionText.swift
32. MentionLayouts -> MentionLayout.swift
33. MentionLights.swift -> MentionEdges.swift
34. MentionLights.swift -> MentionState.swift
35. MentionLights.swift -> MentionStyle.swift
36. MentionLightsPlugin -> MentionLights.swift
37. MentionMenus.swift -> MentionState.swift
38. MentionMenus.swift -> MentionStyle.swift
39. MentionParts.swift -> Mentionable.swift
40. MentionParts.swift -> MentionDrawing.swift
41. MentionParts.swift -> MentionState.swift
42. MentionParts.swift -> MentionStyle.swift
43. MentionParts.swift -> MentionTextView.swift
44. MentionPicker.swift -> Mentionable.swift
45. MentionPicker.swift -> MentionPlaces.swift
46. MentionPicker.swift -> MentionScope.swift
47. MentionPicker.swift -> MentionState.swift
48. MentionPicker.swift -> MentionStyle.swift
49. MentionPill.swift -> Mentionable.swift
50. MentionPill.swift -> MentionStyle.swift
51. MentionPill.swift -> MentionTextStyle.swift
52. MentionPlaces.swift -> MentionState.swift
53. MentionProblems.swift -> Mentionable.swift
54. MentionProblems.swift -> MentionScope.swift
55. MentionProblems.swift -> MentionText.swift
56. MentionQueries.swift -> MentionEdges.swift
57. MentionQueries.swift -> MentionLabels.swift
58. MentionQueries.swift -> MentionState.swift
59. MentionQueries.swift -> MentionText.swift
60. MentionQueries.swift -> MentionTextFormat.swift
61. MentionQueriesPlugin -> MentionQueries.swift
62. MentionQuote.swift -> MentionText.swift
63. MentionRows.swift -> MentionState.swift
64. MentionRows.swift -> MentionText.swift
65. Mentions.swift -> MentionEdges.swift
66. Mentions.swift -> MentionFaces.swift
67. Mentions.swift -> MentionMenus.swift
68. Mentions.swift -> MentionParts.swift
69. Mentions.swift -> MentionState.swift
70. MentionScope.swift -> Mentionable.swift
71. MentionScope.swift -> Mentions.swift
72. MentionScope.swift -> MentionTextFormat.swift
73. MentionScopeJoins -> MentionScope.swift
74. MentionScopes -> MentionScope.swift
75. MentionSlashBar.swift -> MentionScope.swift
76. MentionSlashBar.swift -> MentionState.swift
77. MentionSlashBar.swift -> MentionStyle.swift
78. MentionSlashBar.swift -> MentionTextStyle.swift
79. MentionSlashBar.swift -> MentionTextView.swift
80. MentionSlashBarPlugin -> MentionSlashBar.swift
81. MentionsPlugin -> MentionLayouts
82. MentionsPlugin -> Mentions.swift
83. MentionsPlugin -> MentionScopeJoins
84. MentionsPlugin -> MentionScopes
85. MentionsPlugin -> MentionTexts
86. MentionsPlugin -> ShapeMentions
87. MentionState.swift -> Mentionable.swift
88. MentionState.swift -> MentionCatalog.swift
89. MentionState.swift -> MentionEdges.swift
90. MentionState.swift -> MentionLabels.swift
91. MentionState.swift -> MentionMatching.swift
92. MentionState.swift -> MentionPill.swift
93. MentionState.swift -> MentionQuote.swift
94. MentionState.swift -> MentionScope.swift
95. MentionState.swift -> MentionStyle.swift
96. MentionState.swift -> MentionText.swift
97. MentionState.swift -> MentionTextView.swift
98. MentionStyle.swift -> MentionTextStyle.swift
99. MentionText.swift -> MentionScope.swift
100. MentionText.swift -> MentionTextFormat.swift
101. MentionTextArea.swift -> MentionScope.swift
102. MentionTextArea.swift -> MentionState.swift
103. MentionTextArea.swift -> MentionStyle.swift
104. MentionTextArea.swift -> MentionText.swift
105. MentionTextArea.swift -> MentionTextView.swift
106. MentionTexts.swift -> Mentionable.swift
107. MentionTexts.swift -> MentionScope.swift
108. MentionTexts.swift -> MentionTextFormat.swift
109. MentionTexts -> MentionDrawing.swift
110. MentionTextsPlugin -> MentionTexts.swift
111. MentionTextStyle.swift -> Mentionable.swift
112. MentionTextStyle.swift -> MentionText.swift
113. MentionTextView.swift -> Mentionable.swift
114. MentionTextView.swift -> MentionPicker.swift
115. MentionTextView.swift -> MentionPill.swift
116. MentionTextView.swift -> MentionPlaces.swift
117. MentionTextView.swift -> MentionScope.swift
118. MentionTextView.swift -> MentionStyle.swift
119. MentionTextView.swift -> MentionText.swift
120. MentionTextView.swift -> MentionTextStyle.swift
121. MentionValidation.swift -> MentionProblems.swift
122. MentionValidationPlugin -> MentionValidation.swift
123. ShapeMentions -> Mentionable.swift

## Board "Draw" (30 notes, 97 links)

### Notes

- **Draw.swift**: The draw engine's plugin: it owns the nine points the plugins that own a concern fill with this app's words (DrawPoints.swift), and contributes the engine's mark. public DrawPlugin, DrawEngine, DrawEngines, DrawResult, DrawError internal DrawBoard, DrawChange, DrawWarning, DrawStyle public func draw extends PluginID
- **DrawBoard.swift**: The file's shapes by name, every board the app can show, as the run starts. public FileNames extends Drawing, Statement
- **DrawBrought.swift**: The most shapes a run says it brought an issue to; the rest it counts. extends Drawing
- **DrawCommit.swift**: What a column of stand-ins is beside: the clauses its pills are placed by, and the boxes those name, found. private ColumnKey extends Drawing
- **DrawGroups.swift**: A group or ungroup statement, resolved. internal GroupItem extends Drawing
- **DrawIDs.swift**: How a message and a row call an end of an edge: the title the shape has, and, for an end the statement wrote as an id, that id as written. internal EndName, TakenBoards extends Drawing, FileNames
- **DrawLayout.swift**: Places every shape the script moves, or says why it can't (the solver's first problem), and builds each shape as it will be. extends Drawing
- **DrawObstacles.swift**: The board's obstacles, for one run. internal ObstacleIndex
- **DrawPaths.swift**: The shape that holds, when it is a shape on its own board (a frame), else nil: the top of a board has none. extends Drawing, FileNames
- **DrawPoints.swift**: What shapes are called, for `canvas draw`, which names shapes by their titles: how a shape's name is read, which of its kind's properties a title is written to, whether its kind works one out by itself, and how a title is folded… public DrawNaming, DrawNames, DrawLabeling, DrawLabels, EdgeRequest, DrawEdging, DrawEdges, DrawEdgeIdentifying, DrawEdgeIdentities, DrawIssue +13 internal DrawPointKey e
- **DrawQueries.swift**: Refuses a query a property holds (`format: x-canvas-query`) that the query engine won't read, with the engine's own message and hint: syntax and vocabulary, and no word that reads the editor, since the query is stored to run… extends Drawing
- **DrawStandIns.swift**: A shape an edge names that's on a board other than the one the run draws on. internal FarShape, EdgeEndFound, NewStandIn, MadeStandIn, EdgeEnd, EdgeMatch, EdgeIdentity extends Drawing
- **DrawTexts.swift**: Which shape a name stands for, for a text format: what `DrawTextContext.shape` asks. internal DrawTextLookup, DrawTextWriter extends DrawError, Drawing, KindVocabulary
- **DrawVocabulary.swift**: A value a script wrote that its property can't take: what's wrong, and what to write. internal ValueRefusal, KindVocabulary extends Attribute
- **Drawing.swift**: A shape statement, resolved. internal ShapeItem, EdgeItem, DeleteItem, BoardConnection, Drawing, BoardNames public func quoted, indefinite extends Attribute, DeleteStatement, Script
- **Kinds.swift**: A kind, as `kinds` lists it: the language's vocabulary for it. public KindSummary public func kinds
- **Measure.swift**: What `measure` answers. public MeasureResult public func measure extends Drawing
- **StandInRoute.swift**: How a stand-in (a pill that stands for a shape) is read and made, for whatever draws or edits arrows to shapes on other boards: the one answer to "what does this stand for", "which pills does the board have", "which does a delete… public StandInRoute, EdgePlace, StandInSpot
- **Surroundings.swift**: A board shapes land on, as `canvas draw` reads the board it places shapes on: read in place (`editor.reading(of:)`, shown or not), every shape there with a solid (`ShapeContext.solidBounds(of:)`) an obstacle, in paint order… public Landing, PlacingStyle, Surroundings
- **DrawPlugin**: The draw engine's plugin: it owns the nine points the plugins that own a concern fill with this app's words (DrawPoints.swift), and contributes the engine's…
- **DrawChecks**: What checks shapes drawn for `canvas draw`: at most one plugin.
- **DrawEdgeIdentities**: What tells the edges of one pair apart for `canvas draw`: at most one plugin for each property key, read in plugin order.
- **DrawEdges**: What makes edges for `canvas draw`: at most one plugin.
- **DrawEngines**: Who runs `canvas draw`'s engine: `DrawPlugin`, once.
- **DrawGroups**: What groups shapes for `canvas draw`: at most one plugin.
- **DrawLabels**: What names a shape that has no title for the pill that stands for it: at most one plugin.
- **DrawNames**: What names shapes for `canvas draw`: at most one plugin.
- **DrawReports**: What reports on each shape and edge a run made, changed or restated, as the script leaves the board: at most one plugin.
- **DrawTextFormats**: How text of each media type is written in `canvas draw`: at most one plugin for each.
- **DrawValueWriters**: What writes a property's values in `canvas draw`: at most one plugin for each property key.

### Links (the first uses the second)

1. Draw.swift -> DrawBoard.swift
2. Draw.swift -> DrawCommit.swift
3. Draw.swift -> Drawing.swift
4. Draw.swift -> DrawLayout.swift
5. Draw.swift -> DrawPoints.swift
6. Draw.swift -> Surroundings.swift
7. DrawBoard.swift -> DrawIDs.swift
8. DrawBoard.swift -> Drawing.swift
9. DrawBoard.swift -> DrawPaths.swift
10. DrawBoard.swift -> DrawPoints.swift
11. DrawBoard.swift -> DrawStandIns.swift
12. DrawBrought.swift -> Draw.swift
13. DrawBrought.swift -> DrawBoard.swift
14. DrawBrought.swift -> Drawing.swift
15. DrawBrought.swift -> DrawLayout.swift
16. DrawBrought.swift -> DrawPaths.swift
17. DrawBrought.swift -> DrawPoints.swift
18. DrawChecks -> DrawPoints.swift
19. DrawCommit.swift -> DrawBrought.swift
20. DrawCommit.swift -> DrawGroups.swift
21. DrawCommit.swift -> DrawIDs.swift
22. DrawCommit.swift -> Drawing.swift
23. DrawCommit.swift -> DrawLayout.swift
24. DrawCommit.swift -> DrawPaths.swift
25. DrawCommit.swift -> DrawPoints.swift
26. DrawCommit.swift -> DrawStandIns.swift
27. DrawCommit.swift -> DrawVocabulary.swift
28. DrawCommit.swift -> StandInRoute.swift
29. DrawEdgeIdentities -> DrawPoints.swift
30. DrawEdges -> DrawPoints.swift
31. DrawEngines -> Draw.swift
32. DrawGroups.swift -> Draw.swift
33. DrawGroups.swift -> DrawIDs.swift
34. DrawGroups.swift -> Drawing.swift
35. DrawGroups.swift -> DrawLayout.swift
36. DrawGroups.swift -> DrawPaths.swift
37. DrawGroups.swift -> DrawPoints.swift
38. DrawGroups -> DrawPoints.swift
39. DrawIDs.swift -> Draw.swift
40. DrawIDs.swift -> Drawing.swift
41. DrawIDs.swift -> DrawLayout.swift
42. DrawIDs.swift -> DrawPaths.swift
43. DrawIDs.swift -> DrawPoints.swift
44. DrawIDs.swift -> DrawStandIns.swift
45. Drawing.swift -> DrawPoints.swift
46. Drawing.swift -> Kinds.swift
47. Drawing.swift -> StandInRoute.swift
48. DrawLabels -> DrawPoints.swift
49. DrawLayout.swift -> Drawing.swift
50. DrawLayout.swift -> DrawObstacles.swift
51. DrawLayout.swift -> DrawPaths.swift
52. DrawLayout.swift -> DrawPoints.swift
53. DrawLayout.swift -> DrawStandIns.swift
54. DrawNames -> DrawPoints.swift
55. DrawPaths.swift -> Draw.swift
56. DrawPaths.swift -> Drawing.swift
57. DrawPaths.swift -> DrawPoints.swift
58. DrawPaths.swift -> DrawStandIns.swift
59. DrawPlugin -> Draw.swift
60. DrawPlugin -> DrawChecks
61. DrawPlugin -> DrawEdgeIdentities
62. DrawPlugin -> DrawEdges
63. DrawPlugin -> DrawEngines
64. DrawPlugin -> DrawGroups
65. DrawPlugin -> DrawLabels
66. DrawPlugin -> DrawNames
67. DrawPlugin -> DrawReports
68. DrawPlugin -> DrawTextFormats
69. DrawPlugin -> DrawValueWriters
70. DrawPoints.swift -> DrawTexts.swift
71. DrawPoints.swift -> DrawVocabulary.swift
72. DrawQueries.swift -> Drawing.swift
73. DrawQueries.swift -> DrawVocabulary.swift
74. DrawReports -> DrawPoints.swift
75. DrawStandIns.swift -> Draw.swift
76. DrawStandIns.swift -> Drawing.swift
77. DrawStandIns.swift -> StandInRoute.swift
78. DrawTextFormats -> DrawPoints.swift
79. DrawTexts.swift -> Draw.swift
80. DrawTexts.swift -> DrawBoard.swift
81. DrawTexts.swift -> Drawing.swift
82. DrawTexts.swift -> DrawPaths.swift
83. DrawTexts.swift -> DrawVocabulary.swift
84. DrawValueWriters -> DrawPoints.swift
85. DrawVocabulary.swift -> Drawing.swift
86. Kinds.swift -> Draw.swift
87. Kinds.swift -> DrawPoints.swift
88. Kinds.swift -> DrawVocabulary.swift
89. Measure.swift -> Draw.swift
90. Measure.swift -> DrawBoard.swift
91. Measure.swift -> DrawIDs.swift
92. Measure.swift -> Drawing.swift
93. Measure.swift -> DrawPaths.swift
94. Measure.swift -> DrawPoints.swift
95. Measure.swift -> DrawStandIns.swift
96. StandInRoute.swift -> DrawPoints.swift
97. StandInRoute.swift -> Surroundings.swift

## Board "Canvas/Model" (20 notes, 78 links)

### Notes

- **AddedProperty.swift**: A property a plugin adds to the kinds that opt in: something those shapes know (a title, say) that the kinds don't declare themselves. public ShapeProperty, PropertyKeywords, PropertyMigration internal AddedValues, KeptJSON, AddedValue, Boxed extends AnyShapeRecord, ShapeRecord
- **BoardID.swift**: A board of a file (`CanvasFile`): the root, or the board a shape owns, named by that shape's id. public BoardID
- **CanvasDocument.swift**: Every shape on a canvas, back to front: in ascending order of their stacking keys. public CanvasDocument
- **CanvasFile.swift**: Every board of one file: the root, and a board for each shape that owns one (a shape of a `BoardOwning` kind), kept under the owner's id. public CanvasFile
- **ChangeSet.swift**: What one commit did to the document, record by record: the shapes it added, changed (props, or place in the stack) and removed. public ChangeSet
- **Containment.swift**: The container a shape is directly in, as the core goes by it: the one it names (`AnyShapeRecord.container`), if that's on this board, of one of `kinds` (the registry's `containingKinds`) and not kept aside, and the shape itself… extends CanvasDocument, Registry, ShapeContext
- **DocumentDelta.swift**: What a step did to a file: on the board it was made on (`board`), shape by shape, each touched shape's whole record before and after (nil: it wasn't there), its stacking key, metadata, added and kept values included, opaque (kept… public DocumentDelta extends ChangeSet
- **Enclosing.swift**: Puts `container`, a new shape of a `ShapeContaining` kind, down around shapes on this board, holding them: those of `ids` with a box, but what's in another of them (it goes with that one). extends Transaction
- **FileProperty.swift**: A value a plugin keeps on the file as a whole: what belongs to no shape and no board of it (the colors a file names). public FileProperty internal FileValues
- **Identity.swift**: Names a kind of shape. public ShapeKind, PropertyKey, ShapeID, PluginID, ToolID, CanvasCommand
- **ReverseIndex.swift**: What each shape names, kept with the other way round, what names each shape: the shapes a shape's rules looked up and those whose rules looked a shape up, a type's references and the types that refer to it, the shapes a… public ReverseIndex
- **Settling.swift**: What settling shapes did (`Transaction.settle(_:)`). public Settlement internal ContainerRule extends Transaction
- **ShapeMap.swift**: A dictionary keyed by shape id that is copied a piece at a time: its entries are kept in shards, and a copy shares every shard with the original until one of them writes to it, which copies the shard the write reaches and the… internal ShapeMap
- **ShapeMeta.swift**: A shape's metadata: each plugin's members, typed by their keys (`meta[CopiedFrom.self]`), kept as the JSON a board writes. public ShapeMetaKey, ShapeMeta
- **ShapeNaming.swift**: A value that names shapes loosely, wherever a shape keeps it: a kind's own property, a struct in one, a collection, an added property's value (a mention in text). public ShapeNaming extends AnyShapeRecord, Array, Dictionary, Optional, SchemaDefined, Set
- **ShapeRecord.swift**: One shape, with its props typed. public ShapeProps, BoxShapeProps, ShapeRecord, AnyShapeRecord internal ContainerBits
- **ShapeStack.swift**: The shapes of a board, back to front: a random-access collection of their records, the bottom shape first (`Int` positions, like an array's), kept so that a copy shares with the original everything neither has changed. public ShapeStack
- **StackReplay.swift**: A board's stack as a run of restacks leaves it, worked out over the stack the run began with and not by moving anything in it: what a restack changes (the shapes either side of those it moves, and their keys) is kept apart, by… internal StackReplay
- **StackingKey.swift**: Where a shape sits in the stack: a document paints its shapes in ascending key order, and the key is part of the shape's record, so moving a shape changes that shape alone. public StackingKey, StackingKeyGenerator internal FractionalIndexing
- **Transaction.swift**: The only way to change a document: `editor.transact { tx in ... }`. public Transaction internal FileAccess

### Links (the first uses the second)

1. AddedProperty.swift -> Identity.swift
2. AddedProperty.swift -> ShapeRecord.swift
3. BoardID.swift -> Identity.swift
4. CanvasDocument.swift -> DocumentDelta.swift
5. CanvasDocument.swift -> Identity.swift
6. CanvasDocument.swift -> ShapeRecord.swift
7. CanvasDocument.swift -> ShapeStack.swift
8. CanvasDocument.swift -> StackingKey.swift
9. CanvasFile.swift -> BoardID.swift
10. CanvasFile.swift -> CanvasDocument.swift
11. CanvasFile.swift -> ChangeSet.swift
12. CanvasFile.swift -> DocumentDelta.swift
13. CanvasFile.swift -> FileProperty.swift
14. CanvasFile.swift -> Identity.swift
15. CanvasFile.swift -> ShapeMap.swift
16. CanvasFile.swift -> ShapeRecord.swift
17. CanvasFile.swift -> ShapeStack.swift
18. ChangeSet.swift -> BoardID.swift
19. ChangeSet.swift -> CanvasDocument.swift
20. ChangeSet.swift -> Identity.swift
21. ChangeSet.swift -> ShapeRecord.swift
22. ChangeSet.swift -> ShapeStack.swift
23. Containment.swift -> BoardID.swift
24. Containment.swift -> CanvasDocument.swift
25. Containment.swift -> CanvasFile.swift
26. Containment.swift -> Identity.swift
27. Containment.swift -> ShapeRecord.swift
28. Containment.swift -> ShapeStack.swift
29. DocumentDelta.swift -> AddedProperty.swift
30. DocumentDelta.swift -> BoardID.swift
31. DocumentDelta.swift -> ChangeSet.swift
32. DocumentDelta.swift -> FileProperty.swift
33. DocumentDelta.swift -> Identity.swift
34. DocumentDelta.swift -> ShapeRecord.swift
35. Enclosing.swift -> CanvasDocument.swift
36. Enclosing.swift -> Containment.swift
37. Enclosing.swift -> Identity.swift
38. Enclosing.swift -> Settling.swift
39. Enclosing.swift -> ShapeRecord.swift
40. Enclosing.swift -> ShapeStack.swift
41. Enclosing.swift -> Transaction.swift
42. FileProperty.swift -> AddedProperty.swift
43. FileProperty.swift -> Identity.swift
44. ReverseIndex.swift -> Identity.swift
45. Settling.swift -> BoardID.swift
46. Settling.swift -> CanvasDocument.swift
47. Settling.swift -> Containment.swift
48. Settling.swift -> Identity.swift
49. Settling.swift -> ShapeRecord.swift
50. Settling.swift -> ShapeStack.swift
51. Settling.swift -> Transaction.swift
52. ShapeMap.swift -> Identity.swift
53. ShapeMeta.swift -> Identity.swift
54. ShapeNaming.swift -> AddedProperty.swift
55. ShapeNaming.swift -> Identity.swift
56. ShapeNaming.swift -> ShapeRecord.swift
57. ShapeRecord.swift -> Identity.swift
58. ShapeRecord.swift -> ShapeMeta.swift
59. ShapeRecord.swift -> StackingKey.swift
60. ShapeStack.swift -> Identity.swift
61. ShapeStack.swift -> ShapeMap.swift
62. ShapeStack.swift -> ShapeRecord.swift
63. StackReplay.swift -> Identity.swift
64. StackReplay.swift -> ShapeRecord.swift
65. StackReplay.swift -> ShapeStack.swift
66. StackReplay.swift -> StackingKey.swift
67. Transaction.swift -> AddedProperty.swift
68. Transaction.swift -> BoardID.swift
69. Transaction.swift -> CanvasDocument.swift
70. Transaction.swift -> CanvasFile.swift
71. Transaction.swift -> ChangeSet.swift
72. Transaction.swift -> Containment.swift
73. Transaction.swift -> FileProperty.swift
74. Transaction.swift -> Identity.swift
75. Transaction.swift -> ShapeRecord.swift
76. Transaction.swift -> ShapeStack.swift
77. Transaction.swift -> StackingKey.swift
78. Transaction.swift -> StackReplay.swift

## Board "References" (19 notes, 73 links)

### Notes

- **PillColors.swift**: What a pill wears of its original's color: made once from the color's roles (`Swatch`) and shared by every pill of that color, the way a color's `CGColor`s are kept by the color book. internal PillColors
- **ReferenceAnswers.swift**: How a query's answer went for a dynamic reference, as far as its last answer for the question its record asks now says. public ReferenceStatus, ReferenceFailure internal Finding, Landed, RememberedAnswer, Memo, AnswerRevisions extends ReferenceState
- **ReferenceButtons.swift**: The leading symbol's hover and pressed looks (`GoButton`, a canvas button Selection presses and clicks): while the pointer is on it, its disc is the accent's, an arrow going up and out, a step darker while it's pressed. internal ReferenceButtonOverlay
- **ReferenceCondition.swift**: What a reference stands for now, as the pill, the panel's header, the table of contents' row and the menu read it: derived from the reference's props and the file, never stored. public ReferenceCondition, ReferenceFound
- **ReferenceDefinition.swift**: On the main actor as a whole, so its drawing helpers share the protocol's isolation. internal ReferenceDefinition
- **ReferenceDrawing.swift**: What the pill draws, worked out once from its condition: the leading symbol, the label and how it's dressed, what trails, and whether it stands for nothing. internal ReferenceLook, ReferenceMemo, DrawnPlace extends ReferenceDefinition
- **ReferenceEditing.swift**: The text view of a pill's field: one line, whose list of public shapes (`ReferencePicker`) shows in a `CaretListWindow` under it while it's open, as every `EditingTextView`'s list does (the keys that move through it, pick and… internal ReferenceTextView, ReferenceEditor
- **ReferenceEdits.swift**: How a reference is written: each keeps exactly one mode (so `target`, `words` and `query` never disagree) and refits the pill's width to what it now says, growing rightward from where it is. public ReferenceEdits
- **ReferenceInterpreting.swift**: A reference, as the host of its words: what the lifecycle asks of it. internal ReferenceInterpreter extends ReferenceState, ReferenceStatus
- **ReferenceMismatch.swift**: An arrow attached to a reference whose channel what the reference stands for now doesn't take: it ran into the pill while the pill stood for something that took it, and the pill was re-pointed (or what it stood for went private… public ChannelMismatch extends ReferenceState
- **ReferencePanel.swift**: The panel's header: what the reference stands for, as its pill says it, never renamed there: its symbol (secondary, as every header's is), what it's called in the header's own type, and a line under it (the kind and the board, or… public ReferenceHeader, ReferenceQueryContent, ReferenceStatusLine internal ReferencePlaceView, ReferenceQueryView, ReferenceMatchesView extends ReferenceState, ShapeReg
- **ReferencePath.swift**: The path a direct reference's row shows before the name of the shape it stands for: the shapes that shape is inside, outermost first (Topology's tree: the frames it's in, the owner of its board, the frames that one is in, and so… extends ReferenceState
- **ReferencePicker.swift**: The list shown over a pill's field while it's typed into, headless, built on every caret list's (`CaretList`, TextEditing's, which keeps the highlight and says what the keys do): the field feeds it the text after each change… public PublicShapes, ReferenceChoice, ReferencePickerRow, ReferencePicker extends ReferenceState
- **ReferenceRow.swift**: The reference's row in the table of contents: what it stands for, called as its pill calls it, under the symbol of its kind, in its tint, with the list's stand-in arrow cut into the symbol (`standsIn`), so it reads as a pointer… extends ShapeRegistrar
- **ReferenceState.swift**: Per editor, for the whole file: what each reference stands for now (`state(of:)`), the one place the panel, the table of contents and the menu ask. public ReferenceState, ReferenceHeaderContent internal GoButton extends CanvasEditor, ContainerName, ReferenceStyle
- **ReferenceStyle.swift**: The pill's look. internal ReferenceStyle
- **References.swift**: A pill that stands for another shape, anywhere in the file: an arrow to it counts, for everything (queries, the table of contents, Topology's readers), as an arrow to what it stands for, so a shape too many others point at needs… public Reference, ReferenceMode, ReferenceTarget, ReferencesMenuGroup, ReferencesPlugin internal ReferenceTab extends CanvasCommand, PluginID
- **ReferencesPlugin**: References: the Reference tool (R), which places an empty pill and types into it, and the pill: a capsule whose symbol is the kind of what it stands for and…
- **reference**: A pill that stands for another shape, anywhere in the file: an arrow to it counts, for everything (queries, the table of contents, Topology's readers), as an…

### Links (the first uses the second)

1. PillColors.swift -> ReferenceStyle.swift
2. ReferenceAnswers.swift -> PillColors.swift
3. ReferenceAnswers.swift -> ReferenceInterpreting.swift
4. ReferenceAnswers.swift -> ReferencePanel.swift
5. ReferenceAnswers.swift -> References.swift
6. ReferenceAnswers.swift -> ReferenceState.swift
7. ReferenceAnswers.swift -> ReferenceStyle.swift
8. ReferenceButtons.swift -> References.swift
9. ReferenceButtons.swift -> ReferenceState.swift
10. ReferenceButtons.swift -> ReferenceStyle.swift
11. ReferenceCondition.swift -> ReferenceAnswers.swift
12. ReferenceCondition.swift -> References.swift
13. ReferenceDefinition.swift -> PillColors.swift
14. ReferenceDefinition.swift -> ReferenceAnswers.swift
15. ReferenceDefinition.swift -> ReferenceCondition.swift
16. ReferenceDefinition.swift -> ReferenceDrawing.swift
17. ReferenceDefinition.swift -> ReferenceEditing.swift
18. ReferenceDefinition.swift -> ReferenceEdits.swift
19. ReferenceDefinition.swift -> References.swift
20. ReferenceDefinition.swift -> ReferenceState.swift
21. ReferenceDefinition.swift -> ReferenceStyle.swift
22. ReferenceDrawing.swift -> PillColors.swift
23. ReferenceDrawing.swift -> ReferenceAnswers.swift
24. ReferenceDrawing.swift -> ReferenceCondition.swift
25. ReferenceDrawing.swift -> References.swift
26. ReferenceDrawing.swift -> ReferenceState.swift
27. ReferenceDrawing.swift -> ReferenceStyle.swift
28. ReferenceEditing.swift -> ReferenceCondition.swift
29. ReferenceEditing.swift -> ReferenceDrawing.swift
30. ReferenceEditing.swift -> ReferenceEdits.swift
31. ReferenceEditing.swift -> ReferenceInterpreting.swift
32. ReferenceEditing.swift -> ReferencePath.swift
33. ReferenceEditing.swift -> ReferencePicker.swift
34. ReferenceEditing.swift -> References.swift
35. ReferenceEditing.swift -> ReferenceState.swift
36. ReferenceEditing.swift -> ReferenceStyle.swift
37. ReferenceEdits.swift -> ReferenceDrawing.swift
38. ReferenceEdits.swift -> References.swift
39. ReferenceEdits.swift -> ReferenceStyle.swift
40. ReferenceInterpreting.swift -> ReferenceEdits.swift
41. ReferenceInterpreting.swift -> References.swift
42. ReferenceInterpreting.swift -> ReferenceState.swift
43. ReferenceInterpreting.swift -> ReferenceStyle.swift
44. ReferenceMismatch.swift -> ReferenceState.swift
45. ReferenceMismatch.swift -> ReferenceStyle.swift
46. ReferencePanel.swift -> ReferenceCondition.swift
47. ReferencePanel.swift -> ReferenceDefinition.swift
48. ReferencePanel.swift -> ReferenceInterpreting.swift
49. ReferencePanel.swift -> ReferencePath.swift
50. ReferencePanel.swift -> References.swift
51. ReferencePanel.swift -> ReferenceState.swift
52. ReferencePanel.swift -> ReferenceStyle.swift
53. ReferencePath.swift -> ReferenceState.swift
54. ReferencePicker.swift -> ReferenceEdits.swift
55. ReferencePicker.swift -> ReferenceState.swift
56. ReferencePicker.swift -> ReferenceStyle.swift
57. reference -> References.swift
58. ReferenceRow.swift -> ReferenceCondition.swift
59. ReferenceRow.swift -> ReferenceDefinition.swift
60. ReferenceRow.swift -> ReferencePath.swift
61. ReferenceRow.swift -> References.swift
62. ReferenceRow.swift -> ReferenceState.swift
63. ReferenceRow.swift -> ReferenceStyle.swift
64. References.swift -> ReferenceMismatch.swift
65. References.swift -> ReferencePath.swift
66. References.swift -> ReferenceStyle.swift
67. ReferencesPlugin -> reference
68. ReferencesPlugin -> References.swift
69. ReferenceState.swift -> PillColors.swift
70. ReferenceState.swift -> ReferenceCondition.swift
71. ReferenceState.swift -> References.swift
72. ReferenceState.swift -> ReferenceStyle.swift
73. ReferenceStyle.swift -> ReferenceCondition.swift
