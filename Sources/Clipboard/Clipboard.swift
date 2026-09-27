import AppKit
import Canvas
import ContextMenus
import Keyboard
import Selection

/// Cut, copy and paste, as a plugin: ⌘X, ⌘C and ⌘V (registered with Keyboard), Edit › Cut, Copy
/// and Paste (the commands the board's window runs), and Cut, Copy and Paste in every context
/// menu, on shapes and on empty canvas. Copying puts the selection's copyable shapes on the pasteboard; pasting puts
/// copies of them on the board, with new ids, each remembering the shape it was copied from
/// (`CopiedFrom`, kept in its board). Every kind is copyable unless it opts out
/// (`shape.uncopyable()`). Only this app's shapes paste: anything else on the pasteboard (text, an
/// image) is left alone, for now.
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

/// Where a pasted shape was copied from, in its metadata: `record.copiedFrom`. Boards keep it.
public enum CopiedFrom {}

extension CopiedFrom: ShapeMetaKey {
    public typealias Value = CopySource
    public static var owner: PluginID { .clipboard }
    public static var name: String { "copiedFrom" }
}

/// The shape a copy was made from.
public struct CopySource: Codable, Equatable, Sendable {
    /// Its id in the board it was copied from: this one or another, and it may be gone since (a cut
    /// shape always is). A copy of a copy names the copy it was made from.
    public var shape: ShapeID

    public init(shape: ShapeID) { self.shape = shape }
}

extension AnyShapeRecord {
    /// The shape this one is a copy of, if it was pasted (`meta[CopiedFrom.self]`).
    public var copiedFrom: ShapeID? { meta[CopiedFrom.self]?.shape }
}

// MARK: The context menu

/// Cut, Copy and Paste, items for the canvas: after a kind's own items and a feature's, before
/// Arrange.
public enum ClipboardMenuGroup {}
extension ClipboardMenuGroup: MenuGroup {
    public static var order: Int { 100 }
}

// MARK: The plugin

/// `pasteboard` is where copies go and pastes come from: the system's, by default, shared by every
/// board. Tests pass one of their own (`NSPasteboard.withUniqueName()`), so they never touch it.
public struct ClipboardPlugin: CanvasPlugin {
    let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    public var id: PluginID { .clipboard }

    public func register(into registrar: inout PluginRegistrar) {
        let pasteboard = pasteboard
        registrar.service { ClipboardState(editor: $0, pasteboard: pasteboard) }
        // ⌘X, ⌘C and ⌘V on the canvas, and Edit › Cut, Copy and Paste (the board's window runs these
        // commands wherever the keyboard is, but in text), do one thing.
        registrar.command(.cut, shortcuts: [KeyChord("x", .command)], isEnabled: { $0.canCut }) { $0.cutSelection() }
        registrar.command(.copy, shortcuts: [KeyChord("c", .command)], isEnabled: { $0.canCopy }) { $0.copySelection() }
        registrar.command(.paste, shortcuts: [KeyChord("v", .command)], isEnabled: { $0.canPaste }) { $0.paste() }
        // In every context menu, on shapes and on empty canvas. Cut and Copy show when some of the
        // shapes the menu is for can be copied, and act on those; Paste, when there's something
        // to paste.
        registrar.contextMenuForCanvas {
            MenuItem("Cut", in: ClipboardMenuGroup.self, when: { $0.shapes.contains(where: $0.editor.isCopyable) }) { ids, editor in
                editor.cut(ids)
            }
            MenuItem("Copy", in: ClipboardMenuGroup.self, when: { $0.shapes.contains(where: $0.editor.isCopyable) }) { ids, editor in
                editor.copy(ids)
            }
            MenuItem("Paste", in: ClipboardMenuGroup.self, when: { $0.editor.canPaste }) { _, editor in editor.paste() }
        }
    }
}
