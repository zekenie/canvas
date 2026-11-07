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
/// copyable unless it opts out (`shape.uncopyable()`). This app's shapes paste, and text another app put
/// there that a plugin's reader turns into shapes (`registrar.pasteReader`); anything else on the
/// pasteboard (an image, text no reader reads) is left alone. ⇧⌘V (Edit › Paste at Pointer) pastes
/// centered on the pointer while it's over the canvas. Edit › Copy as Image (⇧⌘C) is the window's:
/// this plugin says what it draws, the file a copy of the selection (or the board) would be
/// (`registrar.imageSource`).
extension PluginID {
    public static let clipboard: PluginID = "clipboard"
}

extension CanvasCommand {
    /// Cut (⌘X; Edit › Cut): the shapes copied, then deleted as a cut, so a paste moves them.
    public static let cut: CanvasCommand = "cut"
    /// Copy (⌘C; Edit › Copy): the shapes that can be copied, on the pasteboard.
    public static let copy: CanvasCommand = "copy"
    /// Paste (⌘V; Edit › Paste): what's on the pasteboard put down, selected; from a context menu,
    /// centered on its click.
    public static let paste: CanvasCommand = "paste"
    /// Edit › Paste at Pointer (⇧⌘V): Paste, landing centered on the pointer while it's over the canvas.
    public static let pasteAtPointer: CanvasCommand = "pasteAtPointer"
    /// Edit › Duplicate (⌘D): the shapes copied beside themselves, without the pasteboard.
    public static let duplicate: CanvasCommand = "duplicate"
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

// MARK: Reading what another app put there

/// What turns text another app put on the pasteboard into shapes ⌘V puts down (`registrar.pasteReader`):
/// asked in plugin order, only when the pasteboard holds none of this app's shapes, and the first that reads
/// the text is the paste. A kit switches them: a reader whose plugin's kit is off in the file is never asked.
public enum PasteReaders {}

extension PasteReaders: ExtensionPoint, KitSwitched {
    public typealias Contribution = PasteReader
    public static var owner: PluginID { .clipboard }
    public static func summary(of reader: PasteReader, for _: ShapeTarget) -> String { "paste reader \(reader.name)" }
}

/// A reader of text on the pasteboard (`registrar.pasteReader`).
public struct PasteReader {
    /// What it reads, for the registry's report ("emoji").
    public let name: String
    let read: @MainActor (String, CanvasEditor) -> CanvasFile?
}

extension PluginRegistrar {
    /// Reads text another app put on the pasteboard into shapes: `read` is handed the text and the editor, and
    /// gives back what to put down as a file (its root's shapes, back to front, with the boards they own and
    /// what containers among them hold), anywhere, or nil for text it doesn't read. ⌘V puts its shapes down
    /// as it puts down this app's own, as new shapes, never copies: centered in the view (on the pointer for
    /// Paste at Pointer, on the click for a context menu's Paste), settled where they land, selected, in one
    /// Paste step. Asked as the pasteboard changes, so keep it cheap; only when the pasteboard holds none of this
    /// app's shapes, after the readers before it in plugin order, and never while the plugin's kit is off.
    public mutating func pasteReader(_ name: String, _ read: @escaping @MainActor (_ text: String, _ editor: CanvasEditor) -> CanvasFile?) {
        contribute(PasteReader(name: name, read: read), to: PasteReaders.self)
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

/// Cut, Copy, Duplicate and Paste, items for the canvas: where they first appear, after a kind's own
/// items and a feature's, before Arrange and what the shape is made from.
public enum ClipboardMenuGroup {}
extension ClipboardMenuGroup: MenuGroup {}

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
        // ⌘X, ⌘C and ⌘V on the canvas, Edit › Cut, Copy and Paste (AppKit's own items, which text
        // answers first; the board's window runs these where nothing else took them) and the context
        // menu's items do one thing, on the shapes they're for: some can be copied. Paste lands where
        // ⌘V's rule says (where it was copied from, if that's in view), or, from a context menu,
        // centered on its click.
        registrar.command(.cut, title: "Cut", answering: .cut, shortcut: KeyChord("x", .command), runs: .betweenPresses,
                          isEnabled: { $0.editor.canCopy($0.shapes) }) { $0.editor.cut($0.shapes) }
        registrar.command(.copy, title: "Copy", answering: .copy, shortcut: KeyChord("c", .command),
                          isEnabled: { $0.editor.canCopy($0.shapes) }) { _ = $0.editor.copy($0.shapes) }
        registrar.command(.paste, title: "Paste", answering: .paste, shortcut: KeyChord("v", .command), runs: .betweenPresses,
                          isEnabled: { $0.editor.canPaste }) { subject in
            if let point = subject.point { subject.editor.paste(centeredAt: point) } else { subject.editor.paste() }
        }
        // ⇧⌘V pastes as ⌘V does, but centered on the pointer while it's over the canvas; text being
        // edited keeps the key.
        registrar.command(.pasteAtPointer, title: "Paste at Pointer", in: EditMenu.CutCopyPaste.self, placed: .after(.paste), shortcut: KeyChord("v", [.command, .shift]),
                          runs: .whenIdle, isEnabled: { $0.editor.canPaste }) { $0.editor.pasteAtPointer() }
        // What Edit › Copy as Image draws (the window's item, ⇧⌘C): the file a copy would be.
        registrar.imageSource(isAvailable: { $0.canCopyAsImage }) { $0.imageShapes() }
        // ⌘D and Edit › Duplicate copy the shapes beside themselves without the pasteboard, on a board
        // that takes shapes; ⌥ held on a drag of the selection (Selection's `copiesOnDrag`) carries copies
        // in place of the shapes.
        registrar.command(.duplicate, title: "Duplicate", in: EditMenu.CutCopyPaste.self, placed: .after(.pasteAtPointer), shortcut: KeyChord("d", .command), runs: .whenIdle,
                          isEnabled: { !$0.editor.isBoardReadOnly && $0.editor.canCopy($0.shapes) }) { $0.editor.duplicateBeside($0.shapes) }
        registrar.copiesOnDrag { editor, ids in editor.duplicate(ids) }
        // In every context menu, on shapes and on empty canvas, while the command can act on the menu's
        // shapes (and its click, for Paste); the selection's menu leaves them out, as the menu bar has them.
        registrar.contextMenuForCanvas {
            MenuItem(command: .cut, in: ClipboardMenuGroup.self)
            MenuItem(command: .copy, in: ClipboardMenuGroup.self)
            MenuItem(command: .duplicate, in: ClipboardMenuGroup.self)
            MenuItem(command: .paste, in: ClipboardMenuGroup.self)
        }
    }
}
