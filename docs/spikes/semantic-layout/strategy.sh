#!/bin/sh
# The strategy issue 26 states, from this folder's data, with no key and no app, and beside it what led there: the respike the owner
# judged, the other way to count a link, and Claude's earlier alternative (clusters in new frames, not the owner's plan).
#   1. Topology first: the lens's boards and frames as they are. A frame is one piece in what holds it, and its own notes are grouped
#      inside it; nothing is added.
#   2. Each link is as tight as its two notes are alike: OpenAI's text-embedding-3-large (data/emb-openai-3-large.f16), each note's
#      vector centred on its board's mean, ranked within the board.
#   3. Each container's pieces are grouped by their links, the tighter counting more (cluster.mjs, Louvain, in key order), and the
#      links between groups are pills before anything is placed. The strategy groups at resolution 1.5 (the owner's "smaller").
#   4. The layout branch's engine (slice 4, 4bc3494e) draws the rest with no crossing; where it must still cut, the loosest link first
#      (engine.patch). Then a cut link comes back as an arrow wherever its line crosses nothing (the strategy; SIM_KEEPCUT stops it).
# Writes out/cl-*-units (the groups, the cut, the graphs), out/decided (the strategy's drawing), out/decided-by-gaps, out/e-noframes,
# out/e-units, and build/pictures/strategy (the alternative's sketch). About four minutes.
#   git worktree add /tmp/slice4 4bc3494e && DIGEST_TOOL=/tmp/slice4/.claude/skills/canvas-digest/tool sh strategy.sh
# The boards in the app (pictures/decided, pictures/respike, pictures/strategy) were drawn from out/... by a build of the layout branch
# and captured there:
#   canvas new "Strategy.canvasboard"   # its id, for --board
#   (cd <a checkout of the layout branch> && .claude/skills/canvas-digest/digest apply --out <this folder>/out/decided --board <id>)
#   canvas capture <Board>.png --board <id> --in <Board> --scale 1
set -eu
cd "$(dirname "$0")"
: "${DIGEST_TOOL:?set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)}"
export DIGEST_TOOL EMB=openai-3-large
mkdir -p build out
plan() { node "$1/main.js" plan "$2" data/measure.json "$3" --kinds data/kinds.json --view 1322x893 > "$3.log" 2>&1; }
# each container's items and the group each is in, as kept for the build to match
groups() { node -e "const s=require('./$1/stats.json');process.stdout.write(JSON.stringify({made:'$2',boards:s.boards.map((b)=>({board:b.board,levels:b.levels}))},null,1)+'\n')"; }

echo "== slice 4's engine, patched: the cut links pills from the start (simcut.patch), the engine's own cuts the loosest first (engine.patch)"
rm -rf build/simtool && cp -R "$DIGEST_TOOL" build/simtool && (cd build/simtool && patch -p1 -s < ../../engine.patch && patch -p1 -s < ../../simcut.patch)
[ -f out-branch/drawing.json ] || plan "$DIGEST_TOOL" data/graph.json out-branch
node strategy-counts.mjs data/graph.json out-branch/drawing.json "slice 4"

echo "== the strategy (issue 26): groups at resolution 1.5, the links between them pills, a cut link back as an arrow where its line is clear"
D=out/cl-1.5-units
node cluster.mjs --frames=units --res=1.5 --out=$D | cut -c1-200
groups $D 'cluster.mjs --frames=units --res=1.5, EMB=openai-3-large, a link weighed by its rank' > $D/groups.json
cmp -s $D/groups.json data/groups-decided.json && echo "the groups match data/groups-decided.json" || echo "the groups differ from data/groups-decided.json"
SIM_CUT=$D/cut.json plan build/simtool $D/graph.json out/decided
node strategy-counts.mjs $D/graph.json out/decided/drawing.json "the strategy"
node strategy-pairs.mjs $D out/decided/drawing.json "the strategy"

echo "== the other way to count a link: a link weighed by how alike its two notes are, not by its place in its board's order"
V=out/cl-1.5v-units
node cluster.mjs --frames=units --res=1.5 --weight=value --out=$V | cut -c1-200
groups $V 'cluster.mjs --frames=units --res=1.5 --weight=value, EMB=openai-3-large' > $V/groups.json
SIM_CUT=$V/cut.json plan build/simtool $V/graph.json out/decided-by-gaps
node strategy-pairs.mjs $V out/decided-by-gaps/drawing.json "by the gaps"
node -e "const a=require('./$D/stats.json').boards,b=new Map(require('./$V/stats.json').boards.map((x)=>[x.board,JSON.stringify(x.levels)]));console.log('boards whose groups differ: '+a.filter((x)=>b.get(x.board)!==JSON.stringify(x.levels)).length+' of '+a.length)"

echo "== the respike the owner judged: groups at resolution 1, cut links never put back"
U=out/cl-1-units
node cluster.mjs --frames=units --out=$U | cut -c1-200
groups $U 'cluster.mjs --frames=units, EMB=openai-3-large, resolution 1' > $U/groups.json
cmp -s $U/groups.json data/groups.json && echo "the groups match data/groups.json" || echo "the groups differ from data/groups.json"
SIM_CUT=$U/cut.json SIM_KEEPCUT=1 plan build/simtool $U/graph.json out/e-noframes
node strategy-counts.mjs $U/graph.json out/e-noframes/drawing.json "respike, no new frames" $U

echo "== Claude's alternative, not the owner's plan: the same groups, each in a new untitled frame"
node cluster-frames.mjs $U $U/graph-framed.json
node cluster-frames.mjs $U $U/graph-framed-weighted.json $U/graph.json
SIM_CUT=$U/cut.json SIM_KEEPCUT=1 plan build/simtool $U/graph-framed-weighted.json out/e-units
node strategy-counts.mjs $U/graph-framed-weighted.json out/e-units/drawing.json "the alternative, new frames" $U

echo "== a sketch of Selection and Mentions before and after the alternative (build/pictures/strategy), coloured by cluster"
B=module:Selection,module:Mentions,module:Draw,module:Canvas/Model,module:Types/Form,module:References
node semlayout.mjs --order=sem --sim=emb --frames=arrows --nocrowd=1 --others=hide --tight=$U/tight.json --boards=$B --out=out/idea-1 | cut -c1-120
node semlayout.mjs --order=sem --sim=emb --frames=arrows --nocrowd=1 --others=hide --tight=$U/tight.json --simk=all --cutfile=$U/cut.json \
  --graph=$U/graph-framed.json --boards=$B --out=out/idea-5 | cut -c1-120
[ -x build/stitch ] || swiftc -O stitch.swift -o build/stitch
P=build/pictures/strategy; mkdir -p $P
for b in Selection Mentions; do
  set -- $(node -e "const b=require('./$U/stats.json').boards.find((x)=>x.board==='module:$b');console.log(b.links,b.cut)")
  node render-idea.mjs out/idea-1/drawing.json module:$b $P/$b-before.svg $U "$b, before: all $1 links are arrows" \
    "darker arrow: the two files are more alike. Colour: the cluster each file ends up in" > /dev/null
  GRAPH=$U/graph-framed.json node render-idea.mjs out/idea-5/drawing.json module:$b $P/$b-after.svg $U "$b, after: the $2 links between clusters cut" \
    "a frame stays whole, in one cluster; a cut link is a pill, coloured by its cluster" > /dev/null
  for i in before after; do qlmanage -t -s 1400 -o $P $P/$b-$i.svg > /dev/null 2>&1; done
  build/stitch $P/$b.jpg 2 $P/$b-before.svg.png $P/$b-after.svg.png > /dev/null
done
ls $P/*.jpg
