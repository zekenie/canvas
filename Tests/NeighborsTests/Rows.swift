import Canvas
import CanvasTesting
import SwiftUI
import TableOfContents

// Apart from Fixtures.swift, which names CanvasTesting's `Link`: SwiftUI has a `Link` of its own.

/// A memo's row in the table of contents: its text, as a note's is, "Memo" while it has none.
func memoRowsPlugin() -> Contributor {
    Contributor(id: "memo-rows") { registrar in
        registrar.contentsRow(Memo.self) { memo in ContentsLabel(memo.props.text, placeholder: "Memo") }
    }
}
