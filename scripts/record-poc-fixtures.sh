#!/bin/zsh
# Re-records Tests/CompositionTests/Fixtures from the proof of concept (commit 804db97), from before
# the plugin system. The transcript and pixel-parity tests hold today's canvas to these, so they
# must only ever come from the POC, never from the code under test. Running this is a check:
# afterwards `git status` should show no change.
#
# What's replayed, and how (the steps, the NSEvent player, the capture), is
# Tests/CompositionTests/Replay.swift, compiled here against the POC and in CompositionTests
# against today's code. The POC's arrow timers are Task.sleeps, so this runs on real time and
# takes a few seconds.
set -euo pipefail
cd "${0:A:h}/.."

POC=804db97
SDK=${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}
work=$(mktemp -d -t poc-fixtures)
trap 'git worktree remove --force $work/poc >/dev/null 2>&1 || true; rm -rf -- "${work:?}"' EXIT
git worktree add --quiet --detach $work/poc $POC

srcs=(${(f)"$(print -l $work/poc/Sources/InfiniteCanvas/*.swift | grep -v InfiniteCanvasApp.swift)"})
shared=(Tests/CompositionTests/Replay.swift scripts/poc-fixtures/Board.swift)
compile=(swiftc -sdk $SDK -swift-version 6 -target $(uname -m)-apple-macosx14.0)
$compile $srcs $shared scripts/poc-fixtures/transcript/*.swift -o $work/transcript
$compile $srcs $shared scripts/poc-fixtures/render/*.swift -o $work/render

out=Tests/CompositionTests/Fixtures
$work/transcript > $out/arrow-transcript.txt
(cd $out && $work/render)
print "Recorded $out from $POC."
