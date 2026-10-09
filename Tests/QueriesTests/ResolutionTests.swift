import Canvas
import CanvasTesting
import Queries
import QueryLanguage
import TestKit

@MainActor let resolutionTests = Suite("Resolution", [
    test("what resolves, and the query it ran") {
        let h = try shelf()
        for text in ["*", "chore", #""Alpha""#, "#\(uuid(1))", "chore[estimate>3]:starred", #"pocket > chore, "Pantry" *"#,
                     #":inside("Pantry")"#, #"pocket:has(> chore[status=done])"#, ":top-level", ":current-board",
                     #":edge-to("Alpha", wire|only hot-wire)"#, #":between(chore, pocket, tether)"#, ":dangling(wire)",
                     #":contains("alp")"#, #":not(:is(chore, tile))"#, #":wired-to("Pantry")"#, ":audited", ":heavy",
                     "[caption]", "tile[caption=Tiled]", "link[grade=loose]"] {
            _ = try plan(text, on: h)
        }
        expectEqual(try plan(#"pocket>chore ,"Pantry"   *"#, on: h).canonical, #"pocket > chore, "Pantry" *"#)
        expectEqual(try plan("chore:TOP-LEVEL", on: h).text, "chore:TOP-LEVEL", "the query as sent")
    },
    test("a compound's nodes run cheapest first, and != is not =") {
        let h = try shelf()
        expectEqual(try plan(#"chore[estimate>3]:audited:inside(pocket):starred"#, on: h).description, """
            all of
              :starred
              kind chore
              inside
                kind pocket
              [estimate] of chore integer: > 3
              :audited
            """)
        expectEqual(try plan("chore[status!=done]", on: h).description, """
            all of
              kind chore
              not
                [status] of chore text todo|doing|blocked|done: = "done"
            """)
        expectEqual(try plan(#"pocket "Beta" > chore"#, on: h).description, """
            all of
              kind chore
              directly inside
                all of
                  titled "Beta", a container
                  inside, at any depth
                    kind pocket
            """)
        expectEqual(try plan(#""Beta":has(*), :inside("Alpha"), :not("Pantry")"#, on: h).description, """
            any of
              all of
                titled "Beta", a container
                has
                  every shape
              inside
                titled "Alpha", a container
              not
                titled "Pantry"
            """)
    },
    test("kinds: exact, else did you mean, by id or by what the app calls them") {
        let h = try shelf()
        expectRefused([
            Refused("chor", .unknownKind, "chor isn't a kind.", hint: "Did you mean chore (a Task)?", at: 0, 4),
            Refused("Chore", .unknownKind, "Chore isn't a kind.", hint: "Did you mean chore (a Task)?", at: 0, 5),
            Refused("task[estimate>1]", .unknownKind, "task isn't a kind.", hint: "Did you mean chore (a Task)?", at: 0, 4),
            Refused("pockt > *", .unknownKind, "pockt isn't a kind.", hint: "Did you mean pocket?", at: 0, 5),
            Refused("estimate", .unknownKind, "estimate isn't a kind.", hint: "Attributes are tested in brackets: [estimate].", at: 0, 8),
            Refused("wire", .unknownKind, "wire is an edge type, not a kind.", hint: ":connected-to(*, wire) finds the shapes it joins.", at: 0, 4),
            Refused("tether", .unknownKind, "tether is an edge type, not a kind.", hint: ":connected-to(*, tether) finds the shapes it joins.", at: 0, 6),
            Refused("zebra", .unknownKind, "zebra isn't a kind.", hint: "The kinds: chore, pocket, tile, link.", at: 0, 5),
            Refused(":is(chore, zebra)", .unknownKind, "zebra isn't a kind.", hint: "The kinds: chore, pocket, tile, link.", at: 11, 5),
            // A pseudo-class written without its colon.
            Refused("starred", .unknownKind, "starred isn't a kind.", hint: "A pseudo-class is written after a colon: :starred.", at: 0, 7),
            Refused("pocket > top-level", .unknownKind, "top-level isn't a kind.", hint: "A pseudo-class is written after a colon: :top-level.",
                    at: 9, 9),
        ], on: h)
    },
    test("attributes: the kind's, or some kind's") {
        let h = try shelf()
        expectRefused([
            Refused("chore[estimat=3]", .unknownAttribute, "chore has no attribute estimat.",
                    hint: "Did you mean estimate? Its attributes: caption, due, estimate, flag, meta, note, ratio, shout, status, tags.", at: 5, 11),
            Refused("[estimat=3]", .unknownAttribute, "No kind has an attribute estimat.", hint: "Did you mean estimate?", at: 0, 11),
            Refused("[zzz]", .unknownAttribute, "No kind has an attribute zzz.", at: 0, 5),
            Refused("link[caption]", .unknownAttribute, "link has no captions.", hint: "Its attributes: from, grade, to.", at: 4, 9),
            Refused("link[status=done]", .unknownAttribute, "link has no attribute status.", hint: "Its attributes: from, grade, to.", at: 4, 13),
            Refused("pocket[label]", .unknownAttribute, "pocket has no attribute label.", hint: "Its attributes: caption.", at: 6, 7),
            Refused("chore[frame]", .notBuilt, "frame is where the shape is; where shapes are isn't in the language yet.", at: 5, 7),
            Refused("[frame]", .notBuilt, "frame is where the shape is; where shapes are isn't in the language yet.", at: 0, 7),
            Refused(#"["meta.owner"=x]"#, .unknownAttribute, "No attribute is called meta.owner.",
                    hint: "A member inside an attribute is written without quotes: [meta.owner=x].", at: 0, 16),
        ], on: h)
    },
    test("words people put in brackets for what's written otherwise") {
        let h = try shelf()
        expectRefused([
            Refused("[kind=chore]", .unknownAttribute, "kind isn't an attribute: a shape's kind starts its part of the query.", hint: "chore", at: 0, 12),
            Refused("[type=chore][estimate>3]", .unknownAttribute, "type isn't an attribute: a shape's kind starts its part of the query.",
                    hint: "chore[estimate>3]", at: 0, 12),
            Refused("[id=\(uuid(11))]", .unknownAttribute, "id isn't an attribute: # and a shape's id name the shape.",
                    hint: "#\(uuid(11).uppercased())", at: 0, 41),
            Refused(#"[name="Alpha" i]"#, .unknownAttribute, "name isn't an attribute: a shape's name is its caption.",
                    hint: #"[caption="Alpha" i]"#, at: 0, 16),
            // An owner by title is hinted once the answer finds it holds shapes (HintsTests).
            Refused(#"[board="Pantry"]"#, .unknownAttribute, "board isn't an attribute: what's on a board is written after the shape that owns it.",
                    at: 0, 16),
            Refused(#"chore[page=Pantry][estimate>3]"#, .unknownAttribute,
                    "page isn't an attribute: what's on a board is written after the shape that owns it.", at: 5, 13),
            Refused("chore[board=root]", .unknownAttribute, "board isn't an attribute: what's on a board is written after the shape that owns it.",
                    hint: "chore:top-level", at: 5, 12),
            Refused("[class=Task]", .unsupported, "A type isn't an attribute: a shape is found by its kind, its title, its id, an attribute or a word.",
                    hint: #"Name a kind, or find the word: :contains("Task")."#, at: 0, 12),
            // The hint is a query that reads: a kind by its id, and a head after the space.
            Refused("[kind=task]", .unknownAttribute, "kind isn't an attribute: a shape's kind starts its part of the query.", hint: "chore", at: 0, 11),
            Refused("[type=Pockt] > *", .unknownAttribute, "type isn't an attribute: a shape's kind starts its part of the query.",
                    hint: "pocket", at: 0, 12),
            Refused("[kind=zebra]", .unknownAttribute, "kind isn't an attribute: a shape's kind starts its part of the query.", at: 0, 12),
            Refused("[type=wire]", .unknownAttribute, "type isn't an attribute: a shape's kind starts its part of the query.", at: 0, 11),
            Refused(#"[board=Pantry][estimate>3]"#, .unknownAttribute,
                    "board isn't an attribute: what's on a board is written after the shape that owns it.", at: 0, 14),
        ], on: h)
        for hint in ["chore", "pocket", #""Pantry" > *[estimate>3]"#] { _ = try plan(hint, on: h) }
    },
    test("pseudo-classes: the language's, plugins', or what people reach for") {
        let h = try shelf()
        expectRefused([
            Refused(#":wired("Pantry")"#, .unknownPseudoClass, ":wired isn't a pseudo-class.",
                    hint: "Did you mean :wired-to? :wired-to(S): it has a wire to a shape the query matches.", at: 0, 6),
            Refused(":edgeto(*)", .unknownPseudoClass, ":edgeto isn't a pseudo-class.",
                    hint: "Did you mean :edge-to? :edge-to(S[, types]): has an edge to a shape S matches.", at: 0, 7),
            Refused(":starrred", .unknownPseudoClass, ":starrred isn't a pseudo-class.",
                    hint: "Did you mean :starred? :starred: someone starred it.", at: 0, 9),
            Refused("chore:estimate", .unknownPseudoClass, ":estimate isn't a pseudo-class.",
                    hint: "Attributes are tested in brackets: [estimate].", at: 5, 9),
            Refused(":flag", .unknownPseudoClass, ":flag isn't a pseudo-class.", hint: "Attributes are tested in brackets: [flag].", at: 0, 5),
            Refused("link:flag", .unknownPseudoClass, ":flag isn't a pseudo-class.", at: 4, 5),
            Refused(":pocket", .unknownPseudoClass, ":pocket isn't a pseudo-class.", hint: "A kind starts its part of the query: pocket.", at: 0, 7),
            Refused(#":parent-of("Beta")"#, .unknownPseudoClass, ":parent-of isn't a pseudo-class.",
                    hint: #"A parent has it directly inside: :has(> "Beta")."#, at: 0, 18),
            Refused(":root", .unsupported, ":root has no meaning here: no shape is the file's root.",
                    hint: "Shapes inside nothing, on the file's top board: :top-level.", at: 0, 5),
            Refused(":near(chore)", .notBuilt,
                    ":near isn't in the language yet: where shapes sit on the canvas isn't something a query can ask.", at: 0, 12),
            Refused(":qwxz", .unknownPseudoClass, ":qwxz isn't a pseudo-class.", at: 0, 5),
        ], on: h)
    },
    test("plugins' words take what they take") {
        let h = try shelf()
        expectRefused([
            Refused(":starred(chore)", .badArgument, ":starred takes no argument.", hint: ":starred", at: 0, 15),
            Refused(":wired-to", .badArgument, ":wired-to takes shapes.", hint: #":wired-to("Pantry")"#, at: 0, 9),
            Refused(":wired-to( )", .badArgument, ":wired-to takes shapes.", hint: #":wired-to("Pantry")"#, at: 0, 12),
            // A chore holds no shapes, so nothing is inside one: the hint writes them together, only.
            Refused(":wired-to(chore :starred)", .straySpace, "A space before :starred asks for shapes inside the one before it.",
                    hint: "Write them together for one shape: chore:starred.", at: 16, 8),
            Refused(":wired-to(pocket :starred)", .straySpace, "A space before :starred asks for shapes inside the one before it.",
                    hint: "Write them together for one shape: pocket:starred; for a shape inside it: pocket *:starred.", at: 17, 8),
            Refused(":wired-to(Pantry)", .unknownKind, "Pantry isn't a kind.", hint: "The kinds: chore, pocket, tile, link.", at: 10, 6),
            Refused(":wired-to(chor)", .unknownKind, "chor isn't a kind.", hint: "Did you mean chore (a Task)?", at: 10, 4),
        ], on: h)
    },
    test("edge types: declared, or in the file") {
        let h = try shelf()
        _ = try plan(":edge-from(*, tether)", on: h)
        expectEqual(try plan(":edge-to(*, wire)", on: h).description, """
            edge-to (hot-wire|wire)
              every shape
            """)
        expectEqual(try plan(":edge-to(*, only wire)", on: h).description, """
            edge-to (wire)
              every shape
            """)
        expectEqual(try plan(":dangling", on: h).description, "dangling (every type)")
        expectEqual(try plan(":end-of(link, only wire)", on: h).description, """
            end-of (wire)
              kind link
            """)
        expectEqual(try plan(#":start-of(:ends-at("Alpha"), tether)"#, on: h).description, """
            start-of (tether)
              ends-at (every type)
                titled "Alpha"
            """)
        expectRefused([
            Refused(":edge-to(*, wir)", .unknownEdgeType, "wir isn't an edge type.", hint: "Did you mean wire or hot-wire?", at: 12, 3),
            Refused(":start-of(link, wir)", .unknownEdgeType, "wir isn't an edge type.", hint: "Did you mean wire or hot-wire?", at: 16, 3),
            Refused(":edge-to(*, cable)", .unknownEdgeType, "cable isn't an edge type.", hint: "The edge types: stands-for, wire, hot-wire, tether.", at: 12, 5),
            Refused(":dangling(Wire)", .unknownEdgeType, "Wire isn't an edge type.", hint: "Did you mean wire or hot-wire?", at: 10, 4),
            Refused(#":edge-to("Alpha", chore)"#, .unknownEdgeType, "chore is a kind, not an edge type.",
                    hint: #":edge-to(:is("Alpha", chore))"#, at: 18, 5),
            Refused(#":between("Alpha", "Pantry", pocket)"#, .unknownEdgeType, "pocket is a kind, not an edge type.",
                    hint: #":between("Alpha", :is("Pantry", pocket))"#, at: 28, 6),
        ], on: h)
    },
    test("containers must hold shapes") {
        let h = try shelf()
        let notSpatial = "Being drawn within its bounds isn't something a query can ask yet."
        let holders = "The kinds that hold shapes: pocket."
        expectRefused([
            Refused("chore > *", .cannotContain, "A chore holds no shapes: nothing is inside it. \(notSpatial)", hint: holders, at: 0, 5),
            Refused("chore[estimate>3] tile", .cannotContain, "A chore holds no shapes: nothing is inside it. \(notSpatial)", hint: holders, at: 0, 5),
            Refused(":inside(tile)", .cannotContain, "A tile holds no shapes: nothing is inside it. \(notSpatial)", hint: holders, at: 8, 4),
            Refused(":inside(pocket, link)", .cannotContain, "A link holds no shapes: nothing is inside it. \(notSpatial)", hint: holders, at: 16, 4),
            Refused("chore:has(*)", .cannotContain, "A chore holds no shapes: nothing is inside it. \(notSpatial)", hint: holders, at: 0, 5),
            Refused("#\(uuid(11)) > *", .cannotContain,
                    "#\(uuid(11).uppercased()) is a chore, which holds no shapes: nothing is inside it. \(notSpatial)", hint: holders, at: 0, 37),
            // What :is and :where hold, in a container's place, is in a container's place too.
            Refused(":is(tile) *", .cannotContain, "A tile holds no shapes: nothing is inside it. \(notSpatial)", hint: holders, at: 4, 4),
            Refused(":where(chore) > *", .cannotContain, "A chore holds no shapes: nothing is inside it. \(notSpatial)", hint: holders, at: 7, 5),
            Refused(":inside(:is(pocket, link))", .cannotContain, "A link holds no shapes: nothing is inside it. \(notSpatial)", hint: holders,
                    at: 20, 4),
            Refused(":is(chore):has(> *)", .cannotContain, "A chore holds no shapes: nothing is inside it. \(notSpatial)", hint: holders, at: 4, 5),
            Refused("pocket:is(#\(uuid(11))) > *", .cannotContain,
                    "#\(uuid(11).uppercased()) is a chore, which holds no shapes: nothing is inside it. \(notSpatial)", hint: holders, at: 10, 37),
        ], on: h)
        for text in ["pocket > *", "#\(uuid(2)) *", ":inside(*)", #":inside("Alpha")"#, "#\(uuid(99)) > *", ":has(chore)", "pocket:has(> chore)",
                     ":is(pocket) *", ":is(:starred) > *", "*:not(chore) *", ":is(pocket > *) > *", ":has(:is(chore))"] {
            _ = try plan(text, on: h)
        }
    },
    test("a kind and a title together: the title's node and the kind's, refused as a kind is and as a title is") {
        let h = try shelf()
        expectEqual(try plan(#"chore"Alpha""#, on: h).description, """
            all of
              titled "Alpha"
              kind chore
            """)
        expectEqual(try plan(#"pocket'Pantry' > chore[estimate>3]"#, on: h).description, """
            all of
              kind chore
              directly inside
                all of
                  titled "Pantry"
                  kind pocket
              [estimate] of chore integer: > 3
            """, "the kind says it holds shapes: no title to check as a container's")
        expectEqual(try plan(#"pocket'Pantry' > chore[estimate>3]"#, on: h).canonical, #"pocket"Pantry" > chore[estimate>3]"#)
        let notSpatial = "Being drawn within its bounds isn't something a query can ask yet."
        let together = "Write them together for one shape:"
        expectRefused([
            Refused(#"chor"Alpha""#, .unknownKind, "chor isn't a kind.", hint: "Did you mean chore (a Task)?", at: 0, 4),
            Refused(#"zebra"Alpha""#, .unknownKind, "zebra isn't a kind.", hint: "The kinds: chore, pocket, tile, link.", at: 0, 5),
            Refused(#"link"Alpha""#, .unknownAttribute, "link has no captions.", hint: "The kinds whose shapes have captions: chore, pocket, tile.",
                    at: 4, 7),
            Refused(#"chore"Alpha" > *"#, .cannotContain, "A chore holds no shapes: nothing is inside it. \(notSpatial)",
                    hint: "The kinds that hold shapes: pocket.", at: 0, 5),
            // With a space, a title is inside the kind's shapes: where they hold no shapes, the two written together is what was meant.
            Refused(#"chore "Alpha""#, .cannotContain, "A chore holds no shapes: nothing is inside it. \(notSpatial)",
                    hint: #"\#(together) chore"Alpha"."#, at: 0, 5),
            Refused(#"chore[estimate>3] 'Alpha':starred"#, .cannotContain, "A chore holds no shapes: nothing is inside it. \(notSpatial)",
                    hint: #"\#(together) chore"Alpha"[estimate>3]:starred."#, at: 0, 5),
            // Not for a kind whose shapes have no titles, where the two together would be refused too.
            Refused(#"link "Alpha""#, .cannotContain, "A link holds no shapes: nothing is inside it. \(notSpatial)",
                    hint: "The kinds that hold shapes: pocket.", at: 0, 4),
            Refused(#"chore"Alpha"[estimat=3]"#, .unknownAttribute, "chore has no attribute estimat.",
                    hint: "Did you mean estimate? Its attributes: caption, due, estimate, flag, meta, note, ratio, shout, status, tags.", at: 12, 11),
        ], on: h)
        _ = try plan(#"pocket "Beta""#, on: h)
        expectRefused([
            Refused(#"chore"Alpha""#, .noNames, "Nothing in this app names shapes, so titles can't be used.",
                    hint: "Name shapes by their kind, or by id: # and the id a row gives.", at: 5, 7),
        ], on: try shelf(names: false))
    },
    test("a shape the query can't see is the answer's to refuse, not a container's") {
        let h = try hiddenShelf()
        expectEqual([10, 20].map { h.editor.file.record(id($0))?.isOpaque }, [true, true], "kept aside")
        expectEqual([11, 21].map { h.editor.file.record(id($0))?.kind }, ["chore", "chore"], "in the file, on boards the app can't show")
        expectEqual(refusal("#\(uuid(1)) > *", on: h)?.reason, .cannotContain)
        for hidden in [10, 11, 20, 21] {
            _ = try plan("#\(uuid(hidden)) > *", on: h)
        }
    },
    test("titles need something that names shapes; without Topology nothing resolves") {
        let h = try shelf(names: false)
        expectRefused([
            Refused(#""Alpha""#, .noNames, "Nothing in this app names shapes, so titles can't be used.",
                    hint: "Name shapes by their kind, or by id: # and the id a row gives.", at: 0, 7),
            Refused(#"pocket > "Beta""#, .noNames, "Nothing in this app names shapes, so titles can't be used.",
                    hint: "Name shapes by their kind, or by id: # and the id a row gives.", at: 9, 6),
        ], on: h)
        _ = try plan("[caption]", on: h)

        let bare = try EditorHarness(plugins: [ChoresPlugin(), QueriesPlugin()])
        for text in ["*", "chore", "", "chor["] {
            expectEqual(refusal(text, on: bare)?.reason, .noTopology, text)
        }
        expectEqual(refusal("*", on: bare)?.message, "Nothing in this app knows what's on which board, or what's inside or connected to what.")
    },
    test("problems that don't depend on another are found together, in the query's order") {
        let h = try shelf()
        let error = try require(refusal(#":wird(*), chor[estimat=3], chore[estimat=3][status=soon], :edge-to(*, cable), tile > *"#, on: h))
        expectEqual(error.errors.map(\.reason), [.unknownPseudoClass, .unknownKind, .unknownAttribute, .invalidValue, .unknownEdgeType, .cannotContain])
        expectEqual(error.errors.map { $0.span?.offset }, [0, 10, 32, 43, 70, 78])
        expectEqual(error.reason, .unknownPseudoClass, "the first leads")
        expectEqual(error.message, ":wird isn't a pseudo-class.")

        let many = (0..<25).map { "kind\($0)" }.joined(separator: ", ")
        expectEqual(refusal(many, on: h)?.errors.count, QueryLimits.errors)
        expectEqual(refusal(#"chore:has(*), chore:has(*)"#, on: h)?.errors.count, 2, "one problem at each place")
    },
    // Literals, each read as its property's type takes it.
    test("literals, numbers: quoted or not, finite, whole for an integer's = and !=") {
        let h = try shelf()
        expectEqual(try reading(#"chore[estimate="3"]"#, on: h), try reading("chore[estimate=3]", on: h))
        expectEqual(try reading("chore[ratio<=0.5]", on: h), """
            all of
              kind chore
              [ratio] of chore number: <= 0.5
            """)
        expectEqual(try reading("chore[estimate>=-2]", on: h), """
            all of
              kind chore
              [estimate] of chore integer: >= -2
            """)
        expectEqual(try reading("chore[estimate<2.5]", on: h), """
            all of
              kind chore
              [estimate] of chore integer: < 2.5
            """, "ordering takes any finite number")
        expectRefused([
            Refused("chore[estimate>lots]", .invalidValue, "lots isn't a number.", hint: "estimate takes an integer ≥ 0.", at: 5, 15),
            Refused("chore[estimate=2.5]", .invalidValue, "2.5 isn't a whole number.", hint: "estimate takes an integer ≥ 0.", at: 5, 14),
            Refused("chore[estimate!=2.5]", .invalidValue, "2.5 isn't a whole number.", hint: "estimate takes an integer ≥ 0.", at: 5, 15),
            Refused("chore[estimate<inf]", .invalidValue, "inf isn't a finite number.", hint: "estimate takes an integer ≥ 0.", at: 5, 14),
            Refused("chore[estimate<lots]", .invalidValue, "lots isn't a number.", hint: "estimate takes an integer ≥ 0.", at: 5, 15),
            Refused("chore[ratio=inf]", .invalidValue, "inf isn't a finite number.", hint: "ratio takes a number.", at: 5, 11),
            Refused("chore[ratio=null]", .invalidValue, "null isn't a number.", hint: "ratio takes a number.", at: 5, 12),
            Refused("chore[estimate^=3]", .unsupportedOperator, "^= compares text; estimate is a whole number.",
                    hint: "Use =, !=, <, <=, > or >=.", at: 5, 13),
            Refused("chore[ratio~=3]", .unsupportedOperator, "~= compares words in text and items in lists; ratio is a number.",
                    hint: "Use =, !=, <, <=, > or >=.", at: 5, 10),
            Refused("chore[estimate=3 i]", .unsupportedOperator, "The i flag compares text; estimate is a whole number.",
                    hint: "Leave it out: [estimate=3].", at: 5, 14),
            Refused("chore[ratio=1 s]", .unsupportedOperator, "The s flag compares text; ratio is a number.",
                    hint: "Leave it out: [ratio=1].", at: 5, 11),
        ], on: h)
    },
    test("literals, dates: a day is the whole UTC day; an instant with or without a zone") {
        let h = try shelf()
        expectEqual(try reading("chore[due=2026-10-01]", on: h), """
            all of
              kind chore
              [due] of chore text date-time: = the day 2026-10-01
            """)
        expectEqual(try reading("chore[due<2026-10-01T09:30]", on: h), """
            all of
              kind chore
              [due] of chore text date-time: < 2026-10-01T09:30:00Z
            """)
        expectEqual(try reading(#"chore[due>="2026-10-01T09:30:15.5+02:00"]"#, on: h), try reading("chore[due>=2026-10-01T07:30:15.5Z]", on: h))
        expectEqual(try reading("chore[due=2026-10-01T23:00-01]", on: h), try reading("chore[due=2026-10-02T00:00:00Z]", on: h))
        expectRefused([
            Refused("chore[due=tomorrow]", .invalidValue, "tomorrow isn't a date.", hint: "due takes a date (YYYY-MM-DD or date-time).", at: 5, 14),
            Refused("chore[due=2026-02-30]", .invalidValue, "2026-02-30 isn't a date.", hint: "due takes a date (YYYY-MM-DD or date-time).", at: 5, 16),
            Refused("chore[due>2026-10-01T25:00]", .invalidValue, "2026-10-01T25:00 isn't a date.",
                    hint: "due takes a date (YYYY-MM-DD or date-time).", at: 5, 22),
            Refused("chore[due>2026-10-01T09:00+05:]", .invalidValue, "2026-10-01T09:00+05: isn't a date.",
                    hint: "due takes a date (YYYY-MM-DD or date-time).", at: 5, 26),
            Refused("chore[due*=2026]", .unsupportedOperator, "*= compares text; due is a date.", hint: "Use =, !=, <, <=, > or >=.", at: 5, 11),
            Refused("chore[due=2026-10-01 i]", .unsupportedOperator, "The i flag compares text; due is a date.",
                    hint: "Leave it out: [due=2026-10-01].", at: 5, 18),
        ], on: h)
    },
    test("literals, choices: one of the words, any case with i; as text for the rest") {
        let h = try shelf()
        expectEqual(try reading("chore[status=DONE i]", on: h), """
            all of
              kind chore
              [status] of chore text todo|doing|blocked|done: = "DONE" ignoring case
            """)
        expectEqual(try reading("chore[status^=do]", on: h), """
            all of
              kind chore
              [status] of chore text todo|doing|blocked|done: starts with "do"
            """)
        expectRefused([
            Refused("chore[status=DONE]", .invalidValue, "DONE isn't one of status's words.",
                    hint: "Did you mean done? status takes todo|doing|blocked|done.", at: 5, 13),
            Refused("chore[status!=urgent]", .invalidValue, "urgent isn't one of status's words.",
                    hint: "status takes todo|doing|blocked|done.", at: 5, 16),
            Refused("chore[status<done]", .unsupportedOperator, "< compares numbers and dates; status is one of todo|doing|blocked|done.",
                    hint: "Use = or !=.", at: 5, 13),
            Refused("link[grade=warm]", .invalidValue, "warm isn't one of grade's words.", hint: "grade takes plain|hot|loose.", at: 4, 12),
        ], on: h)
    },
    test("literals, text: any literal, null too, and no ordering") {
        let h = try shelf()
        expectEqual(try reading("chore[note=null]", on: h), """
            all of
              kind chore
              [note] of chore text: = "null"
            """)
        expectEqual(try reading(#"chore[note|="en" i]"#, on: h), """
            all of
              kind chore
              [note] of chore text: is or starts "en-" ignoring case
            """)
        expectEqual(try reading("chore[shout~=hey]", on: h), """
            all of
              kind chore
              [shout] of chore text text/x-shout: has the word "hey"
            """)
        expectRefused([
            Refused("chore[note<5]", .unsupportedOperator, "< compares numbers and dates; note is text.", hint: "Use *=, ^=, $= or =.", at: 5, 8),
        ], on: h)
    },
    test("literals, true|false: an absent one is its default; = and != only") {
        let h = try shelf()
        expectEqual(try reading(#"chore[flag="true"]"#, on: h), try reading("chore[flag=true]", on: h))
        expectEqual(try reading("chore[flag=false]", on: h), """
            all of
              kind chore
              [flag] of chore true|false (false when absent): = false
            """)
        expectEqual(try reading("[flag]", on: h), "[flag] of chore true|false (false when absent): present")
        expectRefused([
            Refused("chore[flag=yes]", .invalidValue, "yes isn't true or false.", hint: "flag takes true|false.", at: 5, 10),
            Refused("chore[flag>false]", .unsupportedOperator, "> compares numbers and dates; flag is true or false.",
                    hint: "Use = or !=: [flag=true].", at: 5, 12),
            Refused("chore[flag=true i]", .unsupportedOperator, "The i flag compares text; flag is true or false.",
                    hint: "Leave it out: [flag=true].", at: 5, 13),
        ], on: h)
    },
    test("literals, lists: ~= an item, read as the list's items are; objects aren't compared") {
        let h = try shelf()
        expectEqual(try reading(#"chore[tags~="two words"]"#, on: h), """
            all of
              kind chore
              [tags] of chore list of text: has the item "two words"
            """)
        expectEqual(try reading("chore[tags~=Urgent i]", on: h), """
            all of
              kind chore
              [tags] of chore list of text: has the item "Urgent" ignoring case
            """)
        expectRefused([
            Refused("chore[tags=urgent]", .unsupportedOperator, "= compares one value; tags is a list.",
                    hint: "[tags~=urgent] finds a list that holds it.", at: 5, 13),
            Refused(#"chore[tags^="ur gent"]"#, .unsupportedOperator, "^= compares text; tags is a list.",
                    hint: #"Use ~=: [tags~="ur gent"] finds a list that holds it."#, at: 5, 17),
            Refused("chore[meta=x]", .notBuilt, "meta is an object: comparing a whole object isn't in the language yet.",
                    hint: "[meta] asks whether it says anything; [meta.member] tests what is inside it.", at: 5, 8),
            Refused("chore[meta^=x]", .unsupportedOperator, "^= compares text; meta is an object.", at: 5, 9),
        ], on: h)
        _ = try plan("chore[meta]", on: h)
    },
    test("literals, names: through the names point, on every kind that has them, and last where one is derived (on the main actor)") {
        let h = try shelf()
        expectEqual(try reading("[caption^=Al]", on: h), #"[caption] of chore|pocket|tile name: starts with "Al""#)
        expectEqual(try reading("tile[caption=Tiled]", on: h), """
            all of
              kind tile
              [caption] of tile name: = "Tiled"
            """)
        expectEqual(try reading("[caption][estimate]", on: h), """
            all of
              [estimate] of chore integer: present
              [caption] of chore|pocket|tile name: present
            """)
        // = matches what the title head matches: the literal folded as the names point folds a title.
        expectEqual(try reading(#"[caption="  Alpha \n"]"#, on: h), #"[caption] of chore|pocket|tile name: = "Alpha""#)
        expectEqual(try reading(#"[caption!=" Alpha" i]"#, on: h), """
            not
              [caption] of chore|pocket|tile name: = "Alpha" ignoring case
            """)
        expectEqual(try reading(#"[caption^="Al "]"#, on: h), #"[caption] of chore|pocket|tile name: starts with "Al ""#)
        expectRefused([
            Refused("[caption<b]", .unsupportedOperator, "< compares numbers and dates; caption is text.", hint: "Use *=, ^=, $= or =.", at: 0, 11),
        ], on: h)
    },
    test("literals, with no kind named: each kind reads the literal its own way, and one that can't is left out") {
        let mixed = Contributor(id: "mixed") { registrar in
            registrar.declare(Rank.self)
            registrar.optIn(Chore.self, to: Rank.self)
            registrar.optIn(Tile.self, to: Flagged.self)
        }
        let h = try shelf(more: [mixed])
        expectEqual(try reading("[flag]", on: h), "[flag] of chore|tile true|false (false when absent): present")
        expectEqual(try reading("[label=3]", on: h), """
            [label] of chore integer: = 3
            [label] of tile text: = "3"
            """)
        expectEqual(try reading("[label=high]", on: h), #"[label] of tile text: = "high""#)
        expectEqual(try reading("[label<3]", on: h), "[label] of chore integer: < 3")
        expectRefused([
            Refused("[label<high]", .invalidValue, "high isn't a number.", hint: "label takes an integer.", at: 0, 12),
            Refused("tile[label<3]", .unsupportedOperator, "< compares numbers and dates; label is text.", hint: "Use *=, ^=, $= or =.", at: 4, 9),
        ], on: h)
    },
])

/// A chore's rank, named as a tile's label is: one attribute name, a number on chores and text on
/// tiles.
enum Rank {}
extension Rank: ShapeProperty {
    static let key: PropertyKey = "label"
    static var defaultValue: Int? { nil }
}

/// What a query's plan says of one attribute test.
@MainActor func reading(_ text: String, on h: EditorHarness) throws -> String {
    try plan(text, on: h).description
}
