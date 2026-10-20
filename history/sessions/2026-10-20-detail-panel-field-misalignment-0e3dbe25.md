# Detail panel field misalignment

Claude Code session `0e3dbe25-c2c1-4ccb-aa4e-d445f208e752`, 2026-10-20 21:37 to 2026-10-20 22:20 UTC, on `claude/detail-panel-field-misalignment-848638`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-20 21:37] USER:
[image attached]

[2026-10-20 21:37] USER:
detail panel for fields has misalignment

[2026-10-20 21:38] ASSISTANT:
Giving the panel's text box a real first baseline (a scroll-view subclass the text host uses), so the row style's baseline alignment lines labels up with the first line of text.

[2026-10-20 21:40] ASSISTANT:
Fixed an argument-order error in my new test; rerunning it against the fix.

[2026-10-20 21:43] ASSISTANT:
The render came out; looking at where the labels land against their boxes.

[2026-10-20 21:47] ASSISTANT:
Now threading `baseline` through `DetailTextBox` (the code editor passes the code font's).

[2026-10-20 21:47] ASSISTANT:
Need `@MainActor` on the local helper; fixing and rerunning.

[2026-10-20 21:49] ASSISTANT:
The new test passes with the fix. Checking it fails without it (so it isn't vacuous).

[2026-10-20 21:50] ASSISTANT:
The full suite is running in the background. I'll report when it finishes.

[2026-10-20 21:55] NOTICE:
background task completed: Background command "Run the full test suite" completed (exit code 0)

[2026-10-20 21:55] WRAP-UP:
Field labels in the detail panel now sit on the first line of their text box instead of at its top edge. The full suite passes (7,449 tests, 0 failures), including a new alignment test that fails without the fix. Nothing is committed, and I haven't looked at it in the running app.
Ask: Commit this?

[2026-10-20 21:55] WRAP-UP:
Field labels in the detail panel now sit on the first line of their text box instead of at its top edge. The full suite passes (7,449 tests, 0 failures), including a new alignment test that fails without the fix. Nothing is committed, and I haven't looked at it in the running app.
Ask: Commit this?

[2026-10-20 21:55] ASSISTANT:
The field labels in the Fields section now sit on the first line of their text, not at the top edge of the box. The full test suite passes (7,449 tests, 0 failures). I haven't looked at it in the running app, because screen capture isn't permitted here, and nothing is committed.

**Cause:** Each row lines its label up on the first text baseline. The text box is an AppKit view that reports no baseline to SwiftUI, so SwiftUI used the box's top edge. In your screenshot "report" and "steps to rep…" sit about one line above their text.

**Fix:** The text box now declares where its first line's baseline is: the box's padding plus the font's baseline. The code editor uses the code font's baseline. The change is in [TextViews.swift](Sources/DetailPanel/TextViews.swift) and [Controls.swift](Sources/DetailPanel/Controls.swift) (`DetailStyle.textBaseline` and `codeBaseline`). Other label-plus-text-box rows in the panel get the same alignment.

**Test:** The new test in [TextViewTests.swift](Tests/DetailPanelTests/TextViewTests.swift) checks that each label lines up with the text's first line, for a box of words, a typed-as-keyed box, a code editor and a text label, both empty and filled. With the fix removed it fails: the label baseline is 117 against the text's 128. I also added a line each to `detail-panel.md` and `plugin-system.md`.

One more thing in your screenshot looks off but isn't in Fields: in the Types rows, the minus icon next to "bug" sits a little lower than the tag and its label. I left it alone.

[2026-10-20 22:20] USER:
Ready to land
