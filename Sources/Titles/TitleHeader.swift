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
    private let text: Binding<String>
    /// False for a shape whose kind doesn't opt into the title Titles keeps: it can't be renamed.
    private var isRenamable = true

    /// The title Titles keeps for the shape (`TitleProperty`), nil while untitled; Titles keeps no
    /// blank one, so a field of only spaces is untitled too. The kind must opt in with `x.title()`:
    /// on one that doesn't, the shape can't hold a title, so a debug build stops here, and the
    /// field is disabled.
    public init<P: ShapeProps>(_ shape: ShapeBinding<P>, placeholder: String? = nil, subtitle: String? = nil, systemImage: String? = nil) {
        assert(shape.holds(TitleProperty.self),
               "TitleHeader($x) renames the title Titles keeps, which \(P.kind) doesn't opt into: call x.title() where it's registered, or give TitleHeader the binding of the title it derives")
        self.init(shape[TitleProperty.self], placeholder: placeholder, subtitle: subtitle, systemImage: systemImage)
        isRenamable = shape.holds(TitleProperty.self)
    }

    /// A title that's nil while untitled: clearing the field sets nil. Anything else is written as
    /// typed, for the binding to keep (Titles' own keeps no blank title); a title of only spaces
    /// reads as none (`Registry.title(of:)`, the pill, the row).
    public init(_ title: Binding<String?>, placeholder: String? = nil, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(Binding(get: { title.wrappedValue ?? "" }, set: { title.wrappedValue = $0.isEmpty ? nil : $0 }),
                  placeholder: placeholder, subtitle: subtitle, systemImage: systemImage)
    }

    /// A title that's blank while untitled.
    public init(_ title: Binding<String>, placeholder: String? = nil, subtitle: String? = nil, systemImage: String? = nil) {
        self.title = title.wrappedValue
        self.placeholder = placeholder
        self.subtitle = subtitle
        self.systemImage = systemImage
        text = title
    }

    public var body: some View {
        DetailHeaderLabel(subtitle: subtitle, systemImage: systemImage) {
            DetailHeaderField(text, placeholder: placeholder)
                .disabled(!isRenamable)
        }
    }
}
