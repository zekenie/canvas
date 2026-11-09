import Adornments
import AppKit
import Canvas
import Selection
import Topology

// What a connection is once it's made: the release of every connection, a port's drag let go on a shape and Connect's (⌘L, its
// picks). Each plugin that owns a meaning a connection may have answers, in plugin order (`ConnectionMade`): nothing, settled (it
// gave the connection what it is, and no one else is asked), or offers. With offers and nothing settled, one list opens at the
// connection: each plugin's offers, a rule between two plugins', a rule, a gray Plain arrow; the first highlighted, so Return takes
// it, under the connection's adornment row (its label's lead), the connection selected while it is open (not one made from a row
// being edited, ⌘L's pick: the shape edited stays selected, and Escape is back on it). A pick is its offerer's
// own step after the release's (Connections' channels: "Change Relation"; Types' relationship types: "Add Type"), so one Undo
// returns to the plain connection and a second removes it. Plain arrow, Escape, a press elsewhere, or a pick gone stale (the
// connection deleted, or given what it is some other way) change nothing.
//
// Connections' own answer is the channels: where the channel a connection was drawn on has a title (`Channel.title`, the kit's
// `writes`) and two or more titled channels fit both its ends, the connection is drawn plain (its channel taken off in the release's
// own step) and they're offered, in the order of the dots it starts from; one titled channel (or an untitled one: a note link) is
// the connection's as it was drawn, and nothing is asked, so a subboard to a subboard never asks.

/// What a plugin says about a connection just made.
public enum ConnectionAnswer {
    /// Nothing: it means nothing to this plugin.
    case nothing
    /// It gave the connection what it is (one relationship type, one titled channel): no one else is asked, and no list opens.
    case settled
    /// What it could be, in this plugin's order: rows of the one list. `drawnPlain` asks that the connection's channel be taken off,
    /// in the release's own step, once the list is known to open (no later plugin settles it), so an Undo of a pick returns to the
    /// plain arrow and a connection some other plugin settled keeps the channel it was drawn on.
    case offers([ConnectionChoice], drawnPlain: Bool = false)
}

/// One row of the list a release opens: the pill a pick would put on the line, and what the pick does.
@MainActor
public struct ConnectionChoice {
    /// What the row is called: its pill's words, what type-select and VoiceOver go by.
    public var title: String
    /// The pill it would put on the line (`writes` in its pink; a relationship type's name in the type's color).
    public var pill: AdornmentLabel
    /// Whether a rule comes before it, inside its plugin's offers (a relationship type's open types after the taken ones).
    public var isSetOff: Bool
    /// What a pick does: its own step. It asks again whether the connection still wants it (a stale pick changes nothing).
    public var pick: @MainActor (CanvasEditor) -> Void

    public init(title: String, pill: AdornmentLabel, isSetOff: Bool = false, pick: @escaping @MainActor (CanvasEditor) -> Void) {
        self.title = title
        self.pill = pill
        self.isSetOff = isSetOff
        self.pick = pick
    }
}

/// The release of every connection: what each plugin that owns a meaning a connection may have answers once it's made, a port's
/// drag let go and Connect's (inside the press's or Connect's step, after the commit that made it). A list; plugin order is the
/// order asked, and the order of their offers in the list. Connections' own answer (its titled channels) is `PortsPlugin`'s.
public enum ConnectionMade {}

extension ConnectionMade: ExtensionPoint {
    public typealias Contribution = @MainActor (ShapeID, CanvasEditor) -> ConnectionAnswer
    public static var owner: PluginID { .ports }
    public static func summary(of _: Contribution, for _: ShapeTarget) -> String { "connection made" }
}

extension PluginRegistrar {
    /// Answers every connection made, once it's committed and inside its step: nothing, settled, or offers for the one list.
    public mutating func connectionMade(_ answer: @escaping @MainActor (ShapeID, CanvasEditor) -> ConnectionAnswer) {
        contribute(answer, to: ConnectionMade.self)
    }
}

/// What a connection's release came to.
public enum ConnectionRelease: Equatable, Sendable {
    /// Nothing answered: the connection is as it was drawn.
    case plain
    /// A plugin settled what it is.
    case settled
    /// The list opened at it.
    case offered
}

extension CanvasEditor {
    /// The release of `connection`, a connection just made (a port's drag let go on a shape, Connect's): every plugin's answer
    /// (`ConnectionMade`), in plugin order, the first that settles ending it; else, with offers, the one list at the connection.
    /// `selecting` false for one made from a row being edited (⌘L's pick, E7 panel 4): the list hangs from the connection, which
    /// isn't selected, so the selection stays on the shape being edited and Escape goes back to it.
    @discardableResult
    public func connectionMade(_ connection: ShapeID, selecting: Bool = true) -> ConnectionRelease {
        var groups: [[ConnectionChoice]] = []
        var plain = false
        for answer in registry.contributions(to: ConnectionMade.self) {
            switch answer.value(connection, self) {
            case .nothing: continue
            case .settled: return .settled
            case .offers(let choices, let drawnPlain):
                if !choices.isEmpty {
                    groups.append(choices)
                    plain = plain || drawnPlain
                }
            }
        }
        guard !groups.isEmpty else { return .plain }
        // The list opens: drawn plain until a pick, in the release's own step.
        if plain { transact(ConnectionsStyle.changeRelation) { $0.update(connection) { $0[ChannelProperty.self] = nil } } }
        presentConnectionChoices(groups, for: connection, selecting: selecting)
        return .offered
    }

    /// The one list at a connection: each group's choices (a plugin's offers), a rule between two groups, a rule, a gray Plain arrow
    /// that changes nothing; the first row highlighted, so Return takes it; under the connection's adornment row (its label's lead,
    /// else the middle of its outline); the connection selected while it is open. Each row is the pill a pick would put on the line,
    /// the row's title its pill's words (type-select and VoiceOver). What a plugin's own list opens
    /// as well (a relationship type's dashed pill).
    /// `below` is where it hangs from, world units, where that isn't the connection's label (a pill clicked). `selecting` false
    /// leaves the selection as it is (a connection made from a row being edited: the shape edited stays the one selected).
    public func presentConnectionChoices(_ groups: [[ConnectionChoice]], for connection: ShapeID, below rect: CGRect? = nil, selecting: Bool = true) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for (at, choice) in group.enumerated() {
                if choice.isSetOff, at > 0 { menu.addItem(.separator()) }
                let item = NSMenuItem(title: choice.title) { [weak self] in
                    guard let self else { return }
                    choice.pick(self)
                }
                item.image = choice.pill.image
                // The pill alone shows (a space for the attributed title that stands in for its words); the title, set after it, stays
                // what type-select and VoiceOver read, and NSMenuItem keeps the attributed one when the title is set.
                item.attributedTitle = NSAttributedString(string: " ")
                item.title = choice.title
                item.setAccessibilityLabel(choice.title)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let plain = NSMenuItem(title: ConnectionsStyle.plainArrow) {}
        plain.attributedTitle = NSAttributedString(string: ConnectionsStyle.plainArrow, attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(plain)
        if selecting { selection = connection }
        let anchor = rect ?? adornmentAnchor(of: connection) ?? shapeContext.geometry(of: connection)?.bounds ?? .zero
        popUpMenu(menu, below: anchor, highlighting: menu.items.first)
    }

    /// Puts `connection` on `channel` (nil: none), one step, "Change Relation": what a pick in a release's list does. Its ends are
    /// asked again as a drag's are, by the port table (a stand-in by what it stands for): the start must start connections on it and
    /// the end take them, each as a row where it's bound to one and as a whole where not; an end that doesn't refuses the change,
    /// and the connection and its ends shake. False with nothing changed (refused, not a connection, or on it already).
    @discardableResult
    public func setChannel(_ channel: ChannelID?, of connection: ShapeID) -> Bool {
        guard let record = document[connection], record.kind == registry.connectorKind, record[ChannelProperty.self] != channel else { return false }
        if let channel {
            guard let ends = registry.connectionEnds(of: record), takes(channel, from: ends.from, part: registry.connectionParts(of: record).from, as: .source),
                  takes(channel, from: ends.to, part: registry.connectionParts(of: record).to, as: .target) else {
                refuseChanges(to: Set([connection] + (registry.connectionEnds(of: record).map { [$0.from, $0.to] } ?? [])))
                return false
            }
        }
        let changed: Bool? = transactWhole(ConnectionsStyle.changeRelation, shaking: [connection]) { transaction in
            transaction.update(connection) { $0[ChannelProperty.self] = channel }
            guard transaction.document[connection]?[ChannelProperty.self] == channel else { throw Transaction.Refused([connection]) }
            return true
        }
        guard changed == true else { return false }
        announce(ConnectionsStyle.changeRelation)
        return true
    }

    /// Whether the shape `id` (a row of it, `part`) may be at a connection's end on `channel` in `role`, by its ports (a stand-in's
    /// by what it stands for): a row on its kind's part ports, a whole shape on its sides'; a stand-in bound with a row (a column
    /// through a pill for its table, an endpoint's own pill) on what it takes either way.
    func takes(_ channel: ChannelID, from id: ShapeID, part: PartID?, as role: PortRole) -> Bool {
        guard let record = document[id], let state = service(PortState.self), let entry = state.ports(of: record)?.entry(on: channel),
              entry.role.allows(role) else { return false }
        if part != nil { return entry.onParts || registry.standIns.kinds.contains(record.kind) }
        return !entry.onParts
    }

    /// The titled channels a connection's ends both take, in the order of the dots it starts from (a row's, else its shape's
    /// sides'), each once.
    func titledChannels(of record: AnyShapeRecord) -> [ChannelID] {
        guard let ends = registry.connectionEnds(of: record), let start = document[ends.from], let state = service(PortState.self),
              let ports = state.ports(of: start) else { return [] }
        let parts = registry.connectionParts(of: record)
        let from = parts.from != nil ? ports.partDots : ports.entries.filter { $0.role != .target && !$0.sides.isEmpty && !$0.onParts }.map(\.channel)
        var seen: Set<ChannelID> = []
        return from.filter { channel in
            registry.channelTitle(channel) != nil && seen.insert(channel).inserted
                && takes(channel, from: ends.from, part: parts.from, as: .source) && takes(channel, from: ends.to, part: parts.to, as: .target)
        }
    }
}

/// Connections' own answer: a connection drawn on a titled channel that two or more titled channels fit is drawn plain and they're
/// offered; one fits, or the channel has no title, and it's as it was drawn (settled for a titled one, so no one else is asked).
@MainActor
enum ChannelRelease {
    static func answer(_ connection: ShapeID, _ editor: CanvasEditor) -> ConnectionAnswer {
        guard let record = editor.document[connection], let channel = record[ChannelProperty.self], editor.registry.channelTitle(channel) != nil else {
            return .nothing
        }
        let fits = editor.titledChannels(of: record)
        guard fits.count >= 2 else { return .settled }
        // Drawn plain until a pick (`drawnPlain`, once the list is known to open): an Undo of the pick returns to the plain arrow,
        // never to a relation nobody chose.
        return .offers(fits.compactMap { fit in
            guard let pill = ChannelPills.label(of: fit, in: editor.registry), let title = editor.registry.channelTitle(fit) else { return nil }
            return ConnectionChoice(title: title, pill: pill) { editor in
                // Stale: gone, or put on a channel some other way since.
                guard let held = editor.document[connection], held[ChannelProperty.self] == nil else { return }
                editor.setChannel(fit, of: connection)
            }
        }, drawnPlain: true)
    }
}

extension ConnectionsStyle {
    /// The gray row that leaves a connection plain: the list's last.
    public static let plainArrow = "Plain arrow"
    /// A pick of a channel in the list.
    public static let changeRelation = "Change Relation"
}
