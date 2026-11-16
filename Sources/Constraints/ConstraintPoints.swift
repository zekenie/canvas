import Canvas
import Palette
import Titles

// Constraints' points: the lists a container has from elsewhere (`InheritedConstraints`: a frame of a type, its
// type's), and the shapes that keep a list their own way, nothing judged against them (`ConstraintHolders`: a type
// note, which keeps its list in its schema).

// MARK: Lists from elsewhere

/// One list a container has from elsewhere (`InheritedConstraints`): the shape that holds it (a type, to go to), the color its
/// pill is drawn in (as Validation's `IssueScopeChip` is; none: the pill is plain) and the constraints, in order. What the holder
/// is called is no part of it: the panel and the menu read the holder's title as it is now (`editor.constraintSourceName(of:)`), so
/// a rename changes nothing the container is given.
public struct ConstraintSource: Hashable, Sendable {
    public var holder: ShapeID
    public var swatch: Swatch?
    public var constraints: [Constraint]

    public init(holder: ShapeID, swatch: Swatch? = nil, constraints: [Constraint]) {
        self.holder = holder
        self.swatch = swatch
        self.constraints = ConstraintList(constraints).constraints
    }
}

extension CanvasEditor {
    /// What the shape that gives a list is called now (its title; "Untitled" with none): read as the document has it, so a view
    /// that shows it draws again on a rename.
    public func constraintSourceName(of holder: ShapeID) -> String {
        shape(inFile: holder).flatMap { registry.title(of: $0) } ?? ConstraintsStyle.untitled
    }
}

/// The constraints a shape takes from elsewhere, beside its own (`InheritedConstraint`): Types gives a frame of a
/// type its types' lists, as it gives a note its type's color, and a type the lists of the types it is built on. Not keyed:
/// every contribution that reaches a kind is asked, in plugin order, and its sources kept in the order given (Types gives the
/// most general first). Asked of shapes of a kind that holds constraints (`constrainable()`), whose lists the index keeps, and of
/// a holder (`ConstraintHolders`), whose section and menu read them as they are (`index.sources(of:)`): one way in for every
/// giver, whatever keeps the shape's own list.
public enum InheritedConstraints {}

extension InheritedConstraints: ExtensionPoint {
    public typealias Contribution = InheritedConstraint
    public static var owner: PluginID { .constraints }
    /// A concern's lists for other kinds' shapes says which: the kinds that hold its property.
    public static var scope: PointScope { .scoped }

    /// "inherited constraints → every shape holding is".
    public static func summary(of _: InheritedConstraint, for target: ShapeTarget) -> String {
        "inherited constraints → \(target)"
    }
}

/// What `InheritedConstraints` stores: the lists a shape is given, by its id, with the editor whose services keep
/// what they're worked out from.
@MainActor
public struct InheritedConstraint {
    let sources: @MainActor (ShapeID, CanvasEditor) -> [ConstraintSource]
    /// The containers that read through a holder (a type's frames and subboards), as the file has them now: what a run that
    /// writes the holder reaches though it writes none of them.
    let readers: (@MainActor (ShapeID, CanvasEditor) -> Set<ShapeID>)?
}

extension ScopedRegistrar {
    /// The lists a container of the kinds the scope reaches has from elsewhere, beside its own:
    ///
    ///     registrar.forShapes(holding: IsAProperty.self) { $0.inheritedConstraints { id, editor in … } }
    ///
    /// Asked as a shape is first read, and again whenever a commit writes it; when what it gives changes with no
    /// commit to the shape (a type's list written), the plugin says so:
    /// `editor.constraintIndex?.inheritedConstraintsDidChange(of: ids)`.
    ///
    /// `readers` says, of a holder (`constraintHolder`), the containers that read through it, as the file has them: a run that
    /// writes the holder (`canvas draw` writing a type's `$constraints`) is told by `touched` to look at the members of each, which
    /// the containers' own lists, kept only for those that have one, could not name when the holder had none before.
    public mutating func inheritedConstraints(_ sources: @escaping @MainActor (ShapeID, CanvasEditor) -> [ConstraintSource],
                                              readers: (@MainActor (ShapeID, CanvasEditor) -> Set<ShapeID>)? = nil) {
        contribute(InheritedConstraint(sources: sources, readers: readers), to: InheritedConstraints.self)
    }
}

// MARK: Holders

/// A shape that keeps a list of constraints its own way (`ConstraintHolder`): a type note, which keeps it in its
/// schema. Nothing is judged against it (it is no place); the lists it keeps reach containers through
/// `InheritedConstraints`, and the writer and the panel read and write it through here. One a kind.
public enum ConstraintHolders {}

extension ConstraintHolders: KeyedExtensionPoint {
    public typealias Contribution = ConstraintHolder
    public static var owner: PluginID { .constraints }
    public static var scope: PointScope { .scoped }
    public static func uniqueKeys(of _: ConstraintHolder, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: ConstraintHolder, for target: ShapeTarget) -> String { "constraint holder → \(target)" }
}

/// How a holder keeps its list: read (nil for a shape of the kind that is no holder now: a note that isn't a type),
/// written inside a transaction it's handed (false when nothing could be written), and what each of its places is called
/// ("each sprint": the noun is the holder's), which heads its panel section ("Inside each sprint") and names it to the model, and
/// why it can't take a list just now, if it can't.
@MainActor
public struct ConstraintHolder {
    let read: @MainActor (AnyShapeRecord, CanvasEditor) -> [Constraint]?
    let write: @MainActor ([Constraint], ShapeID, inout Transaction) -> Bool
    let name: @MainActor (AnyShapeRecord, CanvasEditor) -> String?
    let reason: (@MainActor (AnyShapeRecord, CanvasEditor) -> String?)?
}

extension ScopedRegistrar {
    /// The shapes of the kinds the scope reaches keep a list of constraints their own way: `read` gives it (nil for
    /// a shape that holds none now), `write` puts a list in its place within the transaction handed it, and `name`
    /// says what each of its places is called ("each sprint"; nil for none yet), which Constraints heads its panel section with
    /// ("Inside each sprint") and tells the model. The lists the holder has from what it builds on (a type's from its
    /// supertypes) are `InheritedConstraints`', as a container's are: its section shows them dimmed and read-only, each
    /// going to its holder.
    ///
    /// It also gives the holder its section in the Rules tab (`ConstraintFacesPlugin`'s panel: its heading, its rows and the
    /// box that adds one), in the scope, in the order of the plugin that registers the holder: no second call.
    ///
    /// `reason` says why the holder can't take a list now (a type whose schema isn't JSON yet: "Schema isn't JSON yet."),
    /// short, for a shape `write` would refuse: it is what the bar says when `/constrain` can't add, what the panel shows under
    /// the box that adds one while the words wait there, and what VoiceOver hears; nil says nothing, and the words are Constraints'.
    public mutating func constraintHolder(read: @escaping @MainActor (AnyShapeRecord, CanvasEditor) -> [Constraint]?,
                                          write: @escaping @MainActor ([Constraint], ShapeID, inout Transaction) -> Bool,
                                          name: @escaping @MainActor (AnyShapeRecord, CanvasEditor) -> String?,
                                          reason: (@MainActor (AnyShapeRecord, CanvasEditor) -> String?)? = nil) {
        contribute(ConstraintHolder(read: read, write: write, name: name, reason: reason), to: ConstraintHolders.self)
        constraintHolderSection()
        registerConstraintsMenu(into: &self)
    }
}

extension CanvasEditor {
    /// The holder that keeps a shape's list its own way, if its kind has one and the shape holds a list now.
    func constraintHolder(of record: AnyShapeRecord) -> ConstraintHolder? {
        guard let holder = registry.contributions(to: ConstraintHolders.self, for: record.kind).first,
              holder.read(record, self) != nil else { return nil }
        return holder
    }

    /// What each place of a shape's holder is called ("each sprint"); nil for a shape that is no holder, and for one whose holder has
    /// no name yet.
    public func constraintPlaces(of id: ShapeID) -> String? {
        guard let record = shape(inFile: id), let holder = constraintHolder(of: record) else { return nil }
        return holder.name(record, self)
    }

    /// What a shape's holder heads its panel section with ("Inside each sprint"); nil as `constraintPlaces(of:)`.
    public func constraintHeading(of id: ShapeID) -> String? { constraintPlaces(of: id).map(ConstraintsStyle.inside) }
}
