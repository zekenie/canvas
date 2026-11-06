import Canvas
import CanvasRPC
import CoreGraphics
import DrawScript
import FuzzyMatching

// Text in a script that a plugin writes: a string whose schema says `contentMediaType` of a media
// type some plugin writes (DrawTextFormats) is handed to its format as the script wrote it, and
// what the format gives back is what the shape keeps. A format may name shapes by title
// (`DrawTextContext.shape`), found as the rest of the script finds one, but over every board the
// app can show: no title in a text ever decides which board the run draws on (that reads
// statements' titles alone, `Drawing.board(for:in:)`), and the file's names are read when a
// format first asks for one, so a script whose texts name nothing costs what it did.

/// Which shape a name stands for, for a text format: what `DrawTextContext.shape` asks. Made once
/// a run, after pass one, when every title the script draws or restates is known.
@MainActor
final class DrawTextLookup {
    /// A shape of a board, with the board.
    typealias Place = FileNames.Place

    /// A shape the script draws, restates, or renames to a title.
    struct Own {
        let id: ShapeID
        /// As the statement starts it: of its kind, and whatever else a text can tell of it.
        let record: AnyShapeRecord
        /// What it's called once the script has run.
        let title: String
        /// The properties the statement writes on it (by key), which its record doesn't have yet.
        let writes: Set<String>
    }

    let editor: CanvasEditor
    private let target: BoardReading
    private let naming: DrawNaming?
    /// By title, folded: each title of a shape statement, and each title a statement renames a
    /// shape to.
    private let own: [String: Own]
    /// The titles the script gives to more than one shape it draws or restates.
    private let shared: Set<String>
    /// The titles of `own`, in script order.
    private let ownTitles: [String]
    /// Titles of statements that couldn't be resolved, whose texts say nothing more of them.
    private let unresolved: Set<String>
    /// The shapes `delete "X"` removes.
    private let deleted: Set<ShapeID>
    /// The file's names: given when the script names shapes, else read at the first name asked.
    private var fileNames: FileNames?
    /// The boards the deletes take, with the boards under them: read once, when a name is on one.
    private var taken: Set<BoardID>?
    /// The keys a program's run names shapes by (`DrawOptions.keys`), each the id of the shape it names: found before a title.
    private let keys: [String: ShapeID]
    /// Every shape the script draws or restates, by id, for a key that names one.
    private let ownByID: [ShapeID: Own]

    init(editor: CanvasEditor, target: BoardReading, naming: DrawNaming?, items: [ShapeItem], itemsByTitle: [String: [Int]],
         unresolved: Set<String>, deleted: Set<ShapeID>, fileNames: FileNames?, keys: [String: ShapeID] = [:]) {
        self.editor = editor
        self.keys = keys
        var byID: [ShapeID: Own] = [:]
        if !keys.isEmpty {
            // What a shape a program's run writes is called: the title its statement gives it (`title:`), else the one it has.
            for item in items {
                let title = item.shape.newTitle.flatMap { naming?.fold($0) } ?? item.title ?? ""
                byID[item.record.id] = Own(id: item.record.id, record: item.record, title: title, writes: Set(item.shape.attributes.map(\.key)))
            }
        }
        ownByID = byID
        self.target = target
        self.naming = naming
        self.unresolved = unresolved
        self.deleted = deleted
        self.fileNames = fileNames
        // `title: "New"` on a restated shape: it's called that once the script has run, which a
        // text names it by, as the old title, the one the rest of the script knows it by, still
        // does. (`ShapeItem.rename` is set as each shape is completed: too late for a text before it.)
        var renamed: [Int: String] = [:]
        if let naming {
            for index in items.indices {
                guard items[index].existing != nil, let written = items[index].shape.newTitle, let new = naming.fold(written),
                      new != items[index].title else { continue }
                renamed[index] = new
            }
        }
        var own: [String: Own] = [:], titles: [String] = [], shared: Set<String> = []
        for index in items.indices {
            guard let title = items[index].title, let named = itemsByTitle[title], named.contains(index) else { continue }
            // A title the script gives to shapes in more than one container is no title a text can name.
            guard named.count == 1 else {
                shared.insert(title)
                continue
            }
            own[title] = Own(id: items[index].record.id, record: items[index].record, title: renamed[index] ?? title, writes: Set(items[index].shape.attributes.map(\.key)))
            titles.append(title)
        }
        for (index, new) in renamed.sorted(by: { $0.key < $1.key }) where own[new] == nil {
            own[new] = Own(id: items[index].record.id, record: items[index].record, title: new, writes: Set(items[index].shape.attributes.map(\.key)))
            titles.append(new)
        }
        self.own = own
        self.shared = shared
        ownTitles = titles
    }

    // MARK: Asking

    func shape(called written: String, admitting admits: @MainActor (AnyShapeRecord, Set<String>) -> String?) throws(DrawError) -> DrawTextShape {
        do throws(DrawError) {
            return try find(called: written, admitting: admits)
        } catch {
            // What the file's names say of a title, not what is wrong with how it is written.
            guard [ScriptError.Reason.unknownTitle.rawValue, ScriptError.Reason.ambiguousTitle.rawValue, ScriptError.Reason.invalidValue.rawValue].contains(error.reason),
                  error.reason != Drawing.skipped else { throw error }
            var named = error
            named.fromNameLookup = true
            named.lookedForName = written
            throw named
        }
    }

    private func find(called written: String, admitting admits: @MainActor (AnyShapeRecord, Set<String>) -> String?) throws(DrawError) -> DrawTextShape {
        // A key of a program's run names the shape it's given for, before any title.
        if let id = keys[written] { return try keyed(id, written, admitting: admits) }
        guard let naming else {
            throw DrawError("titles name shapes, and nothing here gives shapes names", reason: ScriptError.Reason.noNames.rawValue,
                            hint: "leave titles out: without a plugin that names shapes, no shape can be named or found by name")
        }
        guard let title = naming.fold(written) else {
            throw DrawError("a title can't be blank", reason: ScriptError.Reason.syntax.rawValue, hint: "name a shape by its title")
        }
        // What's called that and isn't admitted: the first of them, by where it is, and why not.
        var refused: (kind: ShapeKind, why: String)?
        if shared.contains(title) {
            throw DrawError("\(quoted(title)) is the title of more than one shape this script draws", reason: ScriptError.Reason.ambiguousTitle.rawValue,
                            hint: FileNames.textHint)
        }
        if let entry = own[title] {
            guard let why = admits(entry.record, entry.writes) else { return DrawTextShape(id: entry.id, title: entry.title) }
            refused = (entry.record.kind, why)
        } else if unresolved.contains(title) {
            throw DrawError("", reason: Drawing.skipped)
        }
        let file = editor.file
        let all = names()?.places[title] ?? []
        let taken = takenBoards()
        let live = all.filter { !deleted.contains($0.id) && !taken.contains($0.board) }
        func admitted(_ places: [Place]) -> [Place] {
            places.filter { place in
                guard let record = file.record(place.id) else { return false }
                guard let why = admits(record, []) else { return true }
                if refused == nil { refused = (record.kind, why) }
                return false
            }
        }

        // The board the run draws on, by itself: one is the shape, two or more are ambiguous.
        let here = admitted(live.filter { $0.board == target.board })
        if here.count > 1 { throw several(here, title, on: "the board") }
        if let found = here.first { return DrawTextShape(id: found.id, title: title) }
        // Then the rest of the file, as an edge finds a shape there: the board the window shows
        // first, else the one other board that has one.
        if let names = names() {
            switch names.beyond(title, among: live.filter { $0.board != target.board }, admitting: admitted, shownAs: "the board the window shows") {
            case .shape(let found):
                return DrawTextShape(id: found.id, title: title)
            case .ambiguous(let message, _):
                throw DrawError(message, reason: ScriptError.Reason.ambiguousTitle.rawValue, hint: FileNames.textHint)
            case .none:
                break
            }
        }

        if let refused {
            throw DrawError("\(quoted(title)) is \(indefinite(refused.kind)), \(refused.why)", reason: ScriptError.Reason.invalidValue.rawValue)
        }
        if all.count > live.count {
            throw DrawError("names \(quoted(title)), which this script deletes", reason: ScriptError.Reason.unknownTitle.rawValue,
                            hint: "draw \(quoted(title)) again after deleting it, or leave it out")
        }
        let guesses = Suggestions.closest(to: title, among: admittedTitles(admits, taken: taken))
        throw DrawError("there's no shape called \(quoted(title))", reason: ScriptError.Reason.unknownTitle.rawValue,
                        hint: guesses.isEmpty ? "a title is one the file has as the script starts, or one the script draws"
                                  : "did you mean \(listed(guesses.map(quoted), or: true))?")
    }

    /// The shape a key names: one the script draws or restates, else the file's, held to what `admits` takes; what it's called is
    /// its title, else the key.
    private func keyed(_ id: ShapeID, _ key: String, admitting admits: @MainActor (AnyShapeRecord, Set<String>) -> String?) throws(DrawError) -> DrawTextShape {
        let called = { (record: AnyShapeRecord) -> String in
            self.naming.flatMap { naming in naming.name(record, self.editor.registry).flatMap(naming.fold) } ?? key
        }
        if let own = ownByID[id] {
            if let why = admits(own.record, own.writes) {
                throw DrawError("\(quoted(key)) is \(indefinite(own.record.kind)), \(why)", reason: ScriptError.Reason.invalidValue.rawValue)
            }
            return DrawTextShape(id: id, title: own.title.isEmpty ? called(own.record) : own.title)
        }
        guard let record = editor.file.record(id), !deleted.contains(id) else {
            throw DrawError("there's no shape for the key \(quoted(key))", reason: ScriptError.Reason.unknownTitle.rawValue,
                            hint: "a key names a node of the document")
        }
        if let why = admits(record, []) {
            throw DrawError("\(quoted(key)) is \(indefinite(record.kind)), \(why)", reason: ScriptError.Reason.invalidValue.rawValue)
        }
        return DrawTextShape(id: id, title: called(record))
    }

    /// Several shapes on one board are called one title: each with its kind and where it is.
    private func several(_ places: [Place], _ title: String, on board: String) -> DrawError {
        let each = places.compactMap { place in
            editor.file.record(place.id).map { record -> String in
                let bounds = target.shapes.geometry(of: record.id)?.bounds ?? record.box
                let said = Drawing.path(of: record.id, in: editor, naming: naming!)?.written
                    ?? "at \(point(bounds.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero))"
                return "\(indefinite(record.kind)) \(said)"
            }
        }
        return DrawError("\(board) has \(places.count) shapes called \(quoted(title)): \(listed(each))",
                         reason: ScriptError.Reason.ambiguousTitle.rawValue, hint: FileNames.textHint)
    }

    // MARK: What it reads

    /// The file's names, read the first time one is asked for.
    private func names() -> FileNames? {
        if fileNames == nil, let naming { fileNames = FileNames(editor, naming: naming) }
        return fileNames
    }

    /// The boards the deletes take.
    private func takenBoards() -> Set<BoardID> {
        if let taken { return taken }
        let boards = deleted.isEmpty ? [] : Set(editor.file.subtree(ownedBy: deleted))
        taken = boards
        return boards
    }

    /// The titles a text may name, as "did you mean" picks from: the file's, in the order it lists
    /// them, then those the script draws.
    private func admittedTitles(_ admits: @MainActor (AnyShapeRecord, Set<String>) -> String?, taken: Set<BoardID>) -> [String] {
        let file = editor.file
        let names = names()
        let inFile = (names?.titles ?? []).filter { title in
            names?.places[title]?.contains { place in
                !deleted.contains(place.id) && !taken.contains(place.board) && file.record(place.id).map { admits($0, []) == nil } == true
            } == true
        }
        return inFile + ownTitles.filter { title in own[title].map { admits($0.record, $0.writes) == nil } == true }
    }
}

// MARK: Writing a value

extension Drawing {
    /// A value a statement wrote for the property `key`, its strings written as their formats say
    /// (the value itself where no format writes any). A refusal is said on the statement's line, as
    /// `prefix` (`"Plan": text`) says what it's about, then `suffix`; one a statement it depends on
    /// leaves to that statement's own error (`Drawing.skipped`) is passed on as it is.
    func writtenTexts(_ value: JSONValue, of key: String, _ vocabulary: KindVocabulary, owner: ShapeID? = nil, prefix: String, suffix: String = "",
                      _ statement: Statement) throws(DrawError) -> JSONValue {
        guard let textWriter else { return value }
        do throws(DrawError) {
            return try textWriter.written(value, of: key, in: vocabulary, owner: owner)
        } catch {
            guard error.reason != Self.skipped else { throw error }
            throw error.said("\(prefix): \(error.message)\(suffix)", on: statement)
        }
    }
}

extension DrawError {
    /// This refusal as a statement says it: the message it is given, on the statement's line, and still the lookup's if it was.
    func said(_ message: String, on statement: Statement) -> DrawError {
        var said = DrawError(message, reason: reason, hint: hint, line: statement.line, statement: statement.text)
        said.fromNameLookup = fromNameLookup
        said.lookedForName = lookedForName
        return said
    }
}

extension Drawing {
    /// The value a script wrote for a property whose owner has a value writer (`registrar.drawValueWriter`),
    /// written as that writer says (names into ids): `written`, and `set`, what the shape is set to. `held` is
    /// what the shape holds now (nil for a new shape): given, `set` is `written` joined with it, as the
    /// writer says; nil, `set` is `written` alone, for a caller that joins it later (an edge's connection
    /// exists only once it is made). A property with no writer takes the value as it is. A refusal is said on
    /// the statement's line as `writtenTexts` says one.
    func writtenValue(_ value: JSONValue, of key: String, _ vocabulary: KindVocabulary, owner: ShapeID?, joining held: JSONValue??,
                      prefix: String, suffix: String = "", _ statement: Statement) throws(DrawError) -> (written: JSONValue, set: JSONValue) {
        guard let writer = registry.drawValueWriters[key], let textWriter else { return (value, value) }
        do throws(DrawError) {
            let written = try writer.write(value, textWriter.context(of: key, in: vocabulary, owner: owner))
            guard let held else { return (written, written) }
            return (written, writer.merge(written, held, registry))
        } catch {
            guard error.reason != Self.skipped else { throw error }
            throw error.said("\(prefix): \(error.message)\(suffix)", on: statement)
        }
    }
}

/// The formats, and the lookup they ask: what writes the strings of a value a script gave a property.
@MainActor
struct DrawTextWriter {
    let registry: Registry
    let formats: [String: DrawTextFormatting]
    let lookup: DrawTextLookup

    /// What a value writer is given for the property `key` of the kind `vocabulary` reads.
    func context(of key: String, in vocabulary: KindVocabulary, owner: ShapeID?) -> DrawTextContext {
        DrawTextContext(registry: registry, schema: vocabulary.properties[key]?.objectValue ?? [:], owner: owner, lookup: lookup)
    }

    /// `value`, a script's for the property `key` of the kind `vocabulary` reads, with each string in
    /// it whose schema says its content is of a media type a format writes, written by the format:
    /// the property's own, and any inside a value that's an object or a list (by its `properties`,
    /// `additionalProperties`, `prefixItems` and `items`, `$ref`s followed). What isn't a string of
    /// such a schema is as it was. It throws what a format throws, as it's thrown; the caller says
    /// where.
    func written(_ value: JSONValue, of key: String, in vocabulary: KindVocabulary, owner: ShapeID?) throws(DrawError) -> JSONValue {
        guard vocabulary.textKeys.contains(key), let declared = vocabulary.properties[key] else { return value }
        return try written(value, declared: declared, in: vocabulary.schema, owner: owner)
    }

    private func written(_ value: JSONValue, declared: JSONValue, in schema: KindSchema, owner: ShapeID?) throws(DrawError) -> JSONValue {
        let resolved = schema.resolved(declared)
        switch value {
        case .string(let text):
            guard let mediaType = resolved["contentMediaType"]?.stringValue, let format = formats[mediaType] else { return value }
            return .string(try format.write(text, DrawTextContext(registry: registry, schema: declared.objectValue ?? [:], owner: owner, lookup: lookup)))
        case .object(let members):
            var written = members
            for name in members.keys.sorted() {
                guard let declared = resolved["properties"]?[name] ?? resolved["additionalProperties"].flatMap({ $0.objectValue == nil ? nil : $0 }) else {
                    continue
                }
                written[name] = try self.written(members[name]!, declared: declared, in: schema, owner: owner)
            }
            return .object(written)
        case .array(let items):
            var written = items
            let prefix = resolved["prefixItems"]?.arrayValue ?? []
            for index in items.indices {
                guard let declared = prefix.indices.contains(index) ? prefix[index] : resolved["items"] else { continue }
                written[index] = try self.written(items[index], declared: declared, in: schema, owner: owner)
            }
            // A list that is `uniqueItems` holds each once, the first of those that say the same (two titles
            // of one shape come out as one id).
            if resolved["uniqueItems"]?.boolValue == true {
                var seen: Set<JSONValue> = []
                written = written.filter { seen.insert($0).inserted }
            }
            return .array(written)
        default:
            return value
        }
    }
}

// MARK: Where a kind can hold one

extension KindVocabulary {
    /// Whether a property's schema holds a string of one of these media types anywhere inside (a
    /// list's items, an object's members, a `$ref`'s target): what a script's value for it is read
    /// for. Each `$ref` is looked into once, so a schema that holds itself ends.
    static func holds(_ declared: JSONValue, _ mediaTypes: Set<String>, in schema: KindSchema, seen: inout Set<String>) -> Bool {
        if let reference = declared.objectValue?["$ref"]?.stringValue, !seen.insert(reference).inserted { return false }
        let resolved = schema.resolved(declared)
        if let mediaType = resolved["contentMediaType"]?.stringValue, mediaTypes.contains(mediaType) { return true }
        var inside: [JSONValue] = Array(resolved["properties"]?.objectValue?.values ?? [:].values)
        inside += resolved["prefixItems"]?.arrayValue ?? []
        if let items = resolved["items"] { inside.append(items) }
        if let additional = resolved["additionalProperties"], additional.objectValue != nil { inside.append(additional) }
        return inside.contains { holds($0, mediaTypes, in: schema, seen: &seen) }
    }
}
