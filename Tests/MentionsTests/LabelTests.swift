import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Keyboard
import Mentions
import Selection
import TableOfContents
import TestKit
import Titles

// How a shape is called where it's mentioned: `label`, else its title, else `untitled`, else
// "Untitled" and its kind's name; and what a mention of it shows.

private let frame = CGRect(x: 0, y: 0, width: 100, height: 80)

@MainActor let labelTests = Suite("Labels", [
    test("the label is the kind's label, else the title, else untitled, else Untitled and the kind's name") {
        let h = try mentionHarness()
        let registry = h.editor.registry
        @MainActor func appearance(_ id: ShapeID) -> MentionAppearance? { h.editor.document[id].flatMap(registry.mentionAppearance(of:)) }

        let endpoint = h.editor.add(Endpoint(frame, path: "GET /users"), titled: "Users API")
        expectEqual(appearance(endpoint)?.label, "GET /users", "label: comes before the title")
        h.editor.transact { $0.update(endpoint, as: Endpoint.self) { $0.props.path = "  \n " } }
        expectEqual(appearance(endpoint)?.label, "Users API", "a blank label is none")
        h.editor.rename(endpoint, nil)
        expectEqual(appearance(endpoint)?.label, "Untitled Endpoint")
        expectEqual(appearance(endpoint)?.isPlaceholder, true)

        let plate = h.editor.add(Plate(frame), titled: "Groceries")
        expectEqual(appearance(plate)?.label, "Groceries")
        expectEqual(appearance(plate)?.isPlaceholder, false)
        let untitledPlate = h.editor.add(Plate(frame), titled: nil)
        expectEqual(appearance(untitledPlate)?.label, "Untitled Plate")

        let token = h.add(Token(frame, caption: "Milk\n and \t eggs"))
        expectEqual(appearance(token)?.label, "Milk and eggs", "folded to one line")
        expectEqual(appearance(token)?.isPlaceholder, false, "untitled's name says something of the shape")
        let blank = h.add(Token(frame, caption: " \n "))
        expectEqual(appearance(blank)?.label, "Untitled Token")
    },

    test("an untitled shape named by its own mention text names no other shape, live or as held: each mention is @…") {
        let h = try mentionHarness()
        let plate = h.editor.add(Plate(frame), titled: "Groceries")
        let jot = h.add(Jot(frame, text: MentionText([.text("\n Ask "), .mention(plate, label: "Groceries"), .text(" first\nthen more")])))
        let registry = h.editor.registry
        expectEqual(h.editor.document[jot].flatMap(registry.mentionAppearance(of:))?.label, "Ask @… first")
        h.editor.rename(plate, "Food")
        expectEqual(h.editor.document[jot].flatMap(registry.mentionAppearance(of:))?.label, "Ask @… first",
                    "a name reads only its own record")
        h.editor.rename(jot, "Shopping")
        expectEqual(h.editor.document[jot].flatMap(registry.mentionAppearance(of:))?.label, "Shopping")
    },

    test("untitled shapes that mention each other, or themselves, keep their names however often they're written") {
        let h = try mentionHarness()
        let registry = h.editor.registry, state = h.editor.mentionState
        let budget = h.add(Jot(frame, text: "Budget"))
        let see = h.add(Jot(frame, text: MentionText([.text("See "), .mention(budget, label: "Budget")])))
        h.editor.setText(budget, MentionText([.text("Budget, from "), .mention(see, label: "See @…"), .text(" and "), .mention(budget, label: "me")]))
        @MainActor func label(_ id: ShapeID) -> String? { h.editor.document[id].flatMap(registry.mentionAppearance(of:))?.label }
        @MainActor func text(_ id: ShapeID) -> MentionText? { h.editor.document[id]?.typed(as: Jot.self)?.props.text }
        /// Writes the text as its editor would: each mention named as it shows now.
        @MainActor func write(_ id: ShapeID) throws {
            let shown = JotStyle.text.attributedString(try require(text(id))) { state.resolve($0) }
            let written: MentionText = MentionTextStyle.mentionText(from: shown)
            h.editor.setText(id, written)
        }
        try write(budget)
        try write(see)
        let settled = (text(budget), text(see))
        for _ in 0..<4 {
            try write(budget)
            try write(see)
        }
        expectEqual(text(budget), settled.0, "no name grows into another's")
        expectEqual(text(see), settled.1)
        expectEqual(label(budget), "Budget, from @… and @…")
        expectEqual(label(see), "See @…")
        expectEqual(text(see)?.runs, [.text("See "), .mention(budget, label: "Budget, from @… and @…")])
    },

    test("symbol, kind name, detail and tint: the tool's by default, the kind's own where it says") {
        let h = try mentionHarness()
        let registry = h.editor.registry
        let plate = try require(h.record(h.editor.add(Plate(frame), titled: "P")).flatMap(registry.mentionAppearance(of:)))
        expectEqual(plate, MentionAppearance(label: "P", systemImage: "rectangle.fill", kindName: "Plate", detail: "Plate"))
        let token = try require(h.record(h.add(Token(frame, caption: "T"))).flatMap(registry.mentionAppearance(of:)))
        expectEqual(token.systemImage, "circle")
        expectEqual(token.detail, "Token")
        expectEqual(token.tint, nil)
        let starred = try require(h.record(h.add(Token(frame, caption: "S", isStarred: true))).flatMap(registry.mentionAppearance(of:)))
        expectEqual(starred.systemImage, "star.fill")
        expectEqual(starred.kindName, "Token")
        expectEqual(starred.detail, "Starred")
        expectEqual(starred.tint, .systemYellow)
    },

    test("a shape of a kind that isn't mentionable, or kept aside, has no appearance; a mention of it is unavailable") {
        let h = try mentionHarness()
        let registry = h.editor.registry
        let box = h.add(Box(frame))
        expectEqual(h.editor.document[box].flatMap(registry.mentionAppearance(of:)), nil)
        expect(!registry.isMentionable(Box.kind))
        expect(registry.isMentionable(Plate.kind))
        let aside = try keptAside(Plate.kind, id: idC, in: registry)
        expectEqual(registry.mentionAppearance(of: aside), nil)
        append([aside], to: h.editor)
        let lookup: (ShapeID) -> AnyShapeRecord? = { h.editor.document[$0] }
        expectEqual(registry.mentionResolution(of: box, lookup: lookup), .unavailable)
        expectEqual(registry.mentionResolution(of: idC, lookup: lookup), .unavailable)
        expectEqual(registry.mentionResolution(of: ShapeID(), lookup: lookup), .missing)
        let plate = h.editor.add(Plate(frame), titled: "Live")
        expectEqual(registry.mentionResolution(of: plate, lookup: lookup).appearance?.label, "Live")
        expect(registry.mentionResolution(of: plate, lookup: lookup).isLive)
    },

    test("mentionableEveryShape makes the kinds it picks mentionable with the defaults; a kind's own comes first") {
        let every = Contributor(id: "every") { $0.mentionableEveryShape(where: { !($0 is any PaintOrderAnchored) }) }
        let h = try mentionHarness([every])
        let registry = h.editor.registry
        expect(registry.isMentionable(Box.kind))
        expect(!registry.isMentionable(Tag.kind), "where: leaves tags out")
        let box = try require(h.record(h.add(Box(frame))).flatMap(registry.mentionAppearance(of:)))
        expectEqual(box.label, "Untitled box", "a kind without a tool is called by its kind")
        expectEqual(box.systemImage, "square.dashed")
        let token = try require(h.record(h.add(Token(frame, caption: "Mine"))).flatMap(registry.mentionAppearance(of:)))
        expectEqual(token.label, "Mine")
        expect(registry.report.contains("mentionable → every shape"), registry.report)
    },

    test("the report lists who is mentionable, and draws mention text") {
        let registry = try Registry(plugins: mentionPlugins())
        let line = try require(registry.report.split(separator: "\n").first { $0.hasPrefix("mention-fixtures") })
        for item in ["mention scope Blockers", "mentionable → plate", "mention scope Blockers → plate", "mentionable → token",
                     "mention scope Blockers → token", "mentionable → endpoint", "mentionable → jot", "mention text → jot"] {
            expect(line.contains(item), "\(item) in \(line)")
        }
        let mentions = try require(registry.report.split(separator: "\n").first { $0.hasPrefix("mentions ") })
        expect(mentions.contains("service MentionState"), String(mentions))
    },

    test("a list with a mentionable kind needs Mentions") {
        expectThrows(RegistryError.ownerNotInstalled(point: "MentionScopes", owner: .mentions, contributor: "mention-fixtures")) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), MentionFixturesPlugin(), AdornmentsPlugin(),
                                       TableOfContentsPlugin(), TitlesPlugin()])
        }
    },
])
