import Canvas
import Foundation
import Palette

/// A file's own named colors: a name and a value each, kept on the file in the order they were
/// added (`FileColorsProperty`, a file value), listed after the built-in ones in that file only
/// (`ColorBook.names`). A shape names one by its name, so changing a value recolors every shape that
/// names it and rewrites none; renaming and removing rewrite the shapes that hold the name, in the
/// step that changes the list (`CanvasEditor.renameColor`, `removeColor`).

/// One color a file adds. On the file it's `{ "name": …, "value": "#RRGGBB" }`.
public struct FileColor: Hashable, Sendable {
    /// As it's listed and written: on one line (`ShapeColor.folded`).
    public var name: String
    /// To the step of 8 bits a board writes, so what's read back is what was kept.
    public var value: RGB

    public init(name: String, value: RGB) {
        self.name = ShapeColor.folded(name)
        self.value = RGB(hexString: value.hexString) ?? value
    }
}

extension FileColor: Codable {
    private enum Keys: String, CodingKey { case name, value }

    /// Throws for an entry that doesn't read as a name and a hex value (the list drops it).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let name = try container.decode(String.self, forKey: .name)
        guard let value = RGB(hexString: try container.decode(String.self, forKey: .value)) else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "not a hex value")
        }
        self.init(name: name, value: value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(name, forKey: .name)
        try container.encode(value.hexString, forKey: .value)
    }
}

/// The file's colors, in order. Read leniently, so a board written by hand is never refused for
/// them: an entry that doesn't read as a name and a hex value, or whose name the rules refuse (a
/// built-in name, a name an earlier entry has), is dropped.
public struct FileColorList: Equatable, Sendable {
    public var entries: [FileColor]

    public init(_ entries: [FileColor] = []) {
        self.entries = entries
    }

    /// The entry called `name`, whatever its case.
    public func index(of name: String) -> Int? {
        let key = ShapeColor.key(of: name)
        return entries.firstIndex { ShapeColor.key(of: $0.name) == key }
    }

    /// The names' keys (`ShapeColor.key(of:)`), but for one entry's.
    func keys(except index: Int? = nil) -> Set<String> {
        Set(entries.enumerated().compactMap { $0.offset == index ? nil : ShapeColor.key(of: $0.element.name) })
    }
}

extension FileColorList: Codable {
    /// Anything an unkeyed container steps over without reading.
    private struct Skipped: Decodable {}

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var kept: [FileColor] = [], taken: Set<String> = []
        while !container.isAtEnd {
            // A failed decode leaves the container where it was: step over the entry.
            guard let entry = try? container.decode(FileColor.self) else {
                _ = try container.decode(Skipped.self)
                continue
            }
            guard ColorNameRefusal.check(entry.name, takenKeys: taken) == nil else { continue }
            taken.insert(ShapeColor.key(of: entry.name))
            kept.append(entry)
        }
        entries = kept
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for entry in entries { try container.encode(entry) }
    }
}

/// The file's named colors, as a file value (`registrar.declare(file:)`): none until one is added,
/// and a file with none is written as it was before colors had names.
public enum FileColorsProperty {}

extension FileColorsProperty: FileProperty {
    public static let key: PropertyKey = "colors"
    public static var defaultValue: FileColorList { FileColorList() }
}

/// Why a name can't be a color of the file's: a value to say in whatever words fit where it's
/// asked (a field that is typed in, a command), none here.
public enum ColorNameRefusal: Equatable, Sendable {
    /// No name, once it's on one line.
    case empty
    /// It starts with `#`, which writes a value.
    case startsWithHash
    /// Longer than `ColorsStyle.maxNameLength`.
    case tooLong
    /// A built-in color's name, in any case.
    case builtIn
    /// The name of another color of the file, in any case.
    case taken

    /// What refuses `name`, as it would be kept (on one line); nil if it can be a color's name.
    /// `takenKeys` are the keys (`ShapeColor.key(of:)`) of the file's other colors.
    public static func check(_ name: String, takenKeys: Set<String> = []) -> ColorNameRefusal? {
        let name = ShapeColor.folded(name)
        if name.isEmpty { return .empty }
        if name.hasPrefix("#") { return .startsWithHash }
        if name.count > ColorsStyle.maxNameLength { return .tooLong }
        if BuiltInColors.named(name) != nil { return .builtIn }
        if takenKeys.contains(ShapeColor.key(of: name)) { return .taken }
        return nil
    }
}

extension ColorBook {
    /// Why `name` can't be a new color of the file's, or, with `renaming`, the new name of that one
    /// (which may differ from its own only in case); nil if it can. A pure check, for a place that
    /// offers a name before it's tried.
    public func refusal(ofName name: String, renaming old: String? = nil) -> ColorNameRefusal? {
        let oldKey = old.map { ShapeColor.key(of: $0) }
        let taken = Set(fileColors.map { ShapeColor.key(of: $0.name) }.filter { $0 != oldKey })
        return ColorNameRefusal.check(name, takenKeys: taken)
    }
}

extension CanvasEditor {
    /// Adds a color to the file's, after the others, in one step ("Add Color"). False, and nothing
    /// changes, for a name the rules refuse (`ColorBook.refusal(ofName:)`) and without `ColorsPlugin`.
    /// The value is kept to 8 bits a component, as a board writes it.
    @discardableResult
    public func defineColor(named name: String, value: RGB) -> Bool {
        guard colors != nil else { return false }
        var list = file[FileColorsProperty.self]
        guard ColorNameRefusal.check(name, takenKeys: list.keys()) == nil else { return false }
        list.entries.append(FileColor(name: name, value: value))
        transact(ColorsStyle.addColor) { $0.setFileValue(FileColorsProperty.self, to: list) }
        return true
    }

    /// Gives a color of the file's another value, in one step ("Change Color"): the list entry and
    /// nothing else, since every shape that names it is drawn from the list. False for a name the
    /// file lacks, and for the value it has. With a `coalescing` key, a run of changes under it is
    /// one step (a drag in the color panel).
    @discardableResult
    public func setColorValue(of name: String, to value: RGB, coalescing key: AnyHashable? = nil) -> Bool {
        guard colors != nil else { return false }
        var list = file[FileColorsProperty.self]
        guard let index = list.index(of: name) else { return false }
        let changed = FileColor(name: list.entries[index].name, value: value)
        guard changed != list.entries[index] else { return false }
        list.entries[index] = changed
        transact(ColorsStyle.changeColorValue, coalescing: key) { $0.setFileValue(FileColorsProperty.self, to: list) }
        return true
    }

    /// Names the value a shape holds as its color: the file gains a color of that name and value,
    /// and the shape names it, in one step ("Add Color"). False, and nothing changes, for a shape
    /// whose color isn't a value of its own, for a name the rules refuse, and for a read-only shape,
    /// which shakes (the file would gain a color nothing names).
    @discardableResult
    public func nameColor(of id: ShapeID, _ name: String) -> Bool {
        guard case .value(let value)? = shape(inFile: id)?.ownColor, colors != nil else { return false }
        var list = file[FileColorsProperty.self]
        guard ColorNameRefusal.check(name, takenKeys: list.keys()) == nil else { return false }
        let added = FileColor(name: name, value: value)
        list.entries.append(added)
        return rewriting(ColorsStyle.addColor, list: list, holders: [id]) { $0 = .named(added.name) }
    }

    /// Renames a color of the file's, in one step ("Rename Color"): its entry, and `color` on every
    /// shape of every board of the file that names it, whatever the case it's written in. False, and
    /// nothing changes, for a name the file lacks, a new name the rules refuse (it may differ from
    /// the old only in case), the name it has, and when a shape that holds the color is read-only:
    /// that shape would be drawn as its kind's default under a name the file lacks, so none changes,
    /// and the read-only ones shake.
    @discardableResult
    public func renameColor(_ name: String, to newName: String) -> Bool {
        guard colors != nil else { return false }
        var list = file[FileColorsProperty.self]
        guard let index = list.index(of: name) else { return false }
        let new = ShapeColor.folded(newName)
        guard new != list.entries[index].name, ColorNameRefusal.check(new, takenKeys: list.keys(except: index)) == nil else { return false }
        let holders = shapes(holdingColor: list.entries[index].name)
        list.entries[index].name = new
        return rewriting(ColorsStyle.renameColor, list: list, holders: holders) { $0 = .named(new) }
    }

    /// Takes a color out of the file's, in one step ("Remove Color"): its entry, and each shape that
    /// names it takes its value as a hex color, so it looks as it did. False for a name the file
    /// lacks, and when a shape that holds the color is read-only (it would change its look: see
    /// `renameColor`).
    @discardableResult
    public func removeColor(_ name: String) -> Bool {
        guard colors != nil else { return false }
        var list = file[FileColorsProperty.self]
        guard let index = list.index(of: name) else { return false }
        let removed = list.entries.remove(at: index)
        let holders = shapes(holdingColor: removed.name)
        return rewriting(ColorsStyle.removeColor, list: list, holders: holders) { $0 = .value(removed.value) }
    }

    /// The shapes of the file that hold the color called `name` (whatever its case), on every board:
    /// one pass over the file, only kinds with colors.
    private func shapes(holdingColor name: String) -> [ShapeID] {
        let key = ShapeColor.key(of: name)
        let boards = [BoardID.root] + file.children.keys.map { BoardID(owner: $0) }
        var holders: [ShapeID] = []
        for board in boards {
            for shape in contents(of: board).shapes where registry.isColorable(shape.kind) {
                if let held = shape.ownColor?.name, ShapeColor.key(of: held) == key { holders.append(shape.id) }
            }
        }
        return holders
    }

    /// Sets the file's colors and the color of each holder in one step, all or nothing
    /// (`transactWhole`): a holder that is read-only throws it all away, and shakes.
    private func rewriting(_ step: String, list: FileColorList, holders: [ShapeID], to recolor: (inout ShapeColor) -> Void) -> Bool {
        let written: Void? = transactWhole(step) { transaction in
            transaction.setFileValue(FileColorsProperty.self, to: list)
            for id in holders {
                transaction.update(inFile: id) { record in
                    guard var color = record.ownColor else { return }
                    recolor(&color)
                    record[ColorProperty.self] = color
                }
            }
        }
        return written != nil
    }
}
