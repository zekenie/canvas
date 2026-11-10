import AppKit
import CoreGraphics
import Geometry

// What VoiceOver hears of the board, said as the core says anything about shapes: plugins describe
// the shapes of the kinds they reach (`ShapeAccessibility`), one plugin may say the order they're
// walked in and the parts drawn on each (`accessibleOrder`, `accessibleParts`), and the selection is
// the focus. The core knows no kind and no key, and no NSAccessibility: the host (CanvasUI's
// `ShapeElement`s) turns this into elements, and asks for it only when an assistive app asks it.

/// What one plugin says of a shape for VoiceOver (`scope.accessibility { record, editor in … }`). Each
/// field is optional; `editor.accessibleDescription(of:)` joins every plugin's, in plugin order.
public struct AccessibleTraits: Sendable, Equatable {
    /// What the shape is called (its title): said first, before what it is. The first plugin's that
    /// says one.
    public var name: String?
    /// What it is besides its kind ("Person", a type): said after the kind, every plugin's.
    public var labelParts: [String]
    /// What it holds (a note's words). The first plugin's that says one.
    public var value: String?
    /// What it is now ("locked", "1 error"): said last, every plugin's.
    public var states: [String]
    /// What can be done with it, said after a pause. The first plugin's that says one.
    public var help: String?
    /// What it is said to be in its kind's label's place ("Mirror", for a reference shown as one): the first plugin's that
    /// says one; nil, its kind's label.
    public var kind: String?

    public init(name: String? = nil, kind: String? = nil, labelParts: [String] = [], value: String? = nil, states: [String] = [],
                help: String? = nil) {
        self.name = name
        self.kind = kind
        self.labelParts = labelParts
        self.value = value
        self.states = states
        self.help = help
    }
}

/// A shape as VoiceOver says it: "Checkout, Note, Person, locked", its value and its help.
public struct AccessibleDescription: Sendable, Equatable {
    /// What it's called: its title, else what its kind is called.
    public var name: String
    /// What its kind is called (`registry.label(of:)`).
    public var kind: String
    /// Its name, its kind, what else it is and its states, joined with ", ": what VoiceOver reads first.
    public var label: String
    public var value: String?
    public var help: String?
}

/// How soon VoiceOver says an announcement (`editor.announce`): a low one waits for what it's saying,
/// a high one cuts in.
public enum AnnouncementPriority: Sendable {
    case low, medium, high
}

/// A part drawn on a shape as VoiceOver sees it (`registrar.accessibleParts`): a chip, a pill, a
/// button, a handle, an arrow of it.
public struct AccessiblePart {
    /// Stable from frame to frame (the part's own key).
    public var id: AnyHashable
    /// What VoiceOver calls it: "Locked", "Go to Original", "Arrow to Payment".
    public var title: String
    public var role: Role
    /// Where it is, in world units.
    public var rect: CGRect
    /// What pressing it does, as its click does.
    public var press: @MainActor (CanvasEditor) -> Void

    /// What kind of control it is, as the host gives it a role.
    public enum Role: Sendable {
        case button, menuButton, link, checkbox, handle, connection
    }

    public init(id: AnyHashable, title: String, role: Role, rect: CGRect, press: @escaping @MainActor (CanvasEditor) -> Void) {
        self.id = id
        self.title = title
        self.role = role
        self.rect = rect
        self.press = press
    }
}

/// The part of a shape that has the keyboard (`editor.accessibleFocusedPart`).
public struct AccessiblePartFocus: Hashable {
    public var shape: ShapeID
    public var part: AnyHashable

    public init(shape: ShapeID, part: AnyHashable) {
        self.shape = shape
        self.part = part
    }
}

/// `registrar.accessibleParts`: a shape's parts, and the one focused.
struct AccessiblePartsClaim {
    let parts: @MainActor (CanvasEditor, ShapeID) -> [AccessiblePart]
    let focused: @MainActor (CanvasEditor) -> AccessiblePartFocus?
}

extension ScopedRegistrar {
    /// What VoiceOver says of the shapes the scope reaches, as one plugin says it: their title, what
    /// else they are, what they hold, their states (`AccessibleTraits`). Asked only when an assistive
    /// app asks for a shape, never per frame; nil says nothing.
    ///
    ///     registrar.forShapes(adopting: .titled) { titled in
    ///         titled.accessibility { record, editor in AccessibleTraits(name: editor.registry.title(of: record)) }
    ///     }
    public mutating func accessibility(_ describe: @escaping @MainActor (AnyShapeRecord, CanvasEditor) -> AccessibleTraits?) {
        contribute(describe, to: CorePoints.ShapeAccessibility.self)
    }
}

extension ShapeRegistrar {
    /// What VoiceOver says of this kind's shapes, as this plugin says it (see the scoped one).
    public mutating func accessibility(_ describe: @escaping @MainActor (ShapeRecord<Definition.Props>, CanvasEditor) -> AccessibleTraits?) {
        contribute({ record, editor in record.typed(as: Definition.Props.self).flatMap { describe($0, editor) } },
                   to: CorePoints.ShapeAccessibility.self)
    }
}

extension PluginRegistrar {
    /// The order VoiceOver walks the board shown in: the Tab stops where the selection is, in reading
    /// order (Selection's). At most one plugin may claim it; otherwise paint order, the selection first.
    public mutating func accessibleOrder(_ order: @escaping @MainActor (CanvasEditor) -> [ShapeID]) {
        contribute(order, to: CorePoints.AccessibleOrder.self)
    }

    /// The parts drawn on a shape, for VoiceOver (each pressable), and the part that has the keyboard,
    /// nil for none. At most one plugin may claim it; otherwise a shape has none. The plugin says when
    /// the focused part changes (`editor.accessibilityFocusDidChange()`).
    public mutating func accessibleParts(_ parts: @escaping @MainActor (CanvasEditor, ShapeID) -> [AccessiblePart],
                                         focused: @escaping @MainActor (CanvasEditor) -> AccessiblePartFocus?) {
        contribute(AccessiblePartsClaim(parts: parts, focused: focused), to: CorePoints.AccessibleParts.self)
    }
}

extension CanvasEditor {
    /// What VoiceOver says of a shape on the board shown, or elsewhere in the file (`shape(inFile:)`);
    /// nil for one that isn't there.
    public func accessibleDescription(of id: ShapeID) -> AccessibleDescription? {
        shape(inFile: id).map(accessibleDescription(of:))
    }

    /// What VoiceOver says of a shape: every plugin's traits that reach its kind joined (the first
    /// name, value and help; every label part and state), after its kind's label (or what the first
    /// plugin says it is in that place: "Mirror"): "Checkout, Note, Person, locked". A shape kept aside
    /// is its kind alone. Worked out each time it's asked.
    public func accessibleDescription(of record: AnyShapeRecord) -> AccessibleDescription {
        var kind = registry.label(of: record.kind).name, kindSaid = false
        var name: String?, value: String?, help: String?
        var parts: [String] = [], states: [String] = []
        if !record.isOpaque {
            for describe in registry.contributions(to: CorePoints.ShapeAccessibility.self, for: record.kind) {
                guard let traits = describe(record, self) else { continue }
                if name == nil, let said = Self.said(traits.name) { name = said }
                if !kindSaid, let said = Self.said(traits.kind) {
                    kind = said
                    kindSaid = true
                }
                if value == nil, let said = Self.said(traits.value) { value = said }
                if help == nil, let said = Self.said(traits.help) { help = said }
                parts += traits.labelParts.compactMap(Self.said)
                states += traits.states.compactMap(Self.said)
            }
        }
        let label = ((name.map { [$0] } ?? []) + [kind] + parts + states).joined(separator: ", ")
        return AccessibleDescription(name: name ?? kind, kind: kind, label: label, value: value, help: help)
    }

    /// Text with something to say, trimmed; nil for none.
    private static func said(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// What VoiceOver calls the board shown: the root's name (`rootName`), else the name of the shape
    /// that owns it (`accessibleDescription(of:)`); nil for a root the host hasn't named.
    public var accessibleBoardName: String? {
        guard let owner = board.owner else { return rootName.isEmpty ? nil : rootName }
        return accessibleDescription(of: owner)?.name
    }

    /// The selection, as VoiceOver's focus: what commands act on (`registrar.commandShapes`), on the
    /// board shown.
    public var accessibleSelection: [ShapeID] {
        commandSubject.shapes.filter { document[$0] != nil }
    }

    /// Selects shapes for an assistive app (VoiceOver's press on a shape), through the plugin that keeps
    /// the selection (`registrar.commandShapes(_:select:)`). False when none says how.
    @_spi(Host) @discardableResult
    public func selectForAccessibility(_ ids: [ShapeID]) -> Bool {
        guard let select = registry.commandTable.select else { return false }
        select(self, ids)
        return true
    }

    /// The shapes VoiceOver sees on the board shown, at most `limit`: the order a plugin claims
    /// (`accessibleOrder`: the Tab stops where the selection is), then the shapes in view in paint order,
    /// then the selection; with no claim, the selection, then the shapes in view. Past `limit`, those
    /// nearest the selection (else the middle of the view) are kept, the selection first, in that order.
    public func accessibleShapes(limit: Int) -> [ShapeID] {
        let selection = accessibleSelection
        let context = shapeContext
        let view = camera.toWorld(CGRect(origin: .zero, size: viewportSize))
        // The shapes in view, as `paintOrder(in:)` finds them, with the middles of their kept extents,
        // which ranking them by distance reads rather than each one's geometry.
        var inView: [ShapeID] = [], middles: [ShapeID: CGPoint] = [:]
        if viewportSize.width > 0, viewportSize.height > 0 {
            forEachShape(in: view) { record, extent in
                inView.append(record.id)
                middles[record.id] = CGPoint(x: extent.midX, y: extent.midY)
            }
        }
        var seen = Set<ShapeID>(), list: [ShapeID] = []
        let document = document
        func add(_ id: ShapeID) {
            if document[id] != nil, seen.insert(id).inserted { list.append(id) }
        }
        if let order = registry.contributions(to: CorePoints.AccessibleOrder.self).first?.value {
            order(self).forEach(add)
            inView.forEach(add)
            selection.forEach(add)
        } else {
            selection.forEach(add)
            inView.forEach(add)
        }
        guard list.count > limit else { return list }
        func middle(_ id: ShapeID) -> CGPoint? {
            middles[id] ?? context.bounds(of: CollectionOfOne(id)).map { CGPoint(x: $0.midX, y: $0.midY) }
        }
        // Near any selected shape, for a few; for many (⌘A), near the middle of them; for none, of the view.
        let anchors: [CGPoint] = selection.count <= Style.accessibleNearestSelected ? selection.compactMap(middle)
            : context.bounds(of: selection).map { [CGPoint(x: $0.midX, y: $0.midY)] } ?? []
        let from = anchors.isEmpty ? [CGPoint(x: view.midX, y: view.midY)] : anchors
        let selected = Set(selection)
        var ranked: [(id: ShapeID, distance: CGFloat)] = []
        ranked.reserveCapacity(list.count)
        for id in list where !selected.contains(id) {
            var nearest = CGFloat.greatestFiniteMagnitude
            if let point = middle(id) {
                for anchor in from { nearest = min(nearest, hypot(point.x - anchor.x, point.y - anchor.y)) }
            }
            ranked.append((id, nearest))
        }
        ranked.sort { $0.distance < $1.distance }
        // The focused shape (the last selected) first, then the rest of the selection, then the nearest.
        var kept = Set<ShapeID>()
        for id in selection.reversed() where kept.count < limit { kept.insert(id) }
        for entry in ranked where kept.count < limit { kept.insert(entry.id) }
        return list.filter(kept.contains)
    }

    /// The parts drawn on a shape, as VoiceOver sees them (`registrar.accessibleParts`); none without
    /// a claim.
    public func accessibleParts(of id: ShapeID) -> [AccessiblePart] {
        registry.contributions(to: CorePoints.AccessibleParts.self).first?.value.parts(self, id) ?? []
    }

    /// The part of a shape that has the keyboard, as the plugin that claims parts says; nil for none.
    public var accessibleFocusedPart: AccessiblePartFocus? {
        registry.contributions(to: CorePoints.AccessibleParts.self).first?.value.focused(self)
    }

    /// The accessibility focus moved: the selection changed (Selection says, as it changes), or the part
    /// of a shape that has the keyboard. The host tells an assistive app, if one is listening.
    public func accessibilityFocusDidChange() {
        delegate?.editorAccessibilityFocusDidChange(self)
    }

    /// Says `text` to whoever uses VoiceOver ("Zoom 50%", "Locked"), as soon as `priority` says. Kept in
    /// `announcements` in debug builds.
    public func announce(_ text: String, priority: AnnouncementPriority = .medium) {
        #if DEBUG
        announcements.append(text)
        #endif
        delegate?.editorAnnounce(self, text, priority: priority)
    }
}
