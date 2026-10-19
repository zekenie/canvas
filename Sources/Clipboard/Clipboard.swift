import AppKit
import Canvas
import ContextMenus
import Geometry
import Keyboard
import Selection

/// Cut, copy and paste, as a plugin: ⌘X, ⌘C and ⌘V (registered with Keyboard), Edit › Cut, Copy
/// and Paste (the commands the board's window runs), and Cut, Copy and Paste in every context
/// menu, on shapes and on empty canvas. Copying puts the selection's copyable shapes on the
/// pasteboard; pasting puts copies of them on the board, with new ids, each remembering the shape
/// it was copied from (`CopiedFrom`, kept in its board). Cutting and pasting is a move: a paste of
/// what a cut took puts the shapes themselves back, on whatever board, under the ids they had
/// (those the file doesn't use), so what names them (a mention) names them again. Every kind is
/// copyable unless it opts out (`shape.uncopyable()`). Only this app's shapes paste: anything else
/// on the pasteboard (text, an image) is left alone, for now. ⇧⌘V (Edit › Paste at Pointer) pastes
/// centered on the pointer while it's over the canvas. Edit › Copy as Image (⇧⌘C) is the window's:
/// this plugin says what it draws, the file a copy of the selection (or the board) would be
/// (`registrar.imageSource`).
extension PluginID {
    public static let clipboard: PluginID = "clipboard"
}

// MARK: Copyability

/// Whether a kind's shapes can be copied (and so cut). At most one rule per kind, plus one for every
/// kind (`.any`), which a kind's own overrides; a kind with neither is always copyable.
public enum ShapeCopyability {}

extension ShapeCopyability: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (AnyShapeRecord) -> Bool
    public static var owner: PluginID { .clipboard }
    public static func uniqueKeys(of _: Contribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

// Sugar, so opting out is one line.
extension ShapeRegistrar {
    /// This kind's shapes are never copied: copying (or cutting) a selection leaves them out, and on
    /// their own, the context menu has no Cut or Copy. They're still selected, moved and deleted as
    /// usual.
    public mutating func uncopyable() {
        contribute({ _ in false }, to: ShapeCopyability.self)
    }

    /// Copyable only while `isCopyable` says so (a stamp that's sealed, say).
    public mutating func copyable(when isCopyable: @escaping @MainActor (ShapeRecord<Definition.Props>) -> Bool) {
        contribute({ $0.typed(as: Definition.Props.self).map(isCopyable) ?? false }, to: ShapeCopyability.self)
    }
}

// MARK: Where a copy came from

/// Where a pasted copy was copied from, in its metadata: `record.copiedFrom`. Boards keep it. A
/// shape a cut took and a paste put back is no copy: it keeps whatever it had.
public enum CopiedFrom {}

extension CopiedFrom: ShapeMetaKey {
    public typealias Value = CopySource
    public static var owner: PluginID { .clipboard }
    public static var name: String { "copiedFrom" }
}

/// The shape a copy was made from.
public struct CopySource: Codable, Equatable, Sendable {
    /// Its id in the board it was copied from: this one or another, and it may be gone since. A
    /// copy of a copy names the copy it was made from.
    public var shape: ShapeID

    public init(shape: ShapeID) { self.shape = shape }
}

extension AnyShapeRecord {
    /// The shape this one is a copy of, if it was pasted as a copy (`meta[CopiedFrom.self]`).
    public var copiedFrom: ShapeID? { meta[CopiedFrom.self]?.shape }
}

/// Clipboard's constants.
@MainActor
public enum ClipboardStyle {
    /// How far a duplicate lands from what it copies, down and right, in view points.
    public static let duplicateOffset: CGFloat = 16
}

// MARK: The context menu

/// Cut, Copy, Duplicate and Paste, items for the canvas: after a kind's own items and a feature's, before
/// Arrange.
public enum ClipboardMenuGroup {}
extension ClipboardMenuGroup: MenuGroup {
    public static var order: Int { 100 }
}

// MARK: The plugin

/// `pasteboard` is where copies go and pastes come from: the system's, made from nothing (as the
/// product's list makes it), shared by every board. That reaches outside the process, so the plugin
/// is an `OutwardPlugin`: anything but the app that loads the list hands over its own, and tests
/// pass a pasteboard of their own (`NSPasteboard.withUniqueName()`), so they never touch the user's.
public struct ClipboardPlugin: OutwardPlugin {
    let pasteboard: NSPasteboard

    public init() { self.init(pasteboard: .general) }
    public init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    public var id: PluginID { .clipboard }

    public func register(into registrar: inout PluginRegistrar) {
        let pasteboard = pasteboard
        registrar.service { ClipboardState(editor: $0, pasteboard: pasteboard) }
        // ⌘X, ⌘C and ⌘V on the canvas, and Edit › Cut, Copy and Paste (the board's window runs these
        // commands wherever the keyboard is, but in text), do one thing.
        registrar.command(.cut, "Cut", shortcuts: [KeyChord("x", .command)], isEnabled: { $0.canCut }) { $0.cutSelection() }
        registrar.command(.copy, "Copy", shortcuts: [KeyChord("c", .command)], isEnabled: { $0.canCopy }) { $0.copySelection() }
        registrar.command(.paste, "Paste", shortcuts: [KeyChord("v", .command)], isEnabled: { $0.canPaste }) { $0.paste() }
        // ⇧⌘V pastes as ⌘V does, but centered on the pointer while it's over the canvas.
        registrar.command(.pasteAtPointer, "Paste at Pointer", shortcuts: [KeyChord("v", [.command, .shift])], isEnabled: { $0.canPaste }) {
            $0.pasteAtPointer()
        }
        // What Edit › Copy as Image draws (the window's item, ⇧⌘C): the file a copy would be.
        registrar.imageSource(isAvailable: { $0.canCopyAsImage }) { $0.imageShapes() }
        // ⌘D and Edit › Duplicate copy the selection beside itself without the pasteboard; ⌥ held on a drag
        // of the selection (Selection's `copiesOnDrag`) carries copies in place of the shapes.
        registrar.command(.duplicate, "Duplicate", shortcuts: [KeyChord("d", .command)], isEnabled: { $0.canDuplicate }) { $0.duplicateSelection() }
        registrar.copiesOnDrag { editor, ids in editor.duplicate(ids) }
        // In every context menu, on shapes and on empty canvas. Cut, Copy and Duplicate show when some
        // of the shapes the menu is for can be copied, and run their commands on the selection, which
        // the menu's shapes are by then; Paste, when there's something to paste, which lands centered
        // where the menu was asked for (⌘V keeps its rule: where it was copied from, if that's in
        // view), so the item has an action of its own and stands for the command (its key; the
        // selection's menu leaves it out, as the menu bar has Paste).
        registrar.contextMenuForCanvas {
            MenuItem(command: .cut, in: ClipboardMenuGroup.self, when: { $0.shapes.contains(where: $0.editor.isCopyable) })
            MenuItem(command: .copy, in: ClipboardMenuGroup.self, when: { $0.shapes.contains(where: $0.editor.isCopyable) })
            MenuItem(command: .duplicate, in: ClipboardMenuGroup.self,
                     when: { !$0.editor.isBoardReadOnly && $0.shapes.contains(where: $0.editor.isCopyable) })
            MenuItem("Paste", command: .paste, in: ClipboardMenuGroup.self, when: { $0.editor.canPaste }) { subject in   // handed the subject: its point
                if let point = subject.point { subject.editor.paste(centeredAt: point) } else { subject.editor.paste() }
            }
        }
    }
}
