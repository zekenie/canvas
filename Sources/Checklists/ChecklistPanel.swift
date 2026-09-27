import DetailPanel
import SwiftUI

/// The tab a checklist brings to each kind that opts in: after the kind's own tabs, before Style.
public enum ChecklistTab {}
extension ChecklistTab: DetailTab {
    public static var title: String { "Checklist" }
    public static var order: Int { 50 }
}

/// Items: a checkbox and a text field per row; add, remove, reorder and edit.
struct ChecklistRows: View {
    @Binding var items: [ChecklistItem]

    var body: some View {
        DetailList($items, add: { ChecklistItem() }) { $item in
            HStack {
                Toggle("Done", isOn: $item.isDone).labelsHidden()
                TextField("Item", text: $item.text).textFieldStyle(.plain)
            }
        }
    }
}

/// The Items header: "2 of 5", a menu of the bulk actions, each one transaction on the live list.
struct ChecklistMenu<Props>: View {
    @ShapeBinding var shape: Props
    let items: WritableKeyPath<Props, [ChecklistItem]>

    var body: some View {
        let list = shape[keyPath: items]
        if !list.isEmpty {
            Menu("\(list.doneCount) of \(list.count)") {
                ForEach(ChecklistBulkAction.allCases, id: \.self) { action in
                    if action == .removeChecked { Divider() }
                    Button(action.title) { $shape.update { action.apply(to: &$0[keyPath: items]) } }
                        .disabled(!action.isEnabled(for: list))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// A bar and the percentage done.
struct ChecklistProgress: View {
    let items: [ChecklistItem]

    var body: some View {
        HStack {
            ProgressView(value: items.progress)
            Text(items.progress, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
