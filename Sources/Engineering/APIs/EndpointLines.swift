import AppKit
import Canvas
import LineRows

// An endpoint standing alone as LineRows sees it: a shape that is its one row (`goesWithItsRows`). Its row is an item of it (a
// click on it selects it, ⌘X and ⌘C put it on the pasteboard, ⌫ deletes it and the shape with it), its method chip is its lead (a
// click pops the method menu, a drag takes the row into an API, where it lands under its header as a pasted row does), and a cut
// of it pasted on the board is an endpoint again. It isn't edited in place: its kind has no editing view, so its line is never
// typed, and it opens no waiting line.

/// The `endpoint` kind's one row, as LineRows moves it.
struct EndpointLines: LineModel {
    typealias Props = StandaloneEndpoint
    typealias Row = APIRow

    var noun: LineNoun { LineNoun("endpoint") }
    var style: LineStyle { APILooks.line }
    func rows(of props: StandaloneEndpoint) -> [APIRow] { [.endpoint(props.endpoint)] }
    func setRows(_ rows: [APIRow], in props: inout StandaloneEndpoint) {
        // It is its one row: a row put in its place is it (one of another id keeps it), none leaves it as it is (it goes).
        if let endpoint = rows.lazy.compactMap(\.endpoint).first { props.endpoint = endpoint }
    }
    func id(of row: APIRow) -> PartID { row.id }
    func role(of row: APIRow) -> LineRole { APILooks.endpoint }
    func roleOfNewRow(at index: Int, in props: StandaloneEndpoint) -> LineRole { APILooks.endpoint }
    func grammar(for role: LineRole) -> any LineGrammar<APIRow> { APILineGrammar() }
    func lineRect(_ line: Int, in frame: CGRect) -> CGRect { EndpointCard.headerRect(in: frame) }
    func renaming(_ row: APIRow, to id: PartID) -> APIRow { APILines().renaming(row, to: id) }
    func stepName(of change: LineChange<APIRow>) -> String { APILines().stepName(of: change) }
    var goesWithItsRows: Bool { true }

    /// "Endpoint": it is the one ("Endpoint, deprecated" once retired).
    func accessibleLabel(of row: APIRow, at index: Int, among rows: [APIRow]) -> String {
        row.endpoint?.deprecated == true ? "\(noun.title), \(APIStyle.deprecatedState)" : noun.title
    }

    /// Its chip, on its first line, as an API's row's.
    func lead(of row: APIRow, at index: Int, among rows: [APIRow], line: CGRect, in context: LineContext) -> CGRect? {
        guard case .endpoint(let endpoint) = row else { return nil }
        return APIDrawing.chipRect(endpoint.method, member: false, in: line)
    }

    /// Its chip's click: the method menu, as an API's row's.
    func leadAction(of row: APIRow, at index: Int, among rows: [APIRow], in context: LineContext) -> LineLeadAction? {
        guard case .endpoint(let endpoint) = row else { return nil }
        return EndpointMethods.leadAction(endpoint, of: context.shape)
    }
}
