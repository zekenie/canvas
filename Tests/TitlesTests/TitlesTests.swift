import Adornments
import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Keyboard
import Selection
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
    test("a title may be derived: a bridge titles another plugin's kind from its props, and it follows them") {
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
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), PlaquesPlugin(), TitlesPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeAdornments", owner: .adornments, contributor: .titles)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), TitlesPlugin()])
        }
        _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), AdornmentsPlugin(), TitlesPlugin(),
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
    test("a bridge gives another plugin's kind a title Titles keeps, one line") {
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
        expectEqual(try violations().map(\.message), ["Title is 82 characters long as JSON Schema counts them (41 as shown), and should be at most 80."])
        for blank in ["", "   ", " \n\t"] {
            editor.rename(id, "Lobby")
            editor.rename(id, blank)
            expectEqual(editor.name(id), nil, "\(blank.debugDescription) is no title, so none is kept")
            expectEqual(try violations(), [], "untitled: nothing to check")
        }
    },
    test("a title is two lines in the report, its own and its row's name; without the row's, one") {
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), AdornmentsPlugin(), TitlesPlugin(),
                                              TableOfContentsPlugin(), Contributor(id: "fixture-titles") { r in
            r.title(Box.self) { _ in "Box" }
            r.title(Disc.self, pill: false, contents: false) { _ in "Disc" }
        }])
        expectEqual(registry.report, """
        core               tool hand · command undo · command redo
        keyboard           service KeyboardState · key strokes · shortcut H → tool hand · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo
        selection          service SelectionState · tool select · shortcut V → tool select · default tool select · outlines · overlay HandlesOverlay · command delete · shortcut ⌫ → command delete · shortcut ⌦ → command delete · command selectAll · shortcut ⌘A → command selectAll · command goBack · shortcut ⌘[ → command goBack · shortcut ↩ → Edit Selection · shortcut ⌤ → Edit Selection
        fixtures           shape box · shape disc · shape tag
        adornments         service AdornmentState · overlay AdornmentOverlay · CanvasButtons · DecorationHits
        titles             property title · adornment TitlePill → every shape
        table-of-contents  service ContentsState
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
