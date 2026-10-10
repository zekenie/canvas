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
    /// or editing one. A read-only container that wouldn't take a shape is among them, and so is the
    /// owner of a read-only board something tried to put a shape on (`editor.isBoardReadOnly`), which
    /// is on another board. Selection shakes those on the board shown (`RefusalShake`); the plugin whose rule made them read-only may say why too.
    func didRefuseChanges(to ids: Set<ShapeID>, in editor: CanvasEditor)
    /// Another board is about to be shown (`editor.showBoard`), and the one shown is still `old`:
    /// save what belongs to it (a draft, state kept per board in a `BoardStash`). Also before the
    /// file is replaced (`replaceFile`), when `new` is the board shown after, which may be `old`.
    func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor)
    /// Another board is shown: its document, its camera, what the editor keeps of it and the default
    /// tool are in place. Take back what's kept for it, or start over. Don't read another service
    /// here: services hear it one by one, and one read before it's heard is out of date. By default,
    /// the shown board's change as a commit's (`change.changes`, every shape of one board gone and
    /// every shape of the other come): right for state kept per shape, which then follows the switch
    /// like any commit, but it costs both boards' shapes, so a service that keeps less, or keeps it
    /// per board, says what it does instead.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor)
    /// The canvas started or stopped drawing shapes as skeletons (`editor.drawsSkeletons`): the
    /// camera's zoom went past the editor's `skeletonZoom` (a pinch, a zoom command, a board shown
    /// with its camera, heard after `boardDidChange`), or the host moved that past the zoom. Only
    /// when the level changes, never as editing begins or ends (the shape being edited draws in
    /// full either way). A service whose hit testing goes by what a shape draws (a face on its text,
    /// an adornment's label) lets go here of a hover or a button under the pointer that the level
    /// doesn't show now: a pointer held still tells it nothing.
    func drawsSkeletonsDidChange(in editor: CanvasEditor)
    /// The shape being edited isn't any more (`editor.endEditing`, however it came: Escape, a click
    /// elsewhere, another shape edited, another board shown, an undo): its editing view is closed
    /// and what it wrote committed. Its step is closed unless what ended it is an action whose step
    /// is still open (a command, an undo or redo about to apply a step, a draw, a file put in
    /// place), so a service that writes, or asks for something, in answer waits a turn
    /// (`editor.scheduler`) and looks again, as a type's sync does before it takes the
    /// description as done.
    func editingDidEnd(_ id: ShapeID, in editor: CanvasEditor)
}

extension EditorService {
    public func toolDidChange(from old: ToolID, to new: ToolID, in editor: CanvasEditor) {}
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {}
    public func didPlace(_ id: ShapeID, in editor: CanvasEditor) {}
    public func didRefuseChanges(to ids: Set<ShapeID>, in editor: CanvasEditor) {}
    public func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {}
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) { documentDidChange(change.changes, in: editor) }
    public func drawsSkeletonsDidChange(in editor: CanvasEditor) {}
    public func editingDidEnd(_ id: ShapeID, in editor: CanvasEditor) {}
}
