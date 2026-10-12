/// A root `properties` key: a field, or a directive (`$title`). The one place the split is written.
public enum SchemaDirectives {
    /// A field's key does not start `$`. (A bare `$` is neither a field nor a directive, as `Chain` has it.)
    public static func isField(_ key: String) -> Bool {
        !key.hasPrefix("$")
    }

    /// `title` for `$title`; nil for a field's key and for a bare `$`.
    public static func name(_ key: String) -> String? {
        key.hasPrefix("$") && key.count > 1 ? String(key.dropFirst()) : nil
    }
}
