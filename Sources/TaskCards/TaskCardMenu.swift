import Canvas
import ContextMenus

extension ShapeRegistrar where Definition == TaskCardDefinition {
    /// The task's own context menu: its status, as the panel's Status picker sets it. The bulk
    /// checklist actions come from opting into Checklists.
    mutating func taskMenu() {
        contextMenu {
            Submenu("Status") {
                for status in TaskStatus.allCases {
                    MenuItem(status.label, isChecked: { $0.status == status }) { $0.status = status }
                }
            }
        }
    }
}
