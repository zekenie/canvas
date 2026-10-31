import Adornments
import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import DetailPanel
import Keyboard
import Selection
import SlashCommands
import TableOfContents
import TestKit
import Titles

@MainActor let titlesTests = Suite("Titles", [
    test("a kind opts in with one line; its shapes may have no title, and a blank one is none; kinds that don't opt in have none") {
        let editor = try titleEditor()
        let named = editor.add(Plaque(plaqueFrame), named: "Lobby")
        let unnamed = editor.add(Plaque(plaqueFrame))
        let blank = editor.add(Plaque(plaqueFrame), named: " \n ")
        let box = editor.add(Box(plaqueFrame))
        expectEqual([named, unnamed, blank, box].map(editor.title), ["Lobby", nil, nil, nil])
    },
    test("a title reads on one line wherever it shows: the lookup, the row, the pill") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(plaqueFrame), named: "  Front\n\ndesk\t")
        expectEqual(editor.title(id), "Front desk")
        expectEqual(try require(editor.tableOfContents).entries.map { $0.label?.text }, ["Front desk"])
    },
    test("a title may be derived: another plugin titles a kind it doesn't register from its props, and it follows them") {
        let editor = try titleEditor([CardsPlugin(), CardTitlesPlugin()])
        let card = editor.add(Card(plaqueFrame, text: "Hello"))
        expectEqual(editor.title(card), "Hello")
        editor.transact { $0.update(card, as: Card.self) { $0.props.text = "" } }
        expectEqual(editor.title(card), nil)
    },
    test("a kind has one title: a second plugin titling it is a conflict") {
        expectThrows(RegistryError.conflict(point: "ShapeTitles", key: "plaque", plugins: ["plaques", "more"])) {
            _ = try titleEditor([Contributor(id: "more") { $0.title(Plaque.self) { _ in "Another" } }])
        }
    },
    test("opting in needs Titles, and the table of contents, unless the kind's rows keep their own names; Titles needs Adornments, which lays out its pill") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeTitles", owner: .titles, contributor: "plaques")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), PlaquesPlugin(), TableOfContentsPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ContentsTitles", owner: .tableOfContents, contributor: "plaques")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), PlaquesPlugin(), SlashCommandsPlugin(), TitlesPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeAdornments", owner: .adornments, contributor: .titles)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), SlashCommandsPlugin(), TitlesPlugin()])
        }
        _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), AdornmentsPlugin(), SlashCommandsPlugin(), TitlesPlugin(),
                                   Contributor(id: "box-titles") { $0.title(Box.self, contents: false) { _ in "Box" } }])
    },
    test("a title Titles keeps is its property: in the kind's schema with its bounds and owner, and in the report") {
        let registry = try titleEditor().registry
        let title = try require(registry.schema(for: Plaque.kind)?.json["properties"]?["title"])
        expectEqual(title, ["type": "string", "description": "What the shape is called.", "minLength": 1, "maxLength": 80,
                            "x-canvas-owner": "titles"])
        expectEqual(registry.schema(for: Plaque.kind)?.json["required"], ["frame"], "no default, and not required: nil until named")
        expectEqual(registry.properties(for: Plaque.kind), ["title"])
        expectEqual(registry.owner(of: TitleProperty.key), .titles)
        expect(registry.report.contains("plaques            shape plaque · tool plaque · shortcut P → tool plaque · property title → plaque · ShapeTitles → plaque"),
               registry.report)
    },
    test("a derived title isn't a property: the kind's schema doesn't have it") {
        let registry = try titleEditor([CardsPlugin(), CardTitlesPlugin()]).registry
        expectEqual(registry.properties(for: Card.kind), [])
        expectEqual(registry.schema(for: Card.kind)?.json["properties"]?["title"], nil)
    },
    test("another plugin gives a kind it doesn't register a title Titles keeps, one line") {
        let registry = try titleEditor([Contributor(id: "box-titles") { $0.title(Box.self) }]).registry
        expectEqual(registry.properties(for: Box.kind), ["title"])
        expect(registry.report.contains("box-titles         property title → box · ShapeTitles → box · ContentsTitles → box"), registry.report)
        var box = ShapeRecord(Box(plaqueFrame))
        box[TitleProperty.self] = "Crate"
        expectEqual(registry.title(of: AnyShapeRecord(box)), "Crate")
    },
    test("a title past 80 characters (code points) breaks the kind's schema, and is kept all the same; a blank one is none, and never kept") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(plaqueFrame), named: String(repeating: "a", count: 80))
        @MainActor func violations() throws -> [SchemaViolation] { editor.registry.schemaViolations(of: try require(editor.document[id])) }
        expectEqual(try violations(), [])
        editor.rename(id, String(repeating: "a", count: 81))
        expectEqual(editor.name(id)?.count, 81, "kept: a warning's for Validation to give, not a refusal")
        expectEqual(try violations(), [SchemaViolation(path: [.member("title")], keyword: "maxLength",
                                                       message: "Title is 81 characters long, and should be at most 80.")])
        // A thumbs-up with a skin tone is one character on screen, and two code points.
        editor.rename(id, String(repeating: "👍🏽", count: 41))
        expectEqual(try violations().map(\.message), ["Title counts as 82 characters (41 shown), and should be at most 80."])
        for blank in ["", "   ", " \n\t"] {
            editor.rename(id, "Lobby")
            editor.rename(id, blank)
            expectEqual(editor.name(id), nil, "\(blank.debugDescription) is no title, so none is kept")
            expectEqual(try violations(), [], "untitled: nothing to check")
        }
    },
    test("titles fold as they read: whitespace runs to one space, trimmed; blank is none") {
        expectEqual(TitleProperty.folded("  Front\n\ndesk\t"), "Front desk")
        expectEqual(TitleProperty.folded("Lobby"), "Lobby")
        expectEqual(TitleProperty.folded(" \n "), nil)
        expectEqual(TitleProperty.folded(""), nil)
        expectEqual(TitleProperty.folded(nil), nil)
    },
    test("a title folds as the rule says, whether it's read as it's written or folded again: seeded, from ASCII and beyond") {
        // Every kind of whitespace a title may hold, one line or several, and what's around it.
        let pieces = ["a", "Z", "7", "-", " ", "  ", "\t", "\n", "\r\n", "\u{0B}", "\u{0C}", "\r", "\u{1F}", "\u{7F}", "\u{85}",
                      "\u{A0}", "\u{2003}", "\u{3000}", "é", "日", "👍🏽"]
        var random = SplitMix(state: 20_260_928)
        for _ in 0..<5_000 {
            let title = (0..<Int.random(in: 0...8, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
            let rule = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            expectEqual(TitleProperty.folded(title), rule.isEmpty ? nil : rule, "\(title.debugDescription)")
        }
        expectEqual(TitleProperty.folded("Title 5004"), "Title 5004")
        expectEqual(TitleProperty.folded("Title  5004"), "Title 5004")
        expectEqual(TitleProperty.folded(" Title"), "Title")
        expectEqual(TitleProperty.folded("Title\u{A0}5004"), "Title 5004", "a no-break space is whitespace too")
    },
    test("a kind's title is derived when another plugin makes it from what the kind keeps; named only, or none, it isn't") {
        let registry = try titleEditor([CardsPlugin(), CardTitlesPlugin(), Contributor(id: "disc-titles") { r in
            // Named, and derived for the discs nobody named.
            r.optIn(Disc.self, to: TitleProperty.self)
            r.title(Disc.self) { TitleProperty.folded($0[TitleProperty.self]) ?? "Disc" }
        }]).registry
        expect(!registry.titleIsDerived(Plaque.kind), "named: title()")
        expect(registry.titleIsDerived(Card.kind), "derived: title { … }")
        expect(registry.titleIsDerived(Disc.kind), "both")
        expect(!registry.titleIsDerived(Box.kind), "none")
        expectEqual(registry.properties(for: Disc.kind), [TitleProperty.key], "a derived title that can be named too")
        var disc = AnyShapeRecord(ShapeRecord(Disc(plaqueFrame)))
        expectEqual(registry.title(of: disc), "Disc")
        disc[TitleProperty.self] = "  Moon "
        expectEqual(registry.title(of: disc), "Moon")
        disc[TitleProperty.self] = " "
        expectEqual(registry.title(of: disc), "Disc", "a blank name falls back to the derived one")
    },
    test("a title is two lines in the report, its own and its row's name; without the row's, one") {
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), AdornmentsPlugin(), SlashCommandsPlugin(),
                                              TitlesPlugin(), TableOfContentsPlugin(), Contributor(id: "fixture-titles") { r in
            r.title(Box.self) { _ in "Box" }
            r.title(Disc.self, pill: false, contents: false) { _ in "Disc" }
        }])
        expectEqual(registry.report, """
        core               tool hand · command undo · command redo · command zoomIn in ViewMenu.Zoom · command zoomOut in ViewMenu.Zoom · command zoomToActualSize in ViewMenu.Zoom · command zoomToFit in ViewMenu.Zoom · command pageUp · command pageDown · command scrollToStart · command scrollToEnd
        keyboard           service KeyboardState · tool tips · menu keys · keyboard help · key strokes · key releases · shortcut H → tool hand · shortcut Space → Pan · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo · shortcut Q → Tool Lock · shortcut ⌘= → command zoomIn · shortcut ⌘- → command zoomOut · shortcut = → command zoomIn · shortcut - → command zoomOut · shortcut ⌘0 → command zoomToActualSize · shortcut ⇧0 → command zoomToActualSize · shortcut ⇧1 → command zoomToFit · shortcut ⇞ → command pageUp · shortcut ⇟ → command pageDown · shortcut ↖ → command scrollToStart · shortcut ↘ → command scrollToEnd · key hint ⇧ Drag Move Along One Axis · key hint ⌘ Scroll Zoom
        selection          service SelectionState · service RefusalShake · tool select · shortcut V → tool select · default tool select · outlines · overlay GroupFocusOverlay · overlay HandlesOverlay · overlay PartFocusOverlay · key hint ⇧ or ⌘ Click Add or Remove From Selection · key hint ⌘ Drag Select Shapes Wholly in the Box · key hint ⌥ Drag Drag a Copy · key hint ⇧ Resize Keep Proportions · key hint ⌥ Resize Resize From the Center · command shapes · accessible order · accessible parts · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack in NavigationSection · shortcut ⌘[ → command goBack · command goForward after goBack in NavigationSection · shortcut ⌘] → command goForward · command openSelection in NavigationSection · shortcut ⌘↓ → command openSelection · shortcut ↩ → Open Selection · shortcut ⌤ → Open Selection · shortcut ⌥↩ → Open Selection · press focused · command zoomToSelection in ViewMenu.Zoom · shortcut ⇧2 → command zoomToSelection · command smartMagnify · shortcut ← → Nudge or Pan · shortcut ⇧← → Nudge or Pan · shortcut → → Nudge or Pan · shortcut ⇧→ → Nudge or Pan · shortcut ↑ → Nudge or Pan · shortcut ⇧↑ → Nudge or Pan · shortcut ↓ → Nudge or Pan · shortcut ⇧↓ → Nudge or Pan · shortcut ⌥← → Resize · shortcut ⌥⇧← → Resize · shortcut ⌥→ → Resize · shortcut ⌥⇧→ → Resize · shortcut ⌥↑ → Resize · shortcut ⌥⇧↑ → Resize · shortcut ⌥↓ → Resize · shortcut ⌥⇧↓ → Resize · shortcut ⌥⇥ → Next Part · shortcut ⌥⇧⇥ → Previous Part · shortcut ⇥ → Next Shape · shortcut ⇧⇥ → Previous Shape · shortcut ⌥⌘← → Select Nearest Shape · shortcut ⌥⇧⌘← → Add Nearest Shape to Selection · shortcut ⌥⌘→ → Select Nearest Shape · shortcut ⌥⇧⌘→ → Add Nearest Shape to Selection · shortcut ⌥⌘↑ → Select Nearest Shape · shortcut ⌥⇧⌘↑ → Add Nearest Shape to Selection · shortcut ⌥⌘↓ → Select Nearest Shape · shortcut ⌥⇧⌘↓ → Add Nearest Shape to Selection
        fixtures           shape box · shape disc · shape tag
        adornments         service AdornmentState · service ChipFade · layout input adornment-lead · overlay AdornmentOverlay · CanvasButtons · DecorationHits
        slash-commands     service SlashCommandState · key hint / at a Line's Start Run a Command
        titles             property title · adornment TitlePill → every shape with a title pill · adornment TitleTab → every shape with a title tab · /title → every shape holding title · overlay TitleCoverOverlay · accessibility → every shape with a title
        table-of-contents  service ContentsState · host sidebar
        fixture-titles     ShapeTitles → box · ContentsTitles → box · ShapeTitles → disc
        """)
    },
])

@MainActor let contentsTests = Suite("Titles in the table of contents", [
    test("a title names its shape's row, which keeps its kind's symbol and badge; untitled, the row is the kind's own") {
        let editor = try titleEditor()
        editor.add(Plaque(plaqueFrame, caption: "Welcome"), named: "Lobby")
        let unnamed = editor.add(Plaque(plaqueFrame, caption: "Exit"))
        let rows = try require(editor.tableOfContents).entries
        expectEqual(rows.map { $0.label?.text }, ["Lobby", "Exit"])
        expectEqual(rows.map { $0.label?.badge }, ["B", "B"])
        expectEqual(rows.map(\.symbol), ["rectangle.portrait", "rectangle.portrait"])

        editor.rename(unnamed, "Fire exit")
        expectEqual(try require(editor.tableOfContents).entries.map { $0.label?.text }, ["Lobby", "Fire exit"])
    },
    test("a kind with no row of its own is listed by its title, else by its tool's label") {
        let editor = try titleEditor([CardsPlugin(), CardTitlesPlugin()])
        editor.add(Card(plaqueFrame, text: "Hello"))
        editor.add(Card(plaqueFrame))
        let rows = try require(editor.tableOfContents).entries
        expectEqual(rows.map { $0.label?.text }, ["Hello", "Card"])
        let symbol = try require(editor.registry.tools.first { $0.label == "Card" }).systemImage
        expectEqual(rows.map(\.symbol), [symbol, symbol], "the Card tool's")
    },
    test("`contents: false` keeps the kind's row as it is") {
        let editor = try titleEditor([Contributor(id: "box-titles") { $0.title(Box.self, contents: false) { _ in "Titled box" } }])
        let box = editor.add(Box(plaqueFrame))
        expectEqual(editor.title(box), "Titled box")
        expectEqual(try require(editor.tableOfContents).entries.map { $0.label?.text }, ["box"])
    },
])

/// A reproducible stream of choices.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
