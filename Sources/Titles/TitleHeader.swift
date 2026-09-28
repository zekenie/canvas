import Canvas
import DetailPanel
import SwiftUI

/// The detail panel's header for a kind whose shapes are renamed there, so no kind writes its own:
/// the title, as a field in the title's place, over an optional subtitle. It renames the shape as
/// you type (its pill and its row follow), and clearing it leaves the shape untitled. Return, like
/// Escape, gives the keyboard back to the canvas. Put it in the kind's header, given the shape:
///
///     note.details(header: { $note in TitleHeader($note) }) {}
///
/// That renames the title Titles keeps (`x.title()`). A title derived from what the kind keeps is
/// renamed where it comes from, given that binding instead: a `String?`, nil while untitled, or a
/// `String`, blank while untitled (`TitleHeader($card.text)`). One that can't be, such as an
/// ellipse's size, isn't; such a kind shows it in a `DetailHeader`, if at all.
public struct TitleHeader: View {
    /// The title as the field shows it: empty while untitled.
    public let title: String
    /// Shown, dimmed, while there's no title; nil for what the panel calls the kind ("Note").
    public let placeholder: String?
    public let subtitle: String?
    /// Nil for the kind's symbol.
    public let systemImage: String?
    /// False while something else writes the title just now: the field shows it, dimmed, and takes
    /// no typing.
    public let isEnabled: Bool
    /// False while the title can't be written at all (what it's kept in can't take one just now,
    /// or the kind doesn't opt into the title Titles keeps): it shows as text, at full strength, in
    /// the field's place.
    public let isRenamable: Bool
    private let text: Binding<String>

    /// The title Titles keeps for the shape (`TitleProperty`), nil while untitled; Titles keeps no
    /// blank one, so a field of only spaces is untitled too. The kind must opt in with `x.title()`:
    /// on one that doesn't, the shape can't hold a title, so a debug build stops here, and the
    /// title can't be renamed.
    public init<P: ShapeProps>(_ shape: ShapeBinding<P>, placeholder: String? = nil, subtitle: String? = nil, systemImage: String? = nil,
                               isEnabled: Bool = true) {
        assert(shape.holds(TitleProperty.self),
               "TitleHeader($x) renames the title Titles keeps, which \(P.kind) doesn't opt into: call x.title() where it's registered, or give TitleHeader the binding of the title it derives")
        self.init(shape[TitleProperty.self], placeholder: placeholder, subtitle: subtitle, systemImage: systemImage, isEnabled: isEnabled,
                  isRenamable: shape.holds(TitleProperty.self))
    }

    /// A title that's nil while untitled: clearing the field sets nil. Anything else is written as
    /// typed, for the binding to keep (Titles' own keeps no blank title); a title of only spaces
    /// reads as none (`Registry.title(of:)`, the pill, the row).
    public init(_ title: Binding<String?>, placeholder: String? = nil, subtitle: String? = nil, systemImage: String? = nil,
                isEnabled: Bool = true, isRenamable: Bool = true) {
        self.init(Binding(get: { title.wrappedValue ?? "" }, set: { title.wrappedValue = $0.isEmpty ? nil : $0 }),
                  placeholder: placeholder, subtitle: subtitle, systemImage: systemImage, isEnabled: isEnabled, isRenamable: isRenamable)
    }

    /// A title that's blank while untitled.
    public init(_ title: Binding<String>, placeholder: String? = nil, subtitle: String? = nil, systemImage: String? = nil,
                isEnabled: Bool = true, isRenamable: Bool = true) {
        self.title = title.wrappedValue
        self.placeholder = placeholder
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.isRenamable = isRenamable
        text = title
    }

    public var body: some View {
        DetailHeaderLabel(subtitle: subtitle, systemImage: systemImage) {
            DetailHeaderField(text, placeholder: placeholder, isEditable: isRenamable)
                .disabled(!isEnabled)
        }
    }
}
