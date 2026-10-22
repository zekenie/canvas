import AppKit
import Canvas
import Geometry

// Where the keyboard is, as one value a walk can compare after every key: which surface has it and
// what in it, what VoiceOver reads there, whether it shows, and where. Readers say it for what
// AppKit can't see (the canvas keeps the first responder while the selection, or a part of a shape,
// is what has the keyboard); anything else is read from the first responder and its accessibility,
// so a surface whose accessibility is right needs no reader of its own.

/// Where the keyboard is.
public struct Focus: Hashable, CustomStringConvertible {
    /// What has it: "canvas", "panel", "note", "window".
    public var surface: String
    /// What in the surface: a shape's name, a row's, a control's label. Empty for the surface itself
    /// (the canvas with nothing selected).
    public var element: String
    /// The accessibility role and label of what has the keyboard, and its value (P9).
    public var role: String?
    public var label: String?
    public var value: String?
    /// Whether it is drawn with its mark (P7): a caret, an accent outline, the selection.
    public var isMarked: Bool
    /// Whether keys type into it (a text view that edits), so letters there are its own.
    public var acceptsText: Bool
    /// The part of it that is in view, in window coordinates; nil when nothing says.
    public var frame: CGRect?

    public init(surface: String, element: String, role: String? = nil, label: String? = nil, value: String? = nil,
                isMarked: Bool = false, acceptsText: Bool = false, frame: CGRect? = nil) {
        self.surface = surface
        self.element = element
        self.role = role
        self.label = label
        self.value = value
        self.isMarked = isMarked
        self.acceptsText = acceptsText
        self.frame = frame
    }

    /// The stop's name in a walk: "surface/element", or the surface alone.
    public var id: String { element.isEmpty ? surface : "\(surface)/\(element)" }

    public var description: String { id }

    public static func == (a: Focus, b: Focus) -> Bool {
        a.id == b.id && a.role == b.role && a.label == b.label && a.value == b.value && a.isMarked == b.isMarked
            && a.acceptsText == b.acceptsText && a.frame == b.frame
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// What the window's first responder is (role, label, value, mark, frame), named `surface` and
    /// `element` as a reader names it.
    @MainActor
    public static func of(_ window: NSWindow, surface: String, element: String) -> Focus {
        var focus = AppKitFocusReader(surface: surface).read(window) ?? Focus(surface: surface, element: element)
        focus.surface = surface
        focus.element = element
        return focus
    }
}

/// Says where the keyboard is in a window, for what it knows; nil for anywhere else. A walk asks its
/// readers in order, and the first that answers wins; the AppKit reader answers last.
@MainActor
public protocol FocusReader {
    func read(_ window: NSWindow) -> Focus?
}

/// A reader a rig writes as a closure (`.custom("note") { window in … }`).
public struct CustomFocusReader: FocusReader {
    public let name: String
    let reading: @MainActor (NSWindow) -> Focus?
    public func read(_ window: NSWindow) -> Focus? { reading(window) }
}

extension FocusReader where Self == CustomFocusReader {
    public static func custom(_ name: String, _ read: @escaping @MainActor (NSWindow) -> Focus?) -> CustomFocusReader {
        CustomFocusReader(name: name, reading: read)
    }
}

/// The canvas, while it has the first responder: the keyboard is on the selection (named by
/// `selection`, "A+B" for two), or on a part of it (`part`: "A/chip"), or on the board itself (no
/// element) with nothing selected. Marked while something is selected or a part is focused; `frame`
/// is where that is, in window coordinates (the selection's bounds in view), when the rig says.
public struct CanvasFocusReader: FocusReader {
    public let view: NSView
    let selection: @MainActor () -> [String]
    let part: @MainActor () -> String?
    let frame: (@MainActor () -> CGRect?)?

    public func read(_ window: NSWindow) -> Focus? {
        guard let responder = window.firstResponder as? NSView, responder === view else { return nil }
        let names = selection(), part = part()
        var element = names.joined(separator: "+")
        if let part { element += "/\(part)" }
        // What VoiceOver reads: the element the canvas says is focused (a shape, a part), else the canvas.
        let focused = view.accessibilityFocusedUIElement.flatMap { $0 as? NSAccessibilityProtocol }
        let named: NSAccessibilityProtocol = focused.flatMap { $0 as AnyObject === view ? nil : $0 } ?? view
        let visible = view.convert(view.visibleRect, to: nil)
        return Focus(surface: "canvas", element: element, role: AccessibilityProbe.role(of: named),
                     label: AccessibilityProbe.label(of: named), value: AccessibilityProbe.value(of: named),
                     isMarked: !names.isEmpty || part != nil, acceptsText: false,
                     frame: frame.map { $0()?.intersection(visible) } ?? visible)
    }
}

extension FocusReader where Self == CanvasFocusReader {
    public static func canvas(_ view: NSView, selection: @escaping @MainActor () -> [String], part: @escaping @MainActor () -> String? = { nil },
                              frame: (@MainActor () -> CGRect?)? = nil) -> CanvasFocusReader {
        CanvasFocusReader(view: view, selection: selection, part: part, frame: frame)
    }
}

/// The fallback: the first responder as AppKit and accessibility see it. A field's editor stands
/// for its field. The element is the view's accessibility identifier, else its label, else its
/// class; marked when it shows a caret (an editable text view with the keyboard) or draws a focus
/// ring (`focusRingType` isn't `.none`); its frame is the part of it in view.
public struct AppKitFocusReader: FocusReader {
    public let surface: String

    public init(surface: String = "window") { self.surface = surface }

    public func read(_ window: NSWindow) -> Focus? {
        guard let responder = window.firstResponder else { return nil }
        guard let view = responder as? NSView else {
            // The window itself: what accessibility says is focused, if anything.
            let focused = window.accessibilityFocusedUIElement.flatMap { $0 as? NSAccessibilityProtocol }
            return Focus(surface: surface, element: "", role: focused.flatMap(AccessibilityProbe.role(of:)),
                         label: focused.flatMap(AccessibilityProbe.label(of:)), value: focused.flatMap(AccessibilityProbe.value(of:)))
        }
        let text = view as? NSTextView
        let control: NSView = if let text, text.isFieldEditor, let field = text.delegate as? NSView { field } else { view }
        // What VoiceOver reads for it: the element accessibility says is focused, when that is the
        // control's own (a field's cell, a list's row), else the control.
        let named = AccessibilityProbe.focused(in: window).flatMap { AccessibilityProbe.belongs($0, to: control) ? $0 : nil } ?? control
        let label = AccessibilityProbe.label(of: named)
        let identifier = control.accessibilityIdentifier()
        let element = !identifier.isEmpty ? identifier : label ?? String(describing: type(of: control))
        let caret = text.map { $0.isEditable && $0.window?.firstResponder === $0 } ?? false
        let visible = control.visibleRect
        return Focus(surface: surface, element: element, role: AccessibilityProbe.role(of: named), label: label,
                     value: AccessibilityProbe.value(of: named), isMarked: caret || control.focusRingType != .none,
                     acceptsText: text?.isEditable ?? false, frame: visible.isEmpty ? .zero : control.convert(visible, to: nil))
    }
}

extension FocusReader where Self == AppKitFocusReader {
    public static func appKit(surface: String = "window") -> AppKitFocusReader { AppKitFocusReader(surface: surface) }
}

extension CanvasEditor {
    /// The part of `rect` (world units) the canvas `view` shows clear of what the host puts over it
    /// (`unobscuredViewport`), in window coordinates; empty when none of it is.
    public func shownFrame(ofWorld rect: CGRect, in view: NSView) -> CGRect {
        let shown = camera.toView(rect).intersection(unobscuredViewport)
        return shown.isNull || shown.isEmpty ? .zero : view.convert(shown, to: nil)
    }
}
