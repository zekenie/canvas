# App icon not applying to board files

Claude Code session `b95df9c0-77d5-4c87-b769-bd7db601d6ac`, 2026-10-22 03:08 to 2026-10-22 03:16 UTC, on `claude/app-icon-board-files-bde058`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-22 03:08] USER:
the app icon is sick but it doesn't apply to board files

[2026-10-22 03:09] ASSISTANT:
Checking what icon macOS gives a board file today, before changing anything.

[2026-10-22 03:10] ASSISTANT:
Now the docs: build.md's icon bullet and the Icon README.

[2026-10-22 03:10] EDIT .claude/worktrees/app-icon-board-files-bde058/.claude/rules/build.md:
commit all three. Every copy of the app carries the same icon. Board files wear it too: the board type's declaration names it as its badge (`UTTypeIcons`, `UTTypeIconBadgeName`), and macOS draws its own document page with the icon on it, no text under it; without one a board took public.json's icon, the system's page of text (`CFBundleTypeIconSystemGenerated` doesn't help, since the parent type's icon wins over it; an `UTTypeIconFile` or `CFBundleTypeIconFile` of the app icon makes a file look like the app), and a board's Quick Look thumbnail ([Quick Look](quick-look.md)) still shows in its place wherever the Finder draws one. It's a plain

[2026-10-22 03:10] ASSISTANT:
While it builds, I'll unregister the five probe apps.

[2026-10-22 03:10] ASSISTANT:
The worktree build is running in the background; I'll check the generated Info.plist and render a board file's icon from it once it finishes.

[2026-10-22 03:12] NOTICE:
background task completed: Background command "Build the worktree's app" completed (exit code 0)

[2026-10-22 03:12] ASSISTANT:
The copy's plist splits the two types across an imported and an exported list, so my sed made a duplicate key. I'll do the flip with plistlib instead.

[2026-10-22 03:13] ASSISTANT:
One wording fix: the inherited icon showed as a page of text in the first render and a blank page in the second, so the docs shouldn't say "page of text".

[2026-10-22 03:13] EDIT .claude/worktrees/app-icon-board-files-bde058/.claude/rules/build.md:
without one a board took public.json's icon, a plain page (

[2026-10-22 03:13] WRAP-UP:
Board files now get the app icon on macOS's own document page: the board type declares it as its badge in build.sh's Info.plist, and the docs say so. Checked on a probe copy of the built plist; nothing is committed, and the main app won't show it until main has it and is rebuilt.
Ask: Land this on main?

[2026-10-22 03:13] ASSISTANT:
Board files now show the app icon in the middle of macOS's own document page. The before and after is the image above.

**Why it was missing:** the board type said what it conforms to (JSON) but declared no icon of its own, so board files took JSON's plain page.

**The fix** is a few lines in the board type's declaration in [build.sh](build.sh): `UTTypeIcons` naming `AppIcon` as its badge. macOS then draws the page itself, so it matches every other document icon on the system and scales down to 16 points. Every copy of the app writes the same declaration.

**Other ways I tried**, each on a throwaway app with a file type of its own so your real setup wasn't touched:
- Using the app icon as the file icon: files look exactly like the app.
- Asking macOS to generate a document icon from the app icon: JSON's icon still wins.
- Putting "BOARD" under the icon: works. I left the text off to keep it quiet, but it's one more line if you want it.

**Checks:** the worktree builds, and its Info.plist has the badge. I couldn't check the real app itself, because your main checkout's build is what macOS reads the board type from. Instead I registered that build's plist, with its identifiers renamed, as its own app, and rendered a file's icon from it. That render is the bottom row, and I removed the test registration afterwards.

**What's not done:** nothing is committed. Your main checkout's app shows the new icon only once main has this change and is rebuilt; the Finder may need a relaunch to stop showing the old icon. Boards with shapes on them still show their picture of the board in the Finder's icon view; the new icon appears for empty boards, at small sizes and in lists.

I also added a line on the board icon to [build.md](.claude/rules/build.md) and [Icon/README.md](Icon/README.md).

[2026-10-22 03:15] USER:
Put BOARD under the icon on the page, then land.

[2026-10-22 03:15] EDIT .claude/worktrees/app-icon-board-files-bde058/.claude/rules/build.md:
the board type's declaration names it as its badge (`UTTypeIcons`, `UTTypeIconBadgeName`), and macOS draws its own document page with the icon on it and BOARD under it (`UTTypeIconText`);

[2026-10-22 03:15] ASSISTANT:
Rebuilding (only the plist changed, so it should be quick) and rendering from a fresh probe type so no cached icon is reused.

[2026-10-22 03:16] GIT:
git rev-parse HEAD main && git add build.sh .claude/rules/build.md Icon/README.md && git commit -q -F - <<'EOF'
Board files wear the app icon: macOS's own document page with the icon on it and BOARD under it

The owner found the new app icon didn't reach board files, which showed a plain page: the board
type declared no icon, so it took public.json's. Its declaration now names the app icon as its
badge and BOARD as its text (UTTypeIcons), and macOS draws the page, as for its own documents,
at every size. The text was the owner's pick, over the badge alone.

Turned down, tried on probe apps with types of their own: CFBundleTypeIconSystemGenerated, which
the JSON parent's icon wins over, and the app icon as the file icon (UTTypeIconFile or
CFBundleTypeIconFile), which makes a board look like the app. A board's Quick Look thumbnail
still shows in the icon's place wherever the Finder draws one.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1

[2026-10-22 03:16] ASSISTANT:
Committed on the branch. Now the review before landing.

[2026-10-22 03:16] ASSISTANT:
Review found nothing. Writing the session record and landing.
