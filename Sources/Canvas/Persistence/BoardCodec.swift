import Foundation
import Geometry

/// Reads and writes boards. A board is JSON: an envelope around every shape, back to front.
///
///     {
///       "format" : 1,
///       "schema" : { "arrow" : 0, "sticky-note" : 1 },
///       "shapes" : [
///         { "id" : "…", "index" : "a0", "kind" : "sticky-note", "props" : { … } }
///       ]
///     }
///
/// `format` versions the envelope and each record's own members; `schema` gives each kind's props
/// version (`ShapeProps.migrations`). Format 2 added a record's metadata (`AnyShapeRecord.meta`),
/// in `meta`: an object for each plugin that keeps some, by its id. A shape the app can't use is
/// kept as it was, with its own version in `v`: its kind isn't installed, it's from a newer version
/// of its kind, or it didn't load. Reading never drops a shape and never stops at one: it refuses
/// only a file that isn't a board, or one in a newer format. What it had to fix, and what it kept
/// aside, is in the report.
public struct BoardCodec: Sendable {
    /// The newest envelope this app reads. It writes the oldest that holds the board: 1, unless a
    /// shape has metadata, which needs 2. So an app from before metadata still opens a board it
    /// would save back whole, and refuses one it would save without its metadata.
    public static let format = 2

    private let kinds: [ShapeKind: KindCodec]

    /// For the kinds `registry` installs. Build it once; it reads and writes off the main actor.
    @MainActor
    public init(registry: Registry) {
        var kinds: [ShapeKind: KindCodec] = [:]
        for kind in registry.kinds {
            if let definition = registry.definition(for: kind) { kinds[kind] = definition.kindCodec }
        }
        self.kinds = kinds
    }

    /// An installed kind's version; nil for a kind that isn't installed.
    public func version(of kind: ShapeKind) -> Int? { kinds[kind]?.version }

    // MARK: Writing

    public func encode(_ document: CanvasDocument) throws -> Data {
        var schema: [String: Int] = [:]
        for record in document.shapes where !record.isOpaque {
            schema[record.kind.rawValue] = type(of: record.props).migrations.count
        }
        let format = document.shapes.contains { !$0.meta.isEmpty } ? 2 : 1
        return try Self.makeEncoder().encode(Envelope(format: format, schema: schema, shapes: document.shapes.map(Record.init)))
    }

    /// One shape's props, as a board writes them: for fixtures, and tools that edit props as JSON.
    public func encodeProps(_ props: any ShapeProps) throws -> Data { try Self.makeEncoder().encode(props) }

    // MARK: Reading

    public func decode(_ data: Data) throws(BoardReadError) -> LoadedBoard {
        let decoder = Self.makeDecoder()
        decoder.userInfo[.boardCodec] = self
        let contents: Contents
        do {
            contents = try decoder.decode(Contents.self, from: data)
        } catch let error as BoardReadError {
            throw error
        } catch {
            throw .unreadable(Self.describe(error))
        }
        return assemble(contents.records)
    }

    /// One shape's props at `version` of `kind`, migrated to today's: for fixtures, and tools that
    /// edit props as JSON. Throws where reading a board would keep the shape aside.
    public func decodeProps(_ data: Data, kind: ShapeKind, version: Int) throws -> any ShapeProps {
        guard let codec = kinds[kind] else { throw ReadProblem("no installed plugin defines \(kind) shapes") }
        return try props(of: codec, at: version, decode: { try codec.decodeData(data) },
                         json: { try Self.makeDecoder().decode(JSONValue.self, from: data) })
    }

    /// Today's props from a shape's props at `version`: straight into the kind's type when it's
    /// today's version, otherwise through the JSON and each migration since.
    private func props(of codec: KindCodec, at version: Int, decode: () throws -> any ShapeProps,
                       json: () throws -> JSONValue) throws -> any ShapeProps {
        guard version <= codec.version else { throw ReadProblem("version \(version) is newer than this app's \(codec.version)") }
        if version == codec.version { return try decode() }
        guard case .object(var props) = try json() else { throw ReadProblem("its props aren't a JSON object") }
        for migration in codec.migrations[max(version, 0)...] {
            do { try migration.body(&props) } catch {
                throw ReadProblem("the migration “\(migration.name)” failed: \(Self.describe(error))")
            }
        }
        return try codec.decodeData(Self.makeEncoder().encode(JSONValue.object(props)))
    }

    /// One element of `shapes`. Never throws: what can't be read is kept aside.
    fileprivate func read(_ decoder: any Decoder, schema: [String: Int]) -> ReadRecord {
        guard let container = try? decoder.container(keyedBy: RecordKeys.self) else {
            let json = (try? JSONValue(from: decoder)) ?? .null
            return ReadRecord(id: nil, kind: ShapeKind(rawValue: ""), key: nil, props: OpaqueProps(json: json, version: 0),
                              meta: ShapeMeta(), droppedMeta: false, keptAside: .unreadable("it isn't a JSON object"))
        }
        let id = try? container.decode(ShapeID.self, forKey: .id)
        let kind = ShapeKind(rawValue: (try? container.decode(String.self, forKey: .kind)) ?? "")
        let key = (try? container.decode(String.self, forKey: .index)).flatMap(StackingKey.init)
        let version = (try? container.decodeIfPresent(Int.self, forKey: .v)) ?? schema[kind.rawValue] ?? 0
        // Not a ternary: JSONValue is ExpressibleByNilLiteral, so `nil` there would be `.null`.
        var metaJSON: JSONValue?
        if container.contains(.meta) { metaJSON = (try? container.decode(JSONValue.self, forKey: .meta)) ?? .null }
        let (meta, droppedMeta) = Self.meta(metaJSON)
        func keptAside(_ reason: LoadReport.KeptShape.Reason) -> ReadRecord {
            let json = (try? container.decode(JSONValue.self, forKey: .props)) ?? .null
            return ReadRecord(id: id, kind: kind, key: key, props: OpaqueProps(json: json, version: version), meta: meta,
                              droppedMeta: droppedMeta, keptAside: reason)
        }
        guard let codec = kinds[kind] else { return keptAside(.unknownKind) }
        guard version <= codec.version else { return keptAside(.newerVersion(file: version, app: codec.version)) }
        let props: any ShapeProps
        do {
            props = try self.props(of: codec, at: version, decode: { try codec.decode(container.superDecoder(forKey: .props)) },
                                   json: { try container.decode(JSONValue.self, forKey: .props) })
        } catch {
            return keptAside(.unreadable(Self.describe(error)))
        }
        if let frame = (props as? any BoxShapeProps)?.frame, !frame.isFinite {
            return keptAside(.unreadable("its frame isn't finite"))
        }
        return ReadRecord(id: id, kind: kind, key: key, props: props, meta: meta, droppedMeta: droppedMeta, keptAside: nil)
    }

    /// A record's metadata: an object with an object for each plugin. What isn't can't be any
    /// plugin's, so it's left out, and the second value says so.
    private static func meta(_ json: JSONValue?) -> (ShapeMeta, dropped: Bool) {
        guard let json else { return (ShapeMeta(), false) }
        guard let members = json.objectValue else { return (ShapeMeta(), true) }
        let kept = members.filter { $0.value.objectValue != nil }
        return (ShapeMeta(json: kept), kept.count != members.count)
    }

    /// The document, after the repairs a board may need: an id for each shape that has none or
    /// repeats one (the first keeps it), and stacking keys that rise. A board written by this app
    /// needs none.
    private func assemble(_ read: [ReadRecord]) -> LoadedBoard {
        var report = LoadReport()
        var seen = Set<ShapeID>()
        var records: [AnyShapeRecord] = []
        records.reserveCapacity(read.count)
        for item in read {
            let id: ShapeID
            if let old = item.id, seen.insert(old).inserted {
                id = old
            } else {
                id = ShapeID()
                seen.insert(id)
                report.repairs.append(.newID(old: item.id, new: id))
            }
            if let reason = item.keptAside { report.keptAside.append(LoadReport.KeptShape(id: id, kind: item.kind, reason: reason)) }
            if item.droppedMeta { report.repairs.append(.droppedMeta(id)) }
            records.append(AnyShapeRecord(id: id, kind: item.kind, props: item.props, stackingKey: item.key, meta: item.meta))
        }
        if !CanvasDocument.keysRise(records) {
            // Shapes with keys in key order, ties broken by id; each key that doesn't rise is
            // replaced by one that does. Shapes without a key go on top, in the order they came.
            let keyed = records.filter { $0.stackingKey != nil }.sorted {
                ($0.stackingKey!, $0.id.rawValue.uuidString) < ($1.stackingKey!, $1.id.rawValue.uuidString)
            }
            var ordered: [AnyShapeRecord] = []
            for (i, var record) in keyed.enumerated() {
                if let previous = ordered.last?.stackingKey, record.stackingKey! <= previous {
                    let next = keyed[(i + 1)...].lazy.compactMap(\.stackingKey).first { $0 > previous }
                    record.stackingKey = .between(previous, next)
                    report.repairs.append(.newStackingKey(record.id))
                }
                ordered.append(record)
            }
            for var record in records where record.stackingKey == nil {
                record.stackingKey = .between(ordered.last?.stackingKey, nil)
                report.repairs.append(.newStackingKey(record.id))
                ordered.append(record)
            }
            records = ordered
        }
        return LoadedBoard(document: CanvasDocument(shapes: records), report: report)
    }

    // MARK: Settings

    /// Pinned, since migrations and fixtures depend on them: sorted keys, pretty-printed, `CGRect`
    /// as `[[x, y], [width, height]]` (CoreGraphics' own), dates in ISO 8601 to the second, and
    /// NaN and the infinities as the strings "nan", "inf" and "-inf", so a save never fails on them.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    /// A decoding error, said briefly: where, and what.
    static func describe(_ error: any Error) -> String {
        func path(_ codingPath: [any CodingKey]) -> String {
            let text = codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return text.hasPrefix(".") ? String(text.dropFirst()) : text
        }
        switch error {
        case let problem as ReadProblem:
            return problem.message
        case DecodingError.keyNotFound(let key, let context):
            return "\(path(context.codingPath + [key])) is missing"
        case DecodingError.dataCorrupted(let context), DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let at = path(context.codingPath)
            return at.isEmpty ? context.debugDescription : "\(at): \(context.debugDescription)"
        default:
            return "\(error)"
        }
    }
}

/// A board, read: what to open, and what reading it took.
public struct LoadedBoard: Sendable {
    public let document: CanvasDocument
    public let report: LoadReport
}

/// What opening a board kept aside and repaired. Repairs are part of the document now, so the
/// board should be marked edited; kept-aside shapes are saved back as they were.
public struct LoadReport: Equatable, Sendable {
    public var keptAside: [KeptShape]
    public var repairs: [Repair]
    public var isEmpty: Bool { keptAside.isEmpty && repairs.isEmpty }

    public init(keptAside: [KeptShape] = [], repairs: [Repair] = []) {
        self.keptAside = keptAside
        self.repairs = repairs
    }

    /// A shape the board keeps but the app can't use (`AnyShapeRecord.isOpaque`).
    public struct KeptShape: Equatable, Sendable {
        public let id: ShapeID
        public let kind: ShapeKind
        public let reason: Reason

        public init(id: ShapeID, kind: ShapeKind, reason: Reason) {
            self.id = id
            self.kind = kind
            self.reason = reason
        }

        public enum Reason: Equatable, Sendable {
            /// No installed plugin defines the kind.
            case unknownKind
            /// Written by a newer version of the kind's plugin.
            case newerVersion(file: Int, app: Int)
            /// It didn't load: bad props, a failed migration, a frame that isn't finite.
            case unreadable(String)
        }
    }

    public enum Repair: Equatable, Sendable {
        /// The shape had no id, or another shape had it first.
        case newID(old: ShapeID?, new: ShapeID)
        /// Its stacking key was missing, malformed, or not above the shape below it.
        case newStackingKey(ShapeID)
        /// Some of its metadata wasn't an object for a plugin, so no plugin's: it was left out.
        case droppedMeta(ShapeID)
    }
}

/// Why a board won't open.
public enum BoardReadError: Error, Equatable, CustomStringConvertible {
    /// Not a board: not JSON, or not the envelope.
    case unreadable(String)
    /// A newer version of the app wrote it.
    case newerFormat(Int)

    public var description: String {
        switch self {
        case .unreadable(let why): "It isn't a board this app can read: \(why)"
        case .newerFormat(let format): "A newer version of the app wrote it (format \(format); this one reads up to \(BoardCodec.format))."
        }
    }
}

/// How a board reads one kind's props: its migrations, and its type.
struct KindCodec: Sendable {
    let migrations: [PropsMigration]
    let decode: @Sendable (any Decoder) throws -> any ShapeProps
    let decodeData: @Sendable (Data) throws -> any ShapeProps
    var version: Int { migrations.count }

    init<P: ShapeProps>(_: P.Type) {
        migrations = P.migrations
        decode = { try P(from: $0) }
        decodeData = { try BoardCodec.makeDecoder().decode(P.self, from: $0) }
    }
}

private struct ReadProblem: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private struct ReadRecord {
    let id: ShapeID?
    let kind: ShapeKind
    let key: StackingKey?
    let props: any ShapeProps
    let meta: ShapeMeta
    /// Some of its metadata was left out (`LoadReport.Repair.droppedMeta`).
    let droppedMeta: Bool
    /// Nil when the props are the kind's own type.
    let keptAside: LoadReport.KeptShape.Reason?
}

private enum RecordKeys: String, CodingKey { case id, kind, index, props, v, meta }

private struct Envelope: Encodable {
    let format: Int
    let schema: [String: Int]
    let shapes: [Record]
}

private struct Record: Encodable {
    let record: AnyShapeRecord

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RecordKeys.self)
        try container.encode(record.id, forKey: .id)
        try container.encode(record.kind.rawValue, forKey: .kind)
        try container.encodeIfPresent(record.stackingKey, forKey: .index)
        try record.props.encode(to: container.superEncoder(forKey: .props))
        if let opaque = record.opaqueProps { try container.encode(opaque.version, forKey: .v) }
        if !record.meta.isEmpty { try container.encode(record.meta.json, forKey: .meta) }
    }
}

/// The whole file, read in one pass: the envelope, then each shape.
private struct Contents: Decodable {
    var records: [ReadRecord] = []

    private enum Keys: String, CodingKey { case format, schema, shapes }

    init(from decoder: any Decoder) throws {
        let codec = decoder.userInfo[.boardCodec] as! BoardCodec
        let container = try decoder.container(keyedBy: Keys.self)
        let format = try container.decode(Int.self, forKey: .format)
        guard format <= BoardCodec.format else { throw BoardReadError.newerFormat(format) }
        guard format >= 1 else { throw BoardReadError.unreadable("format \(format) isn't a board format") }
        let schema = (try? container.decode([String: Int].self, forKey: .schema)) ?? [:]
        var shapes = try container.nestedUnkeyedContainer(forKey: .shapes)
        while !shapes.isAtEnd {
            records.append(codec.read(try shapes.superDecoder(), schema: schema))
        }
    }
}

extension CodingUserInfoKey {
    fileprivate static let boardCodec = CodingUserInfoKey(rawValue: "boardCodec")!
}
