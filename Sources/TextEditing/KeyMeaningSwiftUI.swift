import SwiftUI

extension KeyMeaning.Modifiers {
    /// The modifiers a SwiftUI key press (`KeyPress.modifiers`) was struck with, the four that change
    /// what a key means: not Caps Lock, the keypad flag or the function flag, which `EventModifiers`
    /// carries as `NSEvent.ModifierFlags` does.
    public init(_ modifiers: EventModifiers) {
        var result: KeyMeaning.Modifiers = []
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.command) { result.insert(.command) }
        self = result
    }
}
