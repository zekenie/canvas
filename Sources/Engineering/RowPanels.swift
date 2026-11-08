import AppKit
import Canvas
import Connections
import DetailPanel
import LineRows
import Neighbors
import Palette
import SwiftUI

// A row of the kit's selected as the panel's subject (E6: "POST /orders/{id}/refunds"): its own tab, what its card holds (an
// endpoint's name, summary, body, responses and connections; a column's type, null, references and on delete), beside Neighbors'
// Connections, whose lists for a row are the kit's lights (Calls It, Writes, Reads; Keys To, Keyed By) and what mentions it. No
// Issues tab: the kit has no checks (decided 23).

/// An endpoint's own tab, when its row is the panel's subject: its card's fields.
public enum EndpointTab {}

extension EndpointTab: DetailTab {
    public static var title: String { KitStyle.endpointTab }
    public static var order: Order<Self> { .first }
}

/// A column's own tab, when its row is the panel's subject: its card's fields.
public enum ColumnTab {}

extension ColumnTab: DetailTab {
    public static var title: String { KitStyle.columnTab }
    public static var order: Order<Self> { .first }
}

extension KitStyle {
    /// The rows' own tabs' titles: what each row is.
    nonisolated public static let endpointTab = "Endpoint"
    nonisolated public static let columnTab = "Column"
}

/// What a row's card holds, a line each: its label and what it says, as the card prints it (`lineRowCard(of:)`), read-only (the card,
/// ⌘↓ in the row, is where it's written). A line that holds nothing says so faintly.
struct RowCardDetails: View {
    let row: DetailRow

    var body: some View {
        if let card = row.editor.lineRowCard(of: row.address) {
            VStack(alignment: .leading, spacing: RowPanelStyle.lineSpacing) {
                ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                    LabeledContent(line.label) {
                        Text(line.value.isEmpty ? RowPanelStyle.empty : line.value)
                            .foregroundStyle(line.value.isEmpty ? .tertiary : .primary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The row tabs' looks.
@MainActor
enum RowPanelStyle {
    static let lineSpacing: CGFloat = 6
    /// What a line that holds nothing says.
    static let empty = "—"
}

extension PluginID {
    public static let engineeringLights: PluginID = "engineering-lights"
}

/// The kit's lights for Neighbors, rows' alone: a selected endpoint's Calls It (what calls it), Writes and Reads (the tables it
/// writes and reads), and a selected column's Keys To and Keyed By, each in its relation's color (a key's, the link's blue), its query
/// written from the channel's edge type id. A row's panel lists them before what mentions it (E6: a row's lights alone come before
/// those that serve both, `NeighborList.order`); hovering asks none of them, and a whole table or API keeps the shipped lights. A plugin
/// value of its own, so a list without Neighbors leaves it out; after the shipped lights in the list, which keep their places.
public struct EngineeringLightsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .engineeringLights }

    public func register(into registrar: inout PluginRegistrar) {
        let calls = Calls.id.rawValue, writes = Writes.id.rawValue, reads = Reads.id.rawValue, key = ForeignKey.id.rawValue
        registrar.neighborLight(KitStyle.callsItTitle, color: NSColor(KitStyle.callsTint), serves: .rows, query: { ":edge-to(\($0), \(calls))" })
        registrar.neighborLight(KitStyle.writesLightTitle, color: NSColor(KitStyle.writesTint), serves: .rows, query: { ":edge-from(\($0), \(writes))" })
        registrar.neighborLight(KitStyle.readsLightTitle, color: NSColor(KitStyle.readsTint), serves: .rows, query: { ":edge-from(\($0), \(reads))" })
        registrar.neighborLight(KitStyle.keysToTitle, color: NSColor(KitStyle.linkBlue), serves: .rows, query: { ":edge-from(\($0), \(key))" })
        registrar.neighborLight(KitStyle.keyedByTitle, color: NSColor(KitStyle.linkBlue), serves: .rows, query: { ":edge-to(\($0), \(key))" })
    }
}

extension KitStyle {
    /// The kit's lights' titles, over their lists in a row's Connections tab.
    nonisolated public static let callsItTitle = "Calls It"
    nonisolated public static let writesLightTitle = "Writes"
    nonisolated public static let readsLightTitle = "Reads"
    nonisolated public static let keysToTitle = "Keys To"
    nonisolated public static let keyedByTitle = "Keyed By"
}
