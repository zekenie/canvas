import AppKit
import Canvas
import ContextMenus
import Draw
import LineRows
import Selection
import SlashCommands
import Titles
import Topology
import Transform

// Changing and retiring an API (K16; E5 panels 2 to 4): an endpoint's method changed from its chip's menu, the card's method line,
// Change Method ▸ in the selection's menu or by typing over it, each one step "Change Method"; `/new-version` and New Version, the
// old API marked deprecated (drawn faint) and a copy beside it, its title's and its server's version bumped, its rows under their
// ids, the arrows its rows start copied onto the copy's; and Group by Prefix, the API's endpoints grouped under a header for each
// first path segment two or more of them share, by the kit's one rule (`APIGroups.byPrefix`, which a paste of OpenAPI runs).

extension CanvasCommand {
    /// New Version: the selected APIs each marked deprecated, a copy of each beside it, one step.
    public static let newVersion: CanvasCommand = "newVersion"
    /// Group by Prefix: the selected APIs' endpoints grouped by their first path segment, one step.
    public static let groupByPrefix: CanvasCommand = "groupByPrefix"
}

/// An API's items in a context menu (New Version, Group by Prefix): after what turns a shape into another, as Create Database's are.
public enum APIMenuGroup {}
extension APIMenuGroup: MenuGroup {
    public static var order: Order<Self> { .after(TransformMenuGroup.self) }
}

/// An endpoint's method, changed: the five the frames draw, from its chip's menu, its card or the selection's menu.
@MainActor
enum EndpointMethods {
    /// What the chip's menu lists: GET, POST, PUT, PATCH, DELETE.
    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    /// The methods offered for an endpoint of `current`: the five, and its own after them where it has another (HEAD).
    static func options(current: String) -> [String] {
        current.isEmpty || methods.contains(current) ? methods : methods + [current]
    }

    /// What a click on an endpoint's chip (row `endpoint` of `shape`) does: its method menu, the method it has checked and
    /// highlighted, hung from the chip; VoiceOver calls it "Method, PATCH".
    static func leadAction(_ endpoint: Endpoint, of shape: ShapeID) -> LineLeadAction {
        let row = endpoint.id
        return LineLeadAction(title: APIStyle.methodButton(endpoint.method)) { editor, rect in
            popUp(row, of: shape, below: rect, in: editor)
        }
    }

    /// The method row `row` of `record` has (an API's endpoint, or an endpoint standing alone).
    static func method(of row: PartID, in record: AnyShapeRecord) -> String? {
        if let api = record.typed(as: API.self) { return api.props.endpoints.first { $0.id == row }?.endpoint?.method }
        if let alone = record.typed(as: StandaloneEndpoint.self), alone.props.endpoint.id == row { return alone.props.endpoint.method }
        return nil
    }

    /// Pops the method menu up under `rect` (world units): a chip each, the current checked and highlighted, so Return keeps it; a
    /// pick, "Change Method". A read-only shape takes none, and shakes.
    static func popUp(_ row: PartID, of shape: ShapeID, below rect: CGRect, in editor: CanvasEditor) {
        guard let record = editor.document[shape], let current = method(of: row, in: record) else { return }
        guard !editor.isReadOnly(shape) else {
            editor.refuseChanges(to: [shape])
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        var highlighted: NSMenuItem?
        for method in options(current: current) {
            let item = NSMenuItem(title: method) { [weak editor] in
                guard let editor else { return }
                change([row], of: shape, to: method, in: editor)
            }
            // The chip alone shows (a space for the attributed title that stands in for its words); the title, set after it, is what
            // type-select and VoiceOver read.
            item.image = chipImage(method)
            item.attributedTitle = NSAttributedString(string: " ")
            item.title = method
            item.setAccessibilityLabel(method)
            if method == current {
                item.state = .on
                highlighted = item
            }
            menu.addItem(item)
        }
        editor.popUpMenu(menu, below: rect, highlighting: highlighted ?? menu.items.first)
    }

    /// A method's chip as the rows draw it, for a menu's row.
    static func chipImage(_ method: String) -> NSImage {
        let text = RowText.line(method, .chip)
        let size = CGSize(width: max(APIStyle.chipLeast, text.width + 2 * APIStyle.chipPadding), height: APIStyle.chipHeight)
        let image = NSImage(size: size, flipped: true) { bounds in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            MainActor.assumeIsolated { APIDrawing.drawChip(method, deprecated: false, in: bounds, cg) }
            return true
        }
        image.accessibilityDescription = method
        return image
    }

    /// Rows `rows` of `shape` given `method`, one step, "Change Method" (nothing where each has it already); a read-only shape
    /// refuses it, and shakes. Whether it changed.
    @discardableResult
    static func change(_ rows: [PartID], of shape: ShapeID, to method: String, in editor: CanvasEditor) -> Bool {
        let wanted = Set(rows)
        guard let record = editor.document[shape], rows.contains(where: { self.method(of: $0, in: record).map { $0 != method } ?? false }) else { return false }
        let done: Bool? = editor.transactWhole(APIStyle.changeMethodStep, shaking: [shape]) { transaction in
            guard let fresh = transaction.document[shape] else { throw Transaction.Refused([shape]) }
            if fresh.kind == API.kind {
                transaction.update(shape, as: API.self) { api in
                    for index in api.props.endpoints.indices where wanted.contains(api.props.endpoints[index].id) {
                        api.props.endpoints[index] = APILines.changing(api.props.endpoints[index]) { $0.method = method }
                    }
                }
            } else {
                transaction.update(shape, as: StandaloneEndpoint.self) { $0.props.endpoint.method = method }
            }
            guard transaction.refusedShapes.isEmpty else { throw Transaction.Refused([shape]) }
            return true
        }
        guard done == true else { return false }
        editor.announce(APIStyle.changeMethodStep)
        return true
    }

    /// The endpoint rows a menu for `subject` is about: those selected as items of its one shape, or an endpoint standing alone's.
    static func rows(of subject: MenuSubject) -> (shape: ShapeID, rows: [PartID], methods: [String])? {
        let editor = subject.editor
        guard subject.shapes.count == 1, let shape = subject.shapes.first, let record = editor.document[shape] else { return nil }
        var ids: [PartID] = []
        if let alone = record.typed(as: StandaloneEndpoint.self) {
            ids = [alone.props.endpoint.id]
        } else if record.kind == API.kind, let selection = editor.selectedItems, selection.shape == shape {
            ids = selection.acting.compactMap { $0.base as? PartID }
        }
        let methods = ids.compactMap { method(of: $0, in: record) }
        guard !methods.isEmpty else { return nil }
        return (shape, ids.filter { method(of: $0, in: record) != nil }, methods)
    }
}

/// `/new-version`'s rules for what a copy is called and where it's served.
@MainActor
enum APIVersions {
    /// A title with its trailing version bumped (`orders API v2` for `orders API v1`), else ` v2` added; untitled, `v2`.
    static func bumpedTitle(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return APIStyle.firstNewVersion }
        if let range = title.range(of: #"(^|\s)v(\d+)$"#, options: .regularExpression),
           let digits = title[range].split(separator: "v").last, let number = Int(digits) {
            let start = title[range].first?.isWhitespace == true ? title.index(after: range.lowerBound) : range.lowerBound
            return title[..<start] + "v\(number + 1)"
        }
        return title + " " + APIStyle.firstNewVersion
    }

    /// A server's host with its trailing `/vN` bumped (`api.shop.dev/v2` for `api.shop.dev/v1`); as it is with none.
    static func bumpedHost(_ host: String) -> String {
        guard let range = host.range(of: #"/v(\d+)$"#, options: .regularExpression), let number = Int(host[range].dropFirst(2)) else { return host }
        return host[..<range.lowerBound] + "/v\(number + 1)"
    }

    /// A version with its first number bumped and the numbers after it 0 (`2.0` for `1.4`, `v3` for `v2`); as it is where it starts
    /// with none, or is none.
    static func bumpedVersion(_ version: String) -> String {
        var parts = version.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard var first = parts.first else { return version }
        let lead = first.hasPrefix("v") ? "v" : ""
        guard let number = Int(first.dropFirst(lead.count)) else { return version }
        first = lead + String(number + 1)
        parts[0] = first
        for index in parts.indices.dropFirst() where Int(parts[index]) != nil { parts[index] = "0" }
        return parts.joined(separator: ".")
    }
}

extension CanvasEditor {
    /// New Version of each API of `ids` (`/new-version`, E5 panel 4), one step "New Version": the API marked deprecated (drawn faint;
    /// the arrows into it stay, a storefront still calls it), and a copy put beside it, as Insert puts one, its title's trailing
    /// version bumped (else " v2" added), its server's trailing `/vN` and its version bumped, its rows under their ids, and each arrow
    /// that starts at one of its rows copied onto the copy's row; the copies selected. A read-only API refuses it all, and shakes.
    /// The copies, empty where nothing was made.
    @discardableResult
    public func newVersion(of ids: [ShapeID]) -> [ShapeID] {
        let apis = ids.filter { document[$0]?.kind == API.kind }
        guard !apis.isEmpty else { return [] }
        // Where each copy goes and the arrows it takes, worked out before the step from the board as it is.
        var plans: [(old: ShapeID, copy: AnyShapeRecord, arrows: [AnyShapeRecord])] = []
        var chosen: [CGRect] = []
        for id in apis {
            guard let record = document[id], let api = record.typed(as: API.self), let size = shapeContext.frame(of: record)?.size else { continue }
            let copyID = ShapeID()
            let rows = Set(api.props.endpoints.map(\.id))
            var arrows: [AnyShapeRecord] = [], seen: Set<ShapeID> = [], reached = CGRect.null
            topology?.forEachEdge(of: id, .outgoing, view: .literal) { edge in
                guard edge.isConnection, let part = edge.sourcePart, rows.contains(part), seen.insert(edge.carrier).inserted,
                      let carrier = document[edge.carrier] else { return }
                let moved = carrier.copy(as: ShapeID()).movingParts(in: registry) { $0.shape == id ? PartAddress(copyID, part: $0.part) : $0 }
                guard let moved else { return }
                arrows.append(moved)
                if edge.target != id, let far = shapeContext.geometry(of: edge.target)?.bounds, !far.isNull, !far.isInfinite { reached = reached.union(far) }
            }
            guard let frame = copyFrame(of: id, size: size, avoiding: chosen, toward: reached.isNull ? nil : reached) else { continue }
            chosen.append(frame)
            var next = api
            next.props.deprecated = false
            next.props.server.host = APIVersions.bumpedHost(next.props.server.host)
            next.props.version = APIVersions.bumpedVersion(next.props.version)
            next.props.frame.origin = frame.origin
            var copy = AnyShapeRecord(next).copy(as: copyID)
            copy[TitleProperty.self] = APIVersions.bumpedTitle(record[TitleProperty.self])
            plans.append((id, copy, arrows))
        }
        guard !plans.isEmpty else { return [] }
        let made: [ShapeID]? = transactWhole(APIStyle.newVersionStep, shaking: Set(apis)) { transaction in
            for plan in plans {
                transaction.update(plan.old, as: API.self) { $0.props.deprecated = true }
                transaction.insert(plan.copy)
                for arrow in plan.arrows { transaction.insert(arrow) }
            }
            guard transaction.refusedShapes.isEmpty else { throw Transaction.Refused(Set(apis)) }
            if case .refused(let container) = transaction.settle(plans.map(\.copy.id)) { throw Transaction.Refused([container]) }
            return plans.map(\.copy.id)
        }
        guard let made else { return [] }
        selectedShapeIDs = made
        revealIfOffscreen(made)
        announce(APIStyle.newVersionStep)
        return made
    }

    /// Where the copy of API `id` goes: beside it as Insert puts one, and clear of the frames chosen for the copies before it (they
    /// are not on the board yet, so the board alone would put two on the same spot). With arrows copied onto it (`toward`, the box
    /// around the shapes they reach), on the side of `id` that faces those shapes, or below it, never on its far side from them:
    /// the copy's arrows then run clean, never across the old version's rows (UX walk 3 evolve-1). Insert's spot only with none.
    private func copyFrame(of id: ShapeID, size: CGSize, avoiding chosen: [CGRect], toward reached: CGRect?) -> CGRect? {
        guard chosen.isEmpty, reached == nil else {
            guard let surroundings = Surroundings(on: board, moving: size, in: self), let bounds = surroundings.reading.shapes.geometry(of: id)?.bounds
            else { return insertionFrame(of: size, beside: [id]) }
            let holder = shapeContext.container(of: id), put = PutBeside.inView(of: self, panned: true)
            let sides = reached.map { PlacingStyle.sides(of: bounds, facing: $0) } ?? PlacingStyle.sides
            let landing = chosen.isEmpty
                ? surroundings.near(id, within: holder, put: put, sides: sides)
                : surroundings.near(bounds, avoiding: chosen, within: holder, put: reached == nil ? nil : put, sides: sides)
            return landing?.rect ?? insertionFrame(of: size, beside: [id])
        }
        return insertionFrame(of: size, beside: [id])
    }

    /// Group by Prefix on each API of `ids` (`/group-by-prefix`, Shape ▸ Group by Prefix), one step: its endpoints by their full
    /// paths, in order, under a header for each first path segment two or more of them share (`APIGroups.byPrefix`), a header of
    /// a prefix it had keeping its id; an API it changes nothing in is left as it is, and none changed makes no step. A read-only
    /// API refuses it all, and shakes. Whether anything changed.
    @discardableResult
    public func groupByPrefix(_ ids: [ShapeID]) -> Bool {
        var changes: [(id: ShapeID, rows: [APIRow], gone: Set<PartAddress>)] = []
        for id in ids {
            guard let api = document[id]?.typed(as: API.self) else { continue }
            let grouped = APIGroups.groupedByPrefix(api.props.endpoints)
            guard grouped != api.props.endpoints else { continue }
            let kept = Set(grouped.map(\.id))
            changes.append((id, grouped, Set(api.props.endpoints.filter { !kept.contains($0.id) }.map { PartAddress(id, part: $0.id) })))
        }
        guard !changes.isEmpty else { return false }
        let done: Bool? = transactWhole(APIStyle.groupByPrefixStep, shaking: Set(changes.map(\.id))) { transaction in
            for change in changes {
                transaction.update(change.id, as: API.self) { $0.props.endpoints = change.rows }
            }
            guard transaction.refusedShapes.isEmpty else { throw Transaction.Refused(Set(changes.map(\.id))) }
            transaction.removeParts(changes.reduce(into: Set<PartAddress>()) { $0.formUnion($1.gone) })
            return true
        }
        guard done == true else { return false }
        announce(APIStyle.groupedWords(changes.reduce(0) { $0 + $1.rows.count { $0.header != nil } }))
        return true
    }
}

extension APIGroups {
    /// `rows` grouped by prefix (Group by Prefix): each endpoint by its full path, in order, under the kit's one rule (`byPrefix`),
    /// a header of a prefix `rows` had keeping its id.
    static func groupedByPrefix(_ rows: [APIRow]) -> [APIRow] {
        let endpoints: [Endpoint] = rows.indices.compactMap { index in
            guard var endpoint = rows[index].endpoint else { return nil }
            endpoint.path = fullPath(of: index, in: rows)
            return endpoint
        }
        let held = Dictionary(rows.compactMap(\.header).map { ($0.prefix, $0.id) }) { first, _ in first }
        return byPrefix(endpoints).map { row in
            guard case .header(var header) = row, let id = held[header.prefix] else { return row }
            header.id = id
            return .header(header)
        }
    }
}

extension PluginRegistrar {
    /// New Version and Group by Prefix (commands, in the menu of shapes that hold an API, and typed as `/new-version` and
    /// `/group-by-prefix`), and Change Method ▸ for endpoints selected as rows, or an endpoint standing alone.
    mutating func apiChanges() {
        func holdsAPI(_ subject: CommandSubject) -> Bool {
            subject.shapes.contains { subject.editor.document[$0]?.kind == API.kind }
        }
        command(.newVersion, title: APIStyle.newVersionStep, runs: .whenIdle, isEnabled: holdsAPI) { $0.editor.newVersion(of: $0.shapes) }
        command(.groupByPrefix, title: APIStyle.groupByPrefixStep, runs: .whenIdle, isEnabled: holdsAPI) { $0.editor.groupByPrefix($0.shapes) }
        contextMenuForCanvas {
            MenuItem(command: .newVersion, in: APIMenuGroup.self)
            MenuItem(command: .groupByPrefix, in: APIMenuGroup.self)
            // About the rows selected, beside their take-out (Take Out Endpoint).
            MenuItems(in: RowsMenuGroup.self, id: "change-method") { subject in
                if let held = EndpointMethods.rows(of: subject) {
                    Submenu(APIStyle.changeMethodMenu, in: RowsMenuGroup.self) {
                        for method in EndpointMethods.options(current: held.methods.count == 1 ? held.methods[0] : "") {
                            MenuItem(method, in: RowsMenuGroup.self, id: method, isChecked: { _ in held.methods.allSatisfy { $0 == method } },
                                     stepName: APIStyle.changeMethodStep) { _, editor in
                                EndpointMethods.change(held.rows, of: held.shape, to: method, in: editor)
                            }
                        }
                    }
                }
            }
        }
        func apis(_ target: SlashTarget, _ editor: CanvasEditor) -> [ShapeID] {
            guard case .selection(let ids) = target else { return [] }
            return ids.filter { editor.document[$0]?.kind == API.kind }
        }
        selectionSlashCommand(.atOnce(APIStyle.newVersionCommand, step: APIStyle.newVersionStep,
                                      when: { target, editor in !editor.isBoardReadOnly && !apis(target, editor).isEmpty }) { target, _, editor in
            editor.newVersion(of: apis(target, editor))
        })
        selectionSlashCommand(.atOnce(APIStyle.groupByPrefixCommand, step: APIStyle.groupByPrefixStep,
                                      when: { target, editor in !editor.isBoardReadOnly && !apis(target, editor).isEmpty }) { target, _, editor in
            editor.groupByPrefix(apis(target, editor))
        })
    }
}
