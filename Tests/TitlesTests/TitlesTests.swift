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
        let named = editor.add(Plaque(plaqueFrame, name: "Lobby"))
        let unnamed = editor.add(Plaque(plaqueFrame))
        let blank = editor.add(Plaque(plaqueFrame, name: " \n "))
        let box = editor.add(Box(plaqueFrame))
        expectEqual([named, unnamed, blank, box].map(editor.title), ["Lobby", nil, nil, nil])
    },
    test("a title reads on one line wherever it shows: the lookup, the row, the pill") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(plaqueFrame, name: "  Front\n\ndesk\t"))
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
    test("opting in needs Titles, and the table of contents, unless the kind's rows keep their own names") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeTitles", owner: .titles, contributor: "plaques")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), PlaquesPlugin(), TableOfContentsPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ContentsTitles", owner: .tableOfContents, contributor: "plaques")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), PlaquesPlugin(), TitlesPlugin(), DetailPanelPlugin()])
        }
        _ = try Registry(plugins: [FixturesPlugin(), TitlesPlugin(), Contributor(id: "box-titles") { $0.title(Box.self, contents: false) { _ in "Box" } }])
    },
    test("a title is two lines in the report, its own and its row's name; without the row's, one") {
        let registry = try Registry(plugins: [FixturesPlugin(), TitlesPlugin(), TableOfContentsPlugin(), Contributor(id: "fixture-titles") { r in
            r.title(Box.self) { _ in "Box" }
            r.title(Disc.self, pill: false, contents: false) { _ in "Disc" }
        }])
        expectEqual(registry.report, """
        core               tool hand
        fixtures           shape box · shape disc · shape tag
        titles             service TitleState · overlay TitleOverlay
        table-of-contents  service ContentsState
        fixture-titles     ShapeTitles → box · ContentsTitles → box · ShapeTitles → disc
        """)
    },
])

@MainActor let contentsTests = Suite("Titles in the table of contents", [
    test("a title names its shape's row, which keeps its kind's symbol and badge; untitled, the row is the kind's own") {
        let editor = try titleEditor()
        editor.add(Plaque(plaqueFrame, name: "Lobby", caption: "Welcome"))
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
