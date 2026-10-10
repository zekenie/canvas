import AppKit
import Canvas
import Connections
import ContextMenus
import DetailPanel
import Keyboard
import Publishing
import Queries
import QueryLanguage
import Selection
import Topology
import Validation

extension PluginID {
    public static let references: PluginID = "references"
}

/// A pill that stands for another shape, anywhere in the file: an arrow to it counts, for everything
/// (queries, the table of contents, Topology's readers), as an arrow to what it stands for, so a
/// shape too many others point at needs no arrow from each. Only a public shape can be stood for
/// (Publishing). Its props are what the person did, never what they found out:
///
/// - `target`: the shape picked, by name (a `ShapeNaming` leaf, not a binding: names cross boards,
///   outlive their shape, and are kept by cut and paste), with the name it had, shown dashed once
///   the shape is gone;
/// - `words`: what was typed when it matched no public shape, and `query`: the query those words
///   mean (nil until they're interpreted), canonical; `all`: every match, or the first in file order.
///
/// Its mode is derived, never stored: `target` wins; else `words` or `query` make it a dynamic
/// reference; else it's empty. What it stands for, whether that is live, and how many it finds are
/// derived and never saved.
public struct Reference: BoxShapeProps {
    public static let kind: ShapeKind = "reference"
    public static let properties = Properties<Reference>(title: "Reference") {
        Property("frame", \.frame).required()
        Property("target", \.target).readOnly().description("The shape it stands for, picked by name.")
        Property("words", \.words).readOnly().maxLength(500)
        Property("query", \.query).maxLength(8_192).format("x-canvas-query").description("Finds what it stands for, in the query language.")
        Property("all", \.all).description("Every match, not just the first.")
    }

    /// What a click with the Reference tool places, and what `canvas draw` places.
    public static let defaultSize = CGSize(width: 120, height: 32)

    /// Its height is the pill's; its width is stored and refitted whenever its text or mode is
    /// written (`ReferenceEdits`).
    public var frame: CGRect
    /// Direct: the shape it stands for.
    public var target: ReferenceTarget?
    /// Dynamic: what was typed.
    public var words: String
    /// Dynamic: the query, nil until the words are interpreted.
    public var query: String?
    /// Dynamic: every match (true), or the first in file order.
    public var all: Bool

    public init(frame: CGRect = .zero, target: ReferenceTarget? = nil, words: String = "", query: String? = nil, all: Bool = false) {
        self.frame = frame
        self.target = target
        self.words = words
        self.query = query
        self.all = all
    }

    public init() { self.init(frame: .zero) }
}

/// How a reference is made, derived from what it holds.
public enum ReferenceMode: Sendable {
    /// Nothing yet: a pill placed and not typed into.
    case empty
    /// One shape picked.
    case direct
    /// Words, or a query, found by looking.
    case dynamic
}

extension Reference {
    public var mode: ReferenceMode {
        if target != nil { .direct } else if !words.isEmpty || query != nil { .dynamic } else { .empty }
    }

    /// What a dynamic reference is called: its words, else its query.
    public var text: String { words.isEmpty ? query ?? "" : words }
}

/// The shape a direct reference stands for, by name: its id, and what it was called when picked,
/// which the pill shows (dashed) once the shape is gone. Coded as written in a board:
/// `{"id": …, "label": …}`.
public struct ReferenceTarget: Codable, Equatable, Hashable, Sendable {
    public var id: ShapeID
    public var label: String

    public init(id: ShapeID, label: String) {
        self.id = id
        self.label = label
    }
}

extension ReferenceTarget: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.reference("reference-target", of: Self.self) { _ in
            ["type": "object",
             "properties": ["id": ["type": "string", "format": "uuid"], "label": ["type": "string"]],
             "required": ["id", "label"],
             "additionalProperties": false,
             "description": "A shape it names, which may be gone, and what it was called."]
        }
    }
}

extension ReferenceTarget: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) { body(id) }

    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> ReferenceTarget {
        ReferenceTarget(id: rename(id) ?? id, label: label)
    }
}

/// The reference's one tab, which shows no strip while it's the only one.
enum ReferenceTab {}

extension ReferenceTab: DetailTab {
    static var title: String { "Reference" }
}

/// What the context menu gives a reference, first: Go to Original.
public enum ReferencesMenuGroup {}
extension ReferencesMenuGroup: MenuGroup {
    public static var order: Int { 0 }
}

extension CanvasCommand {
    /// Goes to what the only selected reference stands for: the panel's button.
    public static let goToOriginal: CanvasCommand = "goToOriginal"
    /// Asks the model to turn the only selected reference's words into a query: the panel's Interpret.
    public static let interpretReference: CanvasCommand = "interpretReference"
}

/// References: the Reference tool (R), which places an empty pill and types into it, and the pill: a
/// capsule whose symbol is the kind of what it stands for and whose label is that shape's live
/// name. It stands for the shape it names (`standsIn`, admitted while the shape is public), so an
/// arrow into it is an arrow into the shape; and for a reference that stands for something else
/// than a picked shape, the words and the query. It opts into Keyboard's key, the table of
/// contents (a row; an arrow that starts at it nests under what it stands for), the detail panel (a
/// header naming what it stands for, and Go to Original), the context menu (Go to Original, first) and
/// Publishing's Referenced In (its own row). Going to the original is a canvas button, the leading
/// symbol, as well. A reference is never public itself (`NeverPublic`).
public struct ReferencesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .references }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ReferenceState(editor: $0) }
        registrar.overlay(ReferenceButtonOverlay())
        registrar.canvasButtons(at: { editor, point in editor.service(ReferenceState.self)?.goButton(atViewPoint: point) },
                                click: { button, editor in editor.service(ReferenceState.self)?.goToOriginal(button.reference) })
        registrar.command(.goToOriginal, isEnabled: { $0.service(ReferenceState.self)?.canGoToOriginal(of: Set($0.selectedShapeIDs)) ?? false }) { editor in
            editor.service(ReferenceState.self)?.goToOriginal(of: Set(editor.selectedShapeIDs))
        }
        registrar.command(.interpretReference, isEnabled: { $0.service(ReferenceState.self)?.canInterpret(Set($0.selectedShapeIDs)) ?? false }) { editor in
            editor.service(ReferenceState.self)?.interpret(only: Set(editor.selectedShapeIDs))
        }
        registrar.detailStatusForEveryShape { shape, context in
            guard shape.kind == Reference.kind, let line = context.service(ReferenceState.self)?.mismatchLine(of: shape.id) else { return [] }
            return [DetailStatus(line, tone: .warning)]
        }
        registrar.shapePopovers { editor, record, _ in editor.service(ReferenceState.self)?.popover(on: record) }
        registrar.contextMenuForCanvas {
            MenuItem(ReferenceStyle.goToOriginal, in: ReferencesMenuGroup.self,
                     when: { $0.editor.service(ReferenceState.self)?.canOffer(goingTo: $0.shapes) ?? false },
                     isEnabled: { $0.editor.service(ReferenceState.self)?.canGoToOriginal(of: Set($0.shapes)) ?? false }) { ids, editor in
                editor.service(ReferenceState.self)?.goToOriginal(of: Set(ids))
            }
            MenuItem(ReferenceStyle.showMatches, in: ReferencesMenuGroup.self,
                     when: { $0.editor.service(ReferenceState.self)?.canOffer(showingMatches: $0.shapes) ?? false },
                     isEnabled: { subject in subject.shapes.count == 1 && subject.editor.service(ReferenceState.self)?.matches(of: subject.shapes[0]) != nil }) { ids, editor in
                editor.service(ReferenceState.self)?.showMatches(of: Set(ids))
            }
        }
        registrar.shape(ReferenceDefinition()) { reference in
            let place = reference.editingPlacement(size: Reference.defaultSize) { Reference() }
            reference.tool(label: "Reference", systemImage: ReferenceStyle.systemImage, shortcut: "r", placing: place)
            reference.portsOnEveryChannel(sides: [.left, .right])
            // Made to stand for a shape as picking it does, which refits its width to the name: how
            // `canvas draw` puts one beside what points at a shape on another board.
            reference.standsIn(maxTargets: ReferenceStyle.maxTargets, admitting: { target, registry in registry.isPublic(target) },
                               needs: "public",
                               makes: { props, target, label in ReferenceEdits.pick(&props, ReferenceTarget(id: target, label: label)) }) { shape, _ in
                if let target = shape.props.target { return .shapes([target.id]) }
                if let query = shape.props.query { return .provided(ReferenceState.key(query: query, all: shape.props.all)) }
                return nil
            }
            reference.standInRow { shape, _ in
                switch shape.props.mode {
                case .direct: StandInRow(symbol: "arrow.up.forward")
                case .dynamic: StandInRow(symbol: ReferenceStyle.dynamicSymbol, text: "“\(shape.props.text)”")
                case .empty: nil
                }
            }
            reference.referenceRow()
            reference.referencePanel()
            // Every match, or the first: steps of their own, the width as it is (the count's room is kept).
            reference.contextMenu {
                MenuItem(ReferenceStyle.matchAll, in: ReferencesMenuGroup.self, when: { $0.mode == .dynamic && !$0.all }) { $0.all = true }
                MenuItem(ReferenceStyle.matchFirst, in: ReferencesMenuGroup.self, when: { $0.mode == .dynamic && $0.all }) { $0.all = false }
            }
            // A query the engine can't read (pasted, or written by hand into a board): a warning in its
            // own words. What it finds, or doesn't, is the pill's to show, never an issue.
            reference.validate(ignoringMoves: true) { shape, context in
                guard shape.props.target == nil, let query = shape.props.query, let queries = context.service(QueryState.self) else { return [] }
                do throws(QueryError) {
                    _ = try queries.check(query)
                    return []
                } catch {
                    return [.warning(error.message, field: "query")]
                }
            }
        }
    }
}
