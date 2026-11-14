#!/bin/sh
# The alternative the spike ended on (2026-11-13), from this folder's data, with no key and no app: each board clustered by meaning, each
# cluster drawn in a new untitled frame, the links between clusters cut. Not the owner's plan, which places notes by the topology the lens
# already draws first and by meaning second, with no new groupings (issue 26).
#   1. What holds what comes first: on each board a frame is one piece, and its own notes are grouped inside it.
#   2. Each link is as tight as its two notes are alike: OpenAI's text-embedding-3-large (data/emb-openai-3-large.f16), each note's vector
#      centred on its board's mean, ranked within the board.
#   3. Each board's pieces are grouped into clusters by their links, the tighter counting more (cluster.mjs, Louvain, in key order), and
#      the links between clusters are pills before anything is placed. Each cluster of two or more is a frame of its own (cluster-frames.mjs).
#   4. The layout branch's engine (slice 4, 4bc3494e) draws the rest with no crossing; where it must still cut, the loosest link first.
# Writes out/cl-1-units (the clusters, the cut, the graphs), out/e-units (the drawing) and build/pictures/strategy (a sketch of two boards
# before and after, from the spike's own force placer). About three minutes.
#   git worktree add /tmp/slice4 4bc3494e && DIGEST_TOOL=/tmp/slice4/.claude/skills/canvas-digest/tool sh strategy.sh
# The boards in the app (pictures/strategy/app-*.jpg) were drawn from out/e-units by a build of 4bc3494e and captured there:
#   canvas new "Strategy.canvasboard"   # its id, for --board
#   (cd <a checkout of 4bc3494e> && .claude/skills/canvas-digest/digest apply --out <this folder>/out/e-units --board <id>)
#   canvas capture <Board>.png --board <id> --in <Board> --scale 1
set -eu
cd "$(dirname "$0")"
: "${DIGEST_TOOL:?set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)}"
export DIGEST_TOOL EMB=openai-3-large
mkdir -p build out
U=out/cl-1-units
plan() { node "$1/main.js" plan "$2" data/measure.json "$3" --kinds data/kinds.json --view 1322x893 > "$3.log" 2>&1; }

echo "== the clusters, and the links between them cut"
node cluster.mjs --frames=units --out=$U | cut -c1-200
node cluster-frames.mjs $U $U/graph-framed.json
node cluster-frames.mjs $U $U/graph-framed-weighted.json $U/graph.json
# the clusters, each container's items and the cluster each is in, as kept for the build to match
node -e "const s=require('./$U/stats.json');process.stdout.write(JSON.stringify({made:'cluster.mjs --frames=units, EMB=openai-3-large, resolution 1',boards:s.boards.map((b)=>({board:b.board,levels:b.levels}))},null,1)+'\n')" > $U/groups.json
cmp -s $U/groups.json data/groups.json && echo "the clusters match data/groups.json" || echo "the clusters differ from data/groups.json"

echo "== drawn by slice 4's engine: the cut links pills from the start (simcut.patch), the engine's own cuts the loosest first (engine.patch)"
rm -rf build/simtool && cp -R "$DIGEST_TOOL" build/simtool && (cd build/simtool && patch -p1 -s < ../../engine.patch && patch -p1 -s < ../../simcut.patch)
SIM_CUT=$U/cut.json SIM_KEEPCUT=1 plan build/simtool $U/graph-framed-weighted.json out/e-units
[ -f out-branch/drawing.json ] || plan "$DIGEST_TOOL" data/graph.json out-branch
node strategy-counts.mjs data/graph.json out-branch/drawing.json "slice 4"
node strategy-counts.mjs $U/graph-framed-weighted.json out/e-units/drawing.json "the strategy" $U

echo "== a sketch of Selection and Mentions before and after (build/pictures/strategy), coloured by cluster"
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
