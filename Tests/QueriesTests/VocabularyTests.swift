import Canvas
import CanvasTesting
import Queries
import QueryLanguage
import TestKit
import Topology

@MainActor let vocabularyTests = Suite("Vocabulary", [
    test("kinds in registry order, with labels, names, boards and attributes") {
        let vocabulary = try QueryVocabulary(registry: Registry(plugins: queryPlugins()))
        expectEqual(vocabulary.kinds.map(\.kind), ["chore", "pocket", "tile", "link"])
        expectEqual(vocabulary.kinds.map(\.label), ["Task", "pocket", "Tile", "link"])
        expectEqual(vocabulary.kinds.map(\.names), [.named, .named, .derived, .none])
        expectEqual(vocabulary.kinds.map(\.holdsBoard), [false, true, false, false])
        expectEqual(vocabulary.kinds.map(\.holdsShapes), [false, true, false, false])
        expectEqual(vocabulary.kinds.map(\.boardName), [nil, "Untitled Pocket", nil, nil])
        let chore = try require(vocabulary.kind("chore"))
        expectEqual(chore.attributes.map(\.name), ["caption", "due", "estimate", "flag", "meta", "note", "ratio", "shout", "status", "tags"])
        expectEqual(chore.attributes.map(\.compactType), ["text (≤ 40)", "date (YYYY-MM-DD or date-time)", "integer ≥ 0", "true|false",
                                                          "JSON {owner, size}", "text", "number", "text", "todo|doing|blocked|done", "JSON [text]"])
        expectEqual(chore.attribute("caption")?.isName, true)
        expectEqual(chore.attribute("shout")?.reads, "read in capitals")
        expectEqual(chore.attribute("shout")?.mediaType, shoutType)
        expectEqual(chore.attribute("note")?.reads, nil)
        expect(chore.attribute("frame") == nil, "where a shape is isn't an attribute")
        let tile = try require(vocabulary.kind("tile"))
        expectEqual(tile.attributes.map(\.name), ["caption", "finish", "label"])
        expectEqual(tile.attribute("caption")?.compactType, "text", "a derived name isn't in the schema: text")
        expectEqual(vocabulary.kind("link")?.attributes.map(\.name), ["from", "grade", "to"])
        expectEqual(vocabulary.nameAttribute, "caption")
    },
    test("edge types in the tree's order, and words, the language's then plugins'") {
        let vocabulary = try QueryVocabulary(registry: Registry(plugins: queryPlugins()))
        expectEqual(vocabulary.edgeTypes.map(\.type), [WireEdge.id, HotWireEdge.id])
        expectEqual(vocabulary.edgeTypes.map(\.parent), [nil, WireEdge.id])
        expectEqual(vocabulary.edgeTypes.map(\.depth), [0, 1])
        expectEqual(vocabulary.words.map(\.word), Word.allCases.map(\.rawValue) + ["starred", "heavy", "audited", "wired-to"])
        expectEqual(Set(vocabulary.words.prefix(Word.allCases.count).map(\.from)), [.queries])
        let wired = try require(vocabulary.words.last)
        expectEqual(wired.form, ":wired-to(S)")
        expectEqual(wired.takes, "shapes")
        expectEqual(wired.from, "words")
        expectEqual(vocabulary.words.first { $0.word == "starred" }?.form, ":starred")
        expectEqual(vocabulary.words.first { $0.word == Word.edgeTo.rawValue }?.form, ":edge-to(S[, types])")
    },
    test("its text, the <vocabulary> block") {
        let vocabulary = try QueryVocabulary(registry: Registry(plugins: queryPlugins()))
        expectEqual(vocabulary.text, """
            Kinds (the id to write; what the app calls it; its attributes and what each takes):
            - chore (Task; titled): caption text (≤ 40), due date (YYYY-MM-DD or date-time), estimate integer ≥ 0, flag true|false, \
            meta JSON {owner, size}, note text, ratio number, shout text (read in capitals), status todo|doing|blocked|done, tags JSON [text]
            - pocket (pocket; titled; holds a board of shapes): caption text (≤ 40)
            - tile (Tile; titled from what it holds): caption text, finish matte|glossy, label text
            - link (link; untitled): from text, grade plain|hot|loose, to text
            Edge types (each takes in those indented under it):
            - wire — a link, from the shape it starts on to the shape it ends on
              - hot-wire — a link graded hot
            Pseudo-classes plugins add:
            - :starred — someone starred it. Example: :starred
            - :heavy — a chore of estimate 5 or more. Example: chore:heavy
            - :audited — someone flagged it. Example: :audited
            - :wired-to(S) — it has a wire to a shape the query matches. Example: :wired-to("Pantry")
            """)
    },
    test("a kind that holds shapes on its board holds shapes, not a board, and says so; one that owns a board says that") {
        let vocabulary = try QueryVocabulary(registry: Registry(plugins: queryPlugins(more: [CorralsPlugin(), corralCaptionsPlugin()])))
        let corral = try require(vocabulary.kind(Corral.kind))
        expectEqual(corral.holdsShapes, true)
        expectEqual(corral.holdsBoard, false)
        expectEqual(corral.boardName, nil, "an untitled one is called by its label")
        expectEqual(vocabulary.kind(Pocket.kind)?.holdsShapes, true)
        expectEqual(vocabulary.kind(Pocket.kind)?.holdsBoard, true)
        expectEqual(vocabulary.kind(Chore.kind)?.holdsShapes, false)
        expect(vocabulary.text.contains("- corral (corral; titled; holds shapes): caption text (≤ 40)"), vocabulary.text)
        expect(vocabulary.text.contains("- pocket (pocket; titled; holds a board of shapes)"), vocabulary.text)
    },
    test("without plugins' words, names or edge types, it says so little") {
        let vocabulary = try QueryVocabulary(registry: Registry(plugins: [ChoresPlugin(), PocketsPlugin(), TopologyPlugin(), QueriesPlugin()]))
        expectEqual(vocabulary.text, """
            Kinds (the id to write; what the app calls it; its attributes and what each takes):
            - chore (Task; untitled): due date (YYYY-MM-DD or date-time), estimate integer ≥ 0, flag true|false, meta JSON {owner, size}, \
            note text, ratio number, status todo|doing|blocked|done, tags JSON [text]
            - pocket (pocket; untitled; holds a board of shapes)
            """)
        expectEqual(vocabulary.kind("pocket")?.boardName, "pocket", "without the board names point, the label")
        expectEqual(vocabulary.nameAttribute, nil)
        expectEqual(vocabulary.words.map(\.word), Word.allCases.map(\.rawValue))
    },
    test("an editor's is made once, on first use, and is the registry's") {
        let h = try shelf()
        let queries = try require(h.editor.queries)
        expectEqual(queries.vocabulary.text, try QueryVocabulary(registry: Registry(plugins: queryPlugins())).text)
        expectEqual(queries.vocabulary.kinds.count, 4)
    },
    // The points, their checks and the report.
    test("points: the registry's report names each contribution") {
        let report = try Registry(plugins: queryPlugins()).report
        for line in ["query engine", "query names", "query board names", "query word :starred", "query word :heavy", "query word :audited",
                     "query word :wired-to", "query text text/x-shout"] {
            expect(report.contains(line), "the report says \(line):\n\(report)")
        }
    },
    test("points: whether the app answers queries is QueriesPlugin's mark, read without the report") {
        expect(try Registry(plugins: queryPlugins()).answersQueries)
        expect(try Registry(plugins: [QueriesPlugin()]).answersQueries, "with nothing that fills its points")
        expect(try !Registry(plugins: [ChoresPlugin(), PocketsPlugin(), TopologyPlugin()]).answersQueries)
    },
    test("points: names and board names: one plugin each") {
        expectThrows(RegistryError.conflict(point: "QueryNames", key: "query names", plugins: ["names", "more-names"])) {
            _ = try Registry(plugins: queryPlugins(more: [Contributor(id: "more-names") { registrar in
                registrar.queryNames(attribute: "label", source: { _, _ in .none }, named: { _ in nil }, derived: { _, _ in nil }, fold: { $0 })
            }]))
        }
        expectThrows(RegistryError.conflict(point: "QueryBoardNames", key: "query board names", plugins: ["board-names", "more-boards"])) {
            _ = try Registry(plugins: queryPlugins(more: [Contributor(id: "more-boards") { $0.queryBoardNames { _, _ in nil } }]))
        }
    },
    test("points: a names attribute is a word a query writes bare") {
        expectThrows(RegistryError.invalid(point: "QueryNames", reason:
                        "bad-names names shapes by the attribute \"a label\", which a query can't write: a letter or _, then letters, digits, - and _")) {
            _ = try Registry(plugins: queryPlugins(names: false, more: [Contributor(id: "bad-names") { registrar in
                registrar.queryNames(attribute: "a label", source: { _, _ in .none }, named: { _ in nil }, derived: { _, _ in nil }, fold: { $0 })
            }]))
        }
    },
    test("points: a word is lowercase words joined by hyphens, none of the language's or its inventions, once") {
        func adding(_ word: String) -> Contributor {
            Contributor(id: "more-words") { registrar in
                registrar.queryPseudoClass(word, "x", example: ":x", prepare: { _ in () }, matches: { _, _ in .no })
            }
        }
        for (word, why) in [("Shiny", "which isn't lowercase words joined by hyphens"), ("shiny--thing", "which isn't lowercase words joined by hyphens"),
                            ("2nd", "which isn't lowercase words joined by hyphens"),
                            ("inside", "one of the language's own words"),
                            ("parent-of", "which the language refuses as a word people reach for; pick another"),
                            ("nth-thing", "which the language refuses as a word people reach for; pick another")] {
            expectThrows(RegistryError.invalid(point: "QueryWords", reason: "more-words adds :\(word), \(why)")) {
                _ = try Registry(plugins: queryPlugins(more: [adding(word)]))
            }
        }
        expectThrows(RegistryError.conflict(point: "QueryWords", key: ":starred", plugins: ["words", "more-words"])) {
            _ = try Registry(plugins: queryPlugins(more: [adding("starred")]))
        }
        _ = try Registry(plugins: queryPlugins(more: [adding("shiny-thing2")]))
    },
    test("points: a relation follows declared edge types, at least one") {
        func relation(_ types: [EdgeTypeID]) -> Contributor {
            Contributor(id: "relations") { $0.queryRelation("tied-to", "x", example: ":tied-to(*)", types: types, direction: .incoming) }
        }
        expectThrows(RegistryError.invalid(point: "QueryWords", reason: "relations adds :tied-to, a relation over edge type tether, which no installed plugin declares")) {
            _ = try Registry(plugins: queryPlugins(more: [relation([tether])]))
        }
        expectThrows(RegistryError.invalid(point: "QueryWords", reason: "relations adds :tied-to, a relation over no edge type")) {
            _ = try Registry(plugins: queryPlugins(more: [relation([])]))
        }
        _ = try Registry(plugins: queryPlugins(more: [relation([HotWireEdge.id])]))
    },
    test("points: one text format per media type, and the points need Queries") {
        let again = Contributor(id: "again") { registrar in
            registrar.queryTextFormat(mediaType: shoutType, describes: "loud", prepare: { _ in () }, read: { text, _ in text })
        }
        expectThrows(RegistryError.conflict(point: "QueryTextFormats", key: "query text text/x-shout", plugins: ["shouts", "again"])) {
            _ = try Registry(plugins: queryPlugins(more: [again]))
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "QueryBoardNames", owner: .queries, contributor: "board-names")) {
            _ = try Registry(plugins: [PocketsPlugin(), boardNamesPlugin()])
        }
    },
])
