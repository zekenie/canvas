import AppKit
import Canvas
import Checklists
import DetailPanel

/// On the main actor as a whole, so its drawing helpers share the protocol's isolation.
@MainActor
struct TaskCardDefinition {}

/// A white card with a color strip down its left edge. From the top: the title and a status pill,
/// the priority and schedule line, the first lines of the notes, the checklist rows that fit, and a
/// progress bar at the foot. A card sized small still draws cleanly: one too narrow for the title
/// beside the pill drops the pill, the lines under the title draw only where they fit above the
/// bar, and everything is clipped to the card. A done card is dimmed as a whole.
extension TaskCardDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<TaskCard>, in context: RenderContext) {
        let task = shape.props, frame = shape.frame, cg = context.cg, card = TaskStyle.path(frame)
        if task.status == .done {
            cg.setAlpha(TaskStyle.doneAlpha)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        context.fillWithShadow(card, TaskStyle.card)
        cg.saveGState()
        cg.addPath(card)
        cg.clip()
        cg.setFillColor(task.color.cgColor)
        cg.fill(CGRect(x: frame.minX, y: frame.minY, width: TaskStyle.stripWidth, height: frame.height))
        drawContent(task, in: TaskStyle.content(of: frame), cg: cg)
        cg.restoreGState()
        if task.status == .done { cg.endTransparencyLayer() }
    }

    func indicatorPath(of shape: ShapeRecord<TaskCard>, in context: ShapeContext) -> CGPath {
        TaskStyle.path(shape.frame)
    }

    private func drawContent(_ task: TaskCard, in inner: CGRect, cg: CGContext) {
        let pill = pill(task.status, topRight: CGPoint(x: inner.maxX, y: inner.minY))
        // The title beside the pill; on a card too narrow for both, the title alone.
        var titleWidth = pill.frame.minX - TaskStyle.spacing - inner.minX
        if titleWidth >= pill.frame.width {
            drawPill(pill, color: TaskStyle.statusColor(task.status), cg: cg)
        } else {
            titleWidth = inner.width
        }
        // The bar keeps the foot; the rest fits above it, the title with at least a line.
        var bottom = inner.maxY
        if task.shows.progress, !task.checklist.isEmpty {
            bottom -= TaskStyle.barHeight
            drawBar(task, in: CGRect(x: inner.minX, y: bottom, width: inner.width, height: TaskStyle.barHeight), cg: cg)
            bottom -= TaskStyle.spacing
        }
        func lines(_ most: Int, _ lineHeight: CGFloat, from y: CGFloat) -> Int { min(most, Int(max(0, bottom - y) / lineHeight)) }
        var y = inner.minY
        y += draw(title(task), at: CGPoint(x: inner.minX, y: y), width: titleWidth,
                  lines: max(1, lines(TaskStyle.titleLines, TaskStyle.titleLineHeight, from: y)), lineHeight: TaskStyle.titleLineHeight)
        y += TaskStyle.spacing
        y += draw(meta(task), at: CGPoint(x: inner.minX, y: y), width: inner.width,
                  lines: lines(1, TaskStyle.lineHeight, from: y), lineHeight: TaskStyle.lineHeight)
        if task.shows.notes, !task.notes.allSatisfy(\.isWhitespace) {
            y += TaskStyle.spacing
            y += draw(NSAttributedString(string: task.notes, attributes: TaskStyle.secondary), at: CGPoint(x: inner.minX, y: y),
                      width: inner.width, lines: lines(TaskStyle.noteLines, TaskStyle.lineHeight, from: y), lineHeight: TaskStyle.lineHeight)
        }
        if task.shows.checklist, !task.checklist.isEmpty {
            y += TaskStyle.spacing
            // Never a negative height: a CGRect's would read as positive, and draw rows over the title.
            drawChecklist(task.checklist, in: CGRect(x: inner.minX, y: y, width: inner.width, height: max(0, bottom - y)))
        }
    }

    /// The status in capitals, and where its pill goes: ending at `topRight`, centered on the
    /// title's first line.
    private func pill(_ status: TaskStatus, topRight: CGPoint) -> (text: NSAttributedString, frame: CGRect) {
        let text = NSAttributedString(string: status.label.uppercased(), attributes: TaskStyle.pillText)
        let width = (text.size().width + TaskStyle.pillPadding * 2).rounded(.up), height = TaskStyle.pillHeight
        return (text, CGRect(x: topRight.x - width, y: topRight.y + ((TaskStyle.titleLineHeight - height) / 2).rounded(),
                             width: width, height: height))
    }

    private func drawPill(_ pill: (text: NSAttributedString, frame: CGRect), color: NSColor, cg: CGContext) {
        cg.addPath(TaskStyle.rounded(pill.frame, radius: pill.frame.height / 2))
        cg.setFillColor(color.cgColor)
        cg.fillPath()
        pill.text.draw(at: CGPoint(x: pill.frame.minX + TaskStyle.pillPadding, y: pill.frame.midY - pill.text.size().height / 2))
    }

    /// The title, struck through when done; "Untitled Task" in gray when there's none.
    private func title(_ task: TaskCard) -> NSAttributedString {
        guard !task.isUntitled else { return NSAttributedString(string: "Untitled Task", attributes: TaskStyle.placeholderTitle) }
        var attributes = TaskStyle.title
        if task.status == .done { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: task.title, attributes: attributes)
    }

    /// "!! · Due Sep 30 · 4 h": the priority marks in their color, then the due date and estimate if set.
    private func meta(_ task: TaskCard) -> NSAttributedString {
        var marks = TaskStyle.marks
        marks[.foregroundColor] = TaskStyle.priorityColor(task.priority)
        let line = NSMutableAttributedString(string: task.priority.marks, attributes: marks)
        var rest: [String] = []
        if let due = task.due { rest.append("Due \(TaskCard.format(due))") }
        if task.estimate > 0 { rest.append(DetailNumberText.format(task.estimate, unit: "h")) }
        for part in rest { line.append(NSAttributedString(string: " · \(part)", attributes: TaskStyle.secondary)) }
        return line
    }

    /// A row per item, as many as fit; if some don't, the last row that fits says how many more.
    private func drawChecklist(_ items: [ChecklistItem], in rect: CGRect) {
        let fit = max(0, Int(rect.height / TaskStyle.rowHeight))
        let shown = items.count <= fit ? items[...] : items.prefix(max(0, fit - 1))
        var rows = shown.map { item in
            let attributes = item.isDone ? TaskStyle.secondary : TaskStyle.body
            // Only a done item's text is struck through, not its box.
            let row = NSMutableAttributedString(string: "\(item.isDone ? "☑" : "☐") ", attributes: attributes)
            var text = attributes
            if item.isDone { text[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            row.append(NSAttributedString(string: item.text, attributes: text))
            return row as NSAttributedString
        }
        if shown.count < items.count, fit > 0 {
            rows.append(NSAttributedString(string: "+\(items.count - shown.count) more", attributes: TaskStyle.secondary))
        }
        for (i, row) in rows.enumerated() {
            draw(row, at: CGPoint(x: rect.minX, y: rect.minY + CGFloat(i) * TaskStyle.rowHeight), width: rect.width,
                 lines: 1, lineHeight: TaskStyle.lineHeight)
        }
    }

    /// A track, filled in the card's color by the share of the checklist that's done.
    private func drawBar(_ task: TaskCard, in rect: CGRect, cg: CGContext) {
        cg.addPath(TaskStyle.rounded(rect, radius: rect.height / 2))
        cg.setFillColor(TaskStyle.track.cgColor)
        cg.fillPath()
        let done = CGRect(x: rect.minX, y: rect.minY, width: rect.width * task.checklist.progress, height: rect.height)
        cg.addPath(TaskStyle.rounded(done, radius: rect.height / 2))
        cg.setFillColor(task.color.cgColor)
        cg.fillPath()
    }

    /// Up to `lines` lines of `text` from `origin`, `width` wide, the last truncated; returns the
    /// height it took.
    @discardableResult
    private func draw(_ text: NSAttributedString, at origin: CGPoint, width: CGFloat, lines: Int, lineHeight: CGFloat) -> CGFloat {
        guard width > 0, lines > 0 else { return 0 }
        let needed = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height
        let height = min(needed.rounded(.up), lineHeight * CGFloat(lines))
        text.draw(with: CGRect(x: origin.x, y: origin.y, width: width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return height
    }
}

/// The card's look. World units.
@MainActor
enum TaskStyle {
    static let size = TaskCard.defaultSize
    static let cornerRadius: CGFloat = 8
    static let stripWidth: CGFloat = 5
    static let padding: CGFloat = 12
    static let spacing: CGFloat = 6
    static let pillHeight: CGFloat = 14
    static let pillPadding: CGFloat = 6
    /// The status menu's dots, in view points.
    static let statusDot: CGFloat = 8
    static let statusDotGap: CGFloat = 4
    static let barHeight: CGFloat = 4
    static let titleLines = 2
    static let noteLines = 2
    static let doneAlpha: CGFloat = 0.55

    static let card = NSColor.white
    static let text = NSColor(white: 0.12, alpha: 1)
    static let secondaryText = NSColor(white: 0.45, alpha: 1)
    static let track = NSColor(white: 0.90, alpha: 1)

    static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 11)
    static let titleLineHeight = lineHeight(of: titleFont)
    static let lineHeight = lineHeight(of: bodyFont)
    static let rowHeight = lineHeight + 3

    static let title: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: text]
    static let placeholderTitle: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: secondaryText]
    static let body: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: text]
    static let secondary: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: secondaryText]
    static let marks: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .heavy)]
    static let pillText: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white, .kern: 0.4,
    ]

    /// The status pill's color, also the status menu's dots.
    static func statusColor(_ status: TaskStatus) -> NSColor {
        switch status {
        case .todo: NSColor(white: 0.55, alpha: 1)
        case .doing: NSColor(srgbRed: 0.20, green: 0.48, blue: 0.96, alpha: 1)
        case .blocked: NSColor(srgbRed: 0.90, green: 0.25, blue: 0.24, alpha: 1)
        case .done: NSColor(srgbRed: 0.20, green: 0.66, blue: 0.35, alpha: 1)
        }
    }

    static func priorityColor(_ priority: TaskPriority) -> NSColor {
        switch priority {
        case .low: secondaryText
        case .medium: NSColor(srgbRed: 0.95, green: 0.55, blue: 0.10, alpha: 1)
        case .high: NSColor(srgbRed: 0.90, green: 0.25, blue: 0.24, alpha: 1)
        }
    }

    /// A line's height as the card lays text out. (NSLayoutManager's default line height is a
    /// point short for 11 pt system text, and a box two of those tall holds just one line.)
    static func lineHeight(of font: NSFont) -> CGFloat {
        NSAttributedString(string: "X", attributes: [.font: font])
            .boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin)
            .height.rounded(.up)
    }

    static func path(_ frame: CGRect) -> CGPath { rounded(frame, radius: cornerRadius) }

    static func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Inside the strip and the padding.
    static func content(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + stripWidth + padding, y: frame.minY + padding,
               width: frame.width - stripWidth - padding * 2, height: frame.height - padding * 2)
    }
}
