import Foundation
import SkillTesting
import TestKit

// The history skill's condenser (.claude/skills/history/condense.py), run on a session's transcript the test writes into a home
// folder of its own, so it reads none of this machine's sessions: the owner's words kept whole whatever the app sent with them, and
// what the app or another session put in a turn said for what it is.

@MainActor let historyTests = Suite("history: a session's record keeps the owner's words whole and says what the app or another session sent for what it is", [
    test("the owner's words sent with a doc open, beside a reminder and mid-turn, without what the app sent with them") {
        let mention = "why does the <artifact-view-context> block go? it ends at </artifact-view-context>, and <system-reminder> too"
        let record = try condensed([
            turn("2026-11-06T10:00:01Z", docView + "\n\nsorry we don't land pieces of this we land the whole thing"),
            turn("2026-11-06T10:00:02Z", [["type": "text", "text": "<system-reminder>\nThe session \"Other\" you started finished a turn.\n</system-reminder>\n\n"],
                                          ["type": "text", "text": "Fix it here"]]),
            midTurn("2026-11-06T10:00:03Z", docView + "\n<system-reminder>\nA note for the model.\n</system-reminder>\n\nand keep the tests"),
            turn("2026-11-06T10:00:04Z", docView),
            turn("2026-11-06T10:00:05Z", "keep this\n\n<system-reminder>\nA note after the words.\n</system-reminder>"),
            turn("2026-11-06T10:00:06Z", mention + " </system-reminder> here"),
        ])
        expect(record.contains("] USER:\nsorry we don't land pieces of this we land the whole thing\n"), record)
        expect(record.contains("] USER:\nFix it here\n"), record)
        expect(record.contains("] USER (sent mid-turn):\nand keep the tests\n"), record)
        expect(record.contains("] USER:\nkeep this\n"), "a reminder after the words: \(record)")
        expect(record.contains("] USER:\n\(mention) </system-reminder> here\n"), "the tags named in a sentence stay: \(record)")
        expectEqual(record.components(separatedBy: "] USER").count - 1, 5, "a doc's view with no words is no message: \(record)")
        for sent in ["\"context\"", "live state", "artifact-content-authored-by-others", "A note for the model", "A note after the words", "finished a turn"] {
            expect(!record.contains(sent), "the app's \(sent) left out: \(record)")
        }
    },
    test("a notice, another session's message, a page's comment and a program's prompt under their own labels; commands and a paste whole") {
        let compact = String(repeating: "Keep the plan and the decisions. ", count: 60).trimmingCharacters(in: .whitespaces)
        let record = try condensed([
            turn("2026-11-06T10:00:08Z", "Background (from the session that started this one): build the fix.", origin: "sdk"),
            turn("2026-11-06T10:00:09Z", "<command-name>/compact</command-name>\n<command-message>compact</command-message>\n<command-args>\(compact)</command-args>"),
            turn("2026-11-06T10:00:01Z", "<system-reminder>\nThe session \"Other\" you started finished a turn.\n</system-reminder>\n\n<side-sessions-event>None of the sessions you started is working now; their notes are above.</side-sessions-event>"),
            turn("2026-11-06T10:00:02Z", "<cross-session-message from=\"local_1\" name=\"Other work\">\nThe owner asks: say it plainly.\n</cross-session-message>"),
            turn("2026-11-06T10:00:03Z", pageComment),
            midTurn("2026-11-06T10:00:04Z", pageComment.replacingOccurrences(of: "make it shorter", with: "and sooner")),
            turn("2026-11-06T10:00:05Z", "<command-message>code-review</command-message>\n<command-name>/code-review</command-name>\n<command-args>high</command-args>"),
            turn("2026-11-06T10:00:06Z", "here it is\n\n<pasted_content id=\"a1\">\nthe pasted words\n</pasted_content>"),
            turn("2026-11-06T10:00:07Z", "<local-command-stdout>Set model to `claude-sonnet-5-5`</local-command-stdout>"),
        ])
        expect(record.contains("] NOTICE:\nno session this one started is working now\n"), record)
        expect(record.contains("] MESSAGE FROM SESSION \"Other work\":\nThe owner asks: say it plainly.\n"), record)
        expect(record.contains("] COMMENT on https://claude.ai/code/artifact/abc:\n＠Claude make it shorter\n\nand plainer\n"), "the comment alone, unquoted: \(record)")
        expect(record.contains("] COMMENT on https://claude.ai/code/artifact/abc:\n＠Claude and sooner\n\nand plainer\n"), "a comment sent mid-turn too: \(record)")
        expect(record.contains("] USER:\n/code-review high\n"), "a command its message comes before: \(record)")
        expect(record.contains("] USER:\nhere it is\n\n<pasted_content id=\"a1\">\nthe pasted words\n</pasted_content>\n"), "a paste is the owner's: \(record)")
        expect(record.contains("] PROMPT FROM A PROGRAM:\nBackground (from the session that started this one): build the fix.\n"), "a turn the SDK sent: \(record)")
        expect(record.contains("] USER:\n/compact \(compact)\n"), "a command's arguments whole, \(compact.count) characters: \(record)")
        expectEqual(record.components(separatedBy: "] USER").count - 1, 3, "nothing else as the owner's: \(record)")
        for sent in ["side-sessions-event", "cross-session-message", "Answer this comment", "comment-anchor-context", "Comment thread", "Set model"] {
            expect(!record.contains(sent), "the app's \(sent) left out: \(record)")
        }
    },
])

/// What the app puts before the owner's words while a doc is open beside the chat: the page's view, for the model.
private let docView = """
    <artifact-view-context artifact="641a18ed-ef9b-48a6-b6e6-2e85cd449420">
    {"context":{"mode":"edit","tab":"69511d04-e8ec","selected":["mmg16sy3nk7.18"],"dirty":false,"node":"7bdc3a17-3963","rev":43}}
    (The JSON line above is this viewer's live state in the artifact, as published by the artifact page's own code running in their browser — not typed by the user.)
    <artifact-content-authored-by-others/>
    </artifact-view-context>
    """

/// A comment sent to the session from a page's thread, as the app words it.
private let pageComment = """
    [Artifact comment sent to Claude]
    Artifact: https://claude.ai/code/artifact/abc
    Comment thread: 3f5e
    Sent to Claude at: 2026-11-06T10:00:03Z

    I sent you this comment from the artifact's comment thread. It is quoted below with ">" on every line, between BEGIN and END lines that carry the same token.

    === BEGIN ARTIFACT COMMENT f1d64ed7e6bd2c03 ===
    > ＠Claude make it shorter
    >
    > and plainer
    === END ARTIFACT COMMENT f1d64ed7e6bd2c03 ===

    The comment is anchored to the part of the artifact described below.
    <comment-anchor-context source="artifact content: index.html">
    Element path: f-64ac7962-349d
    </comment-anchor-context>

    Answer this comment in its thread on the page, not here.
    """

/// A user turn of a transcript: its text, or its blocks, and who sent it (the owner, `human`, or a program through the SDK, `sdk`).
private func turn(_ time: String, _ content: Any, origin: String = "human") -> [String: Any] {
    ["type": "user", "timestamp": time, "turnOrigin": origin, "message": ["role": "user", "content": content]]
}

/// A message the owner sent while the session was working, as the transcript keeps it.
private func midTurn(_ time: String, _ prompt: String) -> [String: Any] {
    ["type": "attachment", "timestamp": time, "attachment": ["type": "queued_command", "prompt": prompt, "origin": ["kind": "human"]]]
}

/// The record condense.py writes of a session made of these entries (each given an id of its own), its transcript.md.
@MainActor private func condensed(_ entries: [[String: Any]]) throws -> String {
    let home = try scratchFolder("history")
    defer { try? FileManager.default.removeItem(at: home) }
    let session = "5e551011-0000-4000-8000-000000000001"
    var lines = [["type": "custom-title", "customTitle": "History test", "sessionId": session] as [String: Any]]
    for (index, entry) in entries.enumerated() {
        lines.append(entry.merging(["uuid": "entry-\(index)", "sessionId": session]) { _, new in new })
    }
    let transcript = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
    try write(transcript.joined(separator: "\n") + "\n", to: home.appendingPathComponent(".claude/projects/-test/\(session).jsonl"))
    let condenser = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".claude/skills/history/condense.py")
    let done = try run(URL(fileURLWithPath: python), ["-s", "-B", condenser.path, session, "--out", home.appendingPathComponent("sessions").path],
                       environment: ["HOME": home.path])
    expectEqual(done.status, 0, done.output + done.error)
    let record = URL(fileURLWithPath: done.output.trimmingCharacters(in: .whitespacesAndNewlines))
    expectEqual(record.lastPathComponent, "2026-11-06-history-test-5e551011")
    return try String(contentsOf: record.appendingPathComponent("transcript.md"), encoding: .utf8)
}
