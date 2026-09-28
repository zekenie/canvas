import AppKit
import Canvas
import DetailPanel
import SwiftUI

/// What mentions a shape, in its panel: a tab of the shape's state that comes and goes, as Issues
/// does, shown only while another shape, on any board of the file, mentions it. A kind that opts
/// into being mentioned (`x.mentionable`, `registrar.mentionable(K.self)`) brings it;
/// `mentionableEveryShape` brings none, since the panel has no section for every shape's record.
public enum MentionsTab {}

extension MentionsTab: DetailTab {
    public static var title: String { MentionStyle.mentionedIn }
    public static var order: Int { 300 }
}

extension MentionsTab {
    /// The tab's one section, over any kind: shown while the shape is mentioned (its own edges, on
    /// every commit), its lines working on a read-only shape too, since going to what mentions it
    /// changes nothing of it.
    @MainActor
    static func section<Props>() -> DetailSection<Props> {
        DetailSection(in: MentionsTab.self, id: "mentioned-in") { shape in
            MentionedInList(target: shape.shapeID, mentions: shape.service(MentionState.self))
        }
        .shownWhile { shape, context in context.service(MentionState.self)?.isMentioned(shape.id) == true }
        .enabledWhileReadOnly()
    }
}

/// A line per shape that mentions the target, on any board, those on the board shown first, in
/// document order: its symbol, its name and its text around the mention
/// (`MentionState.backlinks(of:)`). It observes the target's backlinks alone
/// (`backlinkRevision`), so it redraws when what mentions the shape, or what those quote, changes,
/// though the shape itself doesn't (its section is built again only when its shape changes), and a
/// drag redraws nothing.
struct MentionedInList: View {
    let target: ShapeID
    let mentions: MentionState?

    var body: some View {
        if let mentions {
            let _ = mentions.backlinkRevision(of: target)
            let lines = mentions.backlinks(of: target)
            #if DEBUG
            let _ = (mentions.backlinksShown[target] = lines)
            #endif
            ForEach(lines, id: \.id) { line in
                MentionedInLine(line: line, mentions: mentions)
            }
        }
    }
}

/// One mentioner: the pointer on it hovers it on the canvas, if it's on the board shown, and a
/// click goes to it (shows its board, if it's on another, selects it, and brings it into view; ⌘[
/// comes back).
struct MentionedInLine: View {
    let line: MentionBacklink
    let mentions: MentionState

    var body: some View {
        let id = line.id
        Button { mentions.goToMentioner(id) } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(line.label).lineLimit(1)
                    if !line.quote.isEmpty {
                        Text(line.quote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } icon: {
                Image(systemName: line.systemImage).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .onHover { inside in
            if inside { mentions.hover(id) } else { mentions.endHover(id) }
        }
        .onDisappear { mentions.endHover(id) }
    }
}
