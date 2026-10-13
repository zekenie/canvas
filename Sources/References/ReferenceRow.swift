import Boards
import Canvas
import Mentions
import SwiftUI
import TableOfContents

extension ShapeRegistrar where Definition == ReferenceDefinition {
    /// The reference's row in the table of contents: what it stands for, called as its pill calls it,
    /// under the symbol of its kind, in its tint, with the list's stand-in arrow cut into the symbol
    /// (`standsIn`), so it reads as a pointer to the shape and not the shape; one whose shape went
    /// private keeps the symbol and the arrow. A reference that stands for nothing (the shape is
    /// deleted, not available or not public, or its words aren't interpreted) shows what it holds as a
    /// dimmed placeholder; one that finds every match, its count. A reference to a shape that's there
    /// (public or not) says where it is before its name, "Alpha › Beta › Checkout": the frames and
    /// boards the shape is inside and the reference isn't (`ReferenceState.rowPath(of:to:)`), so rows
    /// for shapes from the same place read alike. A change to the shape it names, or to a shape its
    /// path was read from, remakes its row (`affected`: `rowsAffected(by:)`), and an answer arriving
    /// remakes a dynamic one's (`contentsDidChange(for:)`, from `ReferenceState`).
    mutating func referenceRow() {
        contentsRow(affected: { changes, context in context.service(ReferenceState.self)?.rowsAffected(by: changes) ?? [] }) { shape, context in
            let state = context.service(ReferenceState.self)
            /// Where the shape it stands for is, from where it is.
            var path: [ContentsPathName] {
                (shape.props.target.flatMap { state?.rowPath(of: shape.id, to: $0.id) } ?? [])
                    .map { ContentsPathName($0.text, isPlaceholder: $0.isPlaceholder) }
            }
            return switch state?.state(of: shape.props, id: shape.id) ?? .empty {
            case .empty:
                ContentsLabel("", placeholder: ReferenceStyle.placeholder, systemImage: ReferenceStyle.systemImage)
            case .live(let appearance):
                ContentsLabel(appearance.label, systemImage: appearance.systemImage, color: appearance.tint.map { Color(nsColor: $0) },
                              standsIn: true, path: path)
            case .missing(let label), .unavailable(let label):
                ContentsLabel("", placeholder: label, systemImage: ReferenceStyle.missingSymbol)
            case .notPublic(let appearance):
                ContentsLabel("", placeholder: appearance.label, systemImage: appearance.systemImage, standsIn: true, path: path)
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
