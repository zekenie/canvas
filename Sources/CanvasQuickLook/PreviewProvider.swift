import QuickLookUI
import UniformTypeIdentifiers

/// Quick Look's preview of a board file (space in the Finder, and wherever Quick Look shows a file):
/// its root board, as the app draws it, fitted (`BoardPictures.preview`), as a PNG at the screen's
/// pixels to a point.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let picture = try await MainActor.run { try BoardPictures.preview(of: url) }
        return QLPreviewReply(dataOfContentType: .png, contentSize: picture.size) { _ in try picture.png() }
    }
}
