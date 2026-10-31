#!/bin/zsh
# Builds every module but the app (debug), runs every test executable, as many at once as there are
# cores (a failing one doesn't stop the others), and exits non-zero if any failed. Each one's output
# is printed whole, in order, once it's done.
#
#   ./test.sh               every test executable
#   ./test.sh TARGET...     only these: builds only what they're made of (and the command line,
#                           which tests run), and runs only them
#
# An executable that last ran whole and passed isn't run again while it, and what it reads as it
# runs, are as they were then: its binary, the command line's, every file git sees but the Swift
# sources (which reach a test through its binary), the session records and the Markdown outside
# .claude/skills and Tests, the Markdown there that its own sources or the test support's name, and
# the environment variables tests read (every name a test's source asks the environment for, and
# those of the commands they run, by their prefixes).
# It's named at the end as unchanged since it passed; TEST_ALL=1 runs it anyway.
#
# One that took long last time runs as several processes at once, each a share of its suites
# (TestKit's TEST_SHARD), so none holds the run up long after the rest are done; the tests that
# hold a time budget run after the rest, as many at once as half the machine's performance cores. A
# checkout's first run goes by the timings another checkout of the repository kept.
#
# TEST_FILTER=substring runs only the tests whose "Suite: test" name contains it, and fails if that's
# none at all (a filtered run runs every executable it's given, each as one process). TEST_JOBS=N
# runs N at once; TEST_UI_MENUS=1 (tests that open real menus) runs them one at a time.
set -uo pipefail
zmodload zsh/datetime zsh/mathfunc
cd "${0:A:h}"
[[ ${TEST_JOBS:-1} == <1-> ]] || { print -u2 "test.sh: TEST_JOBS is how many run at once, 1 or more; not '$TEST_JOBS'"; exit 2 }
every=(${(f)"$(./build.sh list test)"}) || exit 1
tests=()
for t in $every; do (( ! $# || ${argv[(Ie)$t]} )) && tests+=$t; done
for t; do (( ${every[(Ie)$t]} )) || { print -u2 "test.sh: no test executable $t (./build.sh list test names them)"; exit 2 }; done
./build.sh tests $@ || exit 1

# A Suite runs only if its target's main.swift passes it to runTests, and Swift doesn't warn about
# one that's left out, so check.
unregistered=()
for t in $tests; do
    files=(Tests/$t/**/*.swift(N)); files=(${files:#Tests/$t/main.swift})
    (( ${#files} )) || continue
    registered=$(sed -E 's#//.*##' Tests/$t/main.swift)
    for suite in ${(f)"$(sed -E 's#//.*##' $files | grep -oE '(let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*([[:space:]]*:[[:space:]]*Suite)?[[:space:]]*=[[:space:]]*Suite\(' | sed -E 's/^(let|var)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\2/')"}; do
        [[ $registered =~ "(^|[^A-Za-z0-9_])$suite([^A-Za-z0-9_]|\$)" ]] ||
            unregistered+="Tests/$t: the Suite $suite isn't passed to runTests in main.swift, so it never runs"
    done
done
(( ${#unregistered} )) && { print -u2 -l -- $unregistered; exit 1 }

# What an executable that passed is checked against (above): the hash of its binary, worked out
# again only when the binary's size or time changed, and what every test reads beside it.
binary_hash() {
    local file=build/debug/$1/$1 memo=build/debug/$1/.hash stamp kept=
    stamp=$(stat -f '%z %Fm' $file) || return 1
    [[ -f $memo ]] && kept=$(<$memo)
    [[ ${kept% *} == $stamp ]] || kept="$stamp $(md5 -q $file)"
    print -r -- $kept > $memo
}
for t in $tests build/debug/CanvasCLI(N:t); do binary_hash $t & done
wait
read=() docs=()
for file in ${(0)"$(git ls-files -co --exclude-standard -z)"}; do
    [[ $file == ((Sources|Examples|Tests)/*.swift|history/*) || ! -f $file ]] && continue
    [[ $file == *.md && $file != (.claude/skills|Tests)/* ]] && docs+=$file || read+=$file
done
# The Markdown elsewhere is the docs, and only a test that names a file reads it (one test reads the
# guide, which most commits change): each counts for the executables whose sources name it, or whose
# test support's do (every test folder that isn't an executable's).
typeset -A named  # by test folder: the docs its sources name, one a line
for line in ${(f)"$(grep -roE '"[^"]+\.md"' --include='*.swift' Tests)"}; do
    folder=${${line#Tests/}%%/*} file=${${line#*:\"}%\"}
    (( ${docs[(Ie)$file]} )) && named[$folder]+=$file$'\n'
done
support=(Tests/*(/N:t)); support=(${support:|every})
typeset -A doc_hash
(( ${#docs} )) && paste <(print -rl -- $docs) <(print -rl -- $docs | git hash-object --stdin-paths) | while IFS=$'\t' read -r file hash; do doc_hash[$file]=$hash; done
docs_read() {  # the docs test $1 reads, and their hashes, as one hash
    local file mine=(${(fu)"$(print -rn -- ${named[$1]:-}; for folder in $support; print -rn -- ${named[$folder]:-})"})
    for file in ${(o)mine}; do print -r -- "$file $doc_hash[$file]"; done | md5 -q
}
# Where to find things, which a test passes on to what it runs, and what test.sh sets itself, aren't
# what a test judges.
asked=(${(f)"$(cat Tests/**/*.swift(N) | grep -oE 'environment\["[A-Z][A-Z0-9_]*"\]' | sed -E 's/environment\["(.*)"\]/\1/' | sort -u)"})
asked=(${asked:#(PATH|HOME|SHELL|TMPDIR|USER|TEST_(ALL|JOBS|SHARD|WEIGHTS|SUITE_TIMES))})
inputs=$({
    paste -d' ' <(print -rl -- $read) <(print -rl -- $read | git hash-object --stdin-paths)
    [[ -f build/debug/CanvasCLI/.hash ]] && print -r -- "CanvasCLI $(<build/debug/CanvasCLI/.hash)"
    env | grep -E "^((${(j:|:)asked})|(TEST|BENCH|QUERY|SCHEMA|DIGEST|SKILL|CANVAS)_[A-Z0-9_]*)=" | grep -vE '^TEST_(ALL|JOBS|SHARD|WEIGHTS|SUITE_TIMES)=' | sort
} | md5 -q)
typeset -A key skipped
run=()
for t in $tests; do
    key[$t]="${$(<build/debug/$t/.hash)##* } $inputs $(docs_read $t)"
    if [[ -z ${TEST_ALL:-} && -z ${TEST_FILTER:-} && -f build/debug/$t/passed && "$(head -n 1 build/debug/$t/passed)" == $key[$t] ]]; then
        skipped[$t]=1
    else
        run+=$t
    fi
done

# What each runs as. An executable with suites kept from a whole run runs as two parts: the tests
# that hold a time budget (TestKit marks them, `b`) and the rest (`r`); one without, or a filtered
# run, or one that opens real menus, as one (`a`, all of it, in one process). A part runs as about
# as many shares as it took the time a core gets last time, every part of its kind at once (but none
# under four seconds: a share starts a process, and makes what its suites share, of its own), and no
# more than it has suites. The budgets' shares come last, and while they run no more run at once than
# half the machine's performance cores: a budget is the test thread's own time, which every core busy
# makes about half again as long (the clocks slow, the caches are shared), and it was set with
# little else running. (On an M5's four, TypesTests' budget suites took the same time two at once as
# alone, and a third longer four at once.)
integer jobs=${TEST_JOBS:-$(sysctl -n hw.ncpu)}
[[ -n ${TEST_UI_MENUS:-} ]] && jobs=1
integer quiet=$(( $(sysctl -n hw.perflevel0.physicalcpu 2> /dev/null || sysctl -n hw.physicalcpu) / 2 ))
(( quiet < 1 )) && quiet=1
(( quiet > jobs )) && quiet=jobs
typeset -A took suites parts count left  # by "test.part": seconds and suites last time, its shares; by test: its parts, the shares left
float rest=0 budgets=0 share budgetShare
# The plan and every share read this run's copy of the suites kept, whatever another run writes
# over build/debug/<test>/suites meanwhile: shares that read different ones would deal differently,
# and a suite could run twice or not at all.
tmp=$(mktemp -d -t tests)
trap 'rm -rf -- "$tmp"' EXIT
# Where an executable's suites aren't kept here yet (a checkout's first run, a test new to it), the
# latest any checkout of the repository kept are, in the folder they share: without them a new
# worktree's first run would run each executable as one process (CompositionTests alone for seven
# minutes), the budgets among the rest. They're times and marks only: whether a test passed is never
# taken from another checkout.
shared=${$(git rev-parse --git-common-dir):A}/test-times
for t in $run; do
    parts[$t]=a; took[$t.a]=0
    [[ -f build/debug/$t/took ]] && took[$t.a]=$(<build/debug/$t/took)
    kept=build/debug/$t/suites
    [[ -f $kept ]] || kept=$shared/$t
    if [[ -z ${TEST_FILTER:-} && -z ${TEST_UI_MENUS:-} && -f $kept ]]; then
        cp $kept $tmp/$t.weights
        # Its lines are "seconds<TAB>suite", the suite's tests that hold no time budget, and
        # "seconds<TAB>suite<TAB>budget<TAB>test" for each that does (TestKit's records).
        for part in r b; do
            took[$t.$part]=$(awk -F'\t' -v p=$part '($3 == "budget") == (p == "b") { s += $1 } END { print s + 0 }' $tmp/$t.weights)
            suites[$t.$part]=$(( $(awk -F'\t' -v p=$part '($3 == "budget") == (p == "b") && !seen[$2]++' $tmp/$t.weights | wc -l) ))
        done
        # The rest always, since a suite with no line yet (one added since) runs with them.
        parts[$t]=r
        (( suites[$t.b] )) && parts[$t]="r b"
    fi
    for part in ${=parts[$t]}; do [[ $part == b ]] && budgets+=took[$t.b] || rest+=took[$t.$part]; done
done
(( share = rest / jobs, budgetShare = budgets / quiet ))
(( share < 4 )) && share=4
(( budgetShare < 4 )) && budgetShare=4
for t in $run; do
    left[$t]=0
    for part in ${=parts[$t]}; do
        integer n=1
        case $part in
        r) (( n = ceil(took[$t.r] / share), n > jobs ? (n = jobs) : 0 )) ;;
        b) (( n = ceil(took[$t.b] / budgetShare), n > quiet ? (n = quiet) : 0 )) ;;
        esac
        (( n > ${suites[$t.$part]:-1} )) && n=${suites[$t.$part]:-1}
        (( n < 1 )) && n=1      # the rest with no suite kept: one share, for those added since
        count[$t.$part]=$n; left[$t]=$(( left[$t] + n ))
    done
done
# The longest shares first (by how long each took last time), so none of them starts last; those of
# the budgets after all the rest.
typeset -F 3 each   # fixed, as sort -n reads it (zsh's float is 4.1e+02)
queued() {  # every share of the parts $1 matches, "test part<k>", longest first
    local t part k
    for t in $run; do
        for part in ${=parts[$t]}; do
            [[ $part == $~1 ]] || continue
            (( each = took[$t.$part] / count[$t.$part] ))
            for k in {1..$count[$t.$part]}; do print -r -- "$each $t $part$k"; done
        done
    done | sort -rn | cut -d' ' -f2-
}
queue=(${(f)"$(queued '[ar]')"} ${(f)"$(queued b)"})

# Each share's output goes to this run's own file, so two runs at once don't read each other's,
# then, all of an executable's shares joined, to build/debug/<test>/output.txt.
run_share() {  # runs share $2 of test $1: its part and its number, r2
    local t=$1 job=$2 start=$EPOCHREALTIME given=()
    local part=${job[1]} k=${job[2,-1]}
    case $part in
    r) given=(TEST_WEIGHTS=$tmp/$t.weights TEST_BUDGETS=skip) ;;
    b) given=(TEST_WEIGHTS=$tmp/$t.weights TEST_BUDGETS=only) ;;
    esac
    (( count[$t.$part] > 1 )) && given+=TEST_SHARD=$k/$count[$t.$part]
    env $given TEST_SUITE_TIMES=$tmp/$t.$job.suites build/debug/$t/$t > $tmp/$t.$job.out 2>&1
    local rc=$?
    print -r -- $(( EPOCHREALTIME - start )) > $tmp/$t.$job.took
    return $rc
}
typeset -A finished running status_of  # a test that ended: its status; a share running: its process; a share that ended: its status
# Joins test $1's shares' output, each but for its count, and the counts added up, in one; and
# keeps, from a whole run, how long it took, its suites' times and, if it passed, what it passed as.
# A share that ends before its count (a crash, an exit in a test) fails the test, whatever its status.
join_shares() {
    local t=$1 part k job last rc=0 whole=1 which
    integer passed=0 failed=0
    typeset -F 3 secs=0
    : > $tmp/$t.out; : > $tmp/$t.suites
    for part in ${=parts[$t]}; do
        for k in {1..$count[$t.$part]}; do
            job=$part$k
            (( status_of[$t.$job] )) && rc=1
            secs+=$(<$tmp/$t.$job.took)
            last=$(tail -n 1 $tmp/$t.$job.out)
            if [[ $last =~ '^([0-9]+) passed, ([0-9]+) failed$' ]]; then
                passed+=match[1]; failed+=match[2]
                sed '$d' $tmp/$t.$job.out >> $tmp/$t.out
            else
                whole=0 rc=1
                cat $tmp/$t.$job.out >> $tmp/$t.out
                case $part in
                a) which=$t ;;
                r) which="share $k of $count[$t.r] of $t's suites that hold no time budget" ;;
                b) which="share $k of $count[$t.b] of $t's suites that hold a time budget" ;;
                esac
                print -r -- "test.sh: $which ended (status $status_of[$t.$job]) before its count" >> $tmp/$t.out
            fi
            cat $tmp/$t.$job.suites >> $tmp/$t.suites 2> /dev/null
        done
    done
    (( whole )) && print -r -- "$passed passed, $failed failed" >> $tmp/$t.out
    cp -f $tmp/$t.out build/debug/$t/output.txt
    if [[ -z ${TEST_FILTER:-} ]]; then
        rm -f build/debug/$t/passed
        if (( whole )); then
            print -r -- $secs > build/debug/$t/took
            cp -f $tmp/$t.suites build/debug/$t/suites
            # Whole, in one step, for a run in another checkout reading it meanwhile (and nothing
            # said where that folder can't be written: a sandboxed run's).
            { mkdir -p $shared && cp -f $tmp/$t.suites $shared/$t.$$ && mv -f $shared/$t.$$ $shared/$t } 2> /dev/null
            (( rc == 0 )) && print -r -- "$key[$t]" > build/debug/$t/passed
        fi
    fi
    return $rc
}

failed=() unchanged=()
integer ran=0 shown=0
show() {  # prints test $1's output under its name, and counts what it ran
    (( ${+skipped[$1]} )) && { unchanged+=$1; return }
    print -P "%B── $1%b"
    cat $tmp/$1.out
    (( finished[$1] == 0 )) || failed+=$1
    # runTests ends with "N passed, M failed".
    local output=(${(f)"$(<$tmp/$1.out)"})
    [[ ${output[-1]:-} =~ '^([0-9]+) passed, ([0-9]+) failed$' ]] && ran+=$(( match[1] + match[2] ))
}
stop_tree() {  # a process and every process under it
    local child
    for child in ${(f)"$(pgrep -P $1)"}; do [[ -n $child ]] && stop_tree $child; done
    kill -TERM $1
}
# Stopped (^C, a TERM): the tests still running stop too, those that ended are shown, and those that
# didn't are named, with where their output so far is.
interrupted() {
    setopt local_options no_err_exit
    local t pid outs
    for pid in ${(v)running}; do stop_tree $pid; done 2> /dev/null
    for t in ${tests[shown+1,-1]}; do
        if (( ${+finished[$t]} )); then
            show $t
        elif outs=($tmp/$t.*.out(Nn)); (( ${#outs} )); then
            cat $outs > build/debug/$t/output.txt
            print -u2 "test.sh: $t was stopped; its output so far is in build/debug/$t/output.txt"
        fi
    done
    exit 130
}
trap interrupted INT TERM HUP

for t in ${(k)skipped}; do finished[$t]=0; done
mkfifo $tmp/done
exec {done}<>$tmp/done      # each share writes "name share status" here as it ends
while (( shown < ${#tests} )); do
    while (( ${#queue} )); do
        t=${queue[1]% *}; job=${queue[1]#* }
        # A budget's share waits until fewer than `quiet` run (above).
        room=$jobs; [[ $job == b* ]] && room=$quiet
        (( ${#running} < room )) || break
        # A job started with & ignores ^C, and so would the test it runs: give it back.
        ( trap - INT QUIT; run_share $t $job; print -r -- "$t $job $?" >&$done ) &
        running[$t.$job]="$!"
        shift queue
    done
    if (( ${#running} )); then
        read -r -u $done t job rc
        unset "running[$t.$job]"; status_of[$t.$job]=$rc
        left[$t]=$(( left[$t] - 1 ))
        if (( ! left[$t] )); then join_shares $t; finished[$t]=$?; fi
    fi
    # Print, in order, every test that's done up to the first that isn't.
    while (( shown < ${#tests} )) && (( ${+finished[${tests[shown+1]}]} )); do
        shown+=1
        show ${tests[shown]}
    done
    (( ${#running} || ${#queue} || shown == ${#tests} )) || { print -u2 "test.sh: ${tests[shown+1]} never ran (test.sh's own mistake)"; exit 1 }
done
exec {done}>&-
(( ${#unchanged} )) && print "unchanged since they passed, so not run (TEST_ALL=1 runs them): ${(j:, :)unchanged}"
(( ${#failed} )) && print -u2 "FAILED: ${(j:, :)failed}"
[[ -n ${TEST_FILTER:-} ]] && (( ran == 0 )) && { print -u2 "TEST_FILTER=$TEST_FILTER matched no tests"; exit 1 }
(( ${#failed} )) && exit 1
print "all test executables passed"
