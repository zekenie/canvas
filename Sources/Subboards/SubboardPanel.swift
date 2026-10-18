import Canvas
import DetailPanel
import Mentions
import SwiftUI
import Titles

/// The subboard's own tab: what it's for. First, before the tabs every shape has.
enum DescriptionTab {}
extension DescriptionTab: DetailTab {
    static var title: String { "Description" }
}

extension ShapeRegistrar where Definition == SubboardDefinition {
    /// The subboard's panel: its header, its title renamed in place ("Untitled Subboard" while it
    /// has none) by its symbol, and its description, mention text in the panel's box (pills, the
    /// `@` picker), in a tab of its own. Each run of typing is one step, "Change Description".
    mutating func subboardPanel() {
        details(header: { $sub in
            TitleHeader($sub, placeholder: Subboard.placeholder, systemImage: Subboard.systemImage)
        }) {
            DetailSection(in: DescriptionTab.self) { $sub in
                MentionTextArea($sub, \.description, height: SubboardStyle.descriptionHeight, placeholder: SubboardStyle.descriptionPlaceholder)
            }
            .named("Description")
        }
    }
}

extension SubboardStyle {
    /// The description's box in the panel, in view points: two of the panel's text areas, since
    /// it's all the tab holds.
    static let descriptionHeight = DetailStyle.textAreaHeight * 2
    static let descriptionPlaceholder = "Add a description"
}
