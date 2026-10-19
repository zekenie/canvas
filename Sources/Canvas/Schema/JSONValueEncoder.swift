import CanvasRPC
import CoreGraphics
import Foundation

/// Encodes a value straight into `JSONValue`, as the board codec's encoder writes it: dates in ISO
/// 8601 to the second, NaN and the infinities as the strings "nan", "inf" and "-inf", data in base
/// 64, URLs as their text. Writing JSON text and reading it back would cost several times as much,
/// and checking shapes against their kinds' schemas reads every shape on a board. It keeps no
/// coding path (`codingPath` is always empty): nothing here reads one, and it would cost an array a
/// value.
struct JSONValueEncoder {
    func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try Self.json(for: value)
    }

    /// `value` as written: the types the board codec's encoder writes its own way, and anything else
    /// by its own `encode(to:)`. Told apart by their types, not by trying a cast to each, which every
    /// value on a board would pay for.
    fileprivate static func json<T: Encodable>(for value: T) throws -> JSONValue {
        if T.self == String.self { return .string(value as! String) }
        if T.self == CGFloat.self { return number(Double(value as! CGFloat)) }
        if T.self == Double.self { return number(value as! Double) }
        if T.self == Bool.self { return .bool(value as! Bool) }
        if T.self == Int.self { return .number(Double(value as! Int)) }
        // As CoreGraphics codes them, [x, y], [width, height] and [[x, y], [width, height]]: every
        // shape has a frame, or points.
        if T.self == CGRect.self {
            let rect = value as! CGRect
            return .array([pair(rect.origin.x, rect.origin.y), pair(rect.size.width, rect.size.height)])
        }
        if T.self == CGPoint.self { return pair((value as! CGPoint).x, (value as! CGPoint).y) }
        if T.self == CGSize.self { return pair((value as! CGSize).width, (value as! CGSize).height) }
        if T.self == UUID.self { return .string((value as! UUID).uuidString) }
        if T.self == JSONValue.self { return finite(value as! JSONValue) }
        if T.self == Date.self { return .string((value as! Date).formatted(.iso8601)) }
        if T.self == Float.self { return number(value as! Float) }
        if T.self == Data.self { return .string((value as! Data).base64EncodedString()) }
        if T.self == URL.self { return .string((value as! URL).absoluteString) }
        // As its text, which is what the board writes: its `doubleValue` is off in the last digits.
        if T.self == Decimal.self {
            let decimal = value as! Decimal
            return number(Double(decimal.description) ?? NSDecimalNumber(decimal: decimal).doubleValue)
        }
        let encoder = ValueEncoder()
        try value.encode(to: encoder)
        // A value that writes nothing is an empty object, as JSONEncoder writes it.
        return encoder.slot?.resolved ?? .object([:])
    }

    /// As the board codec writes a number: NaN and the infinities as strings.
    fileprivate static func number(_ value: Double) -> JSONValue {
        guard !value.isFinite else { return .number(value) }
        return .string(value.isNaN ? "nan" : value > 0 ? "inf" : "-inf")
    }

    /// A float as the board writes it, its shortest text (0.1, not 0.10000000149011612), as a double.
    fileprivate static func number(_ value: Float) -> JSONValue {
        number(Double(String(value)) ?? Double(value))
    }

    /// JSON as the board writes it: a number in it that isn't finite as its string.
    private static func finite(_ json: JSONValue) -> JSONValue {
        switch json {
        case .number(let value): number(value)
        case .array(let elements): .array(elements.map(finite))
        case .object(let members): .object(members.mapValues(finite))
        case .null, .bool, .string: json
        }
    }

    private static func pair(_ first: CGFloat, _ second: CGFloat) -> JSONValue {
        .array([number(Double(first)), number(Double(second))])
    }
}

/// What an encoder wrote: a value, or a container that later writes may still add to.
private enum Slot {
    case value(JSONValue)
    case object(ObjectBox)
    case array(ArrayBox)
    /// `superEncoder`'s encoder, which writes whenever its caller does.
    case encoder(ValueEncoder)

    var resolved: JSONValue {
        switch self {
        case .value(let value): value
        case .object(let box): box.resolved
        case .array(let box): box.resolved
        case .encoder(let encoder): encoder.slot?.resolved ?? .object([:])
        }
    }
}

/// An object being written. A member is finished when it's written, unless it's a container handed
/// out (`nestedContainer`, `superEncoder`), which is finished with the box.
private final class ObjectBox {
    var members: [String: JSONValue] = [:]
    var open: [String: Slot] = [:]

    func put(_ value: JSONValue, _ key: String) {
        members[key] = value
        if !open.isEmpty { open[key] = nil }
    }

    func open(_ slot: Slot, _ key: String) {
        open[key] = slot
        members[key] = nil
    }

    /// The object at `key`, to write more members into: the one there already, open or written, as
    /// the board codec's encoder has it, else a new one.
    func object(at key: String) -> ObjectBox {
        if case .object(let existing)? = open[key] { return existing }
        let nested = ObjectBox()
        if case .object(let written)? = members[key] { nested.members = written }
        open(.object(nested), key)
        return nested
    }

    /// The array at `key`, to append to, likewise.
    func array(at key: String) -> ArrayBox {
        if case .array(let existing)? = open[key] { return existing }
        let nested = ArrayBox()
        if case .array(let written)? = members[key] { nested.items = written }
        open(.array(nested), key)
        return nested
    }

    var resolved: JSONValue {
        guard !open.isEmpty else { return .object(members) }
        var members = members
        for (key, slot) in open { members[key] = slot.resolved }
        return .object(members)
    }
}

/// An array being written; an element handed out as a container holds its place until the box is
/// finished.
private final class ArrayBox {
    var items: [JSONValue] = []
    var open: [Int: Slot] = [:]

    func open(_ slot: Slot) {
        open[items.count] = slot
        items.append(.null)
    }

    var resolved: JSONValue {
        guard !open.isEmpty else { return .array(items) }
        var items = items
        for (index, slot) in open { items[index] = slot.resolved }
        return .array(items)
    }
}

private final class ValueEncoder: Encoder {
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    /// What was written; nil until something is.
    var slot: Slot?

    func container<Key: CodingKey>(keyedBy _: Key.Type) -> KeyedEncodingContainer<Key> {
        if case .object(let box) = slot { return KeyedEncodingContainer(KeyedContainer<Key>(box: box)) }
        let box = ObjectBox()
        slot = .object(box)
        return KeyedEncodingContainer(KeyedContainer<Key>(box: box))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        if case .array(let box) = slot { return UnkeyedContainer(box: box) }
        let box = ArrayBox()
        slot = .array(box)
        return UnkeyedContainer(box: box)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer { SingleContainer(encoder: self) }
}

private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let box: ObjectBox
    var codingPath: [any CodingKey] { [] }

    mutating func encodeNil(forKey key: Key) throws { box.put(.null, key.stringValue) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { box.put(.bool(value), key.stringValue) }
    mutating func encode(_ value: String, forKey key: Key) throws { box.put(.string(value), key.stringValue) }
    mutating func encode(_ value: Double, forKey key: Key) throws { box.put(JSONValueEncoder.number(value), key.stringValue) }
    mutating func encode(_ value: Float, forKey key: Key) throws { box.put(JSONValueEncoder.number(value), key.stringValue) }
    mutating func encode(_ value: Int, forKey key: Key) throws { box.put(.number(Double(value)), key.stringValue) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { box.put(.number(Double(value)), key.stringValue) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { box.put(.number(Double(value)), key.stringValue) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { box.put(.number(Double(value)), key.stringValue) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { box.put(.number(Double(value)), key.stringValue) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { box.put(.number(Double(value)), key.stringValue) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { box.put(.number(Double(value)), key.stringValue) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { box.put(.number(Double(value)), key.stringValue) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { box.put(.number(Double(value)), key.stringValue) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { box.put(.number(Double(value)), key.stringValue) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        box.put(try JSONValueEncoder.json(for: value), key.stringValue)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy _: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(KeyedContainer<NestedKey>(box: box.object(at: key.stringValue)))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        UnkeyedContainer(box: box.array(at: key.stringValue))
    }

    mutating func superEncoder() -> any Encoder {
        let encoder = ValueEncoder()
        box.open(.encoder(encoder), "super")
        return encoder
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        let encoder = ValueEncoder()
        box.open(.encoder(encoder), key.stringValue)
        return encoder
    }
}

private struct UnkeyedContainer: UnkeyedEncodingContainer {
    let box: ArrayBox
    var codingPath: [any CodingKey] { [] }
    var count: Int { box.items.count }

    mutating func encodeNil() throws { box.items.append(.null) }
    mutating func encode(_ value: Bool) throws { box.items.append(.bool(value)) }
    mutating func encode(_ value: String) throws { box.items.append(.string(value)) }
    mutating func encode(_ value: Double) throws { box.items.append(JSONValueEncoder.number(value)) }
    mutating func encode(_ value: Float) throws { box.items.append(JSONValueEncoder.number(value)) }
    mutating func encode(_ value: Int) throws { box.items.append(.number(Double(value))) }
    mutating func encode(_ value: Int8) throws { box.items.append(.number(Double(value))) }
    mutating func encode(_ value: Int16) throws { box.items.append(.number(Double(value))) }
    mutating func encode(_ value: Int32) throws { box.items.append(.number(Double(value))) }
    mutating func encode(_ value: Int64) throws { box.items.append(.number(Double(value))) }
    mutating func encode(_ value: UInt) throws { box.items.append(.number(Double(value))) }
    mutating func encode(_ value: UInt8) throws { box.items.append(.number(Double(value))) }
    mutating func encode(_ value: UInt16) throws { box.items.append(.number(Double(value))) }
    mutating func encode(_ value: UInt32) throws { box.items.append(.number(Double(value))) }
    mutating func encode(_ value: UInt64) throws { box.items.append(.number(Double(value))) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        box.items.append(try JSONValueEncoder.json(for: value))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy _: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let nested = ObjectBox()
        box.open(.object(nested))
        return KeyedEncodingContainer(KeyedContainer<NestedKey>(box: nested))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let nested = ArrayBox()
        box.open(.array(nested))
        return UnkeyedContainer(box: nested)
    }

    mutating func superEncoder() -> any Encoder {
        let encoder = ValueEncoder()
        box.open(.encoder(encoder))
        return encoder
    }
}

private struct SingleContainer: SingleValueEncodingContainer {
    let encoder: ValueEncoder
    var codingPath: [any CodingKey] { [] }

    private func put(_ value: JSONValue) { encoder.slot = .value(value) }

    mutating func encodeNil() throws { put(.null) }
    mutating func encode(_ value: Bool) throws { put(.bool(value)) }
    mutating func encode(_ value: String) throws { put(.string(value)) }
    mutating func encode(_ value: Double) throws { put(JSONValueEncoder.number(value)) }
    mutating func encode(_ value: Float) throws { put(JSONValueEncoder.number(value)) }
    mutating func encode(_ value: Int) throws { put(.number(Double(value))) }
    mutating func encode(_ value: Int8) throws { put(.number(Double(value))) }
    mutating func encode(_ value: Int16) throws { put(.number(Double(value))) }
    mutating func encode(_ value: Int32) throws { put(.number(Double(value))) }
    mutating func encode(_ value: Int64) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt8) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt16) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt32) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt64) throws { put(.number(Double(value))) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        put(try JSONValueEncoder.json(for: value))
    }
}
