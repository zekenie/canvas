/// Per-editor plugin state (an engine, a timer, a selection), made when the editor is and found by
/// type with `editor.service(S.self)`. The editor tells every service what it may need to follow,
/// in the order the services were made: plugin order, except that a service another one's `make`
/// looks up comes first. A commit and another board shown are delivered in two rounds. First each
/// service takes the change in (`documentDidChange`, `boardDidChange`): a service asked for meanwhile
/// (`editor.service`, a layout reading's or a context's `service`) takes it in first, if it hasn't yet,
/// so a service read as another takes a change in has taken it in, whatever the order; and what a
/// service looked up as it was made takes each change in before it, so what it kept from its `make`
/// reads as of the change. A service is busy until its hook returns: asking for one then is a mistake
/// (tests and debug builds stop there; the app goes on with the service as it is), so a service others
/// follow tells them once it has taken the change in (`editor.onceHeard`). Then every service settles
/// (`documentDidSettle`, `boardDidSettle`): none is busy, and what reads around the file or tells the
/// window happens there, or once all have settled (`editor.onceSettled`, for what a service is told
/// while they take the change in). Each hears each change once, in the order they came, and nothing may
/// change the file in either round (a transaction then is a precondition failure).
@MainActor
public protocol EditorService: AnyObject {
    /// Called on every tool switch, including in the middle of a drag.
    func toolDidChange(from old: ToolID, to new: ToolID, in editor: CanvasEditor)
    /// Called after every transaction that changed the document, before anything redraws, with
    /// what it changed: drop what no longer names a shape here, and redo what's kept per shape
    /// for the shapes in `changes` only, reading the services this one is made from (each has taken the
    /// commit in once it's asked for). What asks around (which shapes the commit affected) or tells the
    /// window (a look under the pointer, a view laid out again) waits for `documentDidSettle` or
    /// `editor.onceSettled`. Never
    /// transact here: a write in answer waits a turn (`editor.scheduler`).
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor)
    /// Every service has taken the commit in (`documentDidChange`): none is busy, so any may be read.
    /// Do here what asks what the commit affected, reads around the file or tells the window. Nothing
    /// may transact here either. By default nothing.
    func documentDidSettle(_ changes: ChangeSet, in editor: CanvasEditor)
    /// A place tool (or any `editor.place`) just put these shapes down (one, but for shapes placed
    /// together: `editor.placeLater`), and the default tool is current again. Called before they start
    /// following the pointer or being edited.
    func didPlace(_ ids: [ShapeID], in editor: CanvasEditor)
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
    /// tool are in place. Take back what's kept for it, or start over. Delivered as a commit is: a
    /// service read here has heard it. By default nothing: a service that keeps state per shape of the
    /// board shown follows it as a commit (`documentDidChange(change.changes, in:)`, every shape of one
    /// board gone and every shape of the other come), which costs both boards' shapes, so one that
    /// keeps it per board says what it does instead (a `BoardStash`).
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor)
    /// Every service has taken the board shown in (`boardDidChange`), as `documentDidSettle` after a
    /// commit. By default nothing.
    func boardDidSettle(_ change: BoardChange, in editor: CanvasEditor)
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
    /// Shapes' tints (`editor.tint(of:)`) changed with no commit to the shapes
    /// (`editor.shapeTintsDidChange()`: the file's colors changed): a service that keeps a row's
    /// symbol, or the tint of one, makes it again for the shapes it keeps. A commit to a shape says
    /// so itself.
    func shapeTintsDidChange(in editor: CanvasEditor)
}

extension EditorService {
    public func toolDidChange(from old: ToolID, to new: ToolID, in editor: CanvasEditor) {}
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {}
    public func documentDidSettle(_ changes: ChangeSet, in editor: CanvasEditor) {}
    public func didPlace(_ ids: [ShapeID], in editor: CanvasEditor) {}
    public func didRefuseChanges(to ids: Set<ShapeID>, in editor: CanvasEditor) {}
    public func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {}
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
    public func boardDidSettle(_ change: BoardChange, in editor: CanvasEditor) {}
    public func drawsSkeletonsDidChange(in editor: CanvasEditor) {}
    public func editingDidEnd(_ id: ShapeID, in editor: CanvasEditor) {}
    public func shapeTintsDidChange(in editor: CanvasEditor) {}
}
