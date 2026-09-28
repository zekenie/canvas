import AppKit
import Canvas

/// Where a shape draws one mention text on the canvas: what it says, its box (world units), its
/// style, and at most how many lines. Made from the shape alone: its props or its added values.
@MainActor
public struct MentionTextPlacement {
    public let text: MentionText
    public let box: CGRect
    public let style: MentionTextStyle
    public let lines: Int?

    public init<S>(_ text: ScopedMentionText<S>, in box: CGRect, style: MentionTextStyle, lines: Int? = nil) {
        self.text = MentionText(text)
        self.box = box
        self.style = style
        self.lines = lines
    }

    /// The box the text is laid out in: as tall as `lines` lines, if that's less than the box.
    var laidOutBox: CGRect {
        guard let lines else { return box }
        var box = box
        // Half a point spare, so a lines' height that rounds a hair short still holds the last:
        // no line is anywhere near that short, so it never holds one more.
        box.size.height = min(box.height, CGFloat(max(0, lines)) * MentionTextLayout.lineHeight(of: style) + 0.5)
        return box
    }

    /// Whether it holds a mention.
    var hasMentions: Bool {
        text.runs.contains { if case .mention = $0 { true } else { false } }
    }
}

/// Where each kind draws mention text: one per kind. A kind's render draws exactly these
/// (`drawMentionText`), and its pills are found through them (`mentionPills(of:)`, the faces).
public enum MentionTexts {}

extension MentionTexts: KeyedExtensionPoint {
    public typealias Contribution = MentionTextContribution
    public static var owner: PluginID { .mentions }
    public static func uniqueKeys(of _: MentionTextContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: MentionTextContribution, for target: ShapeTarget) -> String { "mention text → \(target)" }

    /// No mention text takes a length or a pattern (`MentionTextFormat.checkBounds`).
    public static func check(_ registry: Registry) throws { try MentionTextFormat.checkBounds(in: registry) }
}

/// What `MentionTexts` keeps for a kind: its placements, from a shape.
@MainActor
public struct MentionTextContribution {
    let place: @MainActor (AnyShapeRecord) -> [MentionTextPlacement]

    init<P: ShapeProps>(_: P.Type, _ place: @escaping @MainActor (ShapeRecord<P>) -> [MentionTextPlacement]) {
        self.place = { $0.typed(as: P.self).map(place) ?? [] }
    }
}

extension ShapeRegistrar {
    /// Where this kind draws mention text. Its render draws exactly these (`drawMentionText`), and
    /// the pills in them are faces (Selection's `ShapeFaces`): a click edits the shape from the pill,
    /// the pointer over a live one hovers what it names, and a double-click on one of a read-only
    /// shape goes there.
    ///
    ///     note.mentionText { note in [MentionTextPlacement(note.props.text, in: note.textBox, style: NoteStyle.text)] }
    public mutating func mentionText(_ place: @escaping @MainActor (ShapeRecord<Definition.Props>) -> [MentionTextPlacement]) {
        contribute(MentionTextContribution(Definition.Props.self, place), to: MentionTexts.self)
    }
}

extension PluginRegistrar {
    /// Where another plugin's kind draws mention text (bridges).
    public mutating func mentionText<P: ShapeProps>(_: P.Type, _ place: @escaping @MainActor (ShapeRecord<P>) -> [MentionTextPlacement]) {
        contribute(MentionTextContribution(P.self, place), to: MentionTexts.self, for: .kind(P.kind))
    }
}

extension Registry {
    /// Where a shape draws mention text: its kind's placements, none for a kind without.
    public func mentionTextPlacements(of shape: AnyShapeRecord) -> [MentionTextPlacement] {
        guard !shape.isOpaque else { return [] }
        return contributions(to: MentionTexts.self, for: shape.kind).first?.place(shape) ?? []
    }
}

extension RenderContext {
    /// Draws it with `NSAttributedString.draw(with:options:)`, each mention a pill named as its
    /// shape is now, on any board of the file the editor can show (looked up through
    /// `shape(inFile:)`, which a render's lookups don't tie it to), or, if it isn't on one, by the
    /// name it holds, dashed. Text without mentions draws exactly as a plain string with the style's
    /// attributes. What it draws is kept (`MentionTextMemo`), by what it says and how each mention
    /// shows, so a frame of texts that didn't change builds nothing.
    public func drawMentionText(_ placement: MentionTextPlacement) {
        let box = placement.laidOutBox
        let string: NSAttributedString
        if placement.hasMentions {
            let context = self
            var resolver = MentionResolver(registry: shapes.registry, lookup: { context.shape(inFile: $0) })
            string = MentionTextMemo.shared.entry(for: placement, resolver: &resolver, drawing: true).string
        } else {
            string = placement.style.attributedString(placement.text, width: placement.box.width) { _ in .missing }
        }
        string.draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// A pill's place on the canvas, in world units, where the shape is (not where a shake draws it):
/// live, or naming a shape that isn't there or can't be mentioned.
public struct MentionPillFrame: Hashable, Sendable {
    public let target: ShapeID
    public let frame: CGRect
    public let isLive: Bool

    public init(target: ShapeID, frame: CGRect, isLive: Bool) {
        self.target = target
        self.frame = frame
        self.isLive = isLive
    }

    public static func == (a: Self, b: Self) -> Bool { a.target == b.target && a.frame == b.frame && a.isLive == b.isLive }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(target)
        hasher.combine(frame.origin.x)
        hasher.combine(frame.origin.y)
        hasher.combine(frame.size.width)
        hasher.combine(frame.size.height)
        hasher.combine(isLive)
    }
}

extension CanvasEditor {
    /// Where each pill of a shape's mention text is drawn, in world units, in text order: every
    /// placement of its kind's (`MentionTexts`), each pill string drawing shows. A pill on a last
    /// line that's cut short, where the "…" takes its place, and one on a line past the box, aren't
    /// shown, so they have none. Laid out only for the shape asked about, and kept with its text.
    public func mentionPills(of shape: ShapeID) -> [MentionPillFrame] {
        guard let record = document[shape] else { return [] }
        let placements = registry.mentionTextPlacements(of: record)
        guard !placements.isEmpty else { return [] }
        var resolver = MentionResolver(registry: registry, lookup: { [unowned self] in self.shape(inFile: $0) })
        var frames: [MentionPillFrame] = []
        for placement in placements where placement.hasMentions {
            let box = placement.laidOutBox
            let entry = MentionTextMemo.shared.entry(for: placement, resolver: &resolver)
            for pill in entry.pills(in: box.size, style: placement.style) {
                frames.append(MentionPillFrame(target: pill.target, frame: pill.frame.offsetBy(dx: box.minX, dy: box.minY), isLive: pill.isLive))
            }
        }
        return frames
    }
}

// MARK: Resolving, as the canvas does

/// What each mention shows, looked up through `lookup`, with each kind's defaults (its tool's name
/// and symbol) worked out once per resolver rather than once per pill.
@MainActor
struct MentionResolver {
    let registry: Registry
    let lookup: (ShapeID) -> AnyShapeRecord?
    private var defaults: [ShapeKind: MentionKindDefaults] = [:]

    init(registry: Registry, lookup: @escaping (ShapeID) -> AnyShapeRecord?) {
        self.registry = registry
        self.lookup = lookup
    }

    /// As `registry.mentionResolution(of:lookup:)` has it.
    mutating func resolve(_ target: ShapeID) -> MentionResolution {
        guard let record = lookup(target) else { return .missing }
        guard !record.isOpaque else { return .unavailable }
        let kindDefaults: MentionKindDefaults
        if let found = defaults[record.kind] {
            kindDefaults = found
        } else {
            kindDefaults = MentionKindDefaults(record.kind, in: registry)
            defaults[record.kind] = kindDefaults
        }
        return registry.mentionAppearance(of: record, defaults: kindDefaults).map { .live($0) } ?? .unavailable
    }
}

// MARK: The memo

/// Mention text as the canvas draws it, kept by what makes it: the text as stored, how each of its
/// mentions shows, the style and the width. Keyed by content, it's never invalidated: a rename
/// makes a new key, and the old one ages out. Each keeps its pills' places, laid out when first
/// asked (`pills(in:style:)`).
///
/// It keeps `capacity` texts, those used longest ago going first, and never one a frame being drawn
/// has drawn: a frame of more texts than that grows it, and it keeps as many as the last frame of
/// each editor drawing drew, so however many texts are in view, the next frame builds none of them
/// (a cache of fixed size that a frame goes through in order would lose each text just before it's
/// drawn again). Each frame ends where `MentionFrames`, an overlay that draws nothing, runs.
@MainActor
final class MentionTextMemo {
    static let shared = MentionTextMemo(capacity: MentionStyle.memoCapacity)

    struct Key: Hashable {
        let stored: String
        let resolutions: [MentionResolution]
        let font: NSFont
        let color: NSColor
        let lineHeight: CGFloat?
        let surface: MentionSurface
        let width: CGFloat
    }

    /// One text, built: its attributed string, and its pills' places for the last size asked.
    @MainActor
    final class Entry {
        let string: NSAttributedString
        private var laidOut: (size: CGSize, pills: [MentionTextLayout.Pill])?

        init(string: NSAttributedString) { self.string = string }

        /// Where its pills are, laid out in a box of `size` (from the box's top-left), as string
        /// drawing shows them.
        func pills(in size: CGSize, style: MentionTextStyle) -> [MentionTextLayout.Pill] {
            if let laidOut, laidOut.size == size { return laidOut.pills }
            let pills = MentionTextLayout.pills(of: string, in: size, style: style)
            laidOut = (size, pills)
            return pills
        }
    }

    let capacity: Int
    private var slots: [Int: Slot] = [:]
    private var index: [Key: Int] = [:]
    /// The most and least recently used slots: a list through `newer` and `older`.
    private var newest: Int?
    private var oldest: Int?
    private var nextSlot = 0

    /// The frame being drawn, and how many texts it has drawn.
    private var generation = 0
    private var drawnThisFrame = 0
    /// How many texts each editor's last frame drew, while the editor is there.
    private var lastFrames: [ObjectIdentifier: LastFrame] = [:]

    private struct Slot {
        let key: Key
        let entry: Entry
        var newer: Int?
        var older: Int?
        /// The frame that last drew it; -1 for none.
        var drawn: Int
    }

    private struct LastFrame {
        weak var editor: CanvasEditor?
        var drawn: Int
    }

    /// The most it keeps, however many texts a frame draws.
    var ceiling: Int { capacity * MentionStyle.memoCeilingFactor }

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { index.count }

    /// The placement's text as the canvas draws it, each mention as `resolver` resolves it: kept,
    /// or built now. `drawing` is whether a frame draws it, which keeps it until the frame ends.
    func entry(for placement: MentionTextPlacement, resolver: inout MentionResolver, drawing: Bool = false) -> Entry {
        var resolutions: [MentionResolution] = []
        for run in placement.text.runs {
            if case .mention(let id, _) = run { resolutions.append(resolver.resolve(id)) }
        }
        let style = placement.style
        let key = Key(stored: placement.text.stored, resolutions: resolutions, font: style.font, color: style.color,
                      lineHeight: style.lineHeight, surface: style.surface, width: placement.box.width)
        if let slot = index[key], let found = slots[slot] {
            touch(slot)
            if drawing { markDrawn(slot) }
            return found.entry
        }
        var next = resolutions.makeIterator()
        let string = style.attributedString(placement.text, width: placement.box.width) { _ in next.next() ?? .missing }
        #if DEBUG
        MentionDrawingCounts.stringsBuilt += 1
        #endif
        let entry = Entry(string: string)
        let slot = insert(key, entry)
        if drawing { markDrawn(slot) }
        return entry
    }

    /// A frame of `editor`'s has been drawn: what it drew is kept for the next, with the last
    /// frame's of every other editor, and the rest goes, those used longest ago first, down to
    /// `capacity`.
    func frameDidEnd(in editor: CanvasEditor) {
        lastFrames[ObjectIdentifier(editor)] = LastFrame(editor: editor, drawn: drawnThisFrame)
        lastFrames = lastFrames.filter { $0.value.editor != nil }
        generation += 1
        drawnThisFrame = 0
        let kept = max(capacity, lastFrames.values.reduce(0) { $0 + $1.drawn })
        while index.count > kept, let last = oldest { evict(last) }
    }

    private func markDrawn(_ slot: Int) {
        guard let drawn = slots[slot]?.drawn, drawn != generation else { return }
        slots[slot]?.drawn = generation
        drawnThisFrame += 1
    }

    /// Past `capacity`, the text used longest ago makes room, unless this frame has drawn it: then
    /// the memo grows, up to `ceiling` (a frame that never ends, or one of more texts than that).
    @discardableResult
    private func insert(_ key: Key, _ entry: Entry) -> Int {
        if index.count >= capacity, let last = oldest, slots[last]?.drawn != generation || index.count >= ceiling { evict(last) }
        let slot = nextSlot
        nextSlot += 1
        slots[slot] = Slot(key: key, entry: entry, newer: nil, older: newest, drawn: -1)
        if let newest { slots[newest]?.newer = slot }
        newest = slot
        if oldest == nil { oldest = slot }
        index[key] = slot
        return slot
    }

    private func touch(_ slot: Int) {
        guard slot != newest, let current = slots[slot] else { return }
        unlink(slot, current)
        slots[slot]?.newer = nil
        slots[slot]?.older = newest
        if let newest { slots[newest]?.newer = slot }
        newest = slot
        if oldest == nil { oldest = slot }
    }

    private func evict(_ slot: Int) {
        guard let current = slots[slot] else { return }
        unlink(slot, current)
        slots[slot] = nil
        index[current.key] = nil
    }

    /// Takes a slot out of the list, joining its neighbors.
    private func unlink(_ slot: Int, _ current: Slot) {
        if let newer = current.newer { slots[newer]?.older = current.older } else { newest = current.older }
        if let older = current.older { slots[older]?.newer = current.newer } else { oldest = current.newer }
    }
}

extension MentionStyle {
    /// How many texts the canvas keeps built, at least: more while a frame draws more, up to
    /// this many times as many.
    static let memoCapacity = 2048
    static let memoCeilingFactor = 16
}

/// Where each frame of an editor's canvas ends, for the memo: an overlay that draws nothing, run
/// after every shape's render.
struct MentionFrames {}

extension MentionFrames: CanvasOverlay {
    var space: OverlaySpace { .view }
    func draw(in context: OverlayContext) { MentionTextMemo.shared.frameDidEnd(in: context.editor) }
}

#if DEBUG
/// How often the canvas has built mention text and laid out its pills, and how many texts it keeps
/// (debug builds), so tests can hold a frame to what changed.
@MainActor
public enum MentionDrawingCounts {
    public static var stringsBuilt = 0
    public static var layoutsBuilt = 0
    public static var kept: Int { MentionTextMemo.shared.count }
    public static var capacity: Int { MentionTextMemo.shared.capacity }
}
#endif

// MARK: Where string drawing puts pills

/// Where string drawing (`draw(with:options:)`, `.usesLineFragmentOrigin`) puts each pill of a
/// text. An offscreen `NSLayoutManager` with the 10.2 typesetter breaks lines as string drawing
/// does, and puts each glyph where string drawing does across its line, so it says which line each
/// pill is on and how far along. Down the text, it's what string drawing does that counts: every
/// line is at least as tall as a line of the style's text (the 10.2 typesetter makes a line holding
/// only pills, and a line break, as short as a pill, and sets it lower in a fixed line), and a pill
/// sits as far above its line's bottom as it does in a line of text, where the layout manager puts
/// it where string drawing does (an attachment glyph's location is its bottom edge).
@MainActor
enum MentionTextLayout {
    struct Pill: Hashable {
        let target: ShapeID
        /// From the box's top-left, flipped (down is +y), as the canvas is.
        let frame: CGRect
        let isLive: Bool
    }

    /// The pills of `string` shown in a box of `size`: those on lines that fit, less any that the
    /// "…" string drawing ends a cut-short last line with would cover.
    static func pills(of string: NSAttributedString, in size: CGSize, style: MentionTextStyle) -> [Pill] {
        #if DEBUG
        MentionDrawingCounts.layoutsBuilt += 1
        #endif
        // Laid out with stand-ins of the pills' size: a layout manager may give an attachment it lays
        // out a cell of its own, and the drawn pills stay as string drawing had them.
        let laid = NSMutableAttributedString(attributedString: string)
        var found: [(index: Int, pill: MentionAttachment)] = []
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let pill = value as? MentionAttachment else { return }
            laid.addAttribute(.attachment, value: standIn(pill.bounds), range: range)
            for index in range.location..<NSMaxRange(range) { found.append((index, pill)) }
        }
        guard !found.isEmpty else { return [] }
        let (storage, manager) = layOut(laid, width: size.width)
        defer { withExtendedLifetime(storage) {} }
        let lineHeight = lineHeight(of: style)

        // Each line's glyphs, top and height, as string drawing stacks them, while they fit.
        var lines: [(glyphs: NSRange, top: CGFloat, height: CGFloat)] = []
        var top: CGFloat = 0, isCut = false
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, _, _, glyphs, stop in
            let height = max(rect.height, lineHeight)
            guard top + height <= size.height + 0.01 else {
                isCut = true
                stop.pointee = true
                return
            }
            lines.append((glyphs, top, height))
            top += height
        }
        // Text that doesn't fit ends its last shown line in "…", over whatever reaches past the
        // box's width less the "…"'s.
        let ellipsis = ("\u{2026}" as NSString).size(withAttributes: [.font: style.font]).width
        var pills: [Pill] = []
        for (index, pill) in found {
            let glyph = manager.glyphIndexForCharacter(at: index)
            guard let line = lines.firstIndex(where: { NSLocationInRange(glyph, $0.glyphs) }) else { continue }
            let bounds = pill.bounds
            let x = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + manager.location(forGlyphAt: glyph).x
            let bottom = lines[line].top + lines[line].height - gapBelow(bounds, style: style)
            let frame = CGRect(x: x, y: bottom - bounds.height, width: bounds.width, height: bounds.height)
            if isCut, line == lines.count - 1, frame.maxX + ellipsis > size.width { continue }
            pills.append(Pill(target: pill.target, frame: frame, isLive: pill.resolution.isLive))
        }
        return pills
    }

    /// An attachment of a pill's size, with nothing to draw.
    private static func standIn(_ bounds: CGRect) -> NSTextAttachment {
        let standIn = NSTextAttachment()
        standIn.image = NSImage(size: bounds.size)             // a layout manager reads an attachment's size from its image
        standIn.bounds = bounds
        return standIn
    }

    /// `string` laid out `width` wide, every line, by a layout manager with the 10.2 typesetter,
    /// and the storage that holds it (which the manager doesn't keep).
    private static func layOut(_ string: NSAttributedString, width: CGFloat) -> (NSTextStorage, NSLayoutManager) {
        let storage = NSTextStorage(attributedString: string)
        let manager = NSLayoutManager()
        manager.typesetterBehavior = .behavior_10_2_WithCompatibility
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return (storage, manager)
    }

    /// How far above the bottom of a line of the style's text a pill with these bounds is drawn:
    /// laid out once per style and pill height, in a line with a letter, where the layout manager
    /// puts the pill where string drawing does.
    private static func gapBelow(_ bounds: CGRect, style: MentionTextStyle) -> CGFloat {
        let key = PillKey(font: style.font, lineHeight: style.lineHeight, minY: bounds.minY, height: bounds.height)
        if let known = gaps[key] { return known }
        let line = NSMutableAttributedString(string: "X", attributes: style.attributes)
        let pill = NSMutableAttributedString(attachment: standIn(CGRect(x: 0, y: bounds.minY, width: 10, height: bounds.height)))
        pill.addAttributes(style.attributes, range: NSRange(location: 0, length: pill.length))
        line.append(pill)
        let (storage, manager) = layOut(line, width: 1000)
        defer { withExtendedLifetime(storage) {} }
        let fragment = manager.lineFragmentRect(forGlyphAt: 1, effectiveRange: nil)
        let gap = fragment.height - manager.location(forGlyphAt: 1).y
        gaps[key] = gap
        return gap
    }

    private struct PillKey: Hashable {
        let font: NSFont
        let lineHeight: CGFloat?
        let minY: CGFloat
        let height: CGFloat
    }

    private static var gaps: [PillKey: CGFloat] = [:]

    /// How tall string drawing makes a line of the style's text: its fixed height, else its font's
    /// own, measured once per font.
    static func lineHeight(of style: MentionTextStyle) -> CGFloat {
        if let fixed = style.lineHeight { return fixed }
        if let known = naturalHeights[style.font] { return known }
        let height = NSAttributedString(string: "X", attributes: style.attributes)
            .boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin]).height
        naturalHeights[style.font] = height
        return height
    }

    private static var naturalHeights: [NSFont: CGFloat] = [:]
}
