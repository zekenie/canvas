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
        layoutRevision += 1
        laidOutSizes.forget(ids)
        shapeIndex.layoutDidChange(ids)
        warmIndexes.modifyAll { $0.layoutDidChange(ids) }
        shownBoards.layoutDidChange(ids)
        setNeedsDisplay()
        // Then services, for what is laid out from these shapes' frames on another board (a mirror, as big as its original).
        tellShapesDidChangeLayout(ids)
    }

    /// Sets what a shape's geometry reads under `key` (`ShapeContext.layoutInput`), nil to take it
    /// back, and, if that changes it, has the shape's geometry worked out again
    /// (`shapesDidChangeLayout`). Only the plugin that owns a key sets it, and keeps it up to date as
    /// what it's made from changes; the editor keeps it for the session and writes it nowhere. A key
    /// that has a provider (`registrar.layoutInput`) is asked for, never set.
    public func setLayoutInput<V>(_ key: LayoutInputKey<V>, _ value: V?, for id: ShapeID) {
        precondition(registry.layoutProviders[key.name] == nil, "layout input \(key.name) has a provider, so it is asked for, never set")
        guard layoutInputs.set(key.name, value, for: id) else { return }
        shapesDidChangeLayout([id])
    }

    /// The frame a shape is laid out in, wherever it is in the file: on the board shown it's
    /// `shapeContext.frame(of:)`; on another board the editor can show (`shape(inFile:)`) it's laid
    /// out, and kept, without that board's geometry being worked out. Nil for a shape with no box, or
    /// not there. Observed through `document`.
    public func frame(inFile id: ShapeID) -> CGRect? {
        guard let record = shape(inFile: id) else { return nil }
        if document[id] != nil { return shapeContext.frame(of: record) }
        guard let board = file.board(containing: id) else { return nil }
        return ShapeContext(document: file[board], registry: registry, camera: camera, index: nil, layout: layoutSource).frame(of: record)
    }

    /// A commit changed these shapes: the sizes kept for them are out of date, but for a shape that
    /// only moved (a size doesn't depend on where the shape is: a drag of thousands costs a
    /// comparison). Before the index and the services hear it.
    func forgetLaidOutSizes(after changes: ChangeSet) {
        guard laidOutSizes.count > 0 else { return }
        laidOutSizes.forget(changes.added)
        if changes.changed.count != changes.moved.count {
            laidOutSizes.forget(changes.changed.lazy.filter { !changes.moved.contains($0) })
        }
        laidOutSizes.forget(changes.removed)
        laidOutSizes.forget(changes.elsewhere)
    }

    #if DEBUG
    /// How many laid-out sizes the editor keeps (debug builds): what a test holds a deleted shape's to.
    @_spi(Host) public var laidOutSizeCount: Int { laidOutSizes.count }
    #endif
}
