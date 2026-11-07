import Canvas
import ContextMenus
import CoreGraphics
import SlashCommands
import Titles

// The ways in to tables that aren't a tool: `/table NAME`, a new table named as it's put down; `/database NAME`, a
// database around the selection (around every shape on the board with nothing selected, the command bar's rule; an
// empty one in view on an empty board); and Create Database, in the selection's menu, which `/database` runs too. All of
// them are the kit's, gone from a file with it off.

extension CanvasCommand {
    /// Create Database: a database around the selection, as Create Frame puts a frame round it.
    public static let createDatabase: CanvasCommand = "createDatabase"
}

/// Create Database's group in a context menu.
public enum DatabaseMenuGroup {}
extension DatabaseMenuGroup: MenuGroup {}

extension CanvasEditor {
    /// Puts a database called `name` (nil: untitled) down around these shapes in one step, "Create Database": holding
    /// them where they are, `DatabaseStyle.padding` past them, never under its smallest size, selected (the core's
    /// `place(_:around:)`, as Create Frame's); all or nothing, a locked shape among them leaving it all as it was, and
    /// shaking. Around nothing, an empty one goes down in view, where Insert puts one.
    func createDatabase(named name: String?, around ids: [ShapeID]) {
        guard let placement = registry.placement(for: Database.kind) else { return }
        undoHistory.group(DatabaseStyle.createStep) {
            guard !ids.isEmpty else {
                insert(name.map { placement.setting(TitleProperty.self, to: $0) } ?? placement, named: DatabaseStyle.createStep, beside: [])
                return
            }
            var record = AnyShapeRecord(ShapeRecord(Database()))
            record[TitleProperty.self] = name
            place(record, around: ids, padding: DatabaseStyle.padding, minimumSize: placement.minimumSize)
        }
    }
}

extension PluginRegistrar {
    /// Create Database, the command and its item in the menu of shapes that hold a table or an enum, run on its shapes,
    /// never mid-press or while a shape is edited; `/database NAME`, which runs it named on the command bar's target; and
    /// `/table NAME`, which puts `table` (a new table, not edited) down titled NAME beside the selection, or in view.
    mutating func tableCommands(placing table: Placement) {
        command(.createDatabase, title: DatabaseStyle.createStep, runs: .whenIdle, isEnabled: { subject in
            let document = subject.editor.document
            return subject.shapes.contains { id in document[id].map { [DatabaseTable.kind, DatabaseEnum.kind].contains($0.kind) } ?? false }
        }) { $0.editor.createDatabase(named: nil, around: $0.shapes) }
        contextMenuForCanvas {
            MenuItem(command: .createDatabase, in: DatabaseMenuGroup.self)
        }
        selectionSlashCommand(.atOnce(KitCommands.database, argument: KitCommands.name, step: DatabaseStyle.createStep, when: { _, editor in !editor.isBoardReadOnly }) { target, arguments, editor in
            editor.createDatabase(named: KitCommands.name(in: arguments), around: KitCommands.around(target, in: editor))
        })
        selectionSlashCommand(.atOnce(KitCommands.table, argument: KitCommands.name, step: TableStyle.addStep, when: { _, editor in !editor.isBoardReadOnly }) { target, arguments, editor in
            let beside: [ShapeID] = if case .selection(let ids) = target { ids } else { [] }
            let named = KitCommands.name(in: arguments).map { table.setting(TitleProperty.self, to: $0) } ?? table
            editor.insert(named, named: TableStyle.addStep, beside: beside)
        })
    }
}

/// The kit's commands typed in the command bar.
@MainActor
enum KitCommands {
    static let table = "table"
    static let database = "database"
    /// The hint beside them in the list: what they take.
    static let name = "name"

    /// The name typed: its text, trimmed; nil for none.
    static func name(in arguments: SlashArguments) -> String? {
        TitleProperty.folded(arguments.text)
    }

    /// The shapes `/database` goes around: those selected; with nothing selected, every shape on the board that's in no
    /// container (what a frame holds goes in with it); none on an empty board.
    static func around(_ target: SlashTarget, in editor: CanvasEditor) -> [ShapeID] {
        switch target {
        case .selection(let ids): ids
        case .everything(let ids): ids.filter { editor.document[$0]?.container == nil }
        case .text: []
        }
    }
}
