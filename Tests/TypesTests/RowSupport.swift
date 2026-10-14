import AppKit
import Canvas
import CanvasTesting
import LanguageModels
import Mentions
import TestKit
import Titles
import Types

// Types knows no kind, and the memo of these tests says nowhere its rows go, so it is given no extent and
// every case that holds a memo sees the memo it saw. A slip is a memo that shows rows: its layout reads
// `TypeRows.extent`, it says where its rows are (`typeRows(drawnIn:)`), and its render draws them.

struct RowSlip: BoxShapeProps {
    static let kind: ShapeKind = "row-slip"
    static let properties = Properties<RowSlip>(title: "Row slip") {
        Property("frame", \.frame).required()
        Property("text", \.text).description("What the slip says.")
    }
    var frame: CGRect
    var text: MentionText
    init(frame: CGRect = CGRect(x: 0, y: 0, width: 240, height: 52), text: MentionText = "") {
        self.frame = frame
        self.text = text
    }
    init() { self.init(text: "") }
}

@MainActor
enum RowSlipStyle {
    static let padding: CGFloat = 16
    static let lineHeight: CGFloat = 19
    static let emptyHeight = (lineHeight + 0.5).rounded(.up) + padding * 2
    static let text = MentionTextStyle(font: .systemFont(ofSize: 16), color: NSColor(white: 0.12, alpha: 1), lineHeight: lineHeight)
    static let fill = NSColor.white

    static func textBox(of frame: CGRect) -> CGRect { frame.insetBy(dx: padding, dy: padding) }

    /// As tall as its words at its width, a line at least.
    static func fit(_ slip: inout RowSlip) {
        let inner = slip.frame.width - padding * 2
        guard inner > 0 else { return }
        let lines = text.measuredString(slip.text, width: inner)
            .boundingRect(with: CGSize(width: inner, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
        slip.frame.size.height = max(emptyHeight, (lines + 0.5).rounded(.up) + padding * 2)
    }
}

extension ShapeRecord where Props == RowSlip {
    @MainActor var placement: MentionTextPlacement { MentionTextPlacement(props.text, in: RowSlipStyle.textBox(of: frame), style: RowSlipStyle.text) }

    /// Where the rows go: under the stored box, at the laid-out width less the padding.
    @MainActor func rowsBlock(in context: ShapeContext) -> CGRect? {
        guard let extent = context.layoutInput(TypeRows.extent, of: self) else { return nil }
        let width = max(frame.width, extent.minimumWidth)
        return CGRect(x: frame.minX + RowSlipStyle.padding, y: frame.maxY, width: width - 2 * RowSlipStyle.padding, height: extent.height)
    }
}

@MainActor
struct RowSlipDefinition: ShapeDefinition, LaidOutBox {
    func render(_ shape: ShapeRecord<RowSlip>, in context: RenderContext) {
        let paper = context.shapes.frame(of: shape)
        context.cg.setFillColor(RowSlipStyle.fill.cgColor)
        context.cg.fill(paper)
        context.fillTypeHighlights(of: shape, in: shape.placement)
        context.drawMentionText(shape.placement)
        if let block = shape.rowsBlock(in: context.shapes) { context.drawTypeRows(of: shape, in: block) }
    }

    /// The wider of the stored width and the rows', the stored height and the rows' under it.
    func laidOutSize(of shape: ShapeRecord<RowSlip>, in context: ShapeContext) -> CGSize {
        guard let extent = context.layoutInput(TypeRows.extent, of: shape) else { return shape.frame.size }
        return CGSize(width: max(shape.frame.width, extent.minimumWidth), height: shape.frame.height + extent.height)
    }
}

struct RowSlipsPlugin: CanvasPlugin {
    var id: PluginID { "row-slips" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(RowSlipDefinition()) { slip in
            slip.title()
            slip.mentionText { [$0.placement] }
            slip.mentionable(untitled: { $0.props.text.firstLine ?? FieldValues.name(of: $0) })
            slip.typeWords(\.text, drawnIn: { $0.placement }, fitting: { RowSlipStyle.fit(&$0) })
            slip.canBeType()
            slip.canBeRelationshipType()
            slip.typeable()
            slip.typeRows(drawnIn: { shape, context in shape.rowsBlock(in: context) })
        }
    }
}

/// `typeEditor` with slips.
@MainActor func rowEditor(scheduler: any Scheduler = ManualScheduler(), model: any LanguageModel = ScriptedLanguageModel(),
                          document: CanvasDocument = CanvasDocument(), file: CanvasFile? = nil, more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    try typeEditor(scheduler: scheduler, model: model, document: document, file: file, more: [RowSlipsPlugin()] + more)
}

/// `rowEditor` with the shared types added as slips, Employee a Person.
@MainActor func rowFieldEditor(scheduler: any Scheduler = ManualScheduler(), model: any LanguageModel = ScriptedLanguageModel(),
                               more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    let editor = try rowEditor(scheduler: scheduler, model: model, more: more)
    editor.addFieldSlips([FieldFixtures.person, FieldFixtures.address, FieldFixtures.employee, FieldFixtures.order])
    editor.addTypeLink(FieldFixtures.personID, to: FieldFixtures.employeeID)
    return editor
}

/// A slip that is a type: `schema`, `words`, titled `title` if given.
@MainActor func slipTypeRecord(_ schema: String, words: String = "", title: String? = nil, at origin: CGPoint = CGPoint(x: 40, y: 40),
                               width: CGFloat = 240, id: ShapeID = ShapeID()) -> AnyShapeRecord {
    var props = RowSlip(frame: CGRect(origin: origin, size: CGSize(width: width, height: RowSlipStyle.emptyHeight)), text: MentionText(plain: words))
    RowSlipStyle.fit(&props)
    var record = ShapeRecord(id: id, props)
    record[TypeSchemaProperty.self] = SchemaText(schema)
    if let title { record[TitleProperty.self] = title }
    return AnyShapeRecord(record)
}

/// A slip that is each of the types, in that order.
@MainActor func slipRecord(_ words: String = "", of types: [ShapeID] = [], at origin: CGPoint = CGPoint(x: 40, y: 400), width: CGFloat = 240,
                           id: ShapeID = ShapeID()) -> AnyShapeRecord {
    var props = RowSlip(frame: CGRect(origin: origin, size: CGSize(width: width, height: RowSlipStyle.emptyHeight)), text: MentionText(plain: words))
    RowSlipStyle.fit(&props)
    var record = ShapeRecord(id: id, props)
    if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
    return AnyShapeRecord(record)
}

extension CanvasEditor {
    /// Adds a slip that is a type.
    @discardableResult
    func addSlipType(_ schema: String, words: String = "", title: String? = nil, at origin: CGPoint = CGPoint(x: 40, y: 40), width: CGFloat = 240,
                     id: ShapeID = ShapeID()) -> ShapeID {
        let record = slipTypeRecord(schema, words: words, title: title, at: origin, width: width, id: id)
        transact { $0.insert(record) }
        return record.id
    }

    /// Adds a slip that is each of the types, in that order (none: a plain slip).
    @discardableResult
    func addSlip(_ words: String = "", of types: [ShapeID] = [], at origin: CGPoint = CGPoint(x: 40, y: 400), width: CGFloat = 240) -> ShapeID {
        let record = slipRecord(words, of: types, at: origin, width: width)
        transact { $0.insert(record) }
        return record.id
    }

    /// Adds the shared types (`FieldFixtures`), a slip each, in a column from the left, in one step.
    @discardableResult
    func addFieldSlips(_ types: [FieldFixtures.TypeText]) -> [ShapeID] {
        let records = types.enumerated().map { place, type in
            slipTypeRecord(type.schema, words: type.words, title: type.title, at: CGPoint(x: 40 + Double(place) * 400, y: 40), id: type.id)
        }
        transact("Add Types") { transaction in records.forEach { transaction.insert($0) } }
        return types.map(\.id)
    }

    /// Ann Lee and Bo Park (`FieldFixtures.annLeeID`, `boParkID`) as slips that are Persons, titled, far below the rest: notes for a test to name. The Person type and Employee are added already (`rowFieldEditor`).
    func addFieldPeople() {
        let records = [(FieldFixtures.annLeeID, "Ann Lee"), (FieldFixtures.boParkID, "Bo Park")].enumerated().map { place, person -> AnyShapeRecord in
            var record = slipRecord("", of: [FieldFixtures.personID], at: CGPoint(x: 40 + Double(place) * 300, y: 2400), id: person.0)
            record[TitleProperty.self] = person.1
            return record
        }
        transact("Add People") { transaction in records.forEach { transaction.insert($0) } }
    }

    /// A shape's laid-out frame.
    func laidOut(_ id: ShapeID) -> CGRect? { shapeContext.frame(of: id) }

    func slipWords(_ id: ShapeID) -> MentionText? { document[id]?.typed(as: RowSlip.self)?.props.text }
}

/// The schema of a type of `count` text fields, `f1…`, as `FieldFixtures.wide` writes it.
func wideSchema(_ count: Int) -> String { FieldFixtures.wide(count).schema }
