import Canvas
import CanvasRPC

/// The `$ref`s in `json` that its `$defs` don't have.
public func danglingReferences(in json: JSONObject) -> [String] {
    let defined = Set((json["$defs"]?.objectValue ?? [:]).keys.map { "#/$defs/\($0)" })
    var references: [String] = []
    func walk(_ value: JSONValue) {
        switch value {
        case .object(let object):
            if let reference = object["$ref"]?.stringValue { references.append(reference) }
            object.values.forEach(walk)
        case .array(let array): array.forEach(walk)
        default: break
        }
    }
    walk(.object(json))
    return references.filter { !defined.contains($0) }
}
