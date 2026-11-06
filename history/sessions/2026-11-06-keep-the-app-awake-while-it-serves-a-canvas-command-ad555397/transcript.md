# Keep the app awake while it serves a canvas command

Claude Code session `ad555397-0257-420f-a183-b6be809232c0`, 2026-11-06 03:28 to 2026-11-06 12:50 UTC, on `claude/admiring-joliot-efda94`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-11-06 03:28] USER:
Background (from the session that started this one):
Found while timing a large change in another session: the "Drawing in layers" work, which adds `canvas apply`, drawing records and the canvas-digest and canvas-ingest rewrites. That change is unrelated to this fix, and the slowdown predates it. Every agent drives the app through `canvas` (CanvasRPC over a Unix socket). The app is usually in the background then, because the person's terminal or the Claude app is in front. So every agent-driven command, ingest included, runs several times slower than it needs to. CommandServer runs commands on the main actor. Build with `./build.sh`, test with `./test.sh`; a linked worktree's app is its own app with its own bundle id and preferences (`.claude/rules/build.md`).

Task:
Stop macOS App Nap from throttling the Infinite Canvas app while it serves `canvas` commands.

What was measured (a worktree build of the app on its own `CANVAS_SOCKET`, a 13,479-shape board open, another app frontmost):
- an unchanged `canvas apply --dry-run` of a large drawing took 4.2 s right after the board opened, and 15–27 s once the app had sat idle for about 40 s;
- with `defaults write <the app's bundle id> NSAppSleepDisabled -bool YES` (since removed) it stayed at 4.1 s after 55 s idle;
- an unchanged `.claude/skills/canvas-ingest/ingest` of this repository took 82 s napped and 28 s awake;
- `sample` of a slow run showed the main thread's work spread evenly over every function (no hot spot), and an idle sample showed the app doing nothing between commands. So the slowdown is the throttled process, not the work.

There is no `beginActivity` anywhere in `Sources/`.

The fix: have `CommandServer` (`Sources/CanvasUI/CommandServer.swift`, `run(_:_:on:)`, near line 164) hold `ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: …)` for exactly as long as it serves a command. End it on every path: an answer, a refusal, a timeout, a client gone. That way the app is never napped while it works, and naps again when idle. Check that commands running at once (queries do) are handled, either one activity per command or a count.

Done means:
- the change is in, with a test that every command it begins an activity for ends it (a debug counter is fine);
- a live before-and-after timing as above;
- `.claude/rules/command-line.md` updated where it describes the server;
- the whole suite passes.

Land only on the user's go-ahead, with the session record CLAUDE.md asks for.

Shared notes folder for this group of sessions (outside the repo; read siblings' notes there, leave hand-over notes or large findings there instead of pasting them into messages): /Users/zekenie/Library/Application Support/Claude/side-session-notes/local_3b972fef-67a8-4c85-b740-e2210b929dfe

[2026-11-06 03:32] ASSISTANT:
Reading the command server and the wire's listener to decide where to hold the activity; next I bring this worktree up to main and write the change.

[2026-11-06 03:32] GIT:
git merge --ff-only main && git log --oneline -1

[2026-11-06 03:34] ASSISTANT:
Deciding where the activity goes: I'll hold it in the wire's listener, per request, from its line read to its answer written, so decoding and encoding are covered too. Writing it now.

[2026-11-06 03:35] ASSISTANT:
Building the unchanged app first (in the background), so I can time it napped before the fix.

[2026-11-06 03:37] ASSISTANT:
Writing the timing script while the build runs.

[2026-11-06 03:37] ASSISTANT:
Main just moved (the `canvas apply` work landed), so I'm bringing this worktree up to it and rebuilding, to time the same commands the other session did.

[2026-11-06 03:37] GIT:
git status --short | head -5 && git merge --ff-only main | tail -3 && git log --oneline -1 && (time ./build.sh) > /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-admiring-joliot-efda94/ad555397-0257-420f-a183-b6be809232c0/scratchpad/build-before.log 2>&1; tail -3 /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-admiring-joliot-efda94/ad555397-0257-420f-a183-b6be809232c0/scratchpad/build-before.log

[2026-11-06 03:39] ASSISTANT:
The unchanged build is set aside for the "before" timing. Now writing the change in the listener.

[2026-11-06 03:40] ASSISTANT:
Now the test in the wire's "Answering later" suite.

[2026-11-06 03:40] ASSISTANT:
Adding the same check to the server's two lingering-command tests (a board closed, a `canvas` that times out), where the command outlives its answer.

[2026-11-06 03:41] ASSISTANT:
The wire's 33 tests pass. A quick check that the new test catches a leak: dropping one `end` should fail it.

[2026-11-06 03:42] ASSISTANT:
I'll replay the drawing ingest's digest makes (`canvas apply - --dry-run` of its `drawing.json`), as the other session timed. Launching the unchanged copy hidden on its own socket:

[2026-11-06 03:43] ASSISTANT:
Main thread at priority 46 so far (not napped yet, 32 s after launch). Drawing this repository into a scratch file now, in the background:

[2026-11-06 03:43] ASSISTANT:
While it draws, writing the timing script: it waits idle, samples the app's main-thread priority (which drops when macOS naps it), and times a dry run napped, then again awake.

[2026-11-06 03:43] ASSISTANT:
The landed ingest takes `--board` instead of `--new-file`, so I make the file with `canvas new` first:

[2026-11-06 03:44] ASSISTANT:
Main thread priority is now 4: the idle copy is napped, as expected. Drawing the repository onto board 3:

[2026-11-06 03:44] ASSISTANT:
While it draws, the docs. Checking what the guide says about the listener:

[2026-11-06 03:44] ASSISTANT:
Building the fixed app now (the unchanged copy keeps running from the scratchpad, so this doesn't disturb it):

[2026-11-06 03:45] ASSISTANT:
The fixed build is in `build/`. Writing the doc changes while the first ingest runs.

[2026-11-06 03:45] EDIT .claude/worktrees/admiring-joliot-efda94/.claude/rules/command-line.md:
a connection's answers in the order its requests came, and cancels the requests with ids still running once its client hangs up (never notifications); and holds an activity of the process's for each request from its line read to its answer written (`Answering`: `ProcessInfo.beginActivity`, user-initiated, idle system sleep still allowed), so macOS doesn't nap the app while a client waits: an app whose windows can't be seen is napped (App Nap: its threads at a low priority, its timers put off), an app an agent drives is in the background as a rule, behind the terminal or the app the agent runs in, and napped it answered several times slower (MEASURED). One a request, so requests answered at once hold one each (the app's server answers a query while another waits), each ended however its request ends (an answer, an error, a line that isn't a request, a client gone, `canvas` timing out among them; a notification's once it has run), and none outlives its answer, a cancelled command running on included, so the app naps again when idle (`RPCListener.activitiesHeld`, debug builds, counts them). `canvas` is CanvasCLI

[2026-11-06 03:46] ASSISTANT:
The board holds 13,577 shapes (the other session's was 13,479). A first dry run of its drawing, to check the command and that every verdict is `unchanged`:

[2026-11-06 03:46] ASSISTANT:
Napped (priority 4) before it started, and the dry run took 27.2 s, matching the other session's 15–27 s. Checking the verdicts, then running the timing script on this unchanged copy:

[2026-11-06 03:47] ASSISTANT:
While that runs (about five minutes), the testing lines of the docs:

[2026-11-06 03:47] EDIT .claude/worktrees/admiring-joliot-efda94/.claude/rules/command-line.md:
CanvasRPCTests' "Answering later" hold order on a connection, connections apart, a hang-up's cancelling, `x-timeout`, and each request's activity to its end (three held at once, then a hang-up, a notification, a line that isn't a request: `RPCListener.activitiesHeld`) with a `Holds` listener and a `RawConnection`;

[2026-11-06 03:47] EDIT .claude/worktrees/admiring-joliot-efda94/.claude/rules/command-line.md:
and a `Lingering` board command on a server of its own: a board closed under it answered `board_closed`, and a timed-out `canvas` cancelling it, each time the request's activity ending with its answer while the command runs on)

[2026-11-06 03:47] EDIT .claude/worktrees/admiring-joliot-efda94/docs/plugin-system.md:
each connection's answers in the order its requests came, and cancels the requests still running (not notifications) once its client hangs up; while it answers a request, from its line to its answer, the process holds an activity for it, so macOS doesn't nap an app in the background while a client waits. Knows no canvas, plugin or AppKit. |

[2026-11-06 03:47] EDIT .claude/worktrees/admiring-joliot-efda94/docs/plugin-system.md:
`Holds` listener and a `RawConnection`: answers in order on a connection, one connection never
  waiting on another, a hang-up cancelling what's running, `x-timeout`, each request's activity
  ended with it, `RPCListener.activitiesHeld`); CanvasCLITests run `canvas`

[2026-11-06 03:47] ASSISTANT:
The comment on the answer's write reads oddly; tightening it, and making `Answering` file-private:

[2026-11-06 03:47] ASSISTANT:
Waiting for the unchanged copy's three timed runs to finish.

[2026-11-06 03:48] ASSISTANT:
Waiting for the timed runs (each is 60 s idle plus two dry runs).

[2026-11-06 03:52] ASSISTANT:
Unchanged copy, six dry runs: 21.2–25.3 s, all at priority 4. Now an unchanged ingest rerun on it:

[2026-11-06 03:54] ASSISTANT:
Unchanged copy, ingest rerun napped: 74 s. Now the fixed build: rebuilding it with the final comment edits, then swapping the apps.

[2026-11-06 03:55] ASSISTANT:
No board is edited, so stopping the unchanged copy loses nothing. Swapping in the fixed build on the same socket:

[2026-11-06 03:55] ASSISTANT:
The fixed build is up (build `2279fb396258-dirty-39f05457`) with the 13,577-shape board restored as board 2. Same three timed runs, with 90 s idle so it's surely napped first:

[2026-11-06 04:01] ASSISTANT:
Napped again within seconds of the last command. A direct look at one command, sampling the priority every half second through it and after:

[2026-11-06 04:02] ASSISTANT:
Ingest rerun on the fixed build: 28 s, against 74 s unchanged. Measurements done; stopping the test app and unregistering the scratch copy:

[2026-11-06 04:03] ASSISTANT:
Writing the measured numbers into the docs and the source comment:

[2026-11-06 04:03] EDIT .claude/worktrees/admiring-joliot-efda94/.claude/rules/command-line.md:
an app whose windows can't be seen is napped (App Nap: its threads at a low priority, its timers put off) and stays napped while it works, an app an agent drives is in the background as a rule, behind the terminal or the app the agent runs in, and napped it answered six times slower (2026-11-05, a worktree's build hidden on a socket of its own with this repository's ingest open, 13,577 shapes: `canvas apply --dry-run` of that drawing, every verdict `unchanged`, 21 to 25 s napped and 4.2 s holding the activity, an unchanged `ingest` 74 s and 28 s; the main thread at priority 4 napped, 28 while it answers, and 4 again within half a second of the answer). One a request,

[2026-11-06 04:03] ASSISTANT:
Now the whole suite, in the background:

[2026-11-06 04:03] ASSISTANT:
While the suite runs, a short hand-over note with the measurements in the shared notes folder:

[2026-11-06 04:04] ASSISTANT:
Suite running. Meanwhile, the code review the landing gate asks for, on the working diff:

[2026-11-06 04:04] ASSISTANT:
Review done: no bugs found. I'll take out the source comment's timings once the suite finishes, so the build isn't disturbed mid-run.

[2026-11-06 04:07] ASSISTANT:
One failure, in LanguageModelsTests: a Claude Code concurrency test that timed out at 10 s. LanguageModels doesn't touch the wire, so it looks like load. Rerunning it alone:

[2026-11-06 04:08] ASSISTANT:
It fails alone too. Checking whether it fails on main without my change:

[2026-11-06 04:08] ASSISTANT:
LanguageModels uses no listener; it only links the wire through Canvas. To be sure it isn't mine, running the same test on main in a scratch clone:

[2026-11-06 04:08] ASSISTANT:
It fails the same way on main (2279fb39), so it's not this change. Now dropping the timings from the source comment (the rule doc keeps them, dated), rerunning the wire's tests, and committing:

[2026-11-06 04:09] GIT:
./test.sh CanvasRPCTests 2>&1 | tail -2 && git add -A Sources Tests .claude/rules docs && git status --short && git commit -q -F - <<'EOF'
A request to the app holds an activity from its line read to its answer written, so macOS doesn't nap the app while an agent waits on it

Every agent drives the app through `canvas`, and while it does the app is in the background, behind the terminal or the Claude app the agent runs in. A hidden app that has sat idle a moment is napped (App Nap: its threads at a low priority, its timers put off), and a napped app stays napped while it works, so every agent-driven command, ingest included, ran several times slower than it needs to. Found while timing the drawing-in-layers change: an unchanged `canvas apply --dry-run` of a 13,479-shape drawing took 4.2 s right after the board opened and 15 to 27 s once the app had sat idle 40 s, `NSAppSleepDisabled` held it at 4.1 s, and a `sample` of a slow run had the main thread's work spread evenly over every function. Nothing in Sources began an activity.

The wire's listener now begins one for each request as it reads the request's line (`ProcessInfo.beginActivity`, `.userInitiatedAllowingIdleSystemSleep`: idle system sleep stays allowed) and ends it once the answer is written. One a request, so requests answered at once hold one each, and each ends however its request does: an answer, an error, a line that isn't a request, a client gone (`canvas` timing out among them), a notification once it has run. None outlives its answer, a cancelled command that runs on included, so the app naps again within half a second of going idle.

The finding suggested holding it around CommandServer's run of a command. It is in the listener instead: only the listener sees a request from its line to its answer. Decoding a request (apply's document runs to megabytes) and encoding its answer happen there, off the main actor, and `describe`, which every `canvas` run asks first, never reaches `run`.

Measured on this worktree's build, launched hidden on a socket of its own with this repository's ingest open (13,577 shapes). `canvas apply - --dry-run` of that drawing, every verdict unchanged, took 24.8 to 25.0 s after a minute idle and 21.2 to 25.3 s straight after before the change, the main thread at priority 4 throughout. With the change it took 4.19 to 4.24 s after 90 s idle and 4.15 to 4.16 s straight after, priority 28 while it answers and 4 again within half a second. An unchanged ingest rerun took 74 s before and 28 s after.

`RPCListener.activitiesHeld` (debug builds) counts the activities held. CanvasRPCTests' "Answering later" hold three at once (two clients waiting, and an answer waiting to go back after the one before it) and each way a request ends. CommandLineTests' lingering command, answered `board_closed` and cancelled by a timed-out `canvas`, holds the request's activity ending with the answer while the command runs on.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1

[2026-11-06 04:09] WRAP-UP:
Committed 53175775 on claude/admiring-joliot-efda94: each canvas request holds an activity from its line read to its answer written, so a hidden app isn't napped. A 13,577-shape dry run went from about 25 s to 4.2 s, an ingest rerun from 74 s to 28 s. Not on main yet.
Ask: Land it on main?

[2026-11-06 04:09] ASSISTANT:
The fix is committed on the branch as `53175775` (`claude/admiring-joliot-efda94`), not on main. A hidden app no longer runs `canvas` commands napped: a dry run of a large drawing went from about 25 s to 4.2 s.

**The change.** I put the activity in the listener ([Listener.swift](Sources/CanvasRPC/Listener.swift)), not in `CommandServer.run` as the brief suggested. The listener is the only place that sees a request from when its line is read to when its answer is written:
- Decoding a request happens there, and `apply` sends documents of several megabytes.
- Encoding the answer happens there too.
- `describe`, which every `canvas` run sends first, never reaches `run`.

Each request holds its own activity, so commands running at once are covered. Each one ends however its request ends: an answer, an error, a line that isn't a request, a client gone (which covers `canvas` timing out), or a notification that has finished. None outlives its answer, even when a cancelled command keeps running. Idle system sleep is still allowed.

**Measured.** The setup was this worktree's build launched hidden on its own socket, with this repository's ingest open (13,577 shapes).

| | before | after |
|---|---|---|
| `canvas apply --dry-run` of that drawing (every verdict `unchanged`) | 24.8–25.0 s after a minute idle; 21.2–25.3 s straight after | 4.19–4.24 s after 90 s idle; 4.15–4.16 s straight after |
| unchanged `ingest` rerun | 74 s | 28 s |

The app's main-thread priority shows why:
- **Before:** it sat at 4 (napped) even while serving. A hidden app doesn't wake up to answer a request.
- **After:** it's at 28 while answering, and back to 4 within half a second of the answer, so the app still naps when idle.

**Tests.**
- **New tests:** a test in CanvasRPCTests covers three activities held at once and every way a request ends. It fails when one `end` is dropped; I checked that on purpose. The two lingering-command tests in CommandLineTests now also check that the activity ends with the answer while the command keeps running.
- **Docs:** [command-line.md](.claude/rules/command-line.md) and the guide are updated, and the measurements are dated there.
- **Whole suite:** passes except one LanguageModelsTests test (a Claude Code concurrency test that times out at line 609). It fails the same way on main (2279fb39) in a scratch clone, so it's unrelated to this change.

The code review found no bugs; I acted on its one cleanup point and took the timings out of a source comment. The test app opened a file that isn't mine, `~/Documents/Ingest trials/Drawing in layers.canvasboard`, because it restored the saved windows. It was never edited, and the test app is stopped. The measurements are also in the shared notes folder as `app-nap-fix.md`. Landing it means the squash with the session record CLAUDE.md asks for.

[2026-11-06 05:03] COMPACTED:
(the context was summarized here)

[2026-11-06 12:50] USER:
Land it

[2026-11-06 12:50] GIT:
git status --short && echo "--- branch vs main" && git log --oneline main..HEAD && echo "--- main since branch base" && git log --oneline HEAD..main && echo "--- merge-base" && git merge-base HEAD main && echo "--- message" && git log -1 --format=%B HEAD

[2026-11-06 12:50] ASSISTANT:
Main hasn't moved since the branch was cut (2279fb39), so no rebase is needed. Next, I'll write the session record.
