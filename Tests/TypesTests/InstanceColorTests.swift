import AppKit
import Canvas
import CanvasTesting
import Colors
import Palette
import TestKit
import Titles
import Types

// A type's color on the shapes that are of it (`TypeColorsPlugin`, through Colors' `InheritedColors`): a
// shape with no color of its own takes the color its type's shape holds, the first its chain holds in
// the order its fields resolve; the color a type's id says is its pill's and chips', never its shapes'.

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

extension CanvasEditor {
    /// The color the shape is drawn in, as the book says it.
    fileprivate func drawn(_ id: ShapeID) -> ShapeColor? { document[id].flatMap { colors?.color(of: $0) } }

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
    test("a shape of a type takes the color its type's shape holds; the type keeps its own, and one that holds none gives none") {
        let editor = try colorEditor(), types = try require(editor.types)
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person])
        expectEqual(editor.drawn(ann), nil, "the color the type's id says is its pill's, not its shapes'")
        expectEqual(types.color(inheritedBy: ann), nil)
        editor.setColor(.blue, of: [person])
        expectEqual(editor.drawn(ann), .blue)
        expectEqual(types.color(inheritedBy: ann), .blue)
        expectEqual(editor.document[ann]?.ownColor, nil, "nothing is written to it")
        expectEqual(editor.drawn(person), .blue, "the type's own")
        expectEqual(types.color(inheritedBy: person), nil, "a type takes nothing")
        expectEqual(editor.colors?.swatch(of: try require(editor.document[ann])), BuiltInColors.blue.swatch)
    },
    test("a color of the shape's own wins, and taken away its type's is back") {
        let editor = try colorEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person])
        editor.setColor(.blue, of: [person])
        editor.setColor(.red, of: [ann])
        expectEqual(editor.drawn(ann), .red)
        editor.setColor(nil, of: [ann])
        expectEqual(editor.drawn(ann), .blue)
    },
    test("of two types, the later in its list gives its color, and the earlier's where the later holds none") {
        let editor = try colorEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let pilot = editor.addType(TypeSchemaProperty.starter, title: "Pilot", at: CGPoint(x: 400, y: 40))
        let ann = editor.addInstance("Ann", of: [person, pilot])
        editor.setColor(.blue, of: [person])
        editor.setColor(.green, of: [pilot])
        expectEqual(editor.drawn(ann), .green, "a later one wins, as for fields")
        editor.setColor(nil, of: [pilot])
        expectEqual(editor.drawn(ann), .blue)
    },
    test("a type passes its color to the shapes of the types built on it, the nearest color first; a type built on it keeps its own") {
        let editor = try colorEditor(), types = try require(editor.types)
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let employee = editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 400, y: 40))
        editor.build(employee, on: [person])
        let ann = editor.addInstance("Ann", of: [employee])
        editor.setColor(.blue, of: [person])
        expectEqual(editor.drawn(ann), .blue, "from the type its type is built on")
        expectEqual(editor.drawn(employee), nil, "the type built on it holds none of its own")
        expectEqual(types.color(inheritedBy: employee), nil)
        editor.setColor(.green, of: [employee])
        expectEqual(editor.drawn(ann), .green, "the nearest")
        editor.build(employee, on: [])
        editor.setColor(nil, of: [employee])
        expectEqual(editor.drawn(ann), nil, "built on nothing, its type gives nothing")
    },
    test("a color the file lacks is none: the next in the chain's, else none") {
        let editor = try colorEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let employee = editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 400, y: 40))
        editor.build(employee, on: [person])
        let ann = editor.addInstance("Ann", of: [employee])
        editor.setColor(.named("brand"), of: [employee])
        expectEqual(editor.document[employee]?.ownColor, .named("brand"))
        expectEqual(editor.drawn(ann), nil)
        editor.setColor(.blue, of: [person])
        expectEqual(editor.drawn(ann), .blue, "passed over for the next that holds one the file has")
        expect(editor.defineColor(named: "Brand", value: RGB(hex: 0x123456)))
        expectEqual(editor.drawn(ann), .named("brand"), "the file has it now")
    },
    test("a color written in a type's JSON is its shapes' too") {
        let editor = try colorEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
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
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person])
        var heard = listener.heard
        editor.setColor(.blue, of: [person])
        expectEqual(listener.heard, heard + 1, "no commit names Ann")
        editor.undo()
        expectEqual(editor.drawn(ann), nil)
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
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let heard = listener.heard
        editor.setColor(.blue, of: [person])
        expectEqual(listener.heard, heard)
        let ann = editor.addInstance("Ann", of: [person])
        expectEqual(listener.heard, heard, "a commit that names the shape says so itself")
        editor.setColor(.green, of: [person])
        expectEqual(listener.heard, heard + 1)
        expectEqual(editor.drawn(ann), .green)
    },
    test("deleting the type, or the shape leaving it, takes the color away, and undo brings it back") {
        let editor = try colorEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person])
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
    },
    test("a listed shape is in its type's color") {
        let editor = try colorEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person])
        expectEqual(editor.tint(of: try require(editor.document[ann])), nil, "a memo declares no tint")
        editor.setColor(.purple, of: [person])
        expectEqual(try light(editor.tint(of: try require(editor.document[ann]))), BuiltInColors.purple.swatch.solid.light.hexString)
    },
    test("what a list's chain holds is worked out once, and again only after a chain or a type's color changes") {
        let editor = try colorEditor(), types = try require(editor.types)
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let shapes = (0..<50).map { editor.addInstance("\($0)", of: [person], at: CGPoint(x: 40 + CGFloat($0) * 10, y: 400)) }
        editor.setColor(.blue, of: [person])
        let before = types.chainColorsRead
        for _ in 0..<2 { for shape in shapes { expectEqual(types.color(inheritedBy: shape), .blue) } }
        expectEqual(types.chainColorsRead, before + 1, "fifty shapes of one list, asked twice")
        editor.setColor(.green, of: [person])
        for shape in shapes { expectEqual(types.color(inheritedBy: shape), .green) }
        expectEqual(types.chainColorsRead, before + 2)
    },
    test("without TypeColorsPlugin a type's shapes take nothing of it") {
        let editor = try colorEditor(giving: false)
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person])
        editor.setColor(.blue, of: [person])
        expectEqual(editor.drawn(ann), nil)
        expectEqual(editor.types?.color(inheritedBy: ann), .blue, "the index still says what it would give")
    },
])
