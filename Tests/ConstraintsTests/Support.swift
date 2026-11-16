import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import Constraints
import CoreGraphics
import DetailPanel
import Foundation
import Keyboard
import LanguageModels
import Queries
import QueryTranslation
import Selection
import SlashCommands
import TestKit
import Titles
import Topology
import Validation

// What the suites share: CanvasTesting's corrals (frames) and pockets (subboards), made constrainable and titled by the
// tests; tiles (a kind a tool places: `label`, `finish` matte or glossy) and discs as what goes in them; `:urgent`, a
// word of the tests' own that matches a shape flagged `urgent` and writes the flag (`makes:`); a charter, a kind that
// keeps a list its own way (a holder, as a type will); and a giver of lists from elsewhere, set by the test.
// Queries the constraints use: `tile` ("only tiles"), `tile[finish="glossy"]` ("only glossy tiles"), `:urgent`
// ("only urgent things"), `:not(disc)` ("no discs").

/// Whether a shape is urgent: what `:urgent` matches, and writes.
enum Urgent {}

extension Urgent: ShapeProperty {
    static let key: PropertyKey = "urgent"
    static var defaultValue: Bool? { nil }
}

/// What marks the kinds that keep a list their own way (the holders' scope): the charter's.
enum Chartered {}

extension Chartered: ShapeProperty {
    static let key: PropertyKey = "chartered"
    static var defaultValue: Bool? { nil }
}

/// A box that keeps a list of constraints its own way, in its text (JSON), while it has a name: what a type will be.
struct Charter: BoxShapeProps {
    static let kind: ShapeKind = "charter"
    static let properties = Properties<Charter> {
        Property("frame", \.frame).required()
        Property("name", \.name)
        Property("list", \.list)
    }
    var frame: CGRect
    var name = ""
    var list = "[]"

    init(_ frame: CGRect, name: String = "", list: String = "[]") {
        self.frame = frame
        self.name = name
        self.list = list
    }

    init() { self.init(.zero) }
}

struct CharterDefinition {}

extension CharterDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Charter>, in context: RenderContext) {}
}

/// The lists the test gives shapes from elsewhere, by shape.
@MainActor final class Given {
    var lists: [ShapeID: [ConstraintSource]] = [:]
    /// The containers that read through a holder, by the holder (`readers:`).
    var readers: [ShapeID: Set<ShapeID>] = [:]
    var asked = 0
    /// Why a charter whose list isn't JSON takes none, by its name (the holder's `reason`); nil: it says none, and Constraints' words stand.
    var whyNot: ((String) -> String)?
    /// A charter that gives no `reason` at all (the holder point's is optional): set before the harness is made.
    var noReason = false
}

let onlyTiles = Constraint(says: "only tiles", query: "tile")
let onlyGlossy = Constraint(says: "only glossy tiles", query: #"tile[finish="glossy"]"#)
let onlyUrgent = Constraint(says: "only urgent things", query: ":urgent")
let noDiscs = Constraint(says: "no discs", query: ":not(disc)")

/// What a charter whose list isn't JSON says of why it takes none: the test's `whyNot`, and none at all when `noReason`.
@MainActor func charterReason(_ given: Given) -> (@MainActor (AnyShapeRecord, CanvasEditor) -> String?)? {
    if given.noReason { return nil }
    return { record, _ in
        guard let why = given.whyNot, let charter = record.typed(as: Charter.self),
              (try? JSONDecoder().decode(ConstraintList.self, from: Data(charter.props.list.utf8))) == nil else { return nil }
        return why(charter.props.name)
    }
}

/// The tests' kinds and words: corrals and pockets constrainable and titled, tiles titled and urgent-able, `:urgent`,
/// the charter as a holder, and the giver's lists on every constrainable shape.
@MainActor func fixtures(_ given: Given) -> Contributor {
    Contributor(id: "constraint-fixtures") { r in
        r.constrainable(Corral.self)
        r.constrainable(Pocket.self)
        r.title(Corral.self, contents: false)
        r.title(Pocket.self, contents: false)
        r.title(Tile.self, contents: false)
        r.declare(Urgent.self)
        r.optIn(Tile.self, to: Urgent.self)
        r.optIn(Disc.self, to: Urgent.self)
        r.queryPseudoClass("urgent", "it is urgent", example: ":urgent", reads: .file, prepare: { _ in () },
                           matches: { shape, _ in shape.record[Urgent.self] == true ? .yes : .no },
                           makes: { record, _ in
                               var made = record
                               made[Urgent.self] = true
                               return made
                           })
        r.shape(CharterDefinition()) { charter in
            // What a charter is called is its name, as a type's is its title: what the panel's pill and the menu's "Go to" say.
            charter.title(contents: false) { $0.props.name.isEmpty ? nil : $0.props.name }
        }
        r.declare(Chartered.self)
        r.optIn(Charter.self, to: Chartered.self)
        r.forShapes(holding: Chartered.self) { charters in
            charters.constraintHolder(read: { record, _ in
                guard let charter = record.typed(as: Charter.self), !charter.props.name.isEmpty,
                      let data = charter.props.list.data(using: .utf8) else { return nil }
                return (try? JSONDecoder().decode(ConstraintList.self, from: data))?.constraints ?? []
            }, write: { list, id, transaction in
                // A charter whose list isn't JSON yet takes none, as a type whose schema isn't: false, and nothing said.
                guard let current = transaction.contents(of: transaction.board(containing: id) ?? .root)[id]?.typed(as: Charter.self),
                      (try? JSONDecoder().decode(ConstraintList.self, from: Data(current.props.list.utf8))) != nil else { return false }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard let data = try? encoder.encode(ConstraintList(list)) else { return false }
                transaction.update(inFile: id, as: Charter.self) { $0.props.list = String(decoding: data, as: UTF8.self) }
                return true
            }, name: { record, _ in
                record.typed(as: Charter.self).map { "each \($0.props.name.lowercased())" }
            }, reason: charterReason(given))
        }
        r.forShapes(holding: ConstraintsProperty.self) { held in
            held.inheritedConstraints({ id, _ in
                given.asked += 1
                return given.lists[id] ?? []
            }, readers: { holder, _ in given.readers[holder] ?? [] })
        }
        // A second giver for holders: the one point reaches a charter as it reaches a frame.
        r.forShapes(holding: Chartered.self) { charters in
            charters.inheritedConstraints { id, _ in given.lists[id] ?? [] }
        }
    }
}

/// The words the translator is asked in (the tests' own: the product's are files only its executables have).
let translatorPrompt = "Write a query for the words."
let translatorRule = "The query is stored and run later."
let translatorAccepts = "The words name which shapes {holder} accepts."

/// Every plugin the suites take: keys and the selection (a drag), Topology and Queries, the fixtures' kinds, Validation,
/// the panel, titles (with the adornments and slash commands they need), the menus, a scripted model that translates words
/// (`model`: never the network), Constraints, its issues and its faces.
@MainActor func constraintPlugins(_ given: Given = Given(), log: RefusalLog = RefusalLog(), model: ScriptedLanguageModel = ScriptedLanguageModel(),
                                  _ more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), QueriesPlugin(), FixturesPlugin(), CorralsPlugin(), PocketsPlugin(), TilesPlugin(),
     FreezingPlugin(log: log), ValidationPlugin(), DetailPanelPlugin(), AdornmentsPlugin(), SlashCommandsPlugin(), TitlesPlugin(), TitleQueriesPlugin(),
     ContextMenusPlugin(),
     LanguageModelsPlugin(model: model), QueryTranslationPlugin(prompt: translatorPrompt, referenceRule: translatorRule, accepts: translatorAccepts),
     ConstraintsPlugin(), ConstraintValidationPlugin(), ConstraintFacesPlugin(), fixtures(given)] + more
}

/// A harness 800 × 600, the camera at the origin at 100%: view points are world units.
@MainActor func constraintHarness(_ given: Given = Given(), log: RefusalLog = RefusalLog(), model: ScriptedLanguageModel = ScriptedLanguageModel(),
                                  _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    let h = try EditorHarness(plugins: constraintPlugins(given, log: log, model: model, more))
    h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return h
}

extension EditorHarness {
    var index: ConstraintIndex { editor.constraintIndex! }
    var writer: ConstraintWriter { editor.constraintWriter! }

    /// A corral, titled if a title is given, holding its own constraints, in `container` if one.
    @discardableResult
    func corral(_ title: String?, _ frame: CGRect, _ constraints: [Constraint] = [], in container: ShapeID? = nil) -> ShapeID {
        let id = ShapeID()
        var record = AnyShapeRecord(ShapeRecord(id: id, Corral(frame)))
        record[TitleProperty.self] = title
        if !constraints.isEmpty { record[ConstraintsProperty.self] = ConstraintList(constraints) }
        editor.transact { $0.insert(record.copy(as: id, container: container)) }
        return id
    }

    /// A pocket, titled if a title is given, holding its own constraints.
    @discardableResult
    func pocket(_ title: String?, _ frame: CGRect, _ constraints: [Constraint] = []) -> ShapeID {
        var record = AnyShapeRecord(ShapeRecord(Pocket(frame)))
        record[TitleProperty.self] = title
        if !constraints.isEmpty { record[ConstraintsProperty.self] = ConstraintList(constraints) }
        editor.transact { $0.insert(record) }
        return record.id
    }

    /// A tile 120 × 80 at `origin`, put in by an insert (made here: let in), in `container` if one, on the board shown.
    @discardableResult
    func tile(_ label: String = "", at origin: CGPoint, finish: Tile.Finish = .matte, urgent: Bool = false, in container: ShapeID? = nil) -> ShapeID {
        let id = ShapeID()
        var record = AnyShapeRecord(ShapeRecord(id: id, Tile(CGRect(origin: origin, size: CGSize(width: 120, height: 80)), label: label, finish: finish)))
        if !label.isEmpty { record[TitleProperty.self] = label }
        if urgent { record[Urgent.self] = true }
        editor.transact { $0.insert(record.copy(as: id, container: container)) }
        return id
    }

    /// A disc 50 across at `origin`, put in by an insert, in `container` if one.
    @discardableResult
    func disc(at origin: CGPoint, in container: ShapeID? = nil) -> ShapeID {
        let id = ShapeID()
        let record = AnyShapeRecord(ShapeRecord(id: id, Disc(CGRect(origin: origin, size: CGSize(width: 50, height: 50)))))
        editor.transact { $0.insert(record.copy(as: id, container: container)) }
        return id
    }

    /// Runs the main run loop until every standing query the index holds has answered.
    func settle(file: StaticString = #fileID, line: UInt = #line) {
        let index = index
        expect(spinRunLoop(until: { index.isSettled }, timeout: 5, file: file, line: line), "the index settles", file: file, line: line)
    }

    /// The shapes a place's constraints are broken by.
    func breakers(of place: ConstraintTarget) -> Set<ShapeID> { index.breakers(of: place) }

    /// What Validation says of a shape, as the engine checks it now.
    func issues(of id: ShapeID) -> [String] {
        (editor.validation?.results[id]?.issues ?? []).map(\.message)
    }

    func origin(of id: ShapeID) -> CGPoint? { editor.document[id]?.box?.origin }

    /// Drags a shape from one point to another with the select tool, and lets go.
    func drop(from start: CGPoint, to end: CGPoint) {
        editor.setTool("select")
        press(at: start)
        drag(to: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
        drag(to: end)
        release()
    }
}
