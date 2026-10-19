import CanvasRPC

/// JSON as a value: what a migration rewrites, what the board keeps for a shape the app can't
/// read, and a shape's properties as JSON (`record.propertiesJSON`). It is the wire's `JSON`
/// (CanvasRPC), one type, so what the core writes goes on the wire as it is, with no copy between
/// two of them. Numbers are doubles, so integers beyond 2⁵³ lose precision. A file that names its
/// members (a case, an accessor, a literal) imports CanvasRPC.
public typealias JSONValue = JSON

/// A JSON object: one shape's props, as a migration sees them.
public typealias JSONObject = [String: JSONValue]
