import Canvas
import CanvasRPC

/// Values written over values, member by member: what `canvas draw`'s `fieldValues: {…}` joins with what a
/// shape holds (`FieldValuesPlugin`), and what a fill's answer sets a field to (`FieldFill`). Pure (public so a
/// test of Types reaches it without `@testable`).
public enum FieldValuesMerge {
    /// `written` over `held`: `null` is `null` (the whole property off); an object is set member by
    /// member over the object held (nothing, a scalar or a list held is nothing to keep), a `null`
    /// member removing that member, any other joined with what the member holds; anything else
    /// (a list, a scalar) is the written value, whole. A `null` inside an object written where nothing is
    /// held clears nothing and is dropped, never stored. An object that sets nothing (only `null`s and
    /// empties) over a scalar or a list held leaves it: clearing a member under a value of the other shape
    /// clears nothing, as the one writer's `FieldValues.setting` has it (an address that was text, its type's
    /// field a group now, keeps its street when `{"unit": null}` is written under it).
    public static func merged(_ written: JSONValue, into held: JSONValue?) -> JSONValue {
        guard case .object(let members) = written else { return written }
        if let held, held.objectValue == nil, FieldValues.pruned(written) == nil { return held }
        var result: JSONObject = held?.objectValue ?? [:]
        for (key, member) in members {
            if member == .null {
                result.removeValue(forKey: key)
            } else {
                result[key] = merged(member, into: result[key])
            }
        }
        return .object(result)
    }
}
