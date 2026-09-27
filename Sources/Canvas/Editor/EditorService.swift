/// Per-editor plugin state (an engine, a timer, a selection), made when the editor is and found by
/// type with `editor.service(S.self)`. The editor tells every service what it may need to follow,
/// in the order the services were made: plugin order, except that a service another one's `make`
/// looks up comes first.
@MainActor
public protocol EditorService: AnyObject {
    /// Called on every tool switch, including in the middle of a drag.
    func toolDidChange(from old: ToolID, to new: ToolID, in editor: CanvasEditor)
    /// Called after every transaction that changed the document, before anything redraws, with
    /// what it changed: drop what no longer names a shape here, and redo what's kept per shape
    /// for the shapes in `changes` only.
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor)
    /// A place tool (or any `editor.place`) just put this shape down, and the default tool is
    /// current again. Called before the shape starts following the pointer or being edited.
    func didPlace(_ id: ShapeID, in editor: CanvasEditor)
    /// Something tried to change these shapes and didn't, since they're read-only
    /// (`registrar.readOnlyShapes`): a transaction, once it's done (with every shape it refused, and
    /// after its commit of the rest, if any); a drag, once it gets going (past the drag threshold);
    /// or editing one. The plugin whose rule made them read-only may say why (Locking shakes them).
    func didRefuseChanges(to ids: Set<ShapeID>, in editor: CanvasEditor)
}

extension EditorService {
    public func toolDidChange(from old: ToolID, to new: ToolID, in editor: CanvasEditor) {}
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {}
    public func didPlace(_ id: ShapeID, in editor: CanvasEditor) {}
    public func didRefuseChanges(to ids: Set<ShapeID>, in editor: CanvasEditor) {}
}
