import AppKit
import Canvas
import Observation
import Palette

/// A color's roles as Core Graphics colors, in one appearance: what a render sets its fills and
/// strokes with (`context.colors(of:)`). Made once for a color and kept, since a frame of skeletons
/// draws thousands.
public final class SwatchColors {
    /// A line or a symbol on the canvas, and a fill that holds text.
    public let solid: CGColor
    /// Text on `solid`.
    public let onSolid: CGColor
    /// A faint surface on the canvas.
    public let wash: CGColor
    /// A large surface that holds shapes, raised off the canvas.
    public let surface: CGColor
    /// Text in the color, on the canvas, on `wash` or on `surface`.
    public let ink: CGColor
    /// A note's sheet.
    public let paper: CGColor
    /// Text on `paper`.
    public let paperInk: CGColor

    init(_ swatch: Swatch, dark: Bool) {
        solid = swatch.solid[dark: dark].cgColor
        onSolid = swatch.onSolid[dark: dark].cgColor
        wash = swatch.wash[dark: dark].cgColor
        surface = swatch.surface[dark: dark].cgColor
        ink = swatch.ink[dark: dark].cgColor
        paper = swatch.paper[dark: dark].cgColor
        paperInk = swatch.paperInk[dark: dark].cgColor
    }
}

/// The book of colors (`editor.colors`): which names there are, the built-in ones and then the
/// file's, and what every color looks like. Everything that shows a shape's color asks it: a
/// kind's render (`context.colors(of:)`), another plugin (`swatch(of:)`: a type's pill), the lists
/// of names (`names`: the panel's grid, `/color`, Color ▸).
///
/// A shape's color is its own (`ColorProperty`) where the file has it, else its kind's default
/// (`colorable(default:)`), else none: a name the file lacks is drawn as the default, and warned of
/// (`ColorValidationPlugin`). It keeps nothing per shape: what it keeps is per color, made the first
/// time one is asked for and let go of when the file's colors change, so a frame costs each shape a
/// lookup and a commit costs nothing.
@MainActor
@Observable
public final class ColorBook {
    @ObservationIgnored unowned let editor: CanvasEditor

    /// The colors the file adds, after the built-in ones, in its order.
    public private(set) var fileColors: [NamedColor] = []

    /// A color's roles, and their colors in each appearance.
    private final class Resolved {
        let swatch: Swatch
        let light: SwatchColors
        let dark: SwatchColors
        /// The roles asked for as colors that follow the appearance, made when first asked for and
        /// kept, so two asks are the same color and a list that compares them sees no change.
        var dynamic: [KeyPath<Swatch, Tone>: NSColor] = [:]

        func color(_ role: KeyPath<Swatch, Tone>) -> NSColor {
            if let known = dynamic[role] { return known }
            let made = NSColor(swatch[keyPath: role])
            dynamic[role] = made
            return made
        }

        init(_ swatch: Swatch) {
            self.swatch = swatch
            light = SwatchColors(swatch, dark: false)
            dark = SwatchColors(swatch, dark: true)
        }
    }

    /// The file's colors by `ShapeColor.key(of:)`.
    @ObservationIgnored private var fileColorsByKey: [String: NamedColor] = [:]
    /// What's been asked for, by the color as it's held; nil for a name the file lacks.
    @ObservationIgnored private var resolved: [ShapeColor: Resolved?] = [:]
    /// Each kind's default, resolved; nil for a kind with none.
    @ObservationIgnored private var defaults: [ShapeKind: Resolved?] = [:]
    /// The color and the kind asked for last: shapes drawn one after another mostly share both.
    @ObservationIgnored private var lastColor: (color: ShapeColor, resolved: Resolved?)?
    @ObservationIgnored private var lastKind: (kind: ShapeKind, resolved: Resolved?)?
    /// The appearance last drawn in, and whether it's dark: asked once an appearance, not a shape.
    @ObservationIgnored private var appearance: NSAppearance?
    @ObservationIgnored private var appearanceIsDark = false
    @ObservationIgnored private var handlers: [@MainActor () -> Void] = []

    /// How many distinct colors are kept before the lot is let go: a picker dragged across its
    /// wheel asks for thousands of values.
    private static let capacity = 4096

    init(editor: CanvasEditor) {
        self.editor = editor
        // The file's colors as the file has them now, before anyone has asked what anything looks like.
        let colors = editor.withoutObservingDocument { Self.colors(in: editor) }
        fileColors = colors
        fileColorsByKey = Self.byKey(colors)
    }

    // MARK: The names

    /// Every named color: the built-in ones, then the file's.
    public var names: [NamedColor] { BuiltInColors.all + fileColors }

    /// The color called `name`, whatever its case: a built-in one, else the file's.
    public func named(_ name: String) -> NamedColor? {
        BuiltInColors.named(name) ?? fileColorsByKey[ShapeColor.key(of: name)]
    }

    /// A color as it's stored: a name in the spelling its list has (`BLUE` is `blue`), a value as
    /// it is. Nil for a name neither built in nor the file's.
    public func canonical(_ color: ShapeColor) -> ShapeColor? {
        switch color {
        case .value: color
        case .named(let name): named(name)?.color
        }
    }

    /// Whether the file has the color: false only for a name neither built in nor the file's.
    public func has(_ color: ShapeColor) -> Bool { canonical(color) != nil }

    /// Whether a kind's shapes have colors (`registry.isColorable`): for what is handed the editor's
    /// services and not its registry (a panel section's `shownWhile`).
    func hasColors(_ kind: ShapeKind) -> Bool { editor.registry.isColorable(kind) }

    // MARK: What a color looks like

    /// The roles a color is drawn in; nil for a name the file lacks.
    public func swatch(for color: ShapeColor) -> Swatch? { resolve(color)?.swatch }

    /// The color's `solid` as a color that follows the appearance, the same one for each ask until
    /// the file's colors change; nil for a name the file lacks. A listed shape's symbol.
    func tint(for color: ShapeColor) -> NSColor? { resolve(color)?.color(\.solid) }

    /// The color a shape is drawn in: its own where the file has it, else its kind's default; nil
    /// for a shape drawn as its kind looks on its own, and for a kind with no colors.
    public func color(of record: AnyShapeRecord) -> ShapeColor? {
        guard editor.registry.isColorable(record.kind) else { return nil }
        if let own = record.ownColor, resolve(own) != nil { return own }
        return editor.registry.defaultColor(of: record.kind)
    }

    /// The roles a shape is drawn in, as `color(of:)`.
    public func swatch(of record: AnyShapeRecord) -> Swatch? {
        guard editor.registry.isColorable(record.kind) else { return nil }
        return resolved(own: record.ownColor, kind: record.kind)?.swatch
    }

    /// One role of the color a shape is drawn in, as a color that follows the appearance: what a
    /// view, or anything that takes an `NSColor`, is handed (`book.color(\.paper, of: record)`: a
    /// title's cover's surface). Made once a color and role, and kept; nil for a shape drawn as its
    /// kind looks on its own.
    public func color(_ role: KeyPath<Swatch, Tone>, of record: AnyShapeRecord) -> NSColor? {
        guard editor.registry.isColorable(record.kind) else { return nil }
        return color(role, for: record.ownColor, kind: record.kind)
    }

    /// The same, for a shape of `kind` holding `own`: what a kind asks of its own typed shape.
    public func color(_ role: KeyPath<Swatch, Tone>, for own: ShapeColor?, kind: ShapeKind) -> NSColor? {
        resolved(own: own, kind: kind)?.color(role)
    }

    /// The colors a shape of `kind` holding `own` is drawn in, in the appearance being drawn: what
    /// `context.colors(of:)` answers. Nil for one drawn as its kind looks on its own.
    public func colors(for own: ShapeColor?, kind: ShapeKind) -> SwatchColors? {
        guard let found = resolved(own: own, kind: kind) else { return nil }
        return drawsDark ? found.dark : found.light
    }

    /// The colors a color is drawn in, in the appearance being drawn; nil for a name the file lacks.
    public func colors(for color: ShapeColor) -> SwatchColors? {
        guard let found = resolve(color) else { return nil }
        return drawsDark ? found.dark : found.light
    }

    private func resolved(own: ShapeColor?, kind: ShapeKind) -> Resolved? {
        if let own, let found = resolve(own) { return found }
        if let lastKind, lastKind.kind == kind { return lastKind.resolved }
        let found: Resolved?
        if let known = defaults[kind] {
            found = known
        } else {
            found = editor.registry.defaultColor(of: kind).flatMap { resolve($0) }
            defaults[kind] = .some(found)
        }
        lastKind = (kind, found)
        return found
    }

    private func resolve(_ color: ShapeColor) -> Resolved? {
        if let lastColor, lastColor.color == color { return lastColor.resolved }
        let found: Resolved?
        if let known = resolved[color] {
            found = known
        } else {
            switch color {
            case .value(let value): found = Resolved(Swatch(value))
            case .named(let name): found = named(name).map { Resolved($0.swatch) }
            }
            if resolved.count >= Self.capacity { resolved.removeAll(keepingCapacity: true) }
            resolved[color] = .some(found)
        }
        lastColor = (color, found)
        return found
    }

    /// Whether the appearance being drawn in is dark.
    private var drawsDark: Bool {
        let current = NSAppearance.currentDrawing()
        if current !== appearance {
            appearance = current
            appearanceIsDark = current.isDark
        }
        return appearanceIsDark
    }

    // MARK: Changes

    /// Calls `handler` after the file's colors change (one added, renamed, given another value or
    /// removed, an undo of any, a file put in place): what a plugin that keeps something made from a
    /// color hears, to make it again. A shape's own color changing is a commit, which says so itself.
    public func onChange(_ handler: @escaping @MainActor () -> Void) {
        handlers.append(handler)
    }

    /// Takes the file's colors as they now are, lets go of what was made from the old ones, and
    /// tells who asked.
    func fileColorsDidChange(to colors: [NamedColor]) {
        guard colors != fileColors else { return }
        fileColors = colors
        fileColorsByKey = Self.byKey(colors)
        resolved.removeAll(keepingCapacity: true)
        defaults.removeAll(keepingCapacity: true)
        lastColor = nil
        lastKind = nil
        for handler in handlers { handler() }
        editor.setNeedsDisplay()
    }

    /// The colors the file holds, as named colors.
    private static func colors(in editor: CanvasEditor) -> [NamedColor] {
        editor.file[FileColorsProperty.self].entries.map { NamedColor(name: $0.name, value: $0.value) }
    }

    private static func byKey(_ colors: [NamedColor]) -> [String: NamedColor] {
        Dictionary(colors.map { (ShapeColor.key(of: $0.name), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Takes the file's colors as they now are, if they're what changed.
    private func followFile(_ keys: Set<PropertyKey>) {
        guard keys.contains(FileColorsProperty.key) else { return }
        fileColorsDidChange(to: editor.withoutObservingDocument { Self.colors(in: editor) })
    }
}

extension ColorBook: EditorService {
    /// The file's colors, after a commit, an undo or a redo, and a file put in place.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        followFile(changes.fileValues)
    }

    /// It keeps nothing per shape or per board, so a switch of board is nothing to it; a file put in
    /// place with it (`change.fileValues`) may have other colors. Never the boards' shapes.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        followFile(change.fileValues)
    }
}

extension CanvasEditor {
    /// The book of colors; nil without `ColorsPlugin`.
    public var colors: ColorBook? { service(ColorBook.self) }

    /// Gives these shapes a color, or with nil takes theirs away, in one step ("Change Color"), on
    /// whichever boards they are. A name is stored in its list's spelling. Shapes of a kind with no
    /// colors are left out; a read-only shape is refused by the core, and shakes.
    public func setColor(_ color: ShapeColor?, of ids: [ShapeID]) {
        let taking = ids.filter { id in shape(inFile: id).map { registry.isColorable($0.kind) } ?? false }
        guard !taking.isEmpty else { return }
        let stored = color.map { colors?.canonical($0) ?? $0 }
        transact(ColorsStyle.changeColor) { transaction in
            for id in taking { transaction.update(inFile: id) { $0[ColorProperty.self] = stored } }
        }
    }
}

extension RenderContext {
    /// The colors this shape's color is drawn in, in the appearance being drawn: its own color's
    /// where the file has it, else its kind's default's; nil for a shape drawn as its kind looks on
    /// its own. One lookup a shape: read it in a render and a skeleton alike.
    public func colors<P: ShapeProps>(of shape: ShapeRecord<P>) -> SwatchColors? {
        service(ColorBook.self)?.colors(for: shape[ColorProperty.self], kind: P.kind)
    }
}
