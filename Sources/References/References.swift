import AppKit
import Canvas
import CanvasRPC
import Connections
import ContextMenus
import DetailPanel
import Geometry
import Keyboard
import Publishing
import Queries
import QueryLanguage
import Selection
import SlashCommands
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
    /// Append only. The count is the version boards record.
    public static let migrations = [
        // The pill is tall enough for its place over its name: 40, not 32, about the same center.
        PropsMigration("height 40") { props in
            guard case .array(let frame)? = props["frame"], frame.count == 2,
                  case .array(let origin) = frame[0], origin.count == 2, case .number(let y) = origin[1],
                  case .array(let size) = frame[1], size.count == 2, case .number(let height) = size[1] else { return }
            // The center stays where it was: the origin moves by half the difference.
            props["frame"] = .array([.array([origin[0], .number(y + (height - 40) / 2)]), .array([size[0], .number(40)])])
        },
        // A reference may be a mirror: its look and the scale it draws its original at, a pill at 1 before.
        PropsMigration("look and scale"),
    ]
    public static let properties = Properties<Reference>(title: "Reference") {
        Property("frame", \.frame).required()
        Property("target", \.target).readOnly().description("The shape it stands for, picked by name.")
        Property("words", \.words).readOnly().maxLength(500)
        Property("query", \.query).maxLength(8_192).format("x-canvas-query").description("Finds what it stands for, in the query language.")
        Property("all", \.all).description("Every match, not just the first.")
        Property("look", \.look).description("A pill, or a mirror: what it stands for drawn again under the pill, live.")
        Property("scale", \.scale).minimum(Double(ReferenceStyle.mirrorScales.lowerBound)).maximum(Double(ReferenceStyle.mirrorScales.upperBound))
            .description("How big a mirror draws what it stands for, 1 being its own size.")
    }

    /// What a click with the Reference tool places, and what `canvas draw` places.
    public static let defaultSize = CGSize(width: 120, height: 40)

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
    /// How it shows what it stands for: as a pill, or as a mirror, the pill over the original drawn again, live
    /// (`ReferenceMirror.swift`). Its `frame` is the pill's either way.
    public var look: ReferenceForm
    /// How big a mirror draws its original: 1 is the original's own size. A pill keeps the scale it was last a mirror at.
    public var scale: CGFloat

    public init(frame: CGRect = .zero, target: ReferenceTarget? = nil, words: String = "", query: String? = nil, all: Bool = false,
                look: ReferenceForm = .pill, scale: CGFloat = 1) {
        self.frame = frame
        self.target = target
        self.words = words
        self.query = query
        self.all = all
        self.look = look
        self.scale = scale
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

/// The reference's one tab, which shows no strip while it's the only one; first, as a kind's own is.
enum ReferenceTab {}

extension ReferenceTab: DetailTab {
    static var title: String { "Reference" }
    static var order: Order<Self> { .first }
}

/// What the context menu gives a reference, first: Go to Original, before a kind's own items.
public enum ReferencesMenuGroup {}
extension ReferencesMenuGroup: MenuGroup {
    public static var order: Order<Self> { .before(ShapeMenuGroup.self) }
}

extension CanvasCommand {
    /// Goes to what the only selected reference stands for: the panel's button.
    public static let goToOriginal: CanvasCommand = "goToOriginal"
    /// Asks the model to turn the only selected reference's words into a query: the panel's Interpret.
    public static let interpretReference: CanvasCommand = "interpretReference"
    /// Shows the references it's given as mirrors, and back as pills: the menu's Expand and Collapse, `/expand` and
    /// `/collapse`.
    public static let expandReference: CanvasCommand = "expandReference"
    public static let collapseReference: CanvasCommand = "collapseReference"
}

/// References: the Reference tool (R), which places an empty pill and types into it, and the pill: a
/// capsule whose symbol is the kind of what it stands for and whose label is that shape's live
/// name. It stands for the shape it names (`standsIn`, admitted while the shape is public), so an
/// arrow into it is an arrow into the shape; and for a reference that stands for something else
/// than a picked shape, the words and the query. It opts into Keyboard's key, the table of
/// contents (a row; an arrow that starts at it nests under what it stands for), the detail panel (a
/// header naming what it stands for, and Go to Original) and the context menu (Go to Original, first).
/// Going to the original is a canvas button, the leading
/// symbol, as well. A reference is never public itself (`NeverPublic`).
public struct ReferencesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .references }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ReferenceState(editor: $0) }
        registrar.overlay(ReferenceButtonOverlay())
        registrar.canvasButtons(at: { editor, point in editor.service(ReferenceState.self)?.goButton(atViewPoint: point) },
                                click: { button, editor in editor.service(ReferenceState.self)?.goToOriginal(button.reference) })
        // Go to Original: the panel's button, the context menu's first item (dimmed where there's nothing
        // to go to), on the only reference they're for. Interpret: the panel's, on words no one asked about.
        registrar.command(.goToOriginal, title: ReferenceStyle.goToOriginal,
                          isEnabled: { $0.editor.service(ReferenceState.self)?.canGoToOriginal(of: Set($0.shapes)) ?? false }) { subject in
            subject.editor.service(ReferenceState.self)?.goToOriginal(of: Set(subject.shapes))
        }
        registrar.command(.interpretReference, title: ReferenceStyle.interpret,
                          isEnabled: { $0.editor.service(ReferenceState.self)?.canInterpret(Set($0.shapes)) ?? false }) { subject in
            subject.editor.service(ReferenceState.self)?.interpret(only: Set(subject.shapes))
        }
        // Expand and Collapse: a reference's mirror, and back to its pill, each one step over the shapes it's given.
        registrar.command(.expandReference, title: ReferenceStyle.expand,
                          isEnabled: { $0.editor.references?.canExpand($0.shapes) ?? false }) { subject in
            subject.editor.references?.expand(subject.shapes)
        }
        registrar.command(.collapseReference, title: ReferenceStyle.collapse,
                          isEnabled: { $0.editor.references?.canCollapse($0.shapes) ?? false }) { subject in
            subject.editor.references?.collapse(subject.shapes)
        }
        // What a mirror is laid out by: its original's size, wherever it is.
        registrar.layoutInput(MirrorLayout.original) { record, reading in
            guard let shape = record.typed(as: Reference.self), shape.props.look == .mirror else { return nil }
            return reading.service(ReferenceState.self)?.mirrorBody(of: shape, reading: reading)
        }
        // A double-click on a mirror: its pill re-points it, as a pill's does; its body opens what it shows there. A click
        // only selects it, so a click on the body of a mirror already selected edits nothing.
        registrar.shapeFaces(at: { editor, record, point in
            record.kind == Reference.kind ? editor.references?.mirrorFace(of: record, at: point) : nil
        }, click: { _, _ in }, doubleClick: { face, editor in
            switch face.part {
            case .pill: editor.beginEditing(face.mirror, clickCount: 2)
            case .body(let point): editor.references?.open(mirror: face.mirror, at: point, clickCount: 2)
            }
        })
        // A reference's own footer line: an arrow at it whose channel what it stands for doesn't take.
        registrar.contribute(DetailStatusContribution { shape, context in
            guard let line = context.service(ReferenceState.self)?.mismatchLine(of: shape.id) else { return [] }
            return [DetailStatus(line, tone: .warning)]
        }, to: DetailStatuses.self, for: .kind(Reference.kind))
        registrar.shapePopovers { editor, record, _ in editor.service(ReferenceState.self)?.popover(on: record) }
        registrar.contextMenuForCanvas {
            MenuItem(command: .goToOriginal, in: ReferencesMenuGroup.self,
                     when: { $0.editor.service(ReferenceState.self)?.canOffer(goingTo: $0.shapes) ?? false }, dims: true)
            // Right under Go to Original: Expand for pills (dimmed where none can show its original), Collapse for a mirror.
            MenuItem(command: .expandReference, in: ReferencesMenuGroup.self, when: { subject in
                guard let state = subject.editor.references, state.areReferences(subject.shapes) else { return false }
                return subject.shapes.contains { subject.editor.document[$0]?.typed(as: Reference.self)?.props.look == .pill }
            }, dims: true)
            MenuItem(command: .collapseReference, in: ReferencesMenuGroup.self, when: { subject in
                guard let state = subject.editor.references else { return false }
                return state.areReferences(subject.shapes) && state.canCollapse(subject.shapes)
            })
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
            // A mirror's handles scale it, in proportion (`CustomSizing`); a pill has none.
            reference.resizable(minimumSize: ReferenceStyle.mirrorMinimumSize)
            // Return on a mirror opens what it shows: types into it, or opens its board.
            reference.opens("Open", where: { shape, editor in editor.references?.opens(mirror: shape) ?? false }) { shape, editor in
                editor.references?.open(mirror: shape.id, at: nil)
            }
            reference.slashCommands {
                SlashCommand("expand", command: .expandReference, when: { $0.look == .pill && $0.mode != .empty })
                SlashCommand("collapse", command: .collapseReference, when: { $0.look == .mirror })
            }
            // Made to stand for a shape as picking it does, which refits its width to the name: how
            // `canvas draw` puts one beside what points at a shape on another board.
            reference.standsIn(admitting: { registry in registry.publicShapes },
                               needs: "public",
                               fulfilling: { record, registry in registry.makePublic(&record) },
                               calls: { shape, _ in shape.props.target?.label ?? (shape.props.mode == .dynamic ? shape.props.text : nil) },
                               makes: { props, target, label in ReferenceEdits.pick(&props, ReferenceTarget(id: target, label: label)) },
                               // Where its shape is, beside the name, when the name is another shape's too: fitted as a pick fits it.
                               seats: { props, seat, context in
                                   guard let target = props.target, let place = ReferenceState.place(of: target.id, at: seat, in: context) else { return }
                                   ReferenceEdits.fit(&props, place: place)
                               }) { shape, _ in
                if let target = shape.props.target { return .shapes([target.id]) }
                if let query = shape.props.query { return .provided(ReferenceState.key(query: query, all: shape.props.all)) }
                return nil
            }
            // The go button, the leading symbol, as a part: Return on it goes to the original, as its click does.
            reference.shapeParts(named: "go") { editor, shape in
                guard !editor.drawsSkeletons, let state = editor.service(ReferenceState.self), state.state(of: shape.props, id: shape.id).hasOriginal else { return [] }
                let box = ReferenceStyle.goBox(of: shape.props.frame, zoom: editor.camera.zoom)
                return [ShapePart(id: "go", title: ReferenceStyle.goToOriginal, role: .link, rect: box) { editor in
                    editor.service(ReferenceState.self)?.goToOriginal(shape.id)
                }]
            }
            // VoiceOver: "FieldValues.swift, Reference, in Shop › Policies": the name, the kind, the whole place.
            reference.accessibility { shape, editor in editor.service(ReferenceState.self)?.accessibleTraits(of: shape) }
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
                    _ = try queries.checkStored(query)
                    return []
                } catch {
                    return [.warning(error.message, field: "query")]
                }
            }
        }
    }
}
