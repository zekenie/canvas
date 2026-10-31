# Self-reference creation issue

Claude Code session `17c939c0-c1e5-431c-ae33-c338a5f7ef70`, 2026-10-31 02:16 to 2026-10-31 03:44 UTC, on `claude/self-reference-creation-e0c261`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-31 02:16] USER:
as far as i can tell there's no good way to create a self reference. i try draging from the portal and dropping on the shape but it doesn't work

[2026-10-31 02:17] ASSISTANT:
Still reading: the drag refuses its own shape by design, so I'm checking the tests that hold that rule and what the type-to-itself path already supports.

[2026-10-31 02:17] WRAP-UP:
Dragging a dot back onto its own shape is refused on purpose, so for a type nothing happens. A type related to itself is supported, but only through hidden paths. Nothing has been changed yet.
Ask: Should a drag from a type back onto itself make a relationship type to itself?

[2026-10-31 02:17] ASSISTANT:
You're right: there's no good way. I'm reading "portal" as a port dot and "self reference" as a type related to itself (Person manages Person).

**Why the drop does nothing:** a drag from a dot is never allowed to end on the shape it started from ([Ports.swift:349](Sources/Connections/Ports.swift:349)). So letting go on that shape counts as letting go on empty canvas, and the arrow is removed. This is on purpose, and a test checks it ([RelationshipSelfShippedTests.swift:234](Tests/CompositionTests/RelationshipSelfShippedTests.swift:234)). The rule exists so a plain note never gets an arrow to itself. The trouble is that it also blocks types, where the app already knows what to do: `newRelationshipType(from:to:)` accepts `from == to` and makes the relationship type with two arrows bowed apart.

**What works today, all of it hidden:**
- Mention the type in its own words ("friends with another @Person"), click that pill and choose **Relate to Person**.
- Make a relationship-type note by hand, then do two drags: from the type to it, and from it back to the type.
- Use `canvas draw`.

**The fix I'd make:**
- Releasing a type's drag back on that same type makes a new relationship type from it to itself. You'd get the same pill-naming step as a drag between two different types.
- Plain notes would still refuse.
- Connections can't know about types, so this would be a general switch: a plugin can let a shape accept a connection from itself, and Types would turn it on only for types.
- The keyboard needs a way to do the same thing, so I'd also always offer the type itself under **Relate to ▸** in its Shape menu, not only when its words mention it.

[2026-10-31 02:18] USER:
sorry yes port. go ahead and build

[2026-10-31 02:19] ASSISTANT:
I've read through the drag path. Next I'm adding a general "a shape may take a connection from itself" switch in Connections, which Types will turn on for types.

[2026-10-31 02:20] ASSISTANT:
Now writing the code: a scoped "connects to itself" point in Connections, the drag's own-shape check reading it, and Arrows taking back any arrow the release leaves running from a shape to itself.

[2026-10-31 02:23] ASSISTANT:
Audit passes. Now building and running the arrow-ports and relationship tests (the full build runs first, so this takes a while).

[2026-10-31 02:26] ASSISTANT:
It compiles. The filter matches test names rather than suites, so I'll run the built test executables directly.

[2026-10-31 02:28] ASSISTANT:
Tests are next. Every type will now show Relate to ▸ with its own name, so I'll also update the one existing menu test that listed only the types its words mention.

[2026-10-31 02:28] ASSISTANT:
Adding the Connections-level test: the starting shape takes the drag only when a scoped plugin says so, and then it's outlined like any other target.

[2026-10-31 02:29] ASSISTANT:
While the full suite runs, I'm updating the rules files and the plugin guide.

[2026-10-31 02:29] ASSISTANT:
Now editing the rules files: connections first.

[2026-10-31 02:30] ASSISTANT:
Connections, relationships and types docs are updated. Arrows, keyboard navigation and the plugin guide are next, while the full suite keeps running.

[2026-10-31 02:31] EDIT docs/plugin-system.md:
literal edges and `registry.accepts`, once per revision of the reference's edges
(`ReferenceState.channelMismatch(of:)`).

### A drag back onto where it starts

A connection never ends where it starts, but a plugin may let a port's drag end on the shape it
started from, for that drag's release to make something else of it
([SelfConnections.swift](../Sources/Connections/SelfConnections.swift)). It says so for the shapes of
the kinds its scope reaches, of each shape, as the drag passes over the one it started from:

```swift
registrar.forShapes(holding: TypeSchemaProperty.self) { types in
    types.connectsToItself { shape, editor in editor.relatesToItself(shape) }
}
```

That's `ArrowPortsPlugin`'s: a type dragged back onto itself is related to itself, and the release
(`ArrowConnecting.finished`, Types' `connectionDrawn`) replaces the arrow with a relationship type
and an arrow into it and one out of it. `editor.channel(of:endingAt:)` answers for the start then,
on the channels the shape takes, so the faint outline and the hint show it as any other end. Such
a connection is never kept: the connector takes back whatever the release leaves joining the shape
to itself, in the press's step, so a release that makes nothing of it leaves no step. Connect (⌘L)
and `canvas draw` are untouched: one takes two shapes, and the other refuses an edge on a channel
from a shape to itself.

### The dots and the select tool

[2026-10-31 02:31] EDIT .claude/worktrees/self-reference-creation-e0c261/docs/plugin-system.md:
literal edges and `registry.accepts`, once per revision of the reference's edges
(`ReferenceState.channelMismatch(of:)`).

### A drag back onto where it starts

A connection never ends where it starts, but a plugin may let a port's drag end on the shape it
started from, for that drag's release to make something else of it
([SelfConnections.swift](../Sources/Connections/SelfConnections.swift)). It says so for the shapes of
the kinds its scope reaches, of each shape, as the drag passes over the one it started from:

```swift
registrar.forShapes(holding: TypeSchemaProperty.self) { types in
    types.connectsToItself { shape, editor in editor.relatesToItself(shape) }
}
```

That's `ArrowPortsPlugin`'s: a type dragged back onto itself is related to itself, and the release
(`ArrowConnecting.finished`, Types' `connectionDrawn`) replaces the arrow with a relationship type
and an arrow into it and one out of it. `editor.channel(of:endingAt:)` answers for the start then,
on the channels the shape takes, so the faint outline and the hint show it as any other end. Such
a connection is never kept: the connector takes back whatever the release leaves joining the shape
to itself, in the press's step, so a release that makes nothing of it leaves no step. Connect (⌘L)
and `canvas draw` are untouched: one takes two shapes, and the other refuses an edge on a channel
from a shape to itself.

### The dots and the select tool

[2026-10-31 02:31] ASSISTANT:
The docs are done, and the guide now has a short section on a drag back onto where it starts. I'm waiting for the full test suite to finish.

[2026-10-31 02:31] ASSISTANT:
The main checkout is untouched (the untracked `dogfood/model/` there was already there and isn't mine). Waiting on the suite.

[2026-10-31 02:31] ASSISTANT:
While waiting, I'm reviewing my own diff.

[2026-10-31 02:31] ASSISTANT:
Everything is written. The full test suite is running in the background, and I'll pick up when it finishes. The one test I've run so far (ArrowPorts) showed the new drag working. The rest of the suite hasn't reported yet.

[2026-10-31 03:00] NOTICE:
background task completed: Background command "Run the full test suite in the background" completed (exit code 0)

[2026-10-31 03:00] ASSISTANT:
Only the arrow-ports line changed, as expected. Updating both copies.

[2026-10-31 03:03] ASSISTANT:
The report checks pass now. The `relationshipLanding` budget still fails when run alone (162 ms against 16), so I'm checking whether my change causes it or whether it already failed before.

[2026-10-31 03:04] GIT:
git add -A Sources Tests docs .claude/rules && git status --short && git commit -q -F - <<'EOF'
A type dragged from its port back onto itself is related to itself

There was no direct way to say a type relates to itself (Person manages
Person): dropping a type's drag back on the type did nothing, because a
port's drag never ended where it started. The writer for it already
existed (newRelationshipType with from == to: a relationship type and two
arrows bowed apart), but only a self-mention in the type's words, two
drags through a hand-made relationship type, or canvas draw reached it.

Connections gets a scoped point, SelfConnections: a plugin may let a
drag end on the shape it started from, for the release to make
something else of it. ArrowPortsPlugin says so for a type (Types'
relatesToItself: a type and no relationship type), and the release
already replaces an arrow between two types with a relationship type.
An arrow from a shape to itself is still never kept: the connector
deletes whatever the release leaves joining a shape to itself, so a
refused release leaves no step. Plain notes and relationship types are
unchanged, as are Connect and canvas draw.

The keyboard way (every drag has one): Relate to ▸ on a type now lists
the type itself, by name, always, since a type may relate to itself
more than once, as the drag allows.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -1

[2026-10-31 03:04] ASSISTANT:
Committed on the branch as d2f0d0d5. Running the code review now.

[2026-10-31 03:07] ASSISTANT:
Now the fixes. First the memo and the corrected doc comment in SelfConnections.swift:

[2026-10-31 03:07] ASSISTANT:
Next: the self offer hidden while the type's words are edited, as the words' offers are (finding 6), and the doc wording (findings 2 and 3).

[2026-10-31 03:07] ASSISTANT:
Now the missing test (finding 8): a drag from Person that passes over Person and goes on to Company.

[2026-10-31 03:10] ASSISTANT:
The test was wrong, not the code: this board already has Employment between Person and Company. I'll build the board without those ends.

[2026-10-31 03:12] ASSISTANT:
ArrowPorts passes in full, including the new pass-over test. Now CompositionTests and TypesTests, one at a time.

[2026-10-31 03:12] ASSISTANT:
CompositionTests and TypesTests are running in the background. I'll finish once they report back.

[2026-10-31 03:40] NOTICE:
background task completed: Background command "Run CompositionTests and TypesTests alone" completed (exit code 0)

[2026-10-31 03:40] GIT:
git add -A Sources Tests docs .claude/rules && git commit -q -F - <<'EOF'
Fix what reviewing the self-relation drag found

The predicate is canRelateToItself: it says a drag back onto the type
would relate it, not that it is related. The point's contributions are
memoized by kind, since the overlay asks on every frame of a drag, and
the docs say so instead of "only while under the pointer". Relate to ▸
leaves the type itself out while its words are edited, as it does the
words' offers. The docs no longer claim no drag leaves an arrow from a
shape to itself: a re-aimed end still binds there, as tldraw's does.
A test drags from a type over itself and on to another type.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline main..HEAD

[2026-10-31 03:40] WRAP-UP:
Dragging a type's port back onto the type now relates it to itself, and Relate to ▸ on every type lists the type itself as the keyboard way. Reviewed and fixed; two commits on the branch, not on main. Not tried in the app on screen.
Ask: Land it on main?

[2026-10-31 03:40] ASSISTANT:
Dragging from a type's port and dropping it back on the same type now relates the type to itself. You get a new relationship type between two arrows that bow apart (one into it, one out), and its name is ready to type in the pill. One Undo removes it all. It's built, reviewed and committed on the branch, but not landed on main, and I haven't tried it in the app on screen.

- **Where the change is:** Connections has a new general switch that lets a plugin allow a drag to end on the shape it started from (`SelfConnections`). The arrow code turns it on for types only. If nothing replaces the arrow on release, the arrow is deleted, so you never end up with an arrow from a shape to itself. Plain notes and relationship types work as before.
- **Keyboard way:** **Relate to ▸** on a type now always lists the type itself. It stays listed after the first time, so you can add a second self-relationship (like "manages" and "friends with"), just as the drag can.
- **Things you'll notice:**
  - Every type's right-click and Shape menu now has the Relate to ▸ submenu.
  - Letting go back on a type no longer cancels the drag; Escape does.
- **Tests:** new tests cover the drag, a type in a locked frame (nothing is made and no step is left), a drag that passes over the type on its way to another type, and the menu item. The full suite was run, and every suite this change touches was rerun alone and passes. The registry report (and its copy in the guide) gained one line for the new switch. The remaining failures are TypesTests timing budgets plus four LanguageModels sign-in timeouts in the first run. The failing budgets changed from run to run while the machine's load average was around 30, and those tests don't use any of this code.
- **Review:** the review found 10 issues. I fixed 6: a public name that read like a state, a per-frame lookup now cached, two inaccurate doc claims, the type itself showing in Relate to ▸ while the type's words are being edited, and the missing pass-over test. Two needed no change, and I skipped two small duplications.

[2026-10-31 03:44] USER:
Land it

[2026-10-31 03:44] GIT:
git status --short; git log --oneline -1 main; git merge-base HEAD main; git rebase main 2>&1 | tail -3; git log --oneline main..HEAD

[2026-10-31 03:44] ASSISTANT:
The rebase onto the latest main (7ffd380a) was clean. Writing the session record:
