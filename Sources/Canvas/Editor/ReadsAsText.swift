import AppKit

/// An attachment in an editing text that reads as text: the name a mention's pill shows, say. The
/// text selected in an editing view (`editor.editingSelectedText`) has each such attachment as what
/// it reads as, and drops any that doesn't adopt this, so a selection across a pill is searched for
/// by the pill's name, not by the one object-replacement character the pill is in the string. The
/// core knows no attachment: whatever puts one in a text view adopts this.
@MainActor
public protocol ReadsAsText: NSTextAttachment {
    /// What the attachment reads as, as plain text.
    var readsAs: String { get }
}

extension NSAttributedString {
    /// The plain text of `range`, each attachment that adopts `ReadsAsText` as what it reads as and
    /// every other attachment dropped.
    @MainActor
    public func readingAttachments(in range: NSRange) -> String {
        var text = ""
        enumerateAttributes(in: range, options: []) { attributes, run, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                guard let readable = attachment as? ReadsAsText else { return }
                text += String(repeating: readable.readsAs, count: run.length)
            } else {
                text += (string as NSString).substring(with: run)
            }
        }
        return text
    }
}
