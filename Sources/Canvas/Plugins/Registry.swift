import AppKit
import CanvasRPC
import Foundation

/// Everything the installed plugins registered: built once from the plugin list, checked, then
/// frozen and handed to each editor. Tests build their own.
@MainActor
public struct Registry {
    /// Core first, then the plugin list's order.
    let pluginIDs: [PluginID]
    private let byPoint: [ObjectIdentifier: [RawContribution]]
    /// What `contributions(to:for:)` returns, worked out once, since plugins ask per shape (every
    /// shape in a frame, some of them): for each kind with contributions of its own to a point, or
    /// that a scoped contribution reaches, its own, then those for every kind and those whose scope
    /// reaches it, each in plugin order; every kind's alone (`forAnyKind`) for a kind with neither.
    /// Scopes are resolved last (`resolveScopes`), once everything they read is built.
    private var forKind: [ObjectIdentifier: [ShapeKind: [RawContribution]]]
    private let forAnyKind: [ObjectIdentifier: [RawContribution]]
    /// While capabilities' tests run (`resolveScopes`), on the registry they're handed: the points that
    /// have scoped contributions, which a test may not ask about, since their answer is what's being
    /// worked out.
    private var resolvingScopes = false
    private var scopedPoints: Set<ObjectIdentifier> = []
    /// The kinds each capability a scope names picks, worked out as scopes are resolved.
    private var capabilityKinds: [ShapeCapability: Set<ShapeKind>] = [:]
    private let all: [RawContribution]
    private let definitions: [ShapeKind: any ShapeDefinition]
    /// Kinds whose props are bound to other shapes (`ShapeReferencing`): what a deletion asks to
    /// let go, and what a plugin that follows bindings asks (`record.boundShapes(in:)`), so only
    /// these are walked. Not the kinds that only name shapes (`namingKinds`).
    public let referencingKinds: Set<ShapeKind>
    /// Kinds whose shapes take the shapes bound to them along when they are deleted or copied
    /// (`TakesBoundShapes`).
    public let takingBoundKinds: Set<ShapeKind>
    /// Kinds whose shapes can hold names of shapes (`ShapeNaming`): in their own props, or in an
    /// added property they opt into. A copy renames the names of these kinds' shapes, and a plugin
    /// that follows names walks only these (`record.forEachNamingValue`); no other shape holds one.
    public let namingKinds: Set<ShapeKind>
    /// Kinds whose shapes own boards (`BoardOwning`).
    public let boardOwningKinds: Set<ShapeKind>
    /// Kinds whose shapes contain shapes on their own board (`ShapeContaining`: a frame). Without
    /// one, nothing is in a container, and the core does nothing of containment (Containment.swift).
    public let containingKinds: Set<ShapeKind>
    /// Kinds whose shapes make room below them as they grow (`MakesRoomAsItGrows`): what `Transaction.makeRoom()`
    /// looks for among what a step changed. Without one, it does nothing.
    public let roomMakingKinds: Set<ShapeKind>

    /// The room a shape of `kind` keeps clear below it as it grows (`MakesRoomAsItGrows.roomKeptBelow`), world units: what a
    /// layout that puts such shapes down leaves below each (draw's placing, a paste's grid), so the first row typed into one covers
    /// nothing below it before any push. None for a kind that doesn't make room.
    public func roomKeptBelow(_ kind: ShapeKind) -> CGFloat {
        guard roomMakingKinds.contains(kind) else { return 0 }
        return (definition(for: kind) as? any MakesRoomAsItGrows)?.roomKeptBelow ?? 0
    }
    /// Kinds that draw a skeleton of their own (`CustomSkeleton`), found once: a frame zoomed out
    /// asks for every shape it draws.
    let customSkeletons: [ShapeKind: any CustomSkeleton]
    /// Those outlined their own way (`CustomSkeletonOutline`), found once: ⌘A zoomed out outlines
    /// every shape in view, and asks only these.
    let skeletonOutlines: [ShapeKind: any CustomSkeletonOutline]
    /// Those drawn as a line (`StrokedShape`), found once: a tinted outline of an open shape is
    /// stroked to cover its line, and asks only these.
    let strokedShapes: [ShapeKind: any StrokedShape]
    /// Kinds laid out at another size than their box (`LaidOutBox`), found once: every shape's frame asks.
    let laidOutBoxes: [ShapeKind: any LaidOutBox]
    /// The kinds whose shapes have parts (`PartedShape`), with their definitions.
    let partedDefinitions: [ShapeKind: any PartedShape]
    /// Kinds whose shapes take a frame they're given their own way (`CustomSizing`), found once.
    let customSizings: [ShapeKind: any CustomSizing]
    /// What provides each layout input (`registrar.layoutInput`), by the key's name, found once: a
    /// shape laid out asks for its inputs.
    let layoutProviders: [String: LayoutProvider]
    /// Every plugin's rule for which shapes can't change (`registrar.readOnlyShapes`), found once:
    /// a transaction asks them about every shape it changes.
    private let readOnlyRules: [@MainActor (AnyShapeRecord) -> Bool]
    /// Every plugin's tint for a shape of its own (`registrar.shapeTints`), found once, in plugin
    /// order: `editor.tint(of:)` asks them.
    let shapeTintRules: [@MainActor (AnyShapeRecord, CanvasEditor) -> NSColor?]
    /// The tools that place a kind's shapes (`ShapeRegistrar.tool`): none is enabled on a board that
    /// can't change (`editor.isToolEnabled`).
    let placingTools: Set<ToolID>
    /// The plugin that gives each tool: an off kit's tool isn't enabled in a file (`editor.isToolEnabled`).
    let toolPlugins: [ToolID: PluginID]
    /// The kits plugins join (`registrar.join`): which they are, and which plugin is in which.
    let kitTable: KitTable
    /// Added properties: who declares each, and which kinds opt in.
    let propertyTable: PropertyTable
    /// File properties (`FileProperty`), by key: how each declared one's value is read and written.
    let fileProperties: [PropertyKey: FilePropertyCodec]
    /// Each kind's schema (`schema(for:)`), described once, as the registry is built.
    private let schemas: [ShapeKind: JSONSchema]
    /// The same, compiled to check its shapes against (`schemaViolations(of:)`).
    let schemaValidators: [ShapeKind: SchemaValidator]

    /// What `memo(_:_:)` keeps.
    private let memos = RegistryMemos()

    public init(plugins: [any CanvasPlugin]) throws(RegistryError) {
        let plugins: [any CanvasPlugin] = [CorePlugin()] + plugins
        var ids: [PluginID] = []
        var contributions: [RawContribution] = []
        for plugin in plugins {
            guard !ids.contains(plugin.id) else { throw .duplicatePlugin(plugin.id) }
            ids.append(plugin.id)
            var registrar = PluginRegistrar(pluginID: plugin.id)
            plugin.register(into: &registrar)
            contributions += registrar.contributions
        }
        // What the core gives once plugins join kits: its file value, each kit's item in File ▸ Kits, and each
        // kit's tools' Insert items in its submenu.
        let kitted = Self.kitContributions(contributions)
        contributions = kitted.contributions
        try Self.check(contributions, installed: ids)
        pluginIDs = ids
        // Stable: contributions keep plugin order within each point.
        all = ids.flatMap { id in contributions.filter { $0.pluginID == id } }
        byPoint = Dictionary(grouping: all, by: \.point)
        forAnyKind = byPoint.mapValues { $0.filter { $0.target == .any } }
        forKind = byPoint.mapValues { point in
            let anyKind = point.filter { $0.target == .any }
            return Dictionary(grouping: point.filter { if case .kind = $0.target { true } else { false } }, by: \.target).reduce(into: [:]) { kinds, own in
                if case .kind(let kind) = own.key { kinds[kind] = own.value + anyKind }
            }
        }
        let shapes = byPoint[ObjectIdentifier(CorePoints.Shapes.self)] ?? []
        definitions = Dictionary(shapes.map {
            let shape = $0.value as! ShapeRegistration
            return (shape.kind, shape.definition)
        }, uniquingKeysWith: { first, _ in first })
        referencingKinds = Set(definitions.filter { $0.value is any ShapeReferencing }.keys)
        takingBoundKinds = Set(definitions.filter { $0.value is any TakesBoundShapes }.keys)
        boardOwningKinds = Set(definitions.filter { $0.value is any BoardOwning }.keys)
        containingKinds = Set(definitions.filter { $0.value is any ShapeContaining }.keys)
        roomMakingKinds = Set(definitions.filter { $0.value is any MakesRoomAsItGrows }.keys)
        laidOutBoxes = definitions.compactMapValues { $0 as? any LaidOutBox }
        partedDefinitions = definitions.compactMapValues { $0 as? any PartedShape }
        // A container's edge is its box: what it holds is judged by it, and a resize edits it.
        if let kind = laidOutBoxes.keys.filter(containingKinds.contains).min(by: { $0.rawValue < $1.rawValue }) {
            throw .invalid(point: "Shapes", reason: "\(kind) holds shapes, so it can't be laid out past its box")
        }
        customSizings = definitions.compactMapValues { $0 as? any CustomSizing }
        customSkeletons = definitions.compactMapValues { $0 as? any CustomSkeleton }
        skeletonOutlines = definitions.compactMapValues { $0 as? any CustomSkeletonOutline }
        strokedShapes = definitions.compactMapValues { $0 as? any StrokedShape }
        layoutProviders = Dictionary((byPoint[ObjectIdentifier(CorePoints.LayoutProviders.self)] ?? []).map {
            let provider = $0.value as! LayoutProvider
            return (provider.name, provider)
        }, uniquingKeysWith: { first, _ in first })
        readOnlyRules = (byPoint[ObjectIdentifier(CorePoints.ReadOnlyRules.self)] ?? []).map { $0.value as! CorePoints.ReadOnlyRules.Contribution }
        shapeTintRules = (byPoint[ObjectIdentifier(CorePoints.ShapeTints.self)] ?? []).map { $0.value as! CorePoints.ShapeTints.Contribution }
        placingTools = Set((byPoint[ObjectIdentifier(CorePoints.Tools.self)] ?? []).compactMap {
            let tool = $0.value as! ToolRegistration
            return tool.placement == nil ? nil : tool.descriptor.id
        })
        toolPlugins = Dictionary((byPoint[ObjectIdentifier(CorePoints.Tools.self)] ?? []).map { (($0.value as! ToolRegistration).descriptor.id, $0.pluginID) },
                                 uniquingKeysWith: { first, _ in first })
        kitTable = kitted.table
        let declarations = byPoint[ObjectIdentifier(CorePoints.PropertyDeclarations.self)] ?? []
        let table = try PropertyTable(declarations: declarations,
                                      optIns: byPoint[ObjectIdentifier(CorePoints.PropertyOptIns.self)] ?? [],
                                      definitions: definitions,
                                      kinds: shapes.map { ($0.value as! ShapeRegistration).kind })
        propertyTable = table
        fileProperties = Dictionary((byPoint[ObjectIdentifier(CorePoints.FilePropertyDeclarations.self)] ?? []).map {
            let codec = ($0.value as! FilePropertyDeclaration).codec
            return (codec.key, codec)
        }, uniquingKeysWith: { first, _ in first })
        namingKinds = Set(definitions.filter { kind, definition in
            definition.propsNameShapes || (table.byKind[kind] ?? []).contains { table.codecs[$0]?.naming != nil }
        }.keys)
        // Every declared property's schema, and every kind's, is described and compiled once now, so
        // that what can't be described (two types under one name, a struct that holds itself in
        // place), a member some struct doesn't list (which a board would never save), and a schema
        // that can't be checked against (a `$ref` to nowhere, or back to itself without end, a
        // pattern that isn't a regular expression) refuse the plugin list now, not at the first save,
        // or as a warning on every shape of the kind. Properties first, so a problem in a property's
        // value is its declarer's, not that of the first kind that opts in.
        for c in declarations {
            let codec = (c.value as! PropertyDeclaration).codec
            var described = SchemaDefinitions()
            var json = codec.schema(&described)
            if !described.json.isEmpty { json["$defs"] = .object(described.json) }
            let problems = (codec.holdsOptionals ? ["its value is an optional, or holds optionals in a collection, which a schema can't say"] : [])
                + (codec.defaultValue.map(codec.isNone) == true ? ["its default is a value that's none (isNone), which no shape holds"] : [])
                + Self.problems(of: described) + SchemaValidator(JSONSchema(json)).problems.map { "its schema is broken: \($0)" }
            if let problem = problems.first {
                throw .invalid(point: c.pointName, reason: "property \(codec.key) (from \(c.pluginID)): \(problem)")
            }
        }
        var schemas: [ShapeKind: JSONSchema] = [:], validators: [ShapeKind: SchemaValidator] = [:]
        for c in shapes {
            let shape = c.value as! ShapeRegistration
            var described = SchemaDefinitions()
            let schema = Self.schema(of: shape.kind, defined: shape.definition, properties: propertyTable, in: &described)
            let validator = SchemaValidator(schema)
            if let problem = Self.problems(of: described, props: shape.definition.propsType).first
                ?? validator.problems.first.map({ "its schema is broken: \($0)" }) {
                throw .invalid(point: c.pointName, reason: "\(shape.kind) (from \(c.pluginID)): \(problem)")
            }
            schemas[shape.kind] = schema
            validators[shape.kind] = validator
        }
        self.schemas = schemas
        schemaValidators = validators
        try resolveScopes()
        // Owners are installed, keys unique and scopes resolved by now, so a point's own rules can
        // rely on all three.
        var checked: Set<ObjectIdentifier> = []
        for c in all where checked.insert(c.point).inserted {
            do { try c.pointType.check(self) }
            catch let error as RegistryError { throw error }
            catch { throw .invalid(point: c.pointName, reason: "\(error)") }
        }
    }

    private static func check(_ contributions: [RawContribution], installed: [PluginID]) throws(RegistryError) {
        let kinds = Set(contributions.filter { $0.point == ObjectIdentifier(CorePoints.Shapes.self) }.map(\.target))
        let declared = Set(contributions.compactMap { ($0.value as? PropertyDeclaration)?.codec.key })
        var claimed: [ObjectIdentifier: [AnyHashable: PluginID]] = [:]
        for c in contributions {
            guard installed.contains(c.owner) else {
                throw .ownerNotInstalled(point: c.pointName, owner: c.owner, contributor: c.pluginID)
            }
            if case .kind(let kind) = c.target, !kinds.contains(c.target) {
                throw .unknownKind(kind, point: c.pointName, contributor: c.pluginID)
            }
            if case .holding(let key) = c.target, !declared.contains(key) {
                throw .invalid(point: c.pointName, reason: "\(c.pluginID) contributes for \(c.target), which no installed plugin declares")
            }
            switch (c.pointType.scope, c.target) {
            case (.scoped, .any):
                throw .invalid(point: c.pointName, reason: "\(c.pluginID) contributes for every shape with no scope; say which shapes it's for: "
                               + "forShapes(holding:), forShapes(adopting:), or forEveryShape for what every shape has")
            case (.kinds, .any), (.kinds, .holding), (.kinds, .adopting):
                throw .invalid(point: c.pointName, reason: "\(c.pluginID) contributes for \(c.target == .any ? "every shape" : "\(c.target)"); "
                               + "it takes one kind at a time")
            default: break
            }
            for key in c.keys {
                if let first = claimed[c.point]?[key] {
                    throw .conflict(point: c.pointName, key: "\(key.base)", plugins: [first, c.pluginID])
                }
                claimed[c.point, default: [:]][key] = c.pluginID
            }
        }
    }

    // MARK: Extension points

    /// Every contribution to a point, in plugin order.
    public func contributions<P: ExtensionPoint>(to point: P.Type) -> [Contributed<P.Contribution>] {
        (byPoint[ObjectIdentifier(P.self)] ?? []).map { Contributed(value: $0.value as! P.Contribution, target: $0.target, pluginID: $0.pluginID) }
    }

    /// The contributions that apply to a kind: those for that kind, then those for every kind and those
    /// whose scope reaches it (`forShapes(holding:)`, `forShapes(adopting:)`, `forEveryShape`), each in
    /// plugin order. A scoped contribution reaches no other kind, so a horizontal filters nothing.
    public func contributions<P: ExtensionPoint>(to point: P.Type, for kind: ShapeKind) -> [P.Contribution] {
        // A closure, not `\.value`: a key path in a generic function is built again on every call.
        reaching(ObjectIdentifier(P.self), kind, from: P.self).map { $0.value as! P.Contribution }
    }

    /// The same, with where each came from: for a reader that tells a kind's own from the rest.
    public func contributions<P: ExtensionPoint>(to point: P.Type, reaching kind: ShapeKind) -> [Contributed<P.Contribution>] {
        reaching(ObjectIdentifier(P.self), kind, from: P.self).map {
            Contributed(value: $0.value as! P.Contribution, target: $0.target, pluginID: $0.pluginID)
        }
    }

    private func reaching<P: ExtensionPoint>(_ point: ObjectIdentifier, _ kind: ShapeKind, from _: P.Type) -> [RawContribution] {
        if resolvingScopes {
            precondition(!scopedPoints.contains(point), "a capability's test asked for the contributions to \(P.self), which scopes reach")
        }
        return forKind[point]?[kind] ?? forAnyKind[point] ?? []
    }

    /// Works out which kinds each scoped contribution reaches, as the last of what the registry builds:
    /// `.holding` the kinds that opt into the property, `.adopting` those a capability's test picks
    /// (asked once a kind, of the registry with no scope resolved, which its test may read but for the
    /// points that have scoped contributions). Then, for each point a scope reaches, every kind's list is its
    /// own, then every kind's and the scoped ones that reach it, in plugin order; and two of those that
    /// claim one key on a kind are a conflict, as two for every kind always were (a kind's own may: it
    /// takes the place of the rest, wherever a point keeps the first).
    private mutating func resolveScopes() throws(RegistryError) {
        let scoped = all.filter(\.target.isScoped)
        guard !scoped.isEmpty else { return }
        let kinds = self.kinds
        var holders: [PropertyKey: Set<ShapeKind>] = [:]
        for (kind, keys) in propertyTable.byKind {
            for key in keys { holders[key, default: []].insert(kind) }
        }
        var asked = self
        asked.resolvingScopes = true
        asked.scopedPoints = Set(scoped.map(\.point))
        var picked: [ShapeCapability: Set<ShapeKind>] = [:]
        for c in scoped {
            guard case .adopting(let capability) = c.target, picked[capability] == nil else { continue }
            picked[capability] = Set(kinds.filter { kind in
                asked.registeredKind(kind).map(capability.test) ?? false
            })
        }
        for point in Set(scoped.map(\.point)) {
            let contributions = byPoint[point] ?? []
            var table: [ShapeKind: [RawContribution]] = [:]
            for kind in kinds {
                let reaching = contributions.filter {
                    switch $0.target {
                    case .kind: false
                    case .any: true
                    case .holding(let key): holders[key]?.contains(kind) == true
                    case .adopting(let capability): picked[capability]?.contains(kind) == true
                    }
                }
                let own = contributions.filter { $0.target == .kind(kind) }
                // A kind no scope reaches, with none of its own, reads every kind's (`forAnyKind`).
                guard !own.isEmpty || reaching.contains(where: \.target.isScoped) else { continue }
                table[kind] = own + reaching
                var claimed: [AnyHashable: PluginID] = [:]
                for c in reaching {
                    for key in c.keys(for: .kind(kind)) {
                        if let first = claimed[key] { throw .conflict(point: c.pointName, key: "\(key.base)", plugins: [first, c.pluginID]) }
                        claimed[key] = c.pluginID
                    }
                }
            }
            forKind[point] = table
        }
        capabilityKinds = picked
    }

    /// Whether a contribution for `target` is for a kind: its own, every kind's, or a scope's that
    /// reaches it. For a reader that keeps contributions for many kinds together and picks among
    /// them for a set of shapes (the items for the canvas a menu over shapes shows).
    public func reaches(_ target: ShapeTarget, _ kind: ShapeKind) -> Bool {
        switch target {
        case .kind(let own): own == kind
        case .any: true
        case .holding(let key): properties(for: kind).contains(key)
        case .adopting(let capability):
            capabilityKinds[capability]?.contains(kind) ?? memo(CapabilityKindKey(capability: capability, kind: kind)) {
                registeredKind(kind).map(capability.test) ?? false
            }
        }
    }

    /// A value a plugin works out of this registry once, per key, since the registry never changes:
    /// what a per-shape or per-frame question would otherwise work out again each time (a kind's
    /// contributions filtered, say). The key names the value and its kind: a plugin's own type and
    /// the kind.
    public func memo<Key: Hashable, Value>(_ key: Key, _ make: () -> Value) -> Value {
        let table = memos.table(Key.self, Value.self)
        if let known = table.values[key] { return known }
        let made = make()
        table.values[key] = made
        return made
    }

    /// For a point that takes one contribution per kind, plus one for every kind (keyed by
    /// `[target]`, as a rule is): each installed kind's own, else every kind's. A kind with neither
    /// isn't in it. Worked out on each call: keep what it returns, as the registry never changes.
    public func contributionByKind<P: ExtensionPoint>(to point: P.Type) -> [ShapeKind: P.Contribution] {
        kinds.reduce(into: [:]) { byKind, kind in byKind[kind] = contributions(to: P.self, for: kind).first }
    }

    // MARK: The core's points

    public var kinds: [ShapeKind] { contributions(to: CorePoints.Shapes.self).map(\.value.kind) }

    public func definition(for kind: ShapeKind) -> (any ShapeDefinition)? { definitions[kind] }

    /// Whether a kind's shapes may be laid out at another size than their box (`LaidOutBox`).
    public func isLaidOutBox(_ kind: ShapeKind) -> Bool { laidOutBoxes[kind] != nil }

    /// The kinds whose shapes have parts (`PartedShape`): their rows.
    public var partedKinds: Set<ShapeKind> { Set(partedDefinitions.keys) }

    /// Whether a kind's shapes have parts (`PartedShape`), a look-up.
    public func isParted(_ kind: ShapeKind) -> Bool { partedDefinitions[kind] != nil }

    /// Whether every shape of a kind is all its one row (`PartedShape.isAllItsOneRow`), a look-up.
    public func isAllItsOneRow(_ kind: ShapeKind) -> Bool { partedDefinitions[kind]?.isAllItsOneRow == true }

    /// A shape's parts, in reading order, as its kind says them (`PartedShape.parts(of:)`): each one's id, name,
    /// kind word, lead and whether it stands alone. Nil for a shape of a kind with no parts (or none installed).
    public func parts(of shape: AnyShapeRecord) -> [PartName]? {
        partedDefinitions[shape.kind]?.erasedParts(of: shape)
    }

    /// Whether `part` of `shape` is no part that only heads rows (a path prefix: `PartName.isConnectable`). True for a part the
    /// shape doesn't list, which a binding through a pill names (the row of the shape it stands for).
    public func isConnectable(part: PartID, of shape: AnyShapeRecord) -> Bool {
        parts(of: shape)?.first { $0.id == part }?.isConnectable ?? true
    }

    /// `shape` with these parts taken out (`PartedShape.removing(_:from:)`), keeping its metadata; nil when its kind has
    /// no parts, doesn't take them out by id, or it has none of them. The writer then hands them to `removeParts`.
    public func removing(_ parts: Set<PartID>, from shape: AnyShapeRecord) -> AnyShapeRecord? {
        partedDefinitions[shape.kind]?.erasedRemoving(parts, from: shape)
    }

    /// Whether a kind's shapes take a frame they're given their own way (`CustomSizing`).
    public func takesFramesItsOwnWay(_ kind: ShapeKind) -> Bool { customSizings[kind] != nil }

    /// The shape given `frame`, in world units, as a resize by hand or `canvas draw`'s `size:` gives it, `axes` saying
    /// which ways the frame gives its size, over `context` (the shapes as the writer has them): as its kind takes it
    /// (`CustomSizing`: a note keeps a height it's given as the least it is, and is as tall as its words need), else
    /// its box. As it is for a shape kept aside or with no box.
    public func sized(_ record: AnyShapeRecord, to frame: CGRect, giving axes: SizeAxes, in context: ShapeContext) -> AnyShapeRecord {
        guard !record.isOpaque, record.box != nil else { return record }
        var record = record
        if let sizing = customSizings[record.kind] { sizing.erasedSize(&record, to: frame, giving: axes, in: context) } else { record.box = frame }
        return record
    }

    /// The ways a resize by hand gives a shape its size (`CustomSizing.resizedAxes`): both for a kind that doesn't say.
    public func resizedAxes(of record: AnyShapeRecord) -> SizeAxes {
        customSizings[record.kind].map { $0.erasedResizedAxes(of: record) } ?? .both
    }

    /// Whether a shape is resized by hand as far as its kind says (`CustomSizing.isResizable`): true for a kind that
    /// says nothing of it. Which kinds resize at all is Selection's (`ShapeResizing`).
    public func isResizable(_ record: AnyShapeRecord, in context: ShapeContext) -> Bool {
        customSizings[record.kind].map { $0.erasedIsResizable(record, in: context) } ?? true
    }

    /// A shape's outline as its kind draws it (its kind's `indicatorPath`), in world units: on the
    /// shape's own edge, which the core grows outward before it strokes a selection, a hover or the
    /// hint (`CanvasEditor.outlinePath(of:)`, `outlineGap`). For an overlay that decorates a shape
    /// along it and grows the outline itself (Validation's ring). Nil for a shape kept aside, or of
    /// a kind no plugin defines.
    public func indicatorPath(of shape: AnyShapeRecord, in context: ShapeContext) -> CGPath? {
        shape.isOpaque ? nil : definition(for: shape.kind)?.erasedIndicatorPath(of: shape, in: context)
    }

    /// How wide a shape's line is drawn, in world units, if its kind is drawn as a line
    /// (`StrokedShape`): what the canvas covers it with when it's lit (`Outlines.tinted`), and what an
    /// overlay that decorates the line goes by. Nil for any other kind, a shape kept aside, or one of
    /// a kind no plugin defines.
    public func lineWidth(of shape: AnyShapeRecord, in context: ShapeContext) -> CGFloat? {
        shape.isOpaque ? nil : strokedShapes[shape.kind]?.erasedLineWidth(of: shape, in: context)
    }

    /// Whether a shape's board can be shown wherever the shape's own board can: it isn't kept
    /// aside, and its kind owns boards (`BoardOwning`). What `canShow` asks of every owner on a
    /// board's path, so what walks a file's boards from the root down asks it too.
    public func ownsShowableBoard(_ shape: AnyShapeRecord) -> Bool { !shape.isOpaque && boardOwningKinds.contains(shape.kind) }

    /// Whether a plugin's rule says the shape can't change (`registrar.readOnlyShapes`), by the record
    /// alone: what a rule says of one shape. A shape in a read-only container is read-only too, which
    /// this doesn't see: what goes by a shape in its board asks `isReadOnly(_:in:)`.
    public func isReadOnly(_ shape: AnyShapeRecord) -> Bool {
        readOnlyRules.contains { $0(shape) }
    }

    /// Whether any installed plugin says some shapes can't change: without one, nothing need ask.
    var hasReadOnlyRules: Bool { !readOnlyRules.isEmpty }

    /// A kind's properties as one JSON Schema (draft 2020-12): an object with each of its own
    /// properties, then each added property it opts into (marked with its owner, `x-canvas-owner`),
    /// with their types, defaults and constraints; only those marked `required()` required, and nothing
    /// else allowed; a kind whose shapes own boards (`BoardOwning`) is marked `x-canvas-board`. Shared
    /// definitions are under `$defs`, named after their modules (`core.rect`, `mentions.text`),
    /// and every `$ref` is local. It describes a shape as one object, own and added properties side
    /// by side (a board keeps the two apart). Nil for a kind no plugin registers.
    public func schema(for kind: ShapeKind) -> JSONSchema? { schemas[kind] }

    /// A kind's schema, as `schema(for:)` has it: its own properties and those it opts into, as an
    /// object schema, with the definitions they share, which `shared` holds too.
    private static func schema(of kind: ShapeKind, defined definition: any ShapeDefinition, properties table: PropertyTable,
                               in shared: inout SchemaDefinitions) -> JSONSchema {
        var json = definition.propsSchema(in: &shared)
        var properties = json["properties"]?.objectValue ?? [:]
        for key in table.byKind[kind] ?? [] {
            guard let codec = table.codecs[key], let owner = table.owners[key] else { continue }
            var property = codec.schema(&shared)
            property["x-canvas-owner"] = .string(owner.rawValue)
            if let value = codec.defaultValue, let encoded = try? JSONValue(boardEncoding: value) { property["default"] = encoded }
            properties[key.rawValue] = .object(property)
        }
        json["properties"] = .object(properties)
        if definition is any BoardOwning { json["x-canvas-board"] = true }
        if json["title"] == nil { json["title"] = .string(kind.rawValue) }
        json["$schema"] = .string(JSONSchema.dialect)
        json["$id"] = .string("tag:infinite-canvas,2026:kinds/\(kind)")
        if !shared.json.isEmpty { json["$defs"] = .object(shared.json) }
        return JSONSchema(json)
    }

    /// What describing found wrong, then what's wrong with the list of each struct it described, in
    /// the order it met them (a kind's own props first), and whether one that holds names of shapes
    /// doesn't adopt `ShapeNaming`: every struct but the kind's `props`, which is walked by its list.
    private static func problems(of described: SchemaDefinitions, props: (any ShapeProps.Type)? = nil) -> [String] {
        described.problems + described.described.flatMap { type in
            let isProps = props.map { ObjectIdentifier($0) == ObjectIdentifier(type) } ?? false
            return propertyListProblems(of: type) + (isProps ? [] : namingProblems(of: type))
        }
    }

    /// The added properties installed plugins declare.
    public var declaredProperties: [PropertyKey] {
        contributions(to: CorePoints.PropertyDeclarations.self).map(\.value.codec.key)
    }

    /// The added properties a kind opts into, in plugin order.
    public func properties(for kind: ShapeKind) -> [PropertyKey] { propertyTable.byKind[kind] ?? [] }

    /// The plugin that declares an added property.
    public func owner(of property: PropertyKey) -> PluginID? { propertyTable.owners[property] }

    /// The document with every shape as its kind has it: each added property its kind opts into
    /// that has a default, and that the shape has no value for, set to the default. What an editor
    /// does to a document it's given, and what opening a board does.
    public func fillingDefaults(_ document: CanvasDocument) -> CanvasDocument {
        var document = document
        for (index, record) in document.shapes.enumerated() {
            let normalized = propertyTable.normalized(record)
            if normalized != record { document.replace(at: index, with: normalized) }
        }
        return document
    }

    /// The file with every board's shapes as their kinds have them (`fillingDefaults(_:)` of each).
    public func fillingDefaults(_ file: CanvasFile) -> CanvasFile {
        var file = file
        file.transformBoards { fillingDefaults($0) }
        return file
    }

    /// The toolbar: the default tool, then the rest in plugin order (the core's Hand first).
    public var tools: [ToolDescriptor] {
        let all = contributions(to: CorePoints.Tools.self).map(\.value.descriptor)
        let lead = defaultTool
        return all.filter { $0.id == lead } + all.filter { $0.id != lead }
    }

    /// Where the editor starts, and returns to on Escape and after placing a shape: the tool a
    /// plugin claimed (`registrar.defaultTool`), else the Hand.
    public var defaultTool: ToolID { contributions(to: CorePoints.DefaultTool.self).first?.value ?? .hand }

    /// The tool ⇧↩ falls back on when the selection is no one kind a tool places (`registrar.insertsBesideByDefault`);
    /// nil when no plugin claimed one.
    public var insertsBesideByDefault: ToolID? { contributions(to: CorePoints.InsertBesideByDefault.self).first?.value }

    /// The tool that places a kind's shapes (the first, if several do); nil for a kind no tool places.
    public func placingTool(for kind: ShapeKind) -> ToolID? {
        contributions(to: CorePoints.Tools.self).lazy.first { $0.value.placement?.kind == kind }?.value.descriptor.id
    }

    /// What the kind's tool places (the first tool's, if several place it): its size and its
    /// props. Nil for a kind no tool places (an arrow), or one a tool draws instead (a line).
    public func placement(for kind: ShapeKind) -> Placement? {
        contributions(to: CorePoints.Tools.self).lazy.compactMap(\.value.placement).first { $0.kind == kind }
    }

    /// What a tool places, for a placing tool (`ShapeRegistrar.tool(placing:)`); nil for any other.
    func placement(forTool id: ToolID) -> Placement? {
        contributions(to: CorePoints.Tools.self).first { $0.value.descriptor.id == id }?.value.placement
    }

    /// What a kind is called, and its symbol, wherever a shape is shown by its kind (a panel's
    /// header, a row, a message): what it declares (`ShapeRegistrar.label`), else its placing
    /// tool's label and symbol ("Note"), else its id, with no symbol. Its tint is the one it
    /// declares (`ShapeRegistrar.tint`), whichever names it; none, and it has none.
    public func label(of kind: ShapeKind) -> KindLabel {
        let tint = contributions(to: CorePoints.KindTints.self, for: kind).first?.color
        if let declared = contributions(to: CorePoints.KindLabels.self, for: kind).first {
            return KindLabel(name: declared.name, systemImage: declared.systemImage, tint: tint)
        }
        let placing = ToolID(placing: kind)
        if let tool = contributions(to: CorePoints.Tools.self).first(where: { $0.value.descriptor.id == placing })?.value.descriptor {
            return KindLabel(name: tool.label, systemImage: tool.systemImage, tint: tint)
        }
        return KindLabel(name: kind.rawValue, systemImage: nil, tint: tint)
    }

    /// A kind's tint (`label(of:).tint`), found once: what `editor.tint(of:)` asks for each shape.
    func kindTint(of kind: ShapeKind) -> NSColor? {
        memo(KindTintMemo(kind: kind)) { label(of: kind).tint }
    }

    var toolFactories: [(ToolID, @MainActor (CanvasEditor) -> any Tool)] {
        contributions(to: CorePoints.Tools.self).map { ($0.value.descriptor.id, $0.value.make) }
    }
    var services: [ServiceRegistration] { contributions(to: CorePoints.Services.self).map(\.value) }
    var overlays: [any CanvasOverlay] { contributions(to: CorePoints.Overlays.self).map(\.value) }
    var willDeleteHandlers: [@MainActor (Set<ShapeID>, inout Transaction) -> Void] {
        contributions(to: CorePoints.WillDelete.self).map(\.value)
    }
    var partsMovedHandlers: [@MainActor ([PartAddress: PartAddress], inout Transaction) -> Void] {
        contributions(to: CorePoints.PartsMoved.self).map(\.value)
    }
    /// What finds the stand-ins naming a shape, if a plugin gives it (`registrar.standInLookup`).
    var standInLookup: (@MainActor (CanvasEditor, ShapeID) -> [ShapeID])? {
        contributions(to: CorePoints.StandInLookups.self).first?.value.lookup
    }
    /// What finds the shapes whose records name a shape, if a plugin gives it (`registrar.standInLookup(_:names:namers:)`).
    var namingLookup: (@MainActor (CanvasEditor, ShapeID) -> [ShapeID])? {
        contributions(to: CorePoints.StandInLookups.self).first?.value.namers
    }
    /// What a stand-in's record names, if a plugin says (`registrar.standInLookup(_:names:)`): one shape, nil for any other record.
    var standInNames: (@MainActor (AnyShapeRecord, Registry) -> ShapeID?)? {
        contributions(to: CorePoints.StandInLookups.self).first?.value.names
    }
    /// A kind's rules for what its shapes hold (`keepsInStep`), found once a kind: every write of an
    /// added value asks.
    func stepRules(for kind: ShapeKind) -> [StepRule] {
        memo(StepRulesMemo(kind: kind)) { contributions(to: CorePoints.KeepsInStep.self, for: kind) }
    }
    var outlineSources: [@MainActor (CanvasEditor) -> Outlines] { contributions(to: CorePoints.OutlineSources.self).map(\.value) }
    var secondaryClickMenu: (@MainActor (CanvasEditor, Pointer) -> NSMenu?)? {
        contributions(to: CorePoints.SecondaryClickMenu.self).first?.value
    }
    var selectionMenu: (@MainActor (CanvasEditor, Set<CanvasCommand>, Bool) -> NSMenu?)? {
        contributions(to: CorePoints.SelectionMenu.self).first?.value
    }
    var keyStrokeHandler: (@MainActor (CanvasEditor, KeyStroke) -> Bool)? {
        contributions(to: CorePoints.KeyStrokes.self).first?.value
    }
    var keyReleaseHandler: (@MainActor (CanvasEditor, KeyStroke?) -> Void)? {
        contributions(to: CorePoints.KeyReleases.self).first?.value
    }
    var translationAdjuster: (@MainActor (CanvasEditor, TranslationStart) -> (any TranslationAdjuster)?)? {
        contributions(to: CorePoints.TranslationAdjusters.self).first?.value
    }
    var resizeAdjuster: (@MainActor (CanvasEditor, ResizeStart) -> (any ResizeAdjuster)?)? {
        contributions(to: CorePoints.ResizeAdjusters.self).first?.value
    }
    var insertionSpot: (@MainActor (CanvasEditor, CGSize, [ShapeID]) -> CGRect?)? {
        contributions(to: CorePoints.InsertionSpots.self).first?.value
    }
    func madeBeside(_ kind: ShapeKind) -> (@MainActor (AnyShapeRecord, AnyShapeRecord) -> AnyShapeRecord)? {
        contributions(to: CorePoints.MadeBeside.self, for: kind).first?.make
    }

    /// Who contributes what, where: the runtime counterpart of Package.swift. A test pins it.
    public var report: String {
        let width = max(14, (pluginIDs.map(\.rawValue.count).max() ?? 0) + 2)
        return pluginIDs.map { id in
            let items = all.filter { $0.pluginID == id }.map(\.summary)
            return "\(id.rawValue.padding(toLength: width, withPad: " ", startingAt: 0))\(items.joined(separator: " · "))"
        }.joined(separator: "\n")
    }
}

public enum RegistryError: Error, Equatable, CustomStringConvertible {
    case duplicatePlugin(PluginID)
    /// Contributing to a point whose owning plugin isn't in the list.
    case ownerNotInstalled(point: String, owner: PluginID, contributor: PluginID)
    /// A contribution for a shape kind no plugin registers.
    case unknownKind(ShapeKind, point: String, contributor: PluginID)
    /// Two contributions claim the same key (a kind, a tool id, a keyboard shortcut, ...).
    case conflict(point: String, key: String, plugins: [PluginID])
    /// A point's own `check` refused the plugin list.
    case invalid(point: String, reason: String)

    public var description: String {
        switch self {
        case .duplicatePlugin(let id): "plugin \(id) is installed twice"
        case .ownerNotInstalled(let point, let owner, let contributor):
            "\(contributor) contributes to \(point), but \(owner), which owns it, isn't installed"
        case .unknownKind(let kind, let point, let contributor):
            "\(contributor) contributes to \(point) for kind \(kind), which no plugin registers"
        case .conflict(let point, let key, let plugins):
            "\(plugins.map(\.rawValue).joined(separator: " and ")) both claim \(key) in \(point)"
        case .invalid(let point, let reason): "\(point): \(reason)"
        }
    }
}

/// A contribution as stored: the value is opaque to the core.
@MainActor
struct RawContribution {
    let pointType: any ExtensionPoint.Type
    let pluginID: PluginID
    let target: ShapeTarget
    let value: Any
    let keys: [AnyHashable]
    let summary: String

    var point: ObjectIdentifier { ObjectIdentifier(pointType) }
    var pointName: String { "\(pointType)" }
    var owner: PluginID { pointType.owner }

    init<P: ExtensionPoint>(_ value: P.Contribution, to _: P.Type, for target: ShapeTarget, from plugin: PluginID) {
        pointType = P.self
        pluginID = plugin
        self.target = target
        self.value = value
        keys = (P.self as? any KeyedExtensionPoint.Type).map { Self.keys(of: value, for: target, claimedIn: $0) } ?? []
        summary = switch value {
        case let shape as ShapeRegistration:
            // A kind's version shows once it has one, so the pinned report shows every bump.
            "shape \(shape.kind)" + (shape.definition.kindCodec.version > 0 ? " v\(shape.definition.kindCodec.version)" : "")
        case let tool as ToolRegistration: "tool \(tool.descriptor.id)"
        case let service as ServiceRegistration: "service \(service.name)"
        case let overlay as any CanvasOverlay: "overlay \(type(of: overlay))"
        case let command as CommandRegistration: "command \(command.command)" + command.reportedPlace
        case let provider as LayoutProvider: "layout input \(provider.name)"
        case let declaration as PropertyDeclaration:
            "property \(declaration.codec.key)" + (declaration.codec.version > 0 ? " v\(declaration.codec.version)" : "")
        case let declaration as FilePropertyDeclaration:
            "file property \(declaration.codec.key)" + (declaration.codec.version > 0 ? " v\(declaration.codec.version)" : "")
        case let optIn as PropertyOptIn: "property \(optIn.key) → \(target == .any ? "every shape" : "\(target)")"
        case let label as KindLabel: "label \(label.name) → \(target)"
        case is KindTint: "tint → \(target)"
        case is MadeBesideShape: "made beside → \(target)"
        default:
            switch P.self {
            case is CorePoints.WillDelete.Type: "willDelete"
            case is CorePoints.PartsMoved.Type: "parts moved"
            case is CorePoints.StandInLookups.Type: "stand-in lookup"
            case is CorePoints.KeepsInStep.Type: "keeps in step → \(target)"
            case is CorePoints.ReadOnlyRules.Type: "read-only shapes"
            case is CorePoints.ShapeTints.Type: "shape tints"
            case is CorePoints.OutlineSources.Type: "outlines"
            case is CorePoints.DefaultTool.Type: "default tool \(value)"
            case is CorePoints.InsertBesideByDefault.Type: "insert beside by default \(value)"
            case is CorePoints.SecondaryClickMenu.Type: "secondary-click menu"
            case is CorePoints.SelectionMenu.Type: "selection menu"
            case is CorePoints.CommandShapes.Type: "command shapes"
            case is CorePoints.KeyStrokes.Type: "key strokes"
            case is CorePoints.KeyReleases.Type: "key releases"
            case is CorePoints.TranslationAdjusters.Type: "translation adjuster"
            case is CorePoints.ResizeAdjusters.Type: "resize adjuster"
            case is CorePoints.InsertionSpots.Type: "insertion spot"
            case is CorePoints.ShapeAccessibility.Type: "accessibility → \(target)"
            case is CorePoints.AccessibleOrder.Type: "accessible order"
            case is CorePoints.AccessibleParts.Type: "accessible parts"
            default: P.summary(of: value, for: target)
            }
        }
    }

    /// The keys it would claim for `target` (a kind a scope reaches), on a keyed point; none on another.
    func keys(for target: ShapeTarget) -> [AnyHashable] {
        (pointType as? any KeyedExtensionPoint.Type).map { Self.keys(of: value, for: target, claimedIn: $0) } ?? []
    }

    private static func keys<K: KeyedExtensionPoint>(of value: Any, for target: ShapeTarget, claimedIn _: K.Type) -> [AnyHashable] {
        K.uniqueKeys(of: value as! K.Contribution, for: target)
    }
}

private struct KindTintMemo: Hashable { let kind: ShapeKind }
private struct StepRulesMemo: Hashable { let kind: ShapeKind }
private struct CapabilityKindKey: Hashable { let capability: ShapeCapability; let kind: ShapeKind }

/// The values `Registry.memo(_:_:)` keeps: a class, so the registry's copies share them. A table
/// for each key type and value type (`MemoTable`), found by the table's own type, so an ask hashes
/// its key as it is: one dictionary of every key as `AnyHashable` boxed each key and cast each value
/// out of `Any`, some 0.5 to 1.6 µs an ask (measured), more than most of the values cost to make,
/// where a board's preview asks two for each of its shapes.
@MainActor
private final class RegistryMemos {
    var tables: [ObjectIdentifier: AnyObject] = [:]

    func table<Key: Hashable, Value>(_: Key.Type, _: Value.Type) -> MemoTable<Key, Value> {
        let id = ObjectIdentifier(MemoTable<Key, Value>.self)
        if let known = tables[id] { return unsafeDowncast(known, to: MemoTable<Key, Value>.self) }
        let made = MemoTable<Key, Value>()
        tables[id] = made
        return made
    }
}

/// The values kept for one key type and value type.
@MainActor
private final class MemoTable<Key: Hashable, Value> {
    var values: [Key: Value] = [:]
}
