import Canvas
import CanvasTesting
import DetailPanel
import SwiftUI

/// A tab every card has, so a card's panel has a tab to leave when the walk chooses Issues.
enum CardTab {}
extension CardTab: DetailTab { static var title: String { "Card" } }

func cardTab() -> Contributor {
    Contributor(id: "walk-tab") { r in
        r.detailsForEveryBox { DetailSection(in: CardTab.self) { _ in Text("Card") } }
    }
}
