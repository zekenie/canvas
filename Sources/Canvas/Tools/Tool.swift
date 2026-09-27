/// One instance per tool id per editor. A reference type: tools keep targeting state.
///
/// A tool handles presses and hover; everything from press to release belongs to the session it
/// starts. Conform in an extension (`extension MyTool: Tool { ... }`): only there does Swift flag a
/// member that nearly matches a defaulted requirement, and the build fails on it.
@MainActor
public protocol Tool: AnyObject {
    func cursor(in editor: CanvasEditor) -> CanvasCursor
    /// May start a session (`editor.session = ...`).
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor)
    /// The pointer moved with no session running: hover. Also called right after a session ends.
    func pointerMoved(_ pointer: Pointer, in editor: CanvasEditor)
    /// The pointer left the canvas with no session running.
    func pointerExited(in editor: CanvasEditor)
    /// Held or released keys changed with no session running.
    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor)
}

extension Tool {
    public func cursor(in editor: CanvasEditor) -> CanvasCursor { .crosshair }
    public func pointerMoved(_ pointer: Pointer, in editor: CanvasEditor) {}
    public func pointerExited(in editor: CanvasEditor) {}
    public func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) {}
}

/// One press-drag-release. Lives on the editor, so it outlives tool switches: a place tool can
/// switch to select and keep dragging; a drawing tool can drag first and switch after. A session
/// that sets `editor.hintedShapeID` clears it when it ends or cancels.
@MainActor
public protocol Session: AnyObject {
    /// Nil shows the tool's cursor.
    func cursor(in editor: CanvasEditor) -> CanvasCursor?
    /// Selection outlines and the selection box step aside while the selection is being dragged.
    var hidesSelectionIndicator: Bool { get }
    func drag(_ pointer: Pointer, in editor: CanvasEditor)
    /// The button came up. The editor clears the session afterwards unless this started another.
    func end(_ pointer: Pointer, in editor: CanvasEditor)
    /// Escape. Return true if the session cancelled; the editor then clears it.
    func cancel(in editor: CanvasEditor) -> Bool
    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor)
}

extension Session {
    public func cursor(in editor: CanvasEditor) -> CanvasCursor? { nil }
    public var hidesSelectionIndicator: Bool { false }
    public func end(_ pointer: Pointer, in editor: CanvasEditor) {}
    public func cancel(in editor: CanvasEditor) -> Bool { false }
    public func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) {}
}
