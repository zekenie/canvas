import AppKit
import Canvas
import DetailPanel
import SwiftUI

/// The task's own tab: what the task is and when it's due.
public enum TaskTab {}
extension TaskTab: DetailTab {
    public static var title: String { "Task" }
}

extension ShapeRegistrar where Definition == TaskCardDefinition {
    /// The task's panel, which is its only editor: the header, the Task tab, and its part of Style.
    /// The Checklist tab comes from opting into Checklists, and Arrange from the panel itself.
    mutating func taskPanel() {
        details(header: { DetailHeader($0.props.isUntitled ? "Untitled Task" : $0.props.title, subtitle: $0.props.summary) }) {
            DetailSection(in: TaskTab.self) { $task in
                LabeledContent("Title") { TextField("Title", text: $task.title) }
                LabeledContent("Status") { StatusPicker(status: $task.status) }
                LabeledContent("Priority") {
                    Picker("Priority", selection: $task.priority) {
                        ForEach(TaskPriority.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            DetailSection("Notes", in: TaskTab.self) { $task in
                DetailTextArea($task.notes)
            }
            DetailSection("Schedule", in: TaskTab.self) { $task in
                // The checkbox switches the due date on, beside the date it governs.
                LabeledContent("Due") {
                    HStack {
                        Toggle("Has due date", isOn: $task.hasDue)
                        if task.hasDue {
                            DatePicker("Due", selection: $task.dueDate, displayedComponents: .date).datePickerStyle(.stepperField)
                        } else {
                            Text("None").foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Estimate") { DetailNumberField(value: $task.estimate, unit: "h", in: 0...999, step: 0.5) }
                LabeledContent("Remaining", value: DetailNumberText.format(task.remaining, unit: "h"))
            }
            DetailSection("Color", in: StyleTab.self) { $task in
                DetailSwatches($task.displayColor, presets: TaskColor.presets.map { ($0.name, $0.color.cgColor) })
            }
            DetailSection("On the Card", in: StyleTab.self) { $task in
                Toggle("Notes", isOn: $task.shows.notes)
                Toggle("Checklist", isOn: $task.shows.checklist)
                Toggle("Progress bar", isOn: $task.shows.progress)
            }
        }
    }
}

/// A pop-up of the statuses, each with a dot in its pill's color.
struct StatusPicker: View {
    @Binding var status: TaskStatus

    var body: some View {
        Picker("Status", selection: $status) {
            ForEach(TaskStatus.allCases) { status in
                Label { Text(status.label) } icon: { Image(nsImage: Self.dot(status)) }.tag(status)
            }
        }
    }

    /// Not a template, so the menu keeps its color. Wider than the dot, for a gap before the title.
    private static func dot(_ status: TaskStatus) -> NSImage {
        let size = TaskStyle.statusDot
        return NSImage(size: CGSize(width: size + TaskStyle.statusDotGap, height: size), flipped: false) { _ in
            TaskStyle.statusColor(status).setFill()
            NSBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).fill()
            return true
        }
    }
}
