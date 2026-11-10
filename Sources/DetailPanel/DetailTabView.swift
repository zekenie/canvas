import Canvas
import SwiftUI

/// One tab of a shape's panel, as the panel draws it: the tab's status lines as a headerless block,
/// then its sections, each under its own header, in the panel's metrics and with its collapse state.
/// For a plugin that shows a tab beside something of its own (a band's list over the current stop's
/// Issues tab: Validation) without learning what is in it. No scroll view and no header: the caller
/// places it, in a `ScrollView` if it is tall. Empty where the shape has neither lines nor sections in
/// the tab, or is gone.
///
/// Draws again as the shape's panel does, for its record, whether it can change, the tab's lines and
/// its shown sections, and for a fold; the commit itself is read here, then skipped.
public struct DetailTabView: View {
    let editor: CanvasEditor
    let shape: ShapeID
    let tab: DetailTabID

    public init(editor: CanvasEditor, shape: ShapeID, tab: DetailTabID) {
        self.editor = editor
        self.shape = shape
        self.tab = tab
    }

    public init<Tab: DetailTab>(editor: CanvasEditor, shape: ShapeID, tab: Tab.Type) {
        self.init(editor: editor, shape: shape, tab: .of(tab))
    }

    public var body: some View {
        if let state = editor.detailPanel, let record = editor.document[shape] {
            // Read on every commit, as the shape's panel's root does, so the content below draws again only
            // when they, or the record, change.
            let statuses = state.statuses(of: record)
            let layout = state.layout(for: record, statuses: statuses.tabs, hidden: state.hiddenSections(of: record))
            TabContent(state: state, editor: editor, record: record, isReadOnly: editor.isReadOnly(shape),
                       lines: layout.statuses(in: tab), sections: layout.resolved(in: tab))
                .equatable()
                .environment(\.detailEditor, editor)
        }
    }
}

/// A tab's lines and sections: skipped unless the record, whether it can change, the lines or the
/// sections shown change. A fold is read here, so it draws again by itself.
struct TabContent: View, Equatable {
    let state: DetailPanelState
    let editor: CanvasEditor
    let record: AnyShapeRecord
    let isReadOnly: Bool
    /// What the stand-in shows, whose sections bind that shape (`ResolvedSection.onShown`).
    var through: ShownThrough?
    let lines: [DetailStatus]
    let sections: [ResolvedSection]

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated {
            a.record == b.record && a.isReadOnly == b.isReadOnly && a.through == b.through && a.lines == b.lines
                && a.sections.map(\.id) == b.sections.map(\.id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The tab's status lines lead, as a headerless block.
            if !lines.isEmpty {
                StatusList(statuses: lines, spacing: DetailStyle.rowSpacing)
                    .padding(.horizontal, DetailStyle.inset)
                    .padding(.top, DetailStyle.sectionTop)
                    .padding(.bottom, DetailStyle.sectionBottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !sections.isEmpty { Divider() }
            }
            ForEach(sections, id: \.id) { resolved in
                let onShown = resolved.onShown ? through : nil
                SectionView(resolved: resolved, editor: editor, record: onShown?.record ?? record,
                            isReadOnly: isReadOnly || onShown?.isReadOnly == true,
                            isCollapsed: state.isCollapsed(resolved.key),
                            toggle: { state.setCollapsed(resolved.key, !state.isCollapsed(resolved.key)) })
                    .equatable()
                if resolved.id != sections.last?.id { Divider() }
            }
        }
    }
}
