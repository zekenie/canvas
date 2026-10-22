# macOS Quicklook regression

Claude Code session `a57b191b-f193-4216-8286-7c01398aeaae`, 2026-10-12 14:51 to 2026-10-12 15:51 UTC, on `main`, `worktree-quicklook-shows-json`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-12 14:51] USER:
[image attached]

[2026-10-12 14:51] USER:
Quicklook on the mac worked for a hot sec but then it stopped. idk when it stopped after the initial commit or if it was even a code change that made it stop (as opposed to something in the env). but either way, this is what happens when i quicklook now.

[2026-10-12 14:51] USER (sent mid-turn):
btw i want a worktree after all

[2026-10-12 14:51] ASSISTANT:
Still diagnosing: the extensions are registered, so I'm checking how the system types the file and whether the extension itself runs.

[2026-10-12 14:53] ASSISTANT:
Reading the system log for that thumbnail request, to see whether Quick Look launched our extension or skipped it.

[2026-10-12 15:00] ASSISTANT:
Running Quick Look's own extension lookup in a fresh process, to tell "the agent's memory is stale" apart from "the system genuinely can't find our extension".

[2026-10-12 15:06] ASSISTANT:
**Confirmed.** With the deleted copies' records gone, Quick Look found and launched our extension. Now checking the thumbnail side and what Finder itself shows.

[2026-10-12 15:06] ASSISTANT:
Cleaning up my experiment (scratch copy unregistered), then re-registering main's build so Finder and the thumbnail agent re-read the list.

[2026-10-12 15:08] ASSISTANT:
Both the preview and the thumbnail now render the board. Last measurements for the durable fix (how cheaply the build can spot deleted copies), then I'll write up the cause and the plan.

[2026-10-12 15:09] ASSISTANT:
It was the environment, not a code change, and Quick Look is working again on this Mac: press space on the file again and tell me if the Finder still shows text.

**Cause.** Every worktree build that gets opened is registered with LaunchServices as another copy of the app, with its own two Quick Look extension records. Deleting a worktree leaves those records behind. Once a deleted copy's extension records exist, Quick Look's lookup fails on them ("could not resolve URL while initializing a bundle record") and returns no extension for board files at all, so it falls back to the JSON text view. That fits "worked for a hot sec": it would have worked until the first such worktree was removed, though I can't date that from the logs. `pluginkit -m` kept listing the extension the whole time, which is why it looked registered.

**How I know.** 23 copies of the app were registered and 21 were deleted worktrees, four of them carrying extension records. A fresh process could not find the extension, even right after I registered a new live copy. After I unregistered those four, it found and launched the extension immediately. A stale Quick Look cache and the SDK stamp were both tested and ruled out.

**What I changed on your machine** (no repo changes yet):
- Unregistered the four deleted copies with `lsregister -u`.
- Re-registered main's build and its two extensions.
- Restarted the thumbnail agent (`pkill -KILL`, as the Quick Look notes describe); it kept making text thumbnails until then.
- Registered and then removed one scratch copy for the experiment.

Seventeen older deleted copies are still registered. They carry no extension records, so they don't affect Quick Look.

**Plan for the durable fix** (in the `quicklook-shows-json` worktree, waiting for your OK):
1. `build.sh` in app mode unregisters every registered copy of the app whose folder is gone, but only on builds that actually changed the bundle. Listing the copies takes about a second (`lsregister -dump Bundle`), so a no-change build stays free. The seventeen leftovers are its first real test.
2. When that removes a copy that carried extensions, the build also restarts the thumbnail agent and prints a line saying so. Otherwise file icons stay as text until you log out.
3. Correct `.claude/rules/quick-look.md`, which says any registered copy serves the type, and add how to diagnose this.
4. I also unregister a worktree's build before removing the worktree, so the gap never opens when I clean up.

**Decision for you:** is it acceptable for the build script to kill the thumbnail agent in step 2? The alternative is that it only prints the command for you to run.

One thing I'm not fixing unless you want it: LaunchServices picks which live copy's extension draws the preview, and the one launch I could trace came from another worktree's build, not main's. A worktree with a changed file format could draw main's files wrongly.

[2026-10-12 15:15] USER:
This is too much to read and understand. I think you have a plan?

[2026-10-12 15:15] ASSISTANT:
Yes. Short version:

**Why it broke:** deleted worktrees leave their app registered with macOS, and those dead entries make Quick Look give up on board files. I removed them by hand, so it works again now.

**Plan, so it doesn't come back:**
1. `build.sh` unregisters dead copies of the app whenever it builds a changed app.
2. If it removed one, it restarts Quick Look's thumbnail agent so file icons recover too.
3. Fix the Quick Look notes, which say this can't happen.

OK to build that?

[2026-10-12 15:16] USER:
Go

[2026-10-12 15:18] ASSISTANT:
Go-ahead received; the parser for spotting dead copies works on the real data. Now writing it into `build.sh` and the notes.

[2026-10-12 15:18] ASSISTANT:
Now the notes, while that builds.

[2026-10-12 15:18] EDIT .claude/worktrees/quicklook-shows-json/.claude/rules/quick-look.md:
`qlmanage -r` resets quicklookd, not the agent.
- Every checkout's build is a copy of the app, registered with its extensions once it's opened, and which copy's extension serves the type is LaunchServices' pick among those still there (not the newest registered, and not `pluginkit -m`'s). A copy that's gone is another matter: removing a worktree unregisters nothing, and while a copy whose folder is gone has its extensions registered, Quick Look gets no extension for a board file at all, however many copies still there have theirs registered, and shows the file as JSON, preview and thumbnail both (`pkd` logs LaunchServices' `could not resolve URL while initializing a bundle record` at each lookup; `pluginkit -m` goes on listing the extension all the while, so it proves nothing). So `build.sh`, in a build that changed the app's bundle and in a checkout's first (`build/.copies` marks it), unregisters every registered copy of the app whose folder is gone (`forget_copies_gone`: `lsregister -dump Bundle`, a second, lists them by the app's identifier; `lsregister -u` takes a path that's gone), and when one of them had extensions it restarts the thumbnail agent, which went on with none after they were unregistered until it was. By hand: `lsregister -u <the worktree>/build/InfiniteCanvas.app`, before or after removing the worktree.

[2026-10-12 15:18] EDIT .claude/worktrees/quicklook-shows-json/.claude/rules/quick-look.md:
`qlmanage -p` can't host a data-based preview extension on this macOS (it throws, for Apple's own too), so a preview needs a host: a `QLPreviewView` in a window placed off every screen, or the Finder.
- When a board file shows as JSON, find out whether Quick Look found the extension before reading its code: no crash report and no `CanvasQuickLook` process in the log means it was never started. A host of your own (a few lines: a `QLPreviewView` given the file, in a window off every screen, its view tree printed after a few seconds) does the lookup in its own process, where the log isn't redacted: `/usr/bin/log show --info --debug --predicate 'process == "host"'` (zsh's own `log` is another command) says `No exact match found in type dictionary … for 'com.example.infinitecanvas.board'` when LaunchServices handed it no extension, and the view tree is a `QLTextView` then, an `NSRemoteView` when the extension drew it. The thumbnail agent's log says which extension it started (`Launching process with config: bundleID: …`): `com.apple.quicklook.thumbnail.TextExtension` is the JSON.

[2026-10-12 15:19] EDIT .claude/worktrees/quicklook-shows-json/.claude/rules/quick-look.md:
is LaunchServices' pick among those still there (the once it was traced, neither the newest registered nor the one `pluginkit -m` listed).

[2026-10-12 15:19] EDIT .claude/worktrees/quicklook-shows-json/.claude/rules/build.md:
in a copy, so what didn't change isn't replaced; [Quick Look](quick-look.md)). A build that changed the bundle, and a checkout's first, also unregisters the copies of the app whose folders are gone (a removed worktree's build stays registered with macOS, and its extensions, registered and gone, hide every copy's from Quick Look), which takes a second; a build that changed nothing skips it.

[2026-10-12 15:19] ASSISTANT:
The compile finished, but the bundle step failed: my new counter reused a name (`installed`) the script already uses for a path. Renaming it.

[2026-10-12 15:21] EDIT .claude/worktrees/quicklook-shows-json/.claude/rules/quick-look.md:
- Every checkout's build is a copy of the app, registered with its extensions once it's opened, and LaunchServices hands Quick Look one copy's extension, by a rule of its own (traced, it was neither the newest registered nor the oldest, nor the one `pluginkit -m` listed, and the preview's copy and the thumbnail's needn't be the same): a board file is drawn by whichever checkout's build that is, with that checkout's code. Removing a worktree unregisters nothing, and when the copy LaunchServices picks is one whose folder is gone, Quick Look gets no extension for a board file at all, however many copies still there have theirs registered, and shows the file as JSON, preview and thumbnail both (`pkd` logs LaunchServices' `could not resolve URL while initializing a bundle record` at each lookup; `pluginkit -m` goes on listing the extension all the while, so it proves nothing). Not every copy that's gone is picked (one registered after the others wasn't), so none is left. `build.sh`,

[2026-10-12 15:21] EDIT .claude/worktrees/quicklook-shows-json/.claude/rules/build.md:
(a removed worktree's build stays registered with macOS, and when Quick Look is handed that one's extensions, a board file shows as JSON), which takes a second;

[2026-10-12 15:22] ASSISTANT:
Build fix verified end to end (it found the dead copy, unregistered it, restarted the agent; preview and thumbnail still render). Committing and running the code review next.

[2026-10-12 15:22] COMMIT MESSAGE FILE commit-message.txt:
A build that changed the app unregisters the copies of it that are gone, so a board file stops showing as JSON in Quick Look

Quick Look worked for a board file when its extension first landed, then stopped: space in the
Finder showed the file's JSON again, and so did its icon. The owner didn't know when it stopped,
or whether a code change did it or something on the machine. It was the machine, and nothing in
the extension: macOS never started it.

Every checkout's build is a copy of the app, and macOS registers one, with its two Quick Look
extensions, when it's opened. Removing a worktree unregisters nothing. LaunchServices hands Quick
Look one copy's extension for a board file, by a rule of its own, and when the copy it picks is
one whose folder is gone, it resolves nothing and hands over none, however many copies still on
disk have theirs registered; Quick Look falls back to the text of a public.json file. Twenty-three
copies were registered here and twenty-one were builds of worktrees since removed, four of them
with extensions. A copy registered fresh, beside them, wasn't found either; with the four
unregistered, the extension was found and started at once. pluginkit -m listed the extension all
along, which is why it looked registered.

So build.sh, in a build that changed the app's bundle and in a checkout's first, asks
LaunchServices for every copy of the app and unregisters those whose folders are gone. Listing
them takes a second (lsregister -dump Bundle; NSWorkspace's list leaves out exactly the ones that
are gone), so a build that changed nothing doesn't spend it, and stays half a second. When a copy
that's gone had extensions, the build restarts Quick Look's thumbnail agent too, which went on
making text thumbnails after the copies were unregistered until it was restarted; the owner
agreed to the build doing that itself.

Ruled out on the way, and worth knowing: a stale Quick Look cache (a process started fresh found
no extension either), and the SDK the binaries are stamped with (swiftc -sdk with no SDKROOT in
the environment stamps 27.0 on this Mac, whatever SDK it compiled against; restamped 26.5, the
extension still wasn't found).

Not changed: which copy still on disk draws a file. LaunchServices picks that too, and a board
file may be drawn by a worktree's build with that worktree's code, the preview by one copy and
the thumbnail by another. The Quick Look notes say so now, where they said any copy would do, and
say how to tell that Quick Look never found the extension before reading its code.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

===== [2026-10-12 15:22] commit written: A build that changed the app unregisters the copies of it that are gone, so a board file stops showing as JSON in Quick Look =====

[2026-10-12 15:22] GIT:
git add build.sh .claude/rules/build.md .claude/rules/quick-look.md && git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas/a57b191b-f193-4216-8286-7c01398aeaae/scratchpad/commit-message.txt && git log --oneline -1 | cut -c1-140

[2026-10-12 15:26] ASSISTANT:
Fixing what the review found: making the Finder look again after a prune, anchoring the `pkill`, guarding against copies that are merely unreachable, and correcting two statements in the notes.

[2026-10-12 15:27] EDIT .claude/worktrees/quicklook-shows-json/.claude/rules/quick-look.md:
by no rule that was found (traced, it has been the newest registered, the oldest and neither, not the one `pluginkit -m` lists, and the preview's copy and the thumbnail's needn't be the same): a board file is drawn by whichever checkout's build that is, with that checkout's code.

[2026-10-12 15:27] EDIT .claude/worktrees/quicklook-shows-json/.claude/rules/quick-look.md:
unregisters every registered copy of the app whose folder is gone (`forget_copies_gone`: `lsregister -dump Bundle`, a second, lists them by the app's identifier, and it warns if the dump, whose form is documented nowhere, has stopped reading; `lsregister -u` takes a path that's gone; a copy on a volume that isn't mounted, or under a folder the shell can't list, isn't taken for gone). When one of them had extensions, what was handed none has to ask again, and unregistering makes nothing ask: a host (the Finder) asks only when an extension is registered, so the build has the copies still there register theirs again (`pluginkit -a`, which works on a copy already registered), and it restarts the thumbnail agent, which went on with none until it was (by its path from the start: `pkill -f` with the bare name kills any process whose command line has the name in it). By hand: `lsregister -u <the worktree>/build/InfiniteCanvas.app`, before or after removing the worktree, then `pluginkit -a` on a copy's two extensions and the agent's restart if Quick Look had already gone to JSON.

[2026-10-12 15:27] EDIT .claude/worktrees/quicklook-shows-json/.claude/rules/quick-look.md:
does the lookup in its own process, and run with `OS_ACTIVITY_DT_MODE=YES` its log isn't redacted (a system process's is, and so is the host's without it): `/usr/bin/log show --info --debug --predicate 'process == "host"'` (zsh's own `log` is another command) says

[2026-10-12 15:28] ASSISTANT:
All checks pass; committing the review fixes and recording the review outcomes.

[2026-10-12 15:28] COMMIT MESSAGE FILE commit-message.txt:
are gone), so a build that changed nothing doesn't spend it, and stays half a second. A copy on a
volume that isn't mounted, or under a folder the shell can't list, isn't taken for gone, and the
build says so if the dump, whose form is documented nowhere, stops reading.

When a copy that's gone had extensions, what was handed none has to ask again, and unregistering
makes nothing ask: the Finder asks only when an extension is registered, so the build has the
copies still on disk register theirs again, and it restarts Quick Look's thumbnail agent, which
went on making text thumbnails until it was restarted. The owner agreed to the build restarting
it itself. It's killed by its path, since pkill -f with its bare name kills any process whose
command line mentions it.

[2026-10-12 15:28] GIT:
git add build.sh .claude/rules/build.md .claude/rules/quick-look.md && git commit -q --amend -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas/a57b191b-f193-4216-8286-7c01398aeaae/scratchpad/commit-message.txt && git log --oneline -2 | cut -c1-130 && git status --short

[2026-10-12 15:29] EDIT /Users/zekenie/.claude/projects/-Users-zekenie-code-native-canvas/memory/work-in-worktree.md:
- Before removing a worktree whose app was opened, unregister its build: `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <worktree>/build/InfiniteCanvas.app`. (My own addition, 2026-10-12, not the user's instruction: removed worktrees' builds stayed registered with macOS and made Quick Look show board files as JSON; `build.sh` prunes them at the next build that changes the app, this closes the gap until then. See `.claude/rules/quick-look.md`.)
- Report a landing in one plain line:

[2026-10-12 15:29] ASSISTANT:
Done and reviewed; it's on the worktree branch as `a74f60cb`, waiting for you to say land.

- **What the build does now:** when it builds a changed app, it unregisters copies of the app whose folders are gone. If one of them had Quick Look extensions, it also makes the Finder look again and restarts the thumbnail agent.
- **Tested:**
  - It cleared the 19 leftover dead copies on its first run.
  - I recreated a dead copy with extensions; the build removed it, the Finder re-queried, and preview and thumbnail both rendered the board.
  - A copy that was only unreadable was left alone.
  - A no-change build still takes 0.5 s.
- **Review:** 12 findings, 9 fixed. The one that mattered: without the "look again" step, the Finder would have kept showing JSON after the cleanup.
- **Not run:** the test suite, since the change is only the app-bundling step of `build.sh` and the notes.

One thing still open: macOS picks which checkout's build draws a board file, and during testing it sometimes used another worktree's build instead of main's, and the two drew the same file differently. Want me to make main's the only one that serves Quick Look?

[2026-10-12 15:35] USER:
So I’m going to be frequently developing in various work trees and running builds. I want this to generally work like I’m kind ok if it sometimes shows the quick look from work tree the last thing that builds is the thing that has the quick look preview. I’m OK.

[2026-10-12 15:36] ASSISTANT:
Then you're covered: with this fix, Quick Look keeps working as worktrees come and go, and a worktree's build drawing the preview is allowed.

One correction: it isn't strictly the last build. macOS picks among the builds still on disk, so you get some current build, not always the newest. I can make it strictly last-build-wins if you want that; it's a small addition to the same build step.

Otherwise, say "land" and I'll merge it.

[2026-10-12 15:50] USER:
land

[2026-10-12 15:50] GIT:
git status --short && git rev-parse --short main HEAD && git rebase main 2>&1 | tail -2 && git log --oneline -2 | cut -c1-120

[2026-10-12 15:51] GIT:
git merge --ff-only worktree-quicklook-shows-json 2>&1 | tail -3 && git log --oneline -1 | cut -c1-130

[2026-10-12 15:51] ASSISTANT:
Merged; now removing the worktree and its branch.

[2026-10-12 15:51] ASSISTANT:
It's on main as `a74f60cb`, and the worktree and its branch are removed.

Your next `./build.sh` in main runs the cleanup check once, then only on builds that change the app.
