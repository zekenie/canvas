import Canvas
import CanvasRPC
import Constraints
import Foundation

extension PluginID {
    public static let typeConstraints: PluginID = "type-constraints"
}

/// Types' constraints for Constraints: a type holds what each shape of it accepts inside it (`$constraints`, held aside in
/// its schema as `$rules` is: `registrar.typeDirective`), and a frame or a subboard of a type has its types' lists beside its
/// own, along the types' chain, the most general type's first (`InheritedConstraints`, as `TypeColorsPlugin` gives a typed
/// shape its type's color). A type note is a holder (`ConstraintHolders`): Constraints' writer reads and writes its list
/// here, one step, and its places are called "each sprint" (Constraints heads its panel section "Inside each sprint"). A plugin value of its own, after Constraints and
/// Types, so a list without Constraints leaves it out.
///
/// What a type holds changes with no commit to the frames of it, and Constraints is told then
/// (`inheritedConstraintsDidChange`): a type's list written, a type recolored (the color its pill has in a frame's panel), a
/// type's own types changed, a type that comes or goes (`TypeConstraints`). A rename is none: the pill reads the type's title as
/// it is now.
public struct TypeConstraintsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .typeConstraints }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.typeDirective(TypeConstraintBook.directive)
        registrar.service { TypeConstraints(editor: $0) }
        registrar.forShapes(holding: TypeSchemaProperty.self) { types in
            types.constraintHolder(read: { record, _ in
                record[TypeSchemaProperty.self].map { TypeConstraintBook.constraints(inSchema: $0.text) }
            }, write: { list, id, transaction in
                guard let board = transaction.board(containing: id),
                      let text = transaction.contents(of: board)[id]?[TypeSchemaProperty.self]?.text,
                      let written = TypeConstraintBook.text(text, setting: list), written != text else { return false }
                transaction.update(id, on: board) { $0[TypeSchemaProperty.self] = SchemaText(written) }
                return true
            }, name: { record, editor in
                editor.types?.name(of: record.id).flatMap(TypesStyle.each)
            }, reason: { record, _ in
                // A schema that isn't JSON yet (mid-edit), or JSON with no place for a list, has nowhere to put one.
                guard let text = record[TypeSchemaProperty.self]?.text, !TypeConstraintBook.takesList(inSchema: text) else { return nil }
                return TypeConstraintBook.isJSON(text) ? TypesStyle.schemaTakesNoList : TypesStyle.schemaNotJSON
            })
        }
        registrar.forShapes(holding: IsAProperty.self) { typed in
            typed.inheritedConstraints({ id, editor in editor.typeConstraints?.sources(of: id) ?? [] },
                                       readers: { type, editor in editor.typeConstraints?.readers(of: type) ?? [] })
        }
    }
}

/// Where a type keeps its constraints, and reading them: `"$constraints": {"const": [{"says": "only tasks", "query":
/// ":is-a(\"Task\")", "reach": "children"}]}` in the root's `properties`, the JSON of Constraints' one codec
/// (`ConstraintList`), a directive Types holds aside (`registrar.typeDirective`), so the model that keeps a type's words and
/// schema in step never sees it, a schema written whole keeps it unless it says it, and a change to it alone is no
/// change to the type's fields.
public enum TypeConstraintBook {
    /// The directive's name: `$constraints`.
    public static let directive = "constraints"
    static let held = HeldDirective(name: directive)

    /// A type's constraints as its schema's text says them: nil for text that isn't a JSON object (a schema mid-edit), else
    /// what `constraints(inSchema:)` gives.
    static func reading(inSchema text: String) -> [Constraint]? {
        guard let root = try? JSONReader.read(text), root.isObject else { return nil }
        return constraints(inSchema: text)
    }

    /// A type's constraints, as its schema's text says them, in order; none for text that isn't JSON, a schema without the
    /// member, or a member that isn't a list. Read as a list is anywhere (`ConstraintList`): a member that isn't a
    /// constraint, has no words or repeats one before it is passed over.
    public static func constraints(inSchema text: String) -> [Constraint] {
        guard let literal = held.constant(in: text), let data = literal.data(using: .utf8),
              let list = try? JSONDecoder().decode(ConstraintList.self, from: data) else { return [] }
        return list.constraints
    }

    /// Whether a schema's text reads as JSON at all (the reason a type takes no list is one of two: it isn't, or it has no place).
    static func isJSON(_ text: String) -> Bool { (try? JSONReader.read(text)) != nil }

    /// Whether a schema's text can take a list: it is a JSON object whose `properties` (if any) is one.
    static func takesList(inSchema text: String) -> Bool {
        held.text(text, setting: ConstraintList([Constraint(says: "x")]).jsonText) != nil
    }

    /// `text` with `list` as its member (none takes the member away), the rest of the text as typed; nil when it isn't a JSON
    /// object or its `properties` isn't one.
    public static func text(_ text: String, setting list: [Constraint]) -> String? {
        let list = ConstraintList(list).constraints
        return held.text(text, setting: list.isEmpty ? nil : ConstraintList(list).jsonText)
    }
}

extension TypesStyle {
    /// Why a type takes no constraint, said in the bar's label (a failure's words are cut at its width, which a test holds), under
    /// the box that adds one and to VoiceOver, so it names no type: the type is what is selected, or the section's heading.
    /// For text that doesn't read as JSON, and for JSON whose root isn't an object or whose `properties` isn't one.
    public static let schemaNotJSON = "Schema isn't JSON yet."
    public static let schemaTakesNoList = "Schema takes no list."
    /// Both reasons, for a test to measure.
    public static let schemaReasons = [schemaNotJSON, schemaTakesNoList]

    /// What each shape of a type is called, its noun after "each": "each sprint" (the type's English rules are headed "Each
    /// sprint", its constraints "Inside each sprint").
    public static func each(_ name: String) -> String? {
        name.isEmpty ? nil : "each \(TypeNoun.of(name))"
    }
}

/// What the file's types give the containers of them, and the telling of Constraints when it changes with no commit to a
/// container: the lists a shape has from its types (`sources(of:)`, read as the type index has them) and what was last seen
/// of each type that holds some (its list), so a commit that changed a type's list, recolored it, changed what it is built on,
/// or took it away or brought it back tells the shapes that read through it, which are the frames and subboards of it
/// (`allInstances`; the ones of a kind that holds constraints are asked again) and the types built on it (holders, whose
/// section shows the lists they have from it: told, not read), and nothing else: a rename tells none.
@MainActor
public final class TypeConstraints {
    private struct Seen: Equatable {
        var list: [Constraint]
    }

    private weak var editor: CanvasEditor?
    /// What each type that holds a list was last seen with.
    @ObservationIgnored private var seen: [ShapeID: Seen] = [:]
    /// Each type's list as its schema's text said it (the parse is the cost: it is kept until the text changes).
    @ObservationIgnored private var parsed: [ShapeID: (text: String, list: [Constraint])] = [:]

    init(editor: CanvasEditor) {
        self.editor = editor
        guard let types = editor.types else { return }
        readEveryType()
        types.onChange { [weak self] change in self?.heard(change) }
        types.onHeldChange { [weak self] change in self?.heard(change) }
    }

    /// The lists a shape has from its types: along its chain, the most general type's first (`TypeIndex.lineage(of:)` has
    /// the nearest first), one a type that holds a list, its holder and its look. For a type, the lists of
    /// the types it is built on.
    public func sources(of shape: ShapeID) -> [ConstraintSource] {
        guard let types = editor?.types else { return [] }
        var found: [ConstraintSource] = []
        for type in types.lineage(of: shape).reversed() where types.isType(type) {
            let list = self.list(of: type, in: types)
            guard !list.isEmpty else { continue }
            found.append(ConstraintSource(holder: type, swatch: types.look(of: type).swatch, constraints: list))
        }
        return found
    }

    /// The frames and subboards that read through a type: those of it, however far (`allInstances`), of a kind that holds
    /// constraints. What a run that writes the type's `$constraints` reaches.
    public func readers(of type: ShapeID) -> Set<ShapeID> {
        guard let editor, let types = editor.types, types.isType(type) else { return [] }
        return types.allInstances(of: type).filter { editor.file.record($0).map { editor.registry.isConstrainable($0.kind) } == true }
    }

    /// A type's list now. While its schema isn't a JSON object (typed halfway), the list it last had: the frames keep it, and
    /// fixing the JSON tells nobody.
    private func list(of type: ShapeID, in types: TypeIndex) -> [Constraint] {
        guard let text = types.schemaText(of: type) else { return [] }
        if let kept = parsed[type], kept.text == text { return kept.list }
        guard let list = TypeConstraintBook.reading(inSchema: text) else { return seen[type]?.list ?? [] }
        parsed[type] = (text, list)
        return list
    }

    private func readEveryType() {
        guard let types = editor?.types else { return }
        seen = [:]
        parsed = [:]
        for type in types.types {
            let list = self.list(of: type, in: types)
            if !list.isEmpty { seen[type] = Seen(list: list) }
        }
    }

    // MARK: Hearing the types

    private func heard(_ change: TypeChange) {
        guard let types = editor?.types else { return }
        if change.everything {
            // Every place reads its lists again when a file is put in place.
            readEveryType()
            return
        }
        var told = refresh(change.types.union(change.membership), in: types)
        // A type that came, went or has other types now: what its shapes have from the chain changes through it, whether or not
        // it holds a list (a type with none, built on one that does).
        if !seen.isEmpty || !told.isEmpty {
            told.formUnion(change.membership.union(change.lineage))
            // A shape that is no type but has instances: the chain goes on through it, so its own `is` changing reaches them.
            told.formUnion(change.lists.filter { !types.isType($0) && types.hasInstances($0) })
        }
        tell(told, in: types)
    }

    private func heard(_ change: TypeHeldChange) {
        guard let types = editor?.types else { return }
        var told = refresh(change.held, in: types)
        told.formUnion(change.recolored.filter { seen[$0] != nil })
        tell(told, in: types)
    }

    /// Reads the lists of `ids` again: those whose list changed, or that held one and no longer do.
    private func refresh(_ ids: Set<ShapeID>, in types: TypeIndex) -> Set<ShapeID> {
        var changed: Set<ShapeID> = []
        for id in ids {
            let list = types.isType(id) ? self.list(of: id, in: types) : []
            if !types.isType(id) { parsed[id] = nil }
            let now = list.isEmpty ? nil : Seen(list: list)
            guard now != seen[id] else { continue }
            seen[id] = now
            changed.insert(id)
        }
        return changed
    }

    /// Constraints hears of every shape that reads through these types.
    private func tell(_ told: Set<ShapeID>, in types: TypeIndex) {
        guard !told.isEmpty, let index = editor?.constraintIndex else { return }
        // What reads through them, however far: instances and the types built on them, and the types themselves.
        var instances = types.affected(by: told).union(told)
        // Only the frames and subboards read through a type, and the types built on it, whose sections show their lists (holders); a
        // note of it is no place.
        if let editor {
            instances = instances.filter { id in
                editor.file.record(id).map { editor.registry.isConstrainable($0.kind) } == true || types.isType(id)
            }
        }
        if !instances.isEmpty { index.inheritedConstraintsDidChange(of: instances) }
    }
}

extension TypeConstraints: EditorService {}

extension CanvasEditor {
    /// What the file's types give the containers of them; nil without `TypeConstraintsPlugin`.
    public var typeConstraints: TypeConstraints? { service(TypeConstraints.self) }
}
