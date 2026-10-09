import Foundation

extension CanvasEditor {
    /// The shapes' geometry is out of date though no commit touched them: it reads something a
    /// commit didn't change (a layout input; another board's names), which has. The editor lets go
    /// of what it kept for them, on the board shown and on those it keeps ready, and of what
    /// looked them up, and redraws; they're worked out again when next asked, so it costs what
    /// they are. It changes nothing stored: no transaction, no undo step, nothing edited.
    public func shapesDidChangeLayout(_ ids: some Sequence<ShapeID>) {
        let ids = Set(ids)
        guard !ids.isEmpty else { return }
        shapeIndex.layoutDidChange(ids)
        warmIndexes.modifyAll { $0.layoutDidChange(ids) }
        setNeedsDisplay()
    }

    /// Sets what a shape's geometry reads under `key` (`ShapeContext.layoutInput`), nil to take it
    /// back, and, if that changes it, has the shape's geometry worked out again
    /// (`shapesDidChangeLayout`). Only the plugin that owns a key sets it, and keeps it up to date as
    /// what it's made from changes; the editor keeps it for the session and writes it nowhere.
    public func setLayoutInput<V>(_ key: LayoutInputKey<V>, _ value: V?, for id: ShapeID) {
        guard layoutInputs.set(key.name, value, for: id) else { return }
        shapesDidChangeLayout([id])
    }
}
