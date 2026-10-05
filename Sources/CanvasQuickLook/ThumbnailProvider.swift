import Foundation
import QuickLookThumbnailing

/// Quick Look's thumbnail of a board file (its icon in the Finder, and wherever files show as
/// pictures): its root board, fitted (`BoardPictures.thumbnail`).
final class ThumbnailProvider: QLThumbnailProvider {
    /// Quick Look asks off the main thread, which the picture is drawn on: it waits for it there.
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void) {
        let url = request.fileURL, limit = request.maximumSize, minimum = request.minimumSize, scale = request.scale
        let made = onMain { Result { try BoardPictures.thumbnail(of: url, fitting: limit, atLeast: minimum, scale: scale) } }
        switch made {
        case .success(let picture):
            handler(QLThumbnailReply(contextSize: picture.size) { context in
                picture.draw(in: context)
                return true
            }, nil)
        case .failure(let error):
            handler(nil, error)
        }
    }
}

/// What `body` returns, run on the main thread, waiting for it there (or at once, on it).
private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated(body) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}
