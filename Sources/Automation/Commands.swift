import Canvas
import CanvasRPC
import CoreGraphics
import Foundation
import Geometry

// The command line's own commands: what any board can do whatever's installed. Other plugins add
// theirs with `registrar.automationCommand`.

public struct AutomationPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .automation }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.automationCommand(
            "create", "Put a shape on a board.",
            discussion: """
                The shape is what the kind's tool would place, with its middle at --at (or the middle of the board's \
                view), and then --props, then each --set, then --size. A kind no tool places (an arrow, a line) starts \
                from the properties given, and --at moves it. `\(RPC.commandName) kinds --schema` says what each kind's \
                properties are. The shape isn't selected, so what's selected stays as it was.
                """,
            params: CreateShape.self, positionals: ["kind"],
            // No kind by name: this plugin knows none, and the kinds are whatever's installed.
            examples: [
                CommandExample("\(RPC.commandName) create <kind>", "What the kind's tool places, in the middle of the board's view."),
                CommandExample("\(RPC.commandName) create <kind> --at 400,300 --size 240,120", "One 240 wide and 120 high, its middle at (400, 300)."),
                CommandExample("\(RPC.commandName) create <kind> --set text='Buy milk'", "One whose text property says Buy milk."),
                CommandExample(#"\#(RPC.commandName) create <kind> --props '{"text": "Buy milk"}'"#, "The same, its properties as JSON."),
            ]
        ) { params, context throws(AutomationError) in
            try create(params, in: context)
        }
        registrar.automationCommand(
            "kinds", "List the kinds of shape the app has, and their properties.",
            discussion: "--schema adds each kind's JSON Schema (draft 2020-12): every property, what it takes, its default and its bounds.",
            scope: .app, params: ListKinds.self, positionals: ["kind"],
            examples: [
                CommandExample("\(RPC.commandName) kinds", "Every kind, what places it, and its properties."),
                CommandExample("\(RPC.commandName) kinds <kind> --schema", "What each of the kind's properties takes."),
            ]
        ) { params, context throws(AutomationError) in
            try kinds(params, in: context.registry)
        }
    }
}

// MARK: create

struct CreateShape: SchemaDefined {
    static let properties = Properties<CreateShape>(title: "create") {
        Property("kind", \.kind).required().description("The kind of shape: one that `\(RPC.commandName) kinds` lists.")
        Property("at", \.at).description("Where the shape's middle goes, in world units. Default: the middle of the board's view.")
        Property("size", \.size).description("Its width and height, in world units, for a kind with a frame. Default: what its tool places.")
        Property("set", \.set).keywords(["x-value-name": "name=value"])
            .description("A property to set: text for a property that's text (text=Hello), JSON for any other (estimate=3).")
        Property("props", \.props).description("Properties as one JSON object, which each --set is set over.")
    }
    var kind = ""
    var at: CGPoint?
    var size: CGSize?
    var set: [String] = []
    var props: JSONObjectParam?
}

/// What `create` made.
struct Created: Encodable {
    let id: String
    let kind: String
    /// Where it is: [[x, y], [width, height]], in world units.
    let bounds: CGRect?
    /// Where it breaks its kind's schema's bounds (a title too long): it's made anyway, as the app
    /// makes anything, and validation warns about it too.
    let warnings: [String]?
}

@MainActor
func create(_ params: CreateShape, in context: AutomationContext) throws(AutomationError) -> Created {
    let editor = try context.board(), registry = context.registry
    let kind = ShapeKind(rawValue: params.kind)
    guard registry.definition(for: kind) != nil else { throw unknownKind(params.kind, in: registry) }
    let schema = registry.schema(for: kind)
    let propertySchemas = schema?.json["properties"]?.objectValue ?? [:]
    if let size = params.size, !(size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite) {
        throw AutomationError("--size is a width and a height, both more than 0.", reason: "invalid_params", invalidParams: true)
    }

    // What the kind's tool places, with its middle where it's asked for.
    let view = editor.camera.toWorld(CGRect(origin: .zero, size: editor.viewportSize))
    var properties = registry.placement(for: kind)?.shape(at: params.at ?? CGPoint(x: view.midX, y: view.midY)).propertiesJSON ?? [:]
    for (name, value) in params.props?.members ?? [:] { properties[name] = value }
    for assignment in params.set {
        guard let equals = assignment.firstIndex(of: "="), equals != assignment.startIndex else {
            throw AutomationError("--set takes name=value, and \(assignment) isn't that.", reason: "invalid_params", invalidParams: true)
        }
        let name = String(assignment[..<equals]), text = String(assignment[assignment.index(after: equals)...])
        guard let property = propertySchemas[name] else { throw unknownProperty(name, of: kind, among: propertySchemas.keys) }
        properties[name] = try value(text, of: name, as: property, in: schema)
    }

    var record: AnyShapeRecord
    do {
        record = try registry.shape(kind, properties: properties)
    } catch {
        switch error {
        case .unknownProperty(let name, _):
            throw unknownProperty(name, of: kind, among: propertySchemas.keys)
        case .unknownKind:
            throw unknownKind(params.kind, in: registry)
        case .unreadable(let why):
            throw AutomationError("A \(kind) can't have those properties: \(why).", reason: "invalid_properties",
                                  hint: "`\(RPC.commandName) kinds \(kind) --schema` says what each property takes.")
        }
    }
    if let box = record.box, params.at != nil || params.size != nil {
        record.box = CGRect(center: params.at ?? CGPoint(x: box.midX, y: box.midY), size: params.size ?? box.size)
    }
    // What its props name must be on this board (an arrow's ends): a shape that names one that isn't
    // would keep naming it, and nothing would ever let go of it.
    var missing: [ShapeID] = []
    _ = record.remappingReferences({ id in
        guard editor.document[id] == nil else { return id }
        missing.append(id)
        return nil
    }, in: editor.shapeContext)
    if !missing.isEmpty {
        throw AutomationError("A \(kind) can't name shapes that aren't on this board: \(missing.map(\.description).joined(separator: ", ")).",
                              reason: "unknown_shape", hint: "Name shapes on the board the command works on (--board).")
    }
    let id = record.id, inserted = record
    editor.transact { transaction in
        transaction.insert(inserted)
        // A kind without a frame moves by its own rules (an arrow, a line), its middle to --at.
        if inserted.box == nil, let at = params.at, let bounds = transaction.shapes.bounds(of: [id]) {
            transaction.translate([id], by: CGPoint(x: at.x - bounds.midX, y: at.y - bounds.midY))
        }
    }
    guard let placed = editor.document[id] else {
        throw AutomationError("The \(kind) couldn't go on the board.", reason: "refused")
    }
    // Each names the property it's about ("Title is 95 characters long, and should be at most 80.").
    let warnings = registry.schemaViolations(of: placed).map(\.message)
    return Created(id: id.description, kind: kind.rawValue, bounds: editor.shapeContext.bounds(of: [id]), warnings: warnings.isEmpty ? nil : warnings)
}

/// A `--set` value: as typed for a property that's text (a string, or one of some strings), and
/// read as JSON for any other (a number, a list, an object).
private func value(_ text: String, of name: String, as property: JSONValue, in schema: JSONSchema?) throws(AutomationError) -> JSONValue {
    // Read as the command line reads the property's schema: what it types as text is text.
    let root = JSON(schema?.json ?? [:]), written = JSON(property)
    if case .text = written.valueShape(in: root) { return .string(text) }
    do {
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    } catch {
        let resolved = written.resolvingReference(in: root)
        let what = resolved["description"]?.stringValue ?? resolved["type"]?.stringValue ?? "JSON"
        throw AutomationError("\(name) takes JSON (\(what)), and \(text) isn't JSON.", reason: "invalid_params",
                              hint: "Quote it for the shell: --set '\(name)=…'.", invalidParams: true)
    }
}

// MARK: kinds

struct ListKinds: SchemaDefined {
    static let properties = Properties<ListKinds>(title: "kinds") {
        Property("kind", \.kind).description("Just this kind.")
        Property("schema", \.schema).description("With each kind's JSON Schema.")
    }
    var kind: String?
    var schema = false
}

/// A kind, as `kinds` lists it.
struct KindSummary: Encodable {
    let kind: String
    let title: String?
    /// The tool that places it, by its label.
    let tool: String?
    /// What its tool places: [width, height].
    let size: CGSize?
    /// Its own and added properties, by name.
    let properties: [String]
    let schema: JSONValue?
}

@MainActor
func kinds(_ params: ListKinds, in registry: Registry) throws(AutomationError) -> [KindSummary] {
    var kinds = registry.kinds.sorted { $0.rawValue < $1.rawValue }
    if let named = params.kind {
        guard let kind = kinds.first(where: { $0.rawValue == named }) else { throw unknownKind(named, in: registry) }
        kinds = [kind]
    }
    return kinds.map { kind in
        let schema = registry.schema(for: kind)?.json ?? [:]
        return KindSummary(kind: kind.rawValue, title: schema["title"]?.stringValue,
                           tool: registry.tools.first { $0.id == ToolID(placing: kind) }?.label,
                           size: registry.placement(for: kind)?.size,
                           properties: (schema["properties"]?.objectValue?.keys).map { $0.sorted() } ?? [],
                           schema: params.schema ? .object(schema) : nil)
    }
}

// MARK: Errors

@MainActor
private func unknownKind(_ name: String, in registry: Registry) -> AutomationError {
    let kinds = registry.kinds.map(\.rawValue).sorted()
    return AutomationError("There's no kind of shape called \(name).", reason: "unknown_kind",
                           hint: (CommandSpec.closest(to: name, among: kinds).map { "Did you mean \($0)? " } ?? "")
                               + "The kinds: \(kinds.joined(separator: ", ")).")
}

private func unknownProperty(_ name: String, of kind: ShapeKind, among names: some Collection<String>) -> AutomationError {
    let names = names.sorted()
    return AutomationError("\(kind) shapes have no property \(name).", reason: "unknown_property",
                           hint: (CommandSpec.closest(to: name, among: names).map { "Did you mean \($0)? " } ?? "")
                               + "Its properties: \(names.joined(separator: ", ")).")
}
