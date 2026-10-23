import Canvas
import DrawScript

// `group "A" and "B"` and `ungroup "A"`: shapes a script puts in one group, or takes out of every group. Draw knows no meaning
// of a group: what groups shapes is a point (`DrawGroups`, Grouping's), which is handed the shapes a statement names and the
// run's transaction, and writes. What Draw owns is the statement. Each shape it names is found as a shape a statement names that
// the file already has is (by its title, or by its id for one with none; one the script draws is found too, by its title, since
// the statements are applied once every shape and edge the script draws is in the transaction), and must be on the board the run
// draws on (`several_boards` otherwise: a title or an id claims its board, `Drawing.board(for:in:)`). A shape is named once in a
// run, by one group or ungroup: two statements about a shape are `duplicate`, so a run stays declarative. A shape that can't be
// named (an arrow, a reference) is `invalid_value`, as at every place that takes an id. A shape that is read-only and would be
// written is `read_only`, as it is for a change or a delete; a statement that writes nothing goes through, and its row says
// `unchanged`.

/// A group or ungroup statement, resolved.
struct GroupItem {
    let statement: Statement
    /// Whether it is an `ungroup`.
    let ungrouping: Bool
    /// The shapes it names, in the order written: each shape's id, and how a row and a message call it.
    let members: [(id: ShapeID, name: EndName)]
}

extension Drawing {
    /// Reads a `group` or `ungroup`: the shape each name is, or why it is none; refused as a whole without something that groups
    /// shapes (`no_groups`), and where a shape is named twice (`duplicate`).
    mutating func resolve(_ group: GroupStatement, ungrouping: Bool, _ statement: Statement) throws(DrawError) {
        guard registry.drawGrouping != nil else { throw noGroups(statement) }
        let word = (ungrouping ? Keyword.ungroup : Keyword.group).rawValue
        var members: [(id: ShapeID, name: EndName)] = []
        for name in group.shapes {
            // A shape whose own statement couldn't be resolved has its error already: this one only follows from it.
            guard let member = try groupMember(name, statement, for: "\(word) names") else { throw skip() }
            if members.contains(where: { $0.id == member.id }) {
                throw DrawError(statement, .duplicate, "\(member.name.said) is named twice in this statement", hint: "name each shape once")
            }
            if let earlier = groupNamed[member.id] {
                throw DrawError(statement, .duplicate, "\(member.name.said) is named twice, here and on line \(earlier)",
                                hint: "a run says a shape's group once: keep one of the two statements")
            }
            members.append(member)
        }
        for member in members { groupNamed[member.id] = statement.line }
        groupings.append(GroupItem(statement: statement, ungrouping: ungrouping, members: members))
    }

    /// The shape a name stands for in a group or ungroup: one the script draws or restates, or one on the board the run draws on (a
    /// title or an id; an id of a kind a title couldn't name is `invalid_value`); `what` begins the message about one that can't
    /// be (`group names "X", which is on …`). Nil for a shape whose own statement couldn't be resolved.
    private func groupMember(_ name: ShapeName, _ statement: Statement, for what: String) throws(DrawError) -> (id: ShapeID, name: EndName)? {
        switch name {
        case .title(let text):
            let title = try folded(text, statement)
            guard let found = try find(title, statement, for: what), let record = record(of: found) else { return nil }
            return (record.id, EndName(title: title))
        case .path(let text):
            guard let found = try find(path: text, statement, for: what), let record = record(of: found) else { return nil }
            let path = try folded(text, statement)
            return (record.id, EndName(title: path.last, path: path.written))
        case .id(let text):
            let id = try shapeID(text, statement), mark = name.written
            guard let found = try find(id: id, written: mark, statement, for: what), let record = record(of: found) else { return nil }
            // Called by its title where it has one, as an edge's end named by its id is.
            let title = Drawing.title(of: record, names: names, naming: naming, registry: registry)
            return (record.id, EndName(title: title, id: id, idWritten: mark))
        }
    }

    /// The shape a name was found to be: one the script draws or restates (its record as the statement leaves it), or a board's.
    private func record(of found: ShapeItem.Found) -> AnyShapeRecord? {
        switch found {
        case .item(let index): items[index].record
        case .shape(let record): record
        case .board, .view, .origin: nil
        }
    }

    func noGroups(_ statement: Statement) -> DrawError {
        DrawError(statement, .noGroups, "nothing here groups shapes",
                  hint: "leave \(Keyword.group.rawValue) and \(Keyword.ungroup.rawValue) out: this app has no plugin that groups shapes")
    }

    /// Applies the group and ungroup statements, in script order, to the transaction every shape and edge of the run is in: what
    /// groups shapes (`DrawGroups`) writes each through it and says whether it changed anything, and the statement's row says
    /// `grouped` or `ungrouped`, else `unchanged`. A shape that refused the write (read-only, as the transaction holds it) is
    /// `read_only`, and nothing commits.
    func applyGroups(in transaction: inout Transaction) throws(DrawError) -> [DrawChange] {
        guard !groupings.isEmpty, let grouping = registry.drawGrouping else { return [] }
        var rows: [DrawChange] = []
        for item in groupings {
            let ids = item.members.map { $0.id }
            let changed = item.ungrouping ? grouping.ungroup(ids, &transaction) : grouping.group(ids, &transaction)
            let refused = transaction.refusedShapes
            if let blocked = item.members.first(where: { refused.contains($0.id) }) {
                throw DrawError(item.statement, .readOnly,
                                "\(blocked.name.said) is read-only (locked, say), so it can't be \(item.ungrouping ? "ungrouped" : "grouped")",
                                hint: "leave it out of the script, or ask the user to unlock it")
            }
            let did: DrawChange.Did = changed ? (item.ungrouping ? .ungrouped : .grouped) : .unchanged
            rows.append(DrawChange(line: item.statement.line, did: did, shapes: item.members.map { $0.name.plain }))
        }
        return rows
    }
}
