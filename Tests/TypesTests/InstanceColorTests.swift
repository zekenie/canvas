import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import Observation
import Palette
import TestKit
import Titles
import Types

// A type's color on the shapes that are of it (`TypeColorsPlugin`, through Colors' `InheritedColors`): a
// shape with no color of its own takes the color its type's pill shows, the one its type's shape holds,
// else the one its type's id says; a color held up the chain comes first, the nearest in the order its
// fields resolve. A type that holds none is given the one its id says, and takes nothing of another's.

/// Memos have colors (none by default), the book of colors is in the list after Types, as the shipped
/// list has it, and Types gives a type's memos its color.
@MainActor private func colorEditor(_ more: [any CanvasPlugin] = [], giving: Bool = true) throws -> CanvasEditor {
    try typeEditor(more: [Contributor(id: "memo-colors") { $0.colorable(Memo.self) }, ColorsPlugin()]
                   + (giving ? [TypeColorsPlugin()] : []) + more)
}

/// Counts what services heard of the tints changing.
@MainActor private final class TintListener {
    var heard = 0
}

extension TintListener: EditorService {
    func shapeTintsDidChange(in editor: CanvasEditor) { heard += 1 }
}

/// A new id whose color, as a type's id says it, is `color`, one of `TypeColors.names`: so a test tells a type's
/// color from another's, and from one a type holds (red and gray are never one an id says).
@MainActor private func id(saying color: ShapeColor) -> ShapeID {
    precondition(TypeColors.names.contains(color), "no id says \(color)")
    while true {
        let id = ShapeID()
        if TypeColors.name(of: id) == color { return id }
    }
}

extension CanvasEditor {
    /// The color the shape is drawn in, as the book says it.
    fileprivate func drawn(_ id: ShapeID) -> ShapeColor? { document[id].flatMap { colors?.color(of: $0) } }

    /// Adds a type titled `title` whose id says `color`.
    fileprivate func addType(_ title: String, saying color: ShapeColor, at origin: CGPoint = CGPoint(x: 40, y: 40)) -> ShapeID {
        addType(TypeSchemaProperty.starter, title: title, at: origin, id: id(saying: color))
    }

    /// Makes `type` built on `others`, as its own `is` list.
    fileprivate func build(_ type: ShapeID, on others: [ShapeID]) {
        transact("Is") { $0.update(type) { $0[IsAProperty.self] = others.map(TypeLink.init) } }
    }
}

/// A color as a list draws it in the light appearance.
@MainActor private func light(_ color: NSColor?) throws -> String {
    var found: NSColor?
    try require(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance { found = try? require(color).usingColorSpace(.sRGB) }
    let srgb = try require(found)
    return RGB(srgb.redComponent, srgb.greenComponent, srgb.blueComponent).hexString
}

@MainActor let instanceColorTests = Suite("A type's color on its shapes", [
    test("a shape of a type takes the color its type's pill shows: its id's, and once its shape holds one, that; the type keeps its own") {
        let editor = try colorEditor(), types = try require(editor.types)
        let person = editor.addType("Person", saying: .orange)
        let ann = editor.addInstance("Ann", of: [person])
        expectEqual(editor.drawn(ann), .orange, "the color its type's id says")
        expectEqual(types.color(inheritedBy: ann), .orange)
        expectEqual(editor.colors?.swatch(of: try require(editor.document[ann])), types.look(of: person).swatch, "its pill's")
        expectEqual(editor.drawn(person), .orange, "the type is given its id's too")
        expectEqual(editor.document[person]?.ownColor, nil, "nothing is written to it")
        editor.setColor(.blue, of: [person])
        expectEqual(editor.drawn(ann), .blue)
        expectEqual(types.color(inheritedBy: ann), .blue)
        expectEqual(editor.document[ann]?.ownColor, nil, "nothing is written to it")
        expectEqual(editor.drawn(person), .blue, "the type's own")
        expectEqual(types.color(inheritedBy: person), .orange, "a type takes no other's: what it is given is its id's")
        expectEqual(editor.colors?.swatch(of: try require(editor.document[ann])), BuiltInColors.blue.swatch)
        expectEqual(editor.colors?.swatch(of: try require(editor.document[ann])), types.look(of: person).swatch, "its pill's still")
        editor.setColor(nil, of: [person])
        expectEqual(editor.drawn(ann), .orange, "its id's again")
        expectEqual(editor.drawn(person), .orange)
    },
    test("a color of the shape's own wins, and taken away its type's is back") {
        let editor = try colorEditor()
        let person = editor.addType("Person", saying: .orange)
        let ann = editor.addInstance("Ann", of: [person])
        editor.setColor(.red, of: [ann])
        expectEqual(editor.drawn(ann), .red, "over its type's id's")
        editor.setColor(.blue, of: [person])
        expectEqual(editor.drawn(ann), .red, "and over the one its type holds")
        editor.setColor(nil, of: [ann])
        expectEqual(editor.drawn(ann), .blue)
    },
    test("of two types, a color the later holds wins, then one the earlier holds, then the later's id's") {
        let editor = try colorEditor()
        let person = editor.addType("Person", saying: .orange)
        let pilot = editor.addType("Pilot", saying: .purple, at: CGPoint(x: 400, y: 40))
        let ann = editor.addInstance("Ann", of: [person, pilot])
        expectEqual(editor.drawn(ann), .purple, "the later's id's, as for fields")
        editor.setColor(.blue, of: [person])
        expectEqual(editor.drawn(ann), .blue, "a color held comes before one an id says")
        editor.setColor(.green, of: [pilot])
        expectEqual(editor.drawn(ann), .green, "a later one wins, as for fields")
        editor.setColor(nil, of: [pilot])
        expectEqual(editor.drawn(ann), .blue)
        editor.setColor(nil, of: [person])
        expectEqual(editor.drawn(ann), .purple)
    },
    test("a color a type holds reaches the shapes of the types built on it, the nearest first; with none held, a shape takes its own type's id's, and a type built on another keeps its own") {
        let editor = try colorEditor(), types = try require(editor.types)
        let person = editor.addType("Person", saying: .orange)
        let employee = editor.addType("Employee", saying: .teal, at: CGPoint(x: 400, y: 40))
        editor.build(employee, on: [person])
        let ann = editor.addInstance("Ann", of: [employee])
        expectEqual(editor.drawn(ann), .teal, "its type's id's, not the one its type is built on's")
        expectEqual(editor.drawn(employee), .teal, "the type built on it is given its own")
        editor.setColor(.blue, of: [person])
        expectEqual(editor.drawn(ann), .blue, "from the type its type is built on")
        expectEqual(editor.drawn(employee), .teal, "the type built on it keeps its own")
        expectEqual(types.color(inheritedBy: employee), .teal)
        editor.setColor(.green, of: [employee])
        expectEqual(editor.drawn(ann), .green, "the nearest")
        editor.build(employee, on: [])
        editor.setColor(nil, of: [employee])
        expectEqual(editor.drawn(ann), .teal, "built on nothing, its type gives its id's")
    },
    test("a color the file lacks is none: the next in the chain's, else its type's id's") {
        let editor = try colorEditor()
        let person = editor.addType("Person", saying: .orange)
        let employee = editor.addType("Employee", saying: .teal, at: CGPoint(x: 400, y: 40))
        editor.build(employee, on: [person])
        let ann = editor.addInstance("Ann", of: [employee])
        editor.setColor(.named("brand"), of: [employee])
        expectEqual(editor.document[employee]?.ownColor, .named("brand"))
        expectEqual(editor.drawn(ann), .teal, "its type's id's, as its pill shows")
        expectEqual(editor.drawn(employee), .teal)
        editor.setColor(.blue, of: [person])
        expectEqual(editor.drawn(ann), .blue, "passed over for the next that holds one the file has")
        expect(editor.defineColor(named: "Brand", value: RGB(hex: 0x123456)))
        expectEqual(editor.drawn(ann), .named("brand"), "the file has it now")
    },
    test("a color written in a type's JSON is its shapes' too") {
        let editor = try colorEditor()
        let person = editor.addType("Person", saying: .orange)
        let ann = editor.addInstance("Ann", of: [person])
        let teal = """
        {
          "type": "object",
          "properties": {
            "$color": {"const": "teal"}
          }
        }
        """
        editor.transact("Change JSON") { $0.update(person) { $0[TypeSchemaProperty.self] = SchemaText(teal) } }
        expectEqual(editor.document[person]?.ownColor, .teal, "the JSON gives the type its color")
        expectEqual(editor.drawn(ann), .teal)
    },
    test("undo and redo of a type's color take its shapes along; the lists hear it, and nothing else tells them") {
        let listener = TintListener()
        let editor = try colorEditor([Contributor(id: "tint-listener") { $0.service { _ in listener } }])
        _ = editor.service(TintListener.self)
        let person = editor.addType("Person", saying: .orange)
        let ann = editor.addInstance("Ann", of: [person])
        var heard = listener.heard
        editor.setColor(.blue, of: [person])
        expectEqual(listener.heard, heard + 1, "no commit names Ann")
        editor.undo()
        expectEqual(editor.drawn(ann), .orange)
        expectEqual(listener.heard, heard + 2)
        editor.redo()
        expectEqual(editor.drawn(ann), .blue)
        expectEqual(listener.heard, heard + 3)
        heard = listener.heard
        editor.transact("Title") { $0.update(person) { $0[TitleProperty.self] = "Human" } }
        editor.transact("Move") { $0.translate([ann], by: CGPoint(x: 40, y: 0)) }
        editor.addInstance("Bo", of: [person])
        expectEqual(listener.heard, heard, "a rename, a move and a new shape of the type change no shape's color the lists keep")
    },
    test("a type recolored with no shape of it tells the lists nothing") {
        let listener = TintListener()
        let editor = try colorEditor([Contributor(id: "tint-listener") { $0.service { _ in listener } }])
        _ = editor.service(TintListener.self)
        let person = editor.addType("Person", saying: .orange)
        let heard = listener.heard
        editor.setColor(.blue, of: [person])
        expectEqual(listener.heard, heard)
        let ann = editor.addInstance("Ann", of: [person])
        expectEqual(listener.heard, heard, "a commit that names the shape says so itself")
        editor.setColor(.green, of: [person])
        expectEqual(listener.heard, heard + 1)
        expectEqual(editor.drawn(ann), .green)
    },
    test("a type that comes or goes, or is built on another now, tells the lists when shapes are of it, though it holds no color") {
        let listener = TintListener()
        let editor = try colorEditor([Contributor(id: "tint-listener") { $0.service { _ in listener } }])
        _ = editor.service(TintListener.self)
        var heard = listener.heard
        let person = editor.addType("Person", saying: .orange)
        let pilot = editor.addType("Pilot", saying: .purple, at: CGPoint(x: 400, y: 40))
        expectEqual(listener.heard, heard, "a type with no shape of it changes no shape's color")
        let ann = editor.addInstance("Ann", of: [person, pilot])
        expectEqual(listener.heard, heard, "a commit that names the shape says so itself")
        expectEqual(editor.drawn(ann), .purple)
        editor.transact("Remove Type") { $0.update(pilot) { $0[TypeSchemaProperty.self] = nil } }
        expectEqual(editor.drawn(ann), .orange, "the type left is the first")
        expectEqual(listener.heard, heard + 1, "no commit names Ann")
        editor.undo()
        expectEqual(editor.drawn(ann), .purple)
        expectEqual(listener.heard, heard + 2)
        heard = listener.heard
        editor.build(person, on: [pilot])
        expectEqual(editor.drawn(ann), .orange, "Person, built on Pilot now, comes before it")
        expectEqual(listener.heard, heard + 1, "no commit names Ann")
    },
    test("a type in a chain given another list of its own tells the lists, so a color held two levels up reaches its shapes") {
        let listener = TintListener()
        let editor = try colorEditor([Contributor(id: "tint-listener") { $0.service { _ in listener } }])
        _ = editor.service(TintListener.self)
        let pilot = editor.addType("Pilot", saying: .purple)
        let person = editor.addType("Person", saying: .orange, at: CGPoint(x: 400, y: 40))
        let employee = editor.addType("Employee", saying: .teal, at: CGPoint(x: 800, y: 40))
        editor.build(employee, on: [person])
        let ann = editor.addInstance("Ann", of: [employee])
        editor.setColor(.red, of: [pilot])
        expectEqual(editor.drawn(ann), .teal, "Pilot is no type of hers")
        let heard = listener.heard
        editor.build(person, on: [pilot])
        expectEqual(editor.drawn(ann), .red, "it is now, through Person")
        expectEqual(listener.heard, heard + 1, "no commit names Ann")
    },
    test("a type taken away ends the chain there, as fields' does: a shape of it takes nothing of what it was built on") {
        let editor = try colorEditor()
        let car = editor.addType("Car", saying: .orange)
        let toyota = editor.addType("Toyota", saying: .teal, at: CGPoint(x: 400, y: 40))
        editor.build(toyota, on: [car])
        let mine = editor.addInstance("Mine", of: [toyota])
        editor.setColor(.blue, of: [car])
        expectEqual(editor.drawn(mine), .blue)
        editor.transact("Remove Type") { $0.update(toyota) { $0[TypeSchemaProperty.self] = nil } }
        expectEqual(editor.drawn(mine), nil, "Toyota is no type now, and Car is reached through it alone")
        expectEqual(editor.drawn(toyota), .blue, "Toyota itself, a memo of Car still, takes Car's")
        editor.undo()
        expectEqual(editor.drawn(mine), .blue)
    },
    test("a name a type holds that the file comes to have reaches its shapes, and what observes the color given hears it") {
        let editor = try colorEditor(), book = try require(editor.colors)
        let person = editor.addType("Person", saying: .orange)
        let ann = editor.addInstance("Ann", of: [person])
        editor.setColor(.named("brand"), of: [person])
        expectEqual(editor.drawn(ann), .orange, "the file lacks it: its id's, as its pill")
        let observed = Flag()
        withObservationTracking { _ = book.inheritedColor(of: ann, kind: Memo.kind) } onChange: { observed.set() }
        expect(editor.defineColor(named: "Brand", value: RGB(hex: 0x123456)))
        expectEqual(editor.drawn(ann), .named("brand"))
        expect(observed.isSet, "the panel's row reads it again")
    },
    test("a file put in place gives its own types' colors, and the lists hear it") {
        let listener = TintListener()
        let editor = try colorEditor([Contributor(id: "tint-listener") { $0.service { _ in listener } }])
        _ = editor.service(TintListener.self)
        let other = id(saying: .purple)
        let ann = instanceRecord("Ann", of: [other])
        let heard = listener.heard
        editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: [typeRecord(TypeSchemaProperty.starter, title: "Pilot", id: other), ann])),
                           showing: .root)
        expectEqual(editor.drawn(ann.id), .purple)
        expect(listener.heard > heard, "the lists hear it")
    },
    test("deleting the type, or the shape leaving it, takes the color away, and undo brings it back") {
        let editor = try colorEditor()
        let person = editor.addType("Person", saying: .orange)
        let ann = editor.addInstance("Ann", of: [person])
        editor.transact("Delete") { $0.delete([person]) }
        expectEqual(editor.drawn(ann), nil, "a type that is gone gives nothing")
        editor.undo()
        expectEqual(editor.drawn(ann), .orange)
        editor.setColor(.blue, of: [person])
        editor.transact("Delete") { $0.delete([person]) }
        expectEqual(editor.drawn(ann), nil)
        editor.undo()
        expectEqual(editor.drawn(ann), .blue)
        editor.transact("Not a Person") { $0.update(ann) { $0[IsAProperty.self] = nil } }
        expectEqual(editor.drawn(ann), nil)
        editor.undo()
        expectEqual(editor.drawn(ann), .blue)
        editor.transact("Remove Type") { $0.update(person) { $0[TypeSchemaProperty.self] = nil } }
        expectEqual(editor.drawn(ann), nil, "a note that is no type gives nothing")
        expectEqual(editor.drawn(person), .blue, "and holds its own still")
    },
    test("a listed shape, and a type, is in its type's color") {
        let editor = try colorEditor()
        let person = editor.addType("Person", saying: .orange)
        let ann = editor.addInstance("Ann", of: [person])
        let orange = BuiltInColors.orange.swatch.solid.light.hexString
        expectEqual(try light(editor.tint(of: try require(editor.document[ann]))), orange, "the color its type's id says")
        expectEqual(try light(editor.tint(of: try require(editor.document[person]))), orange, "as the type is")
        editor.setColor(.purple, of: [person])
        expectEqual(try light(editor.tint(of: try require(editor.document[ann]))), BuiltInColors.purple.swatch.solid.light.hexString)
        editor.transact("Remove Type") { $0.update(person) { $0[TypeSchemaProperty.self] = nil } }
        editor.setColor(nil, of: [person])
        expectEqual(editor.tint(of: try require(editor.document[ann])), nil, "a memo declares no tint")
        expectEqual(editor.tint(of: try require(editor.document[person])), nil)
    },
    test("what a list's chain gives is worked out once, and again only after a chain or a type's color changes") {
        let editor = try colorEditor(), types = try require(editor.types)
        let person = editor.addType("Person", saying: .orange)
        let shapes = (0..<50).map { editor.addInstance("\($0)", of: [person], at: CGPoint(x: 40 + CGFloat($0) * 10, y: 400)) }
        editor.setColor(.blue, of: [person])
        var before = types.chainColorsRead
        for _ in 0..<2 { for shape in shapes { expectEqual(types.color(inheritedBy: shape), .blue) } }
        expectEqual(types.chainColorsRead, before + 1, "fifty shapes of one list, asked twice")
        editor.setColor(nil, of: [person])
        before = types.chainColorsRead
        for _ in 0..<2 { for shape in shapes { expectEqual(types.color(inheritedBy: shape), .orange) } }
        expectEqual(types.chainColorsRead, before + 1, "and with no color held, its id's")
        editor.setColor(.green, of: [person])
        for shape in shapes { expectEqual(types.color(inheritedBy: shape), .green) }
        expectEqual(types.chainColorsRead, before + 2)
    },
    test("without TypeColorsPlugin a type's shapes take nothing of it") {
        let editor = try colorEditor(giving: false)
        let person = editor.addType("Person", saying: .orange)
        let ann = editor.addInstance("Ann", of: [person])
        expectEqual(editor.drawn(ann), nil)
        expectEqual(editor.drawn(person), nil)
        expectEqual(editor.types?.color(inheritedBy: ann), .orange, "the index still says what it would give")
        editor.setColor(.blue, of: [person])
        expectEqual(editor.drawn(ann), nil)
        expectEqual(editor.types?.color(inheritedBy: ann), .blue)
    },
])
