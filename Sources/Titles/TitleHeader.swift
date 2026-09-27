import DetailPanel
import SwiftUI

/// The detail panel's header for a kind whose shapes are renamed there, so no kind writes its own:
/// the title, as a field in the title's place, over an optional subtitle. It renames the shape as
/// you type (its pill and its row follow), and clearing it leaves the shape untitled. Return, like
/// Escape, gives the keyboard back to the canvas. Put it in the kind's header:
///
///     note.details(header: { $note in TitleHeader($note.title) }) {}
///
/// For a title stored in the props: a `String?`, nil while untitled, or a `String`, blank while
/// untitled. A derived title isn't renamed; such a kind shows it in a `DetailHeader`, if at all.
public struct TitleHeader: View {
    /// The title as the field shows it: empty while untitled.
    public let title: String
    /// Shown, dimmed, while there's no title; nil for what the panel calls the kind ("Note").
    public let placeholder: String?
    public let subtitle: String?
    /// Nil for the kind's symbol.
    public let systemImage: String?
    private let text: Binding<String>

    /// A title that's nil while untitled: clearing the field (or leaving only whitespace) sets nil.
    public init(_ title: Binding<String?>, placeholder: String? = nil, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(Binding(get: { title.wrappedValue ?? "" }, set: { title.wrappedValue = $0.allSatisfy(\.isWhitespace) ? nil : $0 }),
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
        }
    }
}
