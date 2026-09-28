import Canvas
import SwiftUI

/// Where you are in a file's boards, as data-canvas shows it: a small pill of crumbs, root first,
/// the board shown last, for over the top middle of the canvas (the host places it there, with
/// `.overlay(alignment: .top)`; it keeps `BoardsStyle.topInset` from the edge itself). Nothing on
/// the root. The board shown is bold and not a button; each board above is, and shows that board
/// with the shape you came through selected (`editor.goUp(to:)`). More than four fold the middle
/// into "…", a menu of the boards it hides. It reads only the crumbs (`BoardCrumbs`), so it redraws
/// when another board is shown or a board above changes, never for a commit on the board shown.
public struct BoardPath: View {
    let editor: CanvasEditor
    let rootName: String

    /// `rootName` names the root's crumb: the file's name, say.
    public init(editor: CanvasEditor, rootName: String) {
        self.editor = editor
        self.rootName = rootName
    }

    public var body: some View {
        if let crumbs = editor.boardCrumbs {
            BoardPathPill(crumbs: crumbs, editor: editor, rootName: rootName)
        }
    }
}

struct BoardPathPill: View {
    let crumbs: BoardCrumbs
    let editor: CanvasEditor
    let rootName: String

    var body: some View {
        #if DEBUG
        let _ = (crumbs.pathRedrawn += 1)
        #endif
        if !crumbs.crumbs.isEmpty {
            let layout = crumbs.layout(rootName: rootName.isEmpty ? BoardsStyle.rootFallback : rootName)
            HStack(spacing: BoardsStyle.spacing) {
                ForEach(layout.leading) { crumb in
                    if crumb.id != layout.leading.first?.id { separator }
                    item(crumb, isCurrent: layout.trailing.isEmpty && crumb.id == layout.leading.last?.id)
                }
                if !layout.folded.isEmpty {
                    separator
                    Menu {
                        ForEach(layout.folded) { crumb in
                            Button(crumb.title) { editor.goUp(to: crumb.board) }
                        }
                    } label: {
                        Text("…")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Boards between")
                }
                ForEach(layout.trailing) { crumb in
                    separator
                    item(crumb, isCurrent: crumb.id == layout.trailing.last?.id)
                }
            }
            .font(.system(size: BoardsStyle.fontSize, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, BoardsStyle.horizontalPadding)
            .padding(.vertical, BoardsStyle.verticalPadding)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .frame(maxWidth: BoardsStyle.maxWidth)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, BoardsStyle.topInset)
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func item(_ crumb: BoardCrumb, isCurrent: Bool) -> some View {
        if isCurrent {
            CrumbWidth(maxWidth: BoardsStyle.crumbMaxWidth) {
                Text(crumb.title).fontWeight(.semibold).truncationMode(.middle)
            }
            .accessibilityAddTraits(.isHeader)
        } else {
            CrumbWidth(maxWidth: BoardsStyle.crumbMaxWidth) {
                // Its own text, one line cut in the middle: a button's title would wrap.
                Button { editor.goUp(to: crumb.board) } label: {
                    Text(crumb.title).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(crumb.title)
            }
        }
    }
}

/// A crumb as wide as its title, but no wider than `maxWidth` (nor than it's offered): a longer
/// title is truncated. (A frame's `maxWidth` would widen a short one.)
struct CrumbWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let crumb = subviews.first else { return .zero }
        return crumb.sizeThatFits(capped(proposal, crumb))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let crumb = subviews.first else { return }
        crumb.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }

    private func capped(_ proposal: ProposedViewSize, _ crumb: LayoutSubview) -> ProposedViewSize {
        let ideal = crumb.sizeThatFits(.unspecified).width
        let width = min(ideal, maxWidth, proposal.width ?? .infinity)
        return ProposedViewSize(width: width, height: proposal.height)
    }
}
