#!/bin/sh
# Runs every measure README.md quotes, from this folder, and draws its pictures again into build/pictures.
# DIGEST_TOOL is the layout branch's canvas-digest tool, the folder that holds main.js and lib/ (commit 4bc3494e of
# claude/canvas-layout-strategy-f81c7d), for instance:
#   git worktree add /tmp/slice4 4bc3494e && DIGEST_TOOL=/tmp/slice4/.claude/skills/canvas-digest/tool sh reproduce.sh
# Needs macOS 14 or later (NaturalLanguage's contextual embedding), node, swiftc and git. Takes about 15 minutes.
set -eu
cd "$(dirname "$0")"
: "${DIGEST_TOOL:?set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)}"
export DIGEST_TOOL
mkdir -p build out
plan() { node "$1/main.js" plan "$2" data/measure.json "$3" --kinds data/kinds.json --view 1322x893 > "$3.log" 2>&1; }

echo '== the vectors'
node texts.mjs
swiftc -O embed.swift -o build/embed
build/embed data
echo '== does similarity carry meaning'
node check-sim.mjs contextual
node judge-input.mjs

echo '== the drawings: main as of the spike (218388bc), and the layout branch'
rm -rf build/main && mkdir -p build/main
(cd "$(git rev-parse --show-toplevel)" && git archive 218388bc .claude/skills/canvas-digest/tool) | tar -x -C build/main
plan build/main/.claude/skills/canvas-digest/tool data/graph.json out-main
plan "$DIGEST_TOOL" data/graph.json out-branch

echo '== the judges, and each way of ranking links against them'
node eval-judge.mjs

echo '== similarity inside the layout branch engine'
node semweights.mjs data/graph-sem.json
plan "$DIGEST_TOOL" data/graph-sem.json out-semcut
rm -rf build/semtool && cp -R "$DIGEST_TOOL" build/semtool && (cd build/semtool && patch -p1 < ../../engine.patch)
plan build/semtool data/graph-sem.json out-semmend
(export SEM_PRECUT=50; plan build/semtool data/graph-sem.json out-pre50)
(export SEM_PRECUT=density; plan build/semtool data/graph-sem.json out-dens)
(export SEM_PRECUT=50 SEM_KEEPCUT=1; plan build/semtool data/graph-sem.json out-pre50nr)

echo '== the force model'
J=module:Selection,module:Mentions,module:Draw,module:Canvas/Model,module:References
node semlayout.mjs --order=sem --sim=mix --out=out/strict
node semlayout.mjs --order=sem --sim=mix --light=1 --out=out/light
node semlayout.mjs --order=struct --sim=mix --light=1 --out=out/light-struct
node semlayout.mjs --order=sem --sim=mix --light=1 --simk=all --precut=density --out=out/combined --boards=$J
node semlayout2.mjs --order=sem --sim=mix --out=out/shared --boards=$J

echo '== health, every board'
for d in out-main out-branch out-semcut out-semmend out-pre50 out-dens out-pre50nr out/strict out/light out/light-struct; do
  printf '%-16s ' "$d"; node score-drawing.mjs "$d/drawing.json"
done
echo '== against the judges'
node agree.mjs main=out-main/drawing.json branch=out-branch/drawing.json semcut=out-semcut/drawing.json semmend=out-semmend/drawing.json \
  pre50=out-pre50/drawing.json dens=out-dens/drawing.json pre50nr=out-pre50nr/drawing.json strict=out/strict/drawing.json \
  light=out/light/drawing.json light-struct=out/light-struct/drawing.json combined=out/combined/drawing.json shared=out/shared/drawing.json
node ceiling.mjs
node combo.mjs

echo '== pictures (build/pictures)'
mkdir -p build/pictures
swiftc -O stitch.swift -o build/stitch
for b in Selection Mentions; do
  set --
  for v in main=out-main branch=out-branch spike=out-pre50 force=out/light; do
    n=${v%%=*} d=${v#*=}
    node render.mjs "$d/drawing.json" "module:$b" "build/pictures/$b-$n.svg" judge/rows.json > /dev/null
    node compose.mjs "build/pictures/$b-$n-panel.svg" "$b: $n=build/pictures/$b-$n.svg" > /dev/null
    qlmanage -t -s 1400 -o build/pictures "build/pictures/$b-$n-panel.svg" > /dev/null 2>&1
    set -- "$@" "build/pictures/$b-$n-panel.svg.png"
  done
  build/stitch "build/pictures/$b.jpg" 2 "$@"
done
node render.mjs out/strict/drawing.json module:Selection build/pictures/collapse.svg judge/rows.json > /dev/null
qlmanage -t -s 1600 -o build/pictures build/pictures/collapse.svg > /dev/null 2>&1

echo '== Selection along the continuum: links cut least alike first, crossings allowed, arrows into frames'
for o in show hide; do for b in 0 0.1 0.25 0.5; do
  node semlayout.mjs --order=sem --sim=mix --simk=all --frames=arrows --nocrowd=1 --budget=$b --others=$o --boards=module:Selection --out=out/cut-$b-$o > /dev/null
  printf 'cut %-4s pills for other boards %-4s ' $b $o; node score-drawing.mjs out/cut-$b-$o/drawing.json module:Selection | tail -1
done; done
for b in 0.1 0.25 0.5; do node cutjudge.mjs "cut $b=out/cut-$b-hide/drawing.json=Selection"; done
for h in 0.5 1; do for b in 0.1 0.25 0.5; do
  node semlayout.mjs --order=sem --sim=mix --simk=all --frames=arrows --nocrowd=1 --budget=$b --others=hide --hub=$h --boards=module:Selection --out=out/hub$h-$b > /dev/null
  printf 'hub penalty %-3s cut %-4s ' $h $b; node score-drawing.mjs out/hub$h-$b/drawing.json module:Selection | tail -1
done; done
node semlayout.mjs --order=sem --sim=mix --simk=all --frames=arrows --nocrowd=1 --oracle=1 --others=hide --boards=module:Selection --out=out/judges-cut > /dev/null
printf 'the judges cut '; node score-drawing.mjs out/judges-cut/drawing.json module:Selection | tail -1
node cutjudge.mjs "the judges cut=out/judges-cut/drawing.json=Selection"
node samecount.mjs
set --
for o in show hide; do for b in 0 0.1 0.25 0.5; do
  pct=$(node -e "console.log(Math.round($b * 100))")
  word=$([ $o = show ] && echo shown || echo hidden)
  node panel.mjs out/cut-$b-$o/drawing.json module:Selection build/pictures/cut-$b-$o.svg "$pct% of links cut, least alike first; pills for other boards $word" judge/rows.json
  qlmanage -t -s 1000 -o build/pictures build/pictures/cut-$b-$o.svg > /dev/null 2>&1
  set -- "$@" build/pictures/cut-$b-$o.svg.png
done; done
build/stitch build/pictures/continuum.jpg 4 "$@"
node panel.mjs out/judges-cut/drawing.json module:Selection build/pictures/judges-cut.svg "cut where both judges chip; pills for other boards hidden" judge/rows.json
qlmanage -t -s 1000 -o build/pictures build/pictures/judges-cut.svg > /dev/null 2>&1
build/stitch build/pictures/judges-cut.jpg 3 build/pictures/cut-0.25-hide.svg.png build/pictures/cut-0.5-hide.svg.png build/pictures/judges-cut.svg.png

echo '== the strategy as stated (springs.mjs): every link an arrow, congestion from k-cores, springs and the break point by similarity'
node springs.mjs --out=out/s-stated
node springs.mjs --frames=arrows --out=out/s-arrows
node springs.mjs --snap=1000 --out=out/s-base > /dev/null
node springs.mjs --snap=1000 --frames=arrows --out=out/s-base-arrows > /dev/null
for d in out-main out-branch out/s-stated out/s-arrows; do printf '%-16s ' "$d"; node score-drawing.mjs "$d/drawing.json"; done
echo '== the readings of the threshold, on Selection'
for s in 1.5 1.75 2; do printf 'stretch, threshold %-5s' $s; node springs.mjs --break=stretch --snap=$s --boards=module:Selection --out=out/s-stretch-$s; done
for s in 1.5 2 3 5; do printf 'strength, threshold %-4s' $s; node springs.mjs --snap=$s --boards=module:Selection --out=out/s-sel-$s; done
echo '== similarity with what each board shares taken out, against the judges'
node springs.mjs --auc=1
node springs.mjs --auc=1 --sim=board
echo '== the five judged boards'
for c in 0 0.5; do node springs.mjs --break=force --sim=board --cut=$c --frames=arrows --boards=$J --out=out/s-force-$c > /dev/null; done
node springs-eval.mjs out/s-base-arrows/drawing.json out-main/drawing.json $J main
node springs-eval.mjs out/s-base-arrows/drawing.json out-branch/drawing.json $J branch
node springs-eval.mjs out/s-base/drawing.json out/s-stated/drawing.json $J 'as stated'
node springs-eval.mjs out/s-base-arrows/drawing.json out/s-arrows/drawing.json $J 'arrows into frames'
for c in 0 0.5; do node springs-eval.mjs out/s-base-arrows/drawing.json out/s-force-$c/drawing.json $J "force below $c"; done

echo '== pictures of the strategy (build/pictures)'
pan() { node panel.mjs "$1/drawing.json" "$2" "build/pictures/$3.svg" "$4" judge/rows.json; qlmanage -t -s 1000 -o build/pictures "build/pictures/$3.svg" > /dev/null 2>&1; }
set --
for b in root module:Selection module:Mentions; do
  t=${b#module:}
  pan out-main $b main-$t "$t: main"
  pan out-branch $b branch-$t "$t: the layout branch"
  pan out/s-stated $b stated-$t "$t: the embedding rule as stated"
  set -- "$@" build/pictures/main-$t.svg.png build/pictures/branch-$t.svg.png build/pictures/stated-$t.svg.png
done
build/stitch build/pictures/strategy.jpg 3 "$@"
set --
for b in Selection Mentions; do
  pan out/s-stated module:$b r1-$b "$b: as stated (breaks on stretch)"
  pan out/s-arrows module:$b r2-$b "$b: links into frames are arrows"
  pan out/s-force-0 module:$b r3-$b "$b: breaks where the force is weak"
  set -- "$@" build/pictures/r1-$b.svg.png build/pictures/r2-$b.svg.png build/pictures/r3-$b.svg.png
done
build/stitch build/pictures/variants.jpg 3 "$@"
set --
for s in 1.5 2 3 5; do pan out/s-sel-$s module:Selection k$s "as stated, threshold $s"; set -- "$@" build/pictures/k$s.svg.png; done
build/stitch build/pictures/threshold.jpg 4 "$@"
