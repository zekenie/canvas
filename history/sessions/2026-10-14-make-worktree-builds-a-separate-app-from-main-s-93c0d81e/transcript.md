# Make worktree builds a separate app from main's

Claude Code session `93c0d81e-7445-4ef2-be75-f3b8a0a538da`, 2026-10-14 02:27 to 2026-10-14 12:55 UTC, on `claude/cool-saha-2be203`, `main`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-14 02:27] USER:
Fix a bug in how `build.sh` identifies the app, in the repo at /Users/zekenie/code/native-canvas. The owner saw the plan below in another session on 2026-10-13 and asked for it to be queued as its own piece of work, so the plan is approved; work in a fresh worktree off main, and land only on the owner's go-ahead after a code review, as the project's memory says.

## The bug

Double-clicking a `.canvasboard` file in the Finder opened an old build of the app. The owner had just built main (`./build.sh && open build/InfiniteCanvas.app` in the main checkout) and still got a window with the detail panel's old "Mentioned In" tab, which commit cdda07fb (on main) removed.

Cause, verified on 2026-10-13:
- Every checkout's `./build.sh` (app mode) writes an `InfiniteCanvas.app` with the same Info.plist: `CFBundleIdentifier` `com.example.InfiniteCanvas`, `CFBundleName` "Infinite Canvas", and a `CFBundleDocumentTypes` entry claiming `com.example.InfiniteCanvas.board` with `LSHandlerRank` `Owner`. The heredoc is around lines 1040-1120 of build.sh; the two Quick Look `.appex` Info.plists are written around lines 1150-1185.
- macOS registers each copy once it's opened. Two copies were registered: `/Users/zekenie/code/native-canvas/build/InfiniteCanvas.app` (main, built 21:12) and `/Users/zekenie/code/native-canvas/.claude/worktrees/relationships/build/InfiniteCanvas.app` (a worktree, built 18:50 from a branch that forked before cdda07fb).
- `osascript -e 'POSIX path of (path to application id "com.example.InfiniteCanvas")'` resolved to the worktree's copy, though main's was built later. `lsregister -dump | grep '^path: .*InfiniteCanvas\.app'` lists both (lsregister is at /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister).
- The project already records the same disease for Quick Look: `.claude/rules/quick-look.md` ("Every checkout's build is a copy of the app ... LaunchServices hands Quick Look one copy's extension, by no rule that was found"). build.sh's `forget_copies_gone` (around lines 1193-1257) only unregisters copies whose folder is gone; nothing handles copies that still exist in other worktrees.

## The fix that was approved

In `build.sh`:
- The main checkout's build stays `com.example.InfiniteCanvas`, the owner of board files.
- A build in a linked git worktree becomes its own app: its own bundle id (something like `com.example.InfiniteCanvas.worktree.<name>`), a name that says which it is ("Infinite Canvas (<worktree name>)"), and board files claimed at a rank that never makes it the default (`Alternate`), so it can still open boards through Open With, `open -a` and drags.
- Stated consequence the owner accepted: a worktree's build has its own preferences and window memory, separate from main's.

Rejected: "last build wins" (each build unregisters the other copies). Opening a worktree's app registers it again, and macOS's pick among same-id copies follows no rule anyone found.

## Things to work out and report (decide the small ones yourself, say what you chose)

- How a build knows it is in a linked worktree (`git rev-parse --git-dir` differs from `--git-common-dir` there), and what a plain clone or a copy with no git counts as.
- What in the app is keyed by the bundle id and so changes for a worktree build: user defaults (settings, spelling settings, the view memory), where the Anthropic key is kept (`.claude/rules/language-models.md`; never print, log or write the key), the socket the `canvas` command line finds the app by (`.claude/rules/command-line.md`). Say which of these a worktree build shares with main's and which it doesn't, and whether any of that breaks how sessions test a worktree's app.
- The type identifiers are literals in the sources and should stay the same in every copy so files, copy and paste, and drags work between copies: `Sources/CanvasUI/BoardDocument.swift:18` (`com.example.InfiniteCanvas.board`), `Sources/Clipboard/ClipboardState.swift` (`.shapes`, `.cut`), `Sources/Mentions/MentionTextView.swift` (`.mention-text`), `Sources/TableOfContents/ContentsDragging.swift` (`UTType(exportedAs: "com.example.InfiniteCanvas.contents-rows")`). Work out whether a worktree build should import the types (`UTImportedTypeDeclarations`) where main's exports them, and what `UTType(exportedAs:)` does in a copy that doesn't export.
- `forget_copies_gone` matches copies by the literal identifier `com.example.InfiniteCanvas` in its awk; it has to go on finding worktree copies under their new ids, and copies registered under the old id.
- Copies already registered under the shared id in worktrees that exist today keep competing until they are rebuilt or unregistered. Say what the change does about them. Do NOT unregister, rebuild, read or otherwise touch other worktrees' builds or branches yourself (other sessions own them, `relationships` among them); if the fix needs an existing copy unregistered, give the owner the command and ask.
- Quick Look: an extension's bundle id must be prefixed by its app's. Check whether the split also makes main's extensions the ones Quick Look uses for board files. Report what you find; don't widen the change to redesign Quick Look registration unasked.

## Checking it

- Don't build in the main checkout. Stand in for it with a scratch clone (a plain `git clone` into your scratchpad counts as a main checkout, or decide otherwise and say so) beside your worktree's build, then check `path to application id "com.example.InfiniteCanvas"` and what `open <file>.canvasboard` on a throwaway board file launches. Unregister every scratch copy you registered when you're done (`lsregister -u <path>`), so you leave LaunchServices as you found it plus the fix.
- Read `.claude/rules/build.md` and `.claude/rules/quick-look.md` before changing build.sh, and update both in the same commit (the project's rule: a change to a subsystem updates its topic file). SkillTests or other tests may hold strings of the Info.plist; run `./test.sh` (or the filtered suites that cover the build and Quick Look) and report the output.
- If the build fails with "this SDK is not supported by the compiler", prefix with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.

Finish with a short report: what changed, what a worktree build shares with main's and what it doesn't, what you found about Quick Look, and anything the owner has to run by hand.

[2026-10-14 02:27] ASSISTANT:
Still reading: I've been through `build.sh`'s app mode and the two topic files, and I'm now tracing what's keyed by the bundle id (defaults, the key file, the socket) before I edit anything.

[2026-10-14 02:33] ASSISTANT:
Reading is done; LaunchServices currently has two copies under the shared id (main's and one worktree's) and picks the worktree's. Now editing `build.sh`, then building and running the checks.

[2026-10-14 02:37] GIT:
git add build.sh Sources/InfiniteCanvas/InfiniteCanvasApp.swift && git commit -q -m "WIP: a worktree's build is an app of its own" && git log --oneline -1 && git clone -q --depth 1 "file://$PWD" build/standin && git -C build/standin log --oneline -1 && git -C build/standin rev-parse --git-dir --git-common-dir && git -C build/standin config --get remote.origin.url

[2026-10-14 02:51] GIT:
git add -A . && git status --short && git commit -q --amend -m "WIP: a worktree's build is an app of its own" && git log --oneline -2

[2026-10-14 02:53] GIT:
git add -A . && git commit -q --amend -F - <<'EOF'
A worktree's build is a copy of the app, an app of its own to macOS, so board files open in the main checkout's build

Double-clicking a .canvasboard file opened an old build: the owner had just
built main and got a window with the detail panel's Mentioned In tab, which
main had removed. Every checkout's build was the same app to macOS
(com.example.InfiniteCanvas, owner of board files), each registered once
opened, and of several under one identifier macOS opens whichever it picks,
by no rule that was found: that day a worktree's build from a branch forked
before the tab went, though main's was built later. Quick Look's topic file
already recorded the same disease for extensions.

The owner's fix: the main checkout's build stays the app; a linked git
worktree's build becomes a copy with its own identifier
(com.example.InfiniteCanvas.worktree.<name>), a name that says which
("Infinite Canvas (<name>)") and board files claimed as an Alternate, so it
still opens them through Open With, `open -a` and drags and is never the
default. They accepted that a copy has its own preferences and view memory.
"Last build wins" (each build unregistering the others) was rejected:
opening a copy registers it again.

Decided while building it:
- A worktree is one by git's own answer (--git-dir isn't --git-common-dir),
  named as git names it, which no two of a repository share. A clone or a
  folder with no git builds the app: macOS offers no app under /private/tmp,
  so scratchpad clones never competed.
- Main's Info.plist is byte for byte what it was.
- A copy imports the board's type, so the app's declaration is the one macOS
  goes by, and exports the rows' type as the app does: the sources make it
  with UTType(exportedAs:), which logs a complaint in an app that only
  imports it. The type identifiers stay the sources' literals in every copy.
- The key's file and the command line's socket are paths, not the
  identifier's, so every copy shares them as before.
- forget_copies_gone finds copies under the new identifiers, and a build
  that finds its own bundle registered under another identifier (a
  worktree's from before this) unregisters it: until a rebuilt bundle is
  opened macOS keeps what it registered.
- The app's menu items say the bundle's name.

Traced with bundles in a namespace of their own: an owner beats an alternate
once both have been opened, whichever was opened last. Quick Look is not
cured by this: it used a copy's extension over the app's nine times in ten,
and each copy's extensions get containers of their own. Both are in the
topic files.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1 | cut -c1-80; tail -c 300 /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-cool-saha-2be203/93c0d81e-7445-4ef2-be75-f3b8a0a538da/scratchpad/test.log

===== [2026-10-14 02:53] commit written: A worktree's build is a copy of the app, an app of its own to macOS, so board files open in the main checkout's build =====

[2026-10-14 02:54] ASSISTANT:
The fix is built, reviewed and committed on `claude/cool-saha-2be203` (`522c9181`, one commit off main's head); it is not on main and waits for your go-ahead. `./test.sh` passed: all 60 test executables, 0 failed.

Board files still open in `relationships`' old build today, because that copy is registered under the app's identifier from before the fix. I didn't touch it. To stop it now, run this (its app is running; reopening that old build registers it again until that branch has this change):

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /Users/zekenie/code/native-canvas/.claude/worktrees/relationships/build/InfiniteCanvas.app
```

## What changed
- **Main's build** is unchanged: its `Info.plist` is byte for byte what main's `build.sh` writes today (checked on a plain clone).
- **A linked worktree's build** is `com.example.InfiniteCanvas.worktree.<name>`, named "Infinite Canvas (<name>)", and claims board files as `Alternate`. The name is git's own for the worktree.
- **A clone or a folder with no git** builds the app. macOS never offers an app under `/private/tmp`, so scratchpad clones were never competing.
- **Types:** the identifiers stay the same in every copy. A copy imports the board type and exports the rows type as main does, because `UTType(exportedAs:)` logs a complaint at launch in an app that only imports it (the type still works).
- **`forget_copies_gone`** finds copies under the new identifiers. A worktree's first build with the fix also unregisters its own old registration.
- **Other edits:** the app's About/Hide/Quit items use the bundle's name, the build's last line says which copy it built, and `build.md`, `quick-look.md`, `boards-on-disk.md` and `CLAUDE.md` are updated.

## What I checked
- **Throwaway bundles in their own namespace:** once both have been opened, the owner opens the file whichever was opened last, and a plain `open <file>` started the app, not the copy. An app that was only registered and never opened loses to one that was opened.
- **Real ids:** this worktree's copy opened a throwaway board with `open -a`, and `canvas status` named it "Infinite Canvas (cool-saha-2be203)". It was never what `path to application id "com.example.InfiniteCanvas"` or a board file resolved to.
- **Not done:** I didn't register the stand-in clone under the real id or run a plain `open` on a real `.canvasboard`. It would have landed in `relationships`' running app.

## Shared with main, and not
- **Shared:** the Anthropic key and the `canvas` socket, since both are paths under `~/Library/Application Support/InfiniteCanvas`. Whichever app takes the socket first still gets `canvas`, so testing a worktree's app works as before.
- **Its own:** preferences (view memory, spelling, window frames, Open Recent) and its Quick Look extensions' identifiers.
- **One thing sessions must do differently:** to open a board in a worktree's build, use `open -a <worktree>/build/InfiniteCanvas.app <file>`.
- **Unchanged:** the Finder still calls every copy "InfiniteCanvas".

## Quick Look
The split does not make main's extensions the ones used. In ten isolated trials the copy's extension drew the thumbnail nine times, regardless of registration order or import versus export. It also has a new cost: each worktree copy that is opened leaves two folders in `~/Library/Containers` that scripts can't delete.

Decision for you: leave the Quick Look extensions out of worktree builds? That would make main's the only ones and end the container litter, but a session working on Quick Look would need a way to opt in. I recommend yes; I held back because you said not to redesign it unasked.

## Left behind
- My probes left 40 empty `com.example.CanvasProbe*` folders in `~/Library/Containers`, and this worktree's copy left two; macOS refused my `rm`. The Finder can delete them, or a terminal with Full Disk Access:

```bash
rm -rf ~/Library/Containers/com.example.CanvasProbe*
```

- LaunchServices is otherwise as I found it: main's and `relationships`' copies only, and main's extension still draws thumbnails.

Review findings I left alone: two worktree names that differ only in punctuation or case would share an identifier, a build run with `GIT_DIR` pointing elsewhere takes a worktree for the app, and nothing automated tests the identity logic.

[2026-10-14 12:17] USER:
sorry what am i supposed to do i'm so confused

[2026-10-14 12:17] ASSISTANT:
Sorry, that was too much. You need to do at most three things, and none is urgent:

1. **Say "land" if you want the fix on main.** Until then nothing has changed for you.

2. **Run one command if you want double-click to open main's build today.** Right now board files open in the `relationships` worktree's old build. This stops that:
   ```bash
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /Users/zekenie/code/native-canvas/.claude/worktrees/relationships/build/InfiniteCanvas.app
   ```

3. **Answer one yes/no question:** should worktree builds leave out the Quick Look extensions? I recommend yes. The fix sorts out double-clicking but not Finder previews, which still mostly come from a worktree's build. A "yes" makes main's build the only one that draws them.

Also optional: my testing left 40 empty folders in `~/Library/Containers` that macOS wouldn't let me delete. They're harmless. To clear them, run this in a terminal with Full Disk Access:

```bash
rm -rf ~/Library/Containers/com.example.CanvasProbe*
```

[2026-10-14 12:19] USER:
so i need to land first?

[2026-10-14 12:19] ASSISTANT:
No, the order doesn't matter, and each fixes a different part:

- **The command** fixes today's problem right away, with or without landing. It removes the old `relationships` build that double-click is landing on now.
- **Landing** stops it from coming back. Without it, the next worktree build someone opens can take over board files again.

For a lasting fix you want both. Run the command whenever you like, and say "land" when you're ready for me to put the change on main.

[2026-10-14 12:19] USER (shell):
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /Users/zekenie/code/native-canvas/.claude/worktrees/relationships/build/InfiniteCanvas.app

[2026-10-14 12:19] ASSISTANT:
The command worked: board files now open in main's build, which is the only app macOS has under the main identifier.

The `relationships` app is still running. If it gets quit and reopened before that branch has this change, it will take over board files again. Landing, plus that branch picking up main, prevents that. Say "land" when you want it on main.

[2026-10-14 12:19] USER (shell):
rm -rf ~/Library/Containers/com.example.CanvasProbe*

[2026-10-14 12:19] ASSISTANT:
Your terminal is blocked the same way mine was: macOS protects that folder from command-line deletion unless the terminal app has Full Disk Access. Nothing was deleted and nothing broke.

The folders are tiny and empty, so it's fine to leave them. If you want them gone, use the Finder:

1. Press ⇧⌘G in the Finder and go to `~/Library/Containers`.
2. Select the folders whose names start with `com.example.CanvasProbe` (sort by name and they're together).
3. Move them to the Trash. macOS may ask you to confirm or enter your password.

Sorry for the mess. My testing made them.

[2026-10-14 12:19] USER:
ok again totally unclear what to do now

[2026-10-14 12:19] ASSISTANT:
You don't need to do anything else; the folders can stay.

Two things are left, and both are up to you:

1. **Say "land"** to put the fix on main.
2. **Answer yes or no:** should worktree builds leave out the Quick Look extensions, so Finder previews always come from main's build? I recommend yes.

[2026-10-14 12:20] USER:
rm: /Users/zekenie/Library/Containers/com.example.CanvasProbeJ.worktree.wt.QuickLookThumbnail/.com.apple.containermanagerd.metadata.plist: Operation not permitted
rm: /Users/zekenie/Library/Containers/com.example.CanvasProbeJ.worktree.wt.QuickLookThumbnail: Operation not permitted

problem?

[2026-10-14 12:20] ASSISTANT:
No, it's not a problem. macOS blocks the command line from deleting anything in that folder, so the `rm` just failed and nothing changed. The folders are empty and do nothing, so leaving them is fine.

[2026-10-14 12:20] USER:
ok land

[2026-10-14 12:20] GIT:
git -C /Users/zekenie/code/native-canvas status --porcelain | head -5; echo "main: $(git rev-parse --short main)  branch base: $(git merge-base --short HEAD main 2>/dev/null || git merge-base HEAD main | cut -c1-8)"; git log --oneline main -3 | cut -c1-90

[2026-10-14 12:20] EDIT /Users/zekenie/.claude/projects/-Users-zekenie-code-native-canvas/memory/user-shell-runs-in-main-checkout.md:
Since 522c9181 (2026-10-14) a worktree's build is its own app to macOS ("Infinite Canvas (<worktree>)", own preferences), so quitting main's copy first isn't needed, but a board file double-clicked or `open`ed opens in main's build: give `open -a <worktree>/build/InfiniteCanvas.app <file>` for a board.

[2026-10-14 12:20] ASSISTANT:
It's on main as 522c9181. The worktree and its branch are removed.

The Quick Look question is still open whenever you want it: should worktree builds leave out their Quick Look extensions?

[2026-10-14 12:55] USER:
i don't care

[2026-10-14 12:55] ASSISTANT:
OK, I'll leave Quick Look as it is. There's nothing left for you to do.
