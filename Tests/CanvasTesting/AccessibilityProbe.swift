import AppKit
import TestKit

// What VoiceOver would read, in an unshown window: the focused element, the tree under an element,
// and what was announced. Announcements are the rig's to say (a closure over what its plugins post),
// so CanvasTesting needs no plugin.

/// An accessibility element as VoiceOver reads it.
public struct AccessibilityNode: Equatable, CustomStringConvertible {
    public var role: String?
    public var label: String?
    public var value: String?
    public var isSelected: Bool
    /// In screen coordinates, as accessibility reports frames (an unshown window's are its own).
    public var frame: CGRect
    public var children: [AccessibilityNode]

    /// "AXButton “Done”", with its value after an equals sign and "(selected)".
    public var description: String {
        var line = role ?? "?"
        if let label { line += " “\(label)”" }
        if let value, !value.isEmpty { line += " = \(value)" }
        if isSelected { line += " (selected)" }
        return line
    }

    /// The tree as lines, each child indented two spaces under its parent.
    public var outline: [String] { [description] + children.flatMap { $0.outline.map { "  \($0)" } } }
}

@MainActor
public enum AccessibilityProbe {
    /// The element that has the keyboard: from the first responder up to the first view that is an
    /// accessibility element (a field's editor's field), asking each for the element focused inside
    /// it (`accessibilityFocusedUIElement`, a list's row, a drawn shape); the window's own answer
    /// when nothing has the first responder.
    public static func focused(in window: NSWindow) -> NSAccessibilityProtocol? {
        if let focused = window.accessibilityFocusedUIElement as? NSAccessibilityProtocol, !(focused is NSWindow), isNamedRole(focused) {
            return focused
        }
        var responder = window.firstResponder as? NSView
        if let text = responder as? NSTextView, text.isFieldEditor, let field = text.delegate as? NSView { responder = field }
        while let view = responder {
            if let inner = view.accessibilityFocusedUIElement as? NSAccessibilityProtocol, inner as AnyObject !== view, !(inner is NSWindow),
               isNamedRole(inner), (inner as? NSView).map({ $0.isDescendant(of: view) }) ?? true {
                return inner
            }
            if view.isAccessibilityElement(), isNamedRole(view) { return view }
            responder = view.superview
        }
        return nil
    }

    /// Whether it has a role, other than the unknown one.
    private static func isNamedRole(_ element: NSAccessibilityProtocol) -> Bool {
        element.accessibilityRole().map { $0 != .unknown } ?? false
    }

    /// The element's tree, `depth` levels down.
    public static func tree(of element: NSAccessibilityProtocol, depth: Int = 8) -> AccessibilityNode {
        let children = depth > 0 ? (element.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol } : []
        return AccessibilityNode(role: element.accessibilityRole()?.rawValue, label: label(of: element), value: value(of: element),
                                 isSelected: element.isAccessibilitySelected(), frame: element.accessibilityFrame(),
                                 children: children.map { tree(of: $0, depth: depth - 1) })
    }

    /// The first view under `root` with an accessibility role (`.list`: a caret list's rows).
    public static func first(_ role: NSAccessibility.Role, under root: NSView?) -> NSView? {
        root?.descendants.first { $0.accessibilityRole() == role }
    }

    /// Its role, unless it has none or the unknown one.
    public static func role(of element: NSAccessibilityProtocol) -> String? {
        isNamedRole(element) ? element.accessibilityRole()?.rawValue : nil
    }

    /// Whether `element` is `view`'s own: the view, its cell, or an element under it.
    public static func belongs(_ element: NSAccessibilityProtocol, to view: NSView) -> Bool {
        var current: Any? = element
        for _ in 0..<16 {
            guard let object = current as AnyObject? else { return false }
            if object === view || (object as? NSCell)?.controlView === view { return true }
            if let inner = object as? NSView, inner.isDescendant(of: view) { return true }
            current = (object as? NSAccessibilityProtocol)?.accessibilityParent()
        }
        return false
    }

    /// What VoiceOver reads as its name: its label, else its title, else a field's placeholder.
    public static func label(of element: NSAccessibilityProtocol) -> String? {
        for name in [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityPlaceholderValue(),
                     (element as? NSTextField)?.placeholderString] {
            if let name, !name.isEmpty { return name }
        }
        return nil
    }

    /// Its value as text.
    public static func value(of element: NSAccessibilityProtocol) -> String? {
        switch element.accessibilityValue() {
        case let text as String: text
        case let text as NSAttributedString: text.string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    /// Fails unless the element has a role and a label (P9).
    public static func expectNamed(_ element: NSAccessibilityProtocol?, _ context: @autoclosure () -> String = "",
                                   file: StaticString = #fileID, line: UInt = #line) {
        guard let element else { return expect(false, "nothing is focused for accessibility \(context())", file: file, line: line) }
        expect(isNamedRole(element), "no accessibility role on \(tree(of: element, depth: 0)) \(context())", file: file, line: line)
        expect(label(of: element) != nil, "no accessibility label on \(tree(of: element, depth: 0)) \(context())", file: file, line: line)
    }

    /// Fails unless the focus has a role and a label (P9).
    public static func expectNamed(_ focus: Focus, file: StaticString = #fileID, line: UInt = #line) {
        expect(!(focus.role ?? "").isEmpty, "\(focus.id) has no accessibility role", file: file, line: line)
        expect(!(focus.label ?? "").isEmpty, "\(focus.id) has no accessibility label", file: file, line: line)
    }
}
