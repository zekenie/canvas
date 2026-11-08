import Foundation

/// A name for something a plugin keeps of how a file is viewed on this Mac, never in the file: a view value (LineRows'
/// folds). Kept per editor while it's open, saved by the host with the file's view (the cameras, the board left open)
/// and handed back before the canvas is made the next time the file opens. Setting one is no commit and no step: it
/// changes nothing stored, marks nothing edited, and Undo never sees it. The core knows nothing of what one holds.
public struct ViewValueKey<Value: Codable & Sendable>: Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

extension CanvasEditor {
    /// The value kept under `key` (`setViewValue`), or handed back by the host from an earlier session; nil for none,
    /// and for one that no longer reads as `V`.
    public func viewValue<V>(_ key: ViewValueKey<V>) -> V? {
        guard let data = viewValueStore[key.name] else { return nil }
        return try? JSONDecoder().decode(V.self, from: data)
    }

    /// Keeps `value` under `key`, nil to let it go: no transaction, no undo step, nothing edited. The plugin that owns a
    /// key sets it whenever what it keeps changes, so what the host saves is current; keep it small (it is saved in the
    /// Mac's defaults with the file's view).
    public func setViewValue<V>(_ key: ViewValueKey<V>, _ value: V?) {
        viewValueStore[key.name] = value.flatMap { try? JSONEncoder().encode($0) }
    }

    /// Every view value, encoded, by key: what the host saves with the file's view (`BoardViewMemory`).
    @_spi(Host) public var viewValues: [String: Data] { viewValueStore }

    /// Puts back the view values an earlier session saved, in place of any kept, before the canvas is made: every service
    /// hears it (`viewValuesDidChange`), so one that reads a value lazily reads it again and lays out again what it changes.
    @_spi(Host) public func restoreViewValues(_ values: [String: Data]) {
        viewValueStore = values
        tellViewValuesRestored()
    }
}
