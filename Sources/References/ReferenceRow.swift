import Canvas
import Mentions
import SwiftUI
import TableOfContents

extension ShapeRegistrar where Definition == ReferenceDefinition {
    /// The reference's row in the table of contents: what it stands for, called as its pill calls it,
    /// under the symbol of its kind, in its tint. A reference that stands for nothing (the shape is
    /// deleted, not available or not public, or its words aren't interpreted) shows what it holds as a
    /// dimmed placeholder; one that finds every match, its count. A change to the shape it names remakes
    /// its row (`affected`: the references that name what a commit changed), and an answer arriving
    /// remakes a dynamic one's (`contentsDidChange(for:)`, from `ReferenceState`).
    mutating func referenceRow() {
        contentsRow(affected: { changes, context in context.service(ReferenceState.self)?.rowsAffected(by: changes) ?? [] }) { shape, context in
            switch context.service(ReferenceState.self)?.state(of: shape.props, id: shape.id) ?? .empty {
            case .empty:
                ContentsLabel("", placeholder: ReferenceStyle.placeholder, systemImage: ReferenceStyle.systemImage)
            case .live(let appearance):
                ContentsLabel(appearance.label, systemImage: appearance.systemImage, color: appearance.tint.map { Color(nsColor: $0) })
            case .missing(let label), .unavailable(let label):
                ContentsLabel("", placeholder: label, systemImage: ReferenceStyle.missingSymbol)
            case .notPublic(let appearance):
                ContentsLabel("", placeholder: appearance.label, systemImage: appearance.systemImage)
            case .notInterpreted(let text), .noMatches(let text), .refused(let text, _), .failed(let text, _), .cannotFind(let text):
                ContentsLabel("", placeholder: text, systemImage: ReferenceStyle.dynamicSymbol)
            case .finding(let text), .interpreting(let text):
                ContentsLabel(text, systemImage: ReferenceStyle.dynamicSymbol)
            case .found(let text, let found):
                ContentsLabel(text, systemImage: ReferenceStyle.dynamicSymbol, badge: found.all ? ReferenceStyle.badge(found.count) : nil)
            }
        }
    }
}
