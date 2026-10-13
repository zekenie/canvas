import AppKit
import Canvas
import DetailPanel
import Palette
import SwiftUI

extension ColorsStyle {
    /// A dot in the panel's row and in its grid.
    public static let dot: CGFloat = 13
    /// A dot's ring in the grid when it is the shape's color, and the gap between it and the dot.
    public static let ringWidth: CGFloat = 1.5
    public static let ringGap: CGFloat = 2
    /// The hairline around a dot, so a pale one reads.
    public static let dotHairline: Double = 0.25
    /// Dots in a row of the grid.
    public static let dotsPerRow = 7
    public static let gridSpacing: CGFloat = 6
    /// Between the groups of the grid, and between the grid and its plain rows.
    public static let groupSpacing: CGFloat = 8
    public static let popoverInset: CGFloat = 10
    public static let popoverRowHeight: CGFloat = 22
    /// The row's measures and type, those of the panel's own rows (`DetailStyle`'s are internal).
    public static let rowHeight: CGFloat = 20
    public static let rowSpacing: CGFloat = 4
    public static let rowGap: CGFloat = 8
    public static let font = Font(DetailStyle.textFont)
    public static let chevron = Font.system(size: 8, weight: .bold)
    /// A dimmed label: the kind's default, and none.
    public static let dimmed: Double = 0.5
    /// Naming a picked color, and a file's color's own menu.
    public static let nameColor = "Name…"
    public static let namePlaceholder = "Name"
    public static let add = "Add"
    public static let rename = "Rename"
    public static let renameColorItem = "Rename…"
    public static let changeColorItem = "Change…"
    public static let removeColorItem = "Remove"
    public static let nameFieldWidth: CGFloat = 140
}

/// What the grid's controls ask for.
public enum ColorChoice {
    /// A color to write; nil takes the shape's color away.
    case color(ShapeColor?)
    /// The system color panel.
    case other
    /// The value the shape holds, named: the file gains the color and the shape names it.
    case name(String)
    /// A color of the file's, renamed.
    case rename(NamedColor, to: String)
    /// A color of the file's, given another value in the system color panel.
    case changeValue(NamedColor)
    /// A color of the file's, taken out of it.
    case remove(NamedColor)
}

/// What the panel's Color row shows for a shape and what a pick writes, with no view, so a test
/// drives it. It reads the book: a name the file lacks is shown as the kind's default, as the shape
/// is drawn.
@MainActor
public struct ColorRowModel {
    private let id: ShapeID
    private let own: ShapeColor?
    private let shown: ShapeColor?
    private let book: ColorBook

    public init(record: AnyShapeRecord, book: ColorBook) {
        self.book = book
        id = record.id
        own = record.ownColor
        shown = book.color(of: record)
    }

    /// What the row says: a named color's name (a built-in one's first letter capitalized, a
    /// file's as written), a value as its hex, and for a shape with no color of its own its kind's
    /// default the same way, or `None`.
    public var title: String {
        guard let shown else { return ColorsStyle.none }
        switch shown {
        case .value(let value): return value.hexString
        case .named(let name):
            return book.named(name)?.title ?? name
        }
    }

    /// Whether the row shows what the shape does not hold itself: its kind's default, or none.
    public var isDimmed: Bool { own.map { !book.has($0) } ?? true }

    /// The dot's color: the color itself, as a swatch shows one, the same in both appearances (its
    /// roles are what a shape draws); nil for none.
    public var tone: Tone? {
        switch shown {
        case .value(let value)?: Tone(value)
        case .named(let name)?: book.named(name).map { Tone($0.value) }
        case nil: nil
        }
    }

    /// The grid's groups: the built-in colors, then the file's when it has any.
    public var groups: [[NamedColor]] {
        [BuiltInColors.all, book.fileColors.filter { !$0.isBuiltIn }].filter { !$0.isEmpty }
    }

    /// Whether the shape's own color is this one (a value is none of the dots).
    public func isRinged(_ color: NamedColor) -> Bool {
        guard let own, let canonical = book.canonical(own) else { return false }
        return canonical == color.color
    }

    /// What a dot writes: the name in its list's spelling.
    public func writes(dot color: NamedColor) -> ShapeColor { book.canonical(color.color) ?? color.color }

    /// What None writes: the shape's color taken away.
    public var writesNone: ShapeColor? { nil }

    /// What a color the system color panel reports writes: its value as sRGB. Nil for a color with
    /// no sRGB form (a pattern).
    public func writes(picked color: NSColor) -> ShapeColor? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return .value(RGB(Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent)))
    }

    /// The value the shape holds that can be given a name: its own color, when that is a value.
    public var nameable: RGB? {
        if case .value(let value)? = own { return value }
        return nil
    }

    /// Why a name can't be given (nil: it can): to a new color, or to `old`, one being renamed.
    public func refusal(ofName name: String, renaming old: NamedColor? = nil) -> ColorNameRefusal? {
        book.refusal(ofName: name, renaming: old?.name)
    }

    /// What a choice in the grid does, through the shape's binding of its color: a color is written
    /// (one write, one step), and Other opens the system color panel, each color it reports
    /// written through the same binding, so a drag in it is one step. `openPanel` is the panel's
    /// opener (the system's when nil): it starts at a color and hands back each one the panel reports.
    public func apply(_ choice: ColorChoice, to color: Binding<ShapeColor?>,
                      openPanel: ((NSColor?, @escaping (NSColor) -> Void) -> Void)? = nil) {
        switch choice {
        case .color(let new): color.wrappedValue = new
        case .other:
            let open = openPanel ?? { [id] in ColorPanelTarget.open(starting: $0, for: id, report: $1) }
            open(panelColor()) { picked in
                if let new = writes(picked: picked) { color.wrappedValue = new }
            }
        case .name(let name):
            book.editor.nameColor(of: id, name)
        case .rename(let named, let name):
            book.editor.renameColor(named.name, to: name)
        case .changeValue(let named):
            let open = openPanel ?? { ColorPanelTarget.open(starting: $0, report: $1) }
            let editor = book.editor, name = named.name
            open(NSColor(named.value)) { picked in
                guard case .value(let value)? = writes(picked: picked) else { return }
                editor.setColorValue(of: name, to: value, coalescing: FileColorRun(name: ShapeColor.key(of: name)))
            }
        case .remove(let named):
            book.editor.removeColor(named.name)
        }
    }

    /// What the system color panel starts from: the color itself, as its dot shows it (never a role
    /// of it, or a value picked and left alone would come back as another).
    public func panelColor() -> NSColor? {
        tone.map { NSColor($0.light) }
    }
}

/// What a drag in the color panel over one of the file's colors is one undo step by.
private struct FileColorRun: Hashable {
    let name: String
}

/// The system color panel, reporting into one handler at a time: the row that opened it last. A
/// drag in it reports a color a tick; the handler writes each, and the binding it writes through
/// runs them together as one step. The panel outlives the row (it floats until it's closed), so a
/// row that opened it for its shape lets go of it when it shows another or goes (`release`): what
/// is picked after that is written nowhere, never to a shape no longer shown.
@MainActor
final class ColorPanelTarget: NSObject {
    private static var current: ColorPanelTarget?
    private let handler: (NSColor) -> Void
    /// The shape whose color it writes; nil for one of the file's colors, which is no shape's.
    private let shape: ShapeID?

    private init(shape: ShapeID?, _ handler: @escaping (NSColor) -> Void) {
        self.shape = shape
        self.handler = handler
    }

    /// Stops the panel reporting, if it reports for `shape`.
    static func release(_ shape: ShapeID) {
        guard current?.shape == shape else { return }
        current = nil
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
    }

    static func open(starting color: NSColor?, for shape: ShapeID? = nil, report: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        let target = ColorPanelTarget(shape: shape, report)
        current = target
        panel.showsAlpha = false
        panel.isContinuous = true
        if let color { panel.color = color }
        panel.setTarget(target)
        panel.setAction(#selector(changed(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) { handler(panel.color) }
}
