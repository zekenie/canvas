#!/bin/zsh
# Builds the module graph declared in Package.swift with swiftc directly (SwiftPM is broken on
# this machine). Every module becomes a static library plus a .swiftmodule, compiled with only its
# own dependency closure on the include path, as many at once as there are cores (BUILD_JOBS), and
# only as far as a change reaches. Every mode first audits Package.swift and the sources, and stops
# if the real graph differs from the declared one.
#
#   ./build.sh              build build/InfiniteCanvas.app (release), with the command line in it
#                           (build/canvas links to it) and its Quick Look extensions
#   ./build.sh tests        build every module but the app, test executables included (debug)
#   ./build.sh bench        build BenchmarkTests (release) and run it: the performance budgets
#   ./build.sh audit        check the graph and every import, compile nothing
#   ./build.sh graph        print each module's layer, dependencies and dependents
#   ./build.sh dot          print the graph for Graphviz
#   ./build.sh api MODULE   print a module's public interface (its contract)
#   ./build.sh list LAYER   print the names of a layer's modules (default: test)
set -euo pipefail
SELF=${0:A}
cd "${SELF:h}"

die() { print -u2 "build.sh: $*"; exit 1 }

# Which layers each layer may depend on (Package.swift's header says the same in prose). The plugins
# that cut across kinds (horizontals) are four layers, so the direction of an edge between two of them
# follows from their layers: a concern imports the surfaces it shows itself on, a feature (a behavior
# nothing builds on) uses surfaces and concerns and no layer but test may import it, and a language
# knows no concern: a concern fills its engine's points instead.
typeset -A MAY_USE=(
    wire        "wire"
    foundation  "foundation wire"
    ui          "foundation wire"
    surface     "foundation surface"
    concern     "foundation surface concern"
    feature     "foundation surface concern"
    language    "foundation surface language wire"
    vertical    "foundation surface concern"
    app         "foundation ui wire"
    cli         "wire"
    testsupport "foundation testsupport"
    test        "wire foundation ui surface concern feature language vertical testsupport"
)
typeset -A EXECUTABLE_LAYER=(app 1 test 1 cli 1)
# The layers whose targets may be the product, or the tests of it: a line that ends `+ shipped`,
# which links every module the list of what ships names (Package.swift's table, read below).
typeset -A SHIPPING_LAYER=(app 1 test 1 testsupport 1)
# The layers a listed plugin's module is in.
typeset -A PLUGIN_LAYER=(surface 1 concern 1 feature 1 language 1 vertical 1)
# What the command line's executable (the cli layer's) is called once it's built: in the app's
# bundle, at Contents/Helpers/canvas, and build/canvas, a link to it.
CLI_NAME=canvas
# Public types that would shadow a module (`Observation` breaks @Observable's expansion), or
# Swift's `Task` or `Span`: a public `Task` would shadow it in every module that imports the
# declaring one.
RESERVED_TYPE_NAMES=(Observation Foundation AppKit SwiftUI CoreGraphics Swift Task Span)

# An SDK the compiler accepts: SDKROOT if set, else the newest installed one that type-checks
# (`xcrun --show-sdk-path` picks MacOSX27.0.sdk here, which swiftc 6.3 rejects). The choice is
# cached in build/.sdk; delete it (or build/) after changing toolchains.
pick_sdk() {
    [[ -n ${SDKROOT:-} ]] && { print -r -- $SDKROOT; return }
    [[ -f build/.sdk && -d "$(<build/.sdk)" ]] && { print -r -- "$(<build/.sdk)"; return }
    local tmp=$(mktemp -d -t sdkprobe) xcrun_sdk=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)
    typeset -aU candidates=(${xcrun_sdk:+${xcrun_sdk:A}} /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk(N-nOn:A))
    print 'let x = 1' > $tmp/probe.swift
    for candidate in $candidates; do
        if swiftc -sdk $candidate -typecheck $tmp/probe.swift 2>/dev/null; then
            rm -rf -- "${tmp:?}"; mkdir -p build; print -r -- $candidate > build/.sdk; print -r -- $candidate; return
        fi
    done
    rm -rf -- "${tmp:?}"; die "no installed SDK works with $(swiftc --version 2>&1 | head -1); set SDKROOT"
}

# Package.swift as it is before it's read: an audit's pass is kept by this, so an edit saved while
# this script runs is audited the next time.
MANIFEST_READ=$(stat -f '%Fm %z %N' -- Package.swift)

# --- 1. Read the manifest's target table --------------------------------------------------------
typeset -a NAMES
typeset -A DEPS KIND DIR LAYER PATH_ARG SUBJECT
# A target's dependencies as its line writes them (LITERAL), and whether it ends `+ shipped`
# (SHIPS): its DEPS are then those and every module the list names.
typeset -A LITERAL SHIPS
# What ships (`let ships = [` ... `]`): each plugin as Module.Type, in order, and where it's written.
typeset -a SHIPPED_PLUGINS=()
typeset -A SHIPPED_AT
integer lineno=0 in_ships=0 ships_read=0
# The parts of a module (`let parts: ... = [` ... `]`): the modules that have them (PARTED), each one's
# parts in the order written (PARTS), what a part, as Module/Part, uses (PART_USES), and where it's
# written.
typeset -a PARTED=()
typeset -A PARTS PART_USES PART_AT
integer in_parts=0 parts_read=0
PARTS_OPEN='let parts: KeyValuePairs<String, [String]> = ['
PARTS_ROW_RE='^[[:space:]]*"([A-Za-z][A-Za-z0-9]*)/([A-Za-z][A-Za-z0-9]*)": \[(("[A-Za-z][A-Za-z0-9]*"(, "[A-Za-z][A-Za-z0-9]*")*)?)\],[[:space:]]*$'
TARGET_RE='^[[:space:]]*\.(target|executableTarget)\(name: "([A-Za-z][A-Za-z0-9]*)", dependencies: \[(("[A-Za-z][A-Za-z0-9]*"(, "[A-Za-z][A-Za-z0-9]*")*)?)\]( \+ shipped)?(, path: "([^"]+)")?\),[[:space:]]*// layer: ([a-z]+)( of ([A-Za-z][A-Za-z0-9]*))?[[:space:]]*$'
SHIPS_ROW_RE='^[[:space:]]*("[A-Za-z][A-Za-z0-9]*\.[A-Za-z][A-Za-z0-9]*",[[:space:]]*)+$'
while IFS= read -r line || [[ -n $line ]]; do
    lineno+=1
    [[ $line =~ '^[[:space:]]*//' ]] && continue
    if (( in_ships )); then
        if [[ $line == ']' ]]; then
            in_ships=0
        elif [[ $line =~ $SHIPS_ROW_RE ]]; then
            for plugin in ${=${line//[\",]/ }}; do
                (( ${+SHIPPED_AT[$plugin]} )) && die "Package.swift:$lineno: $plugin ships twice (also on line $SHIPPED_AT[$plugin])"
                SHIPPED_PLUGINS+=$plugin
                SHIPPED_AT[$plugin]=$lineno
            done
        elif [[ -n ${line//[[:space:]]/} ]]; then
            die "Package.swift:$lineno: a line of what ships is plugins as \"Module.Type\", each followed by a comma, or a comment on its own:\n    $line"
        fi
    elif (( in_parts )); then
        if [[ $line == ']' ]]; then
            in_parts=0
        elif [[ $line =~ $PARTS_ROW_RE ]]; then
            module=$match[1] part=$match[2]
            (( ${+PART_AT[$module/$part]} )) && die "Package.swift:$lineno: $module/$part is a part twice (also on line $PART_AT[$module/$part])"
            PART_USES[$module/$part]=${${match[3]//\"/}//,/}
            PART_AT[$module/$part]=$lineno
            (( ${+PARTS[$module]} )) || PARTED+=$module
            PARTS[$module]="${PARTS[$module]:+$PARTS[$module] }$part"
        elif [[ -n ${line//[[:space:]]/} ]]; then
            die "Package.swift:$lineno: a line of the parts is \"Module/Part\": [\"A\", \"B\"], the parts of that module it uses, or a comment on its own:\n    $line"
        fi
    elif [[ $line == 'let ships = [' ]]; then
        (( ships_read )) && die "Package.swift:$lineno: what ships is written once"
        in_ships=1 ships_read=1
    elif [[ $line == "$PARTS_OPEN" ]]; then
        (( parts_read )) && die "Package.swift:$lineno: the parts are written once"
        in_parts=1 parts_read=1
    elif [[ $line =~ $TARGET_RE ]]; then
        name=$match[2]
        (( ${+DEPS[$name]} )) && die "Package.swift:$lineno: $name is declared twice"
        NAMES+=$name
        KIND[$name]=$match[1]
        LITERAL[$name]=${${match[3]//\"/}//,/}
        [[ -n $match[6] ]] && SHIPS[$name]=1
        PATH_ARG[$name]=$match[8]
        DIR[$name]=${match[8]:-Sources/$name}
        LAYER[$name]=$match[9]
        [[ -n $match[11] ]] && SUBJECT[$name]=$match[11]
        DEPS[$name]=$LITERAL[$name]
        (( ${+MAY_USE[$LAYER[$name]]} )) || die "Package.swift:$lineno: unknown layer '$LAYER[$name]' (layers: ${(k)MAY_USE})"
    elif [[ $line =~ '\.[A-Za-z]+\([[:space:]]*name:' || $line == *[Tt]arget\(* ]]; then
        die "Package.swift:$lineno: this target doesn't match the one-line form at the top of the file:\n    $line"
    elif [[ $line == *'ships = '* ]]; then
        die "Package.swift:$lineno: what ships opens with exactly \`let ships = [\`, on a line of its own:\n    $line"
    elif [[ $line == 'let parts'* ]]; then
        die "Package.swift:$lineno: the parts open with exactly \`$PARTS_OPEN\`, on a line of its own:\n    $line"
    fi
done < Package.swift
(( ${#NAMES} )) || die "no targets in Package.swift"
(( in_ships )) && die "Package.swift: what ships never closes (a line that is only \`]\`)"
(( in_parts )) && die "Package.swift: the parts never close (a line that is only \`]\`)"
(( ${#SHIPPED_PLUGINS} )) || die "Package.swift lists no plugin that ships (\`let ships = [\` ... \`]\`, before the targets)"

# The modules the list names, once each, in its order: what `+ shipped` links.
typeset -aU SHIPPED_MODULES=()
for plugin in $SHIPPED_PLUGINS; do
    module=${plugin%%.*}
    (( ${+DEPS[$module]} )) || die "Package.swift:$SHIPPED_AT[$plugin]: $plugin ships, but there's no module $module"
    (( ${+PLUGIN_LAYER[$LAYER[$module]]} )) || die "Package.swift:$SHIPPED_AT[$plugin]: $plugin ships, but $module is a $LAYER[$module] module: a plugin's is a surface, concern, feature, language or vertical"
    SHIPPED_MODULES+=$module
done
for name in $NAMES; do
    (( ${+SHIPS[$name]} )) || continue
    (( ${+SHIPPING_LAYER[$LAYER[$name]]} )) || die "$name ($LAYER[$name]) can't say + shipped: only the app, its extension, and the tests of what ships and their support are made of the list"
    for dep in ${=LITERAL[$name]}; do
        (( ${SHIPPED_MODULES[(Ie)$dep]} )) && die "$name lists $dep, which + shipped already links: leave it out of the line"
    done
    DEPS[$name]="${LITERAL[$name]:+$LITERAL[$name] }${SHIPPED_MODULES[*]}"
done
# What depends on a library made of the list is made of it too, and says so.
for name in $NAMES; do
    for dep in ${=LITERAL[$name]}; do
        (( ${+SHIPS[$dep]} && ! ${+SHIPS[$name]} )) && die "$name depends on $dep, which is made of what ships (+ shipped), so its line ends + shipped too"
    done
done
# The list as text, a plugin a line: what the product's executables carry (below: SHIPPED_TEXTS).
SHIPPED_LIST=build/shipped/plugins.txt
mkdir -p ${SHIPPED_LIST:h}
[[ -f $SHIPPED_LIST && "$(<$SHIPPED_LIST)" == "${(F)SHIPPED_PLUGINS}" ]] || print -rl -- $SHIPPED_PLUGINS > $SHIPPED_LIST

# --- 2. Check each target's place, layer and dependencies ----------------------------------------
for name in $NAMES; do
    layer=$LAYER[$name]
    if [[ $layer == test* ]]; then
        [[ $DIR[$name] == Tests/$name ]] || die "$name: $layer targets live in Tests/$name (path: \"Tests/$name\")"
    else
        [[ $DIR[$name] == (Sources|Examples)/$name ]] || die "$name: $layer targets live in Sources/$name or Examples/$name"
    fi
    if [[ ! -d $DIR[$name] ]]; then
        [[ -d Examples/$name ]] && die "$name lives in Examples/$name, so its line needs path: \"Examples/$name\""
        die "$name: no directory $DIR[$name]"
    fi
    srcs=($DIR[$name]/**/*.swift(N))
    (( ${#srcs} )) || die "$name has no Swift sources in $DIR[$name]"
    if (( ${+EXECUTABLE_LAYER[$layer]} )); then
        [[ $KIND[$name] == executableTarget ]] || die "$name: layer $layer must be an .executableTarget"
    else
        [[ $KIND[$name] == target ]] || die "$name: layer $layer must be a .target"
    fi
    # What its line writes: the modules + shipped adds are the list's, checked where it's read.
    typeset -a deps=(${=LITERAL[$name]})
    typeset -aU distinct=($deps)
    (( ${#deps} == ${#distinct} )) || die "$name lists a dependency twice"
    for dep in $deps; do
        (( ${+DEPS[$dep]} )) || die "$name depends on $dep, which Package.swift doesn't declare"
        [[ $dep != $name ]] || die "$name depends on itself"
        [[ $KIND[$dep] == target ]] || die "$name depends on $dep, an executable"
        (( ${${(A)=MAY_USE[$layer]}[(Ie)$LAYER[$dep]]} )) ||
            die "$name ($layer) may not depend on $dep ($LAYER[$dep]); $layer may use: $MAY_USE[$layer]"
    done
done
for dir in {Sources,Examples,Tests}/*(/N); do
    [[ ${DIR[${dir:t}]:-} == $dir ]] || die "$dir isn't a target in Package.swift"
done
for file in {Sources,Examples,Tests}/*.swift(N); do die "$file isn't in any target's directory"; done

# The parts of a module that has them (Package.swift's table): folders of its directory, in an order
# they could be built in. A part uses only parts written above it, so there is no cycle, and names
# all of what those use, so its line says everything it compiles with (the build type-checks it with
# exactly those: build_job's `parts`). Every folder of such a module is a part, so no source is in
# none; the sources beside the folders are the module's own, and may use every part.
for module in $PARTED; do
    (( ${+DEPS[$module]} )) || die "Package.swift:$PART_AT[$module/${PARTS[$module]%% *}]: parts of $module, which isn't a module here"
    typeset -a above=()
    for part in ${=PARTS[$module]}; do
        at=Package.swift:$PART_AT[$module/$part]
        [[ -d $DIR[$module]/$part ]] || die "$at: $module/$part is a part, but there's no folder $DIR[$module]/$part"
        srcs=($DIR[$module]/$part/**/*.swift(N))
        (( ${#srcs} )) || die "$at: $module/$part has no Swift sources in $DIR[$module]/$part"
        typeset -a uses=(${=PART_USES[$module/$part]})
        typeset -aU distinct=($uses)
        (( ${#uses} == ${#distinct} )) || die "$at: $module/$part names a part twice"
        for used in $uses; do
            (( ${above[(Ie)$used]} )) ||
                die "$at: $module/$part uses $used, which isn't a part of $module written above it (a part uses only parts above it)"
            for under in ${=PART_USES[$module/$used]}; do
                (( ${uses[(Ie)$under]} )) ||
                    die "$at: $module/$part uses $used, which uses $under, so its line names $under too (a line says all its part compiles with)"
            done
        done
        above+=$part
    done
    for dir in $DIR[$module]/*(/N); do
        (( ${above[(Ie)${dir:t}]} )) || die "$dir isn't a part of $module in Package.swift's table: every folder of a module that has parts is one"
    done
done

# --- 3. Topological order (stable, in manifest order); a cycle is printed as a path -------------
typeset -a ORDER
typeset -A PLACED
while (( ${#ORDER} < ${#NAMES} )); do
    progressed=0
    for name in $NAMES; do
        (( ${+PLACED[$name]} )) && continue
        ready=1
        for dep in ${=DEPS[$name]}; do (( ${+PLACED[$dep]} )) || { ready=0; break }; done
        (( ready )) && { ORDER+=$name; PLACED[$name]=1; progressed=1 }
    done
    if (( ! progressed )); then
        for node in $NAMES; do (( ${+PLACED[$node]} )) || break; done
        typeset -a walk=($node)
        while true; do
            for dep in ${=DEPS[$node]}; do (( ${+PLACED[$dep]} )) || { node=$dep; break }; done
            if (( ${walk[(Ie)$node]} )); then
                typeset -a cycle=(${walk[${walk[(ie)$node]},-1]} $node)
                die "dependency cycle: ${(j: -> :)cycle}"
            fi
            walk+=$node
        done
    fi
done

# Transitive dependencies: compiling needs their .swiftmodules on -I.
typeset -A CLOSURE
for name in $ORDER; do
    typeset -aU acc=()
    for dep in ${=DEPS[$name]}; do acc+=($dep ${=CLOSURE[$dep]}); done
    CLOSURE[$name]="${acc[*]}"
done
# What a module compiles against, and may name: its dependencies, all the way down. The app and its
# extension link what ships and name none of it, so theirs leaves the list's modules out: a plugin's
# types aren't on their include path at all.
typeset -A VISIBLE
for name in $ORDER; do
    VISIBLE[$name]=$CLOSURE[$name]
    (( ${+SHIPS[$name]} )) && [[ $LAYER[$name] == app ]] || continue
    typeset -aU acc=()
    for dep in ${=LITERAL[$name]}; do acc+=($dep ${=CLOSURE[$dep]}); done
    VISIBLE[$name]="${acc[*]}"
done

# The product's text files (Shipped/*.txt): what the product says in a file, not in a module
# (--ask's prompt, whose examples name the shipped kinds, which no module knows all of), and the list
# of what ships, as text (SHIPPED_LIST, written above from Package.swift's table). Each is put in
# every executable that is the product, as a section of its text segment named for the file (`__`,
# then its name with `-` as `_`), where the core's ShippedText reads it back: no path to look under,
# and no module that holds it. A section's name is at most 16 characters, so a file's is at most 14.
SHIPPED_TEXTS=(Shipped/*.txt(N))
for shipped in $SHIPPED_TEXTS; do
    [[ ${shipped:t:r} =~ '^[a-z][a-z0-9-]{0,13}$' ]] ||
        die "$shipped: a shipped text's name is lowercase letters, digits and hyphens, at most 14 characters (it names a section of the binary)"
    [[ ${shipped:t} != ${SHIPPED_LIST:t} ]] || die "$shipped: that name is the list of what ships, which is Package.swift's table"
done
SHIPPED_TEXTS+=($SHIPPED_LIST)
# The executables that are the product: those whose lines end + shipped.
is_product() { [[ $KIND[$1] != target ]] && (( ${+SHIPS[$1]} )) }
# The executables the app carries: those whose lines say `// layer: app of <the app>`. An app
# extension runs on its own, started by macOS, so it is bundled apart from the app (staged below).
carried() { [[ $LAYER[$1] == app ]] && (( ${+SUBJECT[$1]} )) }

# A test target named after a module (<M>Tests) tests M on its own: it may use M, what M uses,
# and testsupport and ui modules, so that (say) SelectionTests can't lean on a shape kind. One named
# after a plugin of M rather than M (TitleQueriesTests, of Titles) says so, `// layer: test
# of M`, and is held the same way. An app that says `// layer: app of A` is an extension that A
# carries (A is an app with no `of` of its own, as only the app carries one). It need not depend on
# A, since an executable can't depend on one.
for name in $NAMES; do
    if (( ${+SUBJECT[$name]} )); then
        subject=$SUBJECT[$name]
        if [[ $LAYER[$name] == app ]]; then
            [[ -n ${DEPS[$subject]+1} ]] || die "$name is carried by $subject, which isn't a module here"
            [[ $LAYER[$subject] == app ]] && (( ! ${+SUBJECT[$subject]} )) ||
                die "$name is carried by $subject ($LAYER[$subject]${SUBJECT[$subject]:+ of $SUBJECT[$subject]}), but only the app carries an extension: an app with no 'of' of its own"
            continue
        fi
        [[ $LAYER[$name] == test ]] || die "$name ($LAYER[$name]) can't say 'of': only a test says what it tests (// layer: test of <module>), and only an extension what carries it (// layer: app of <the app>)"
        [[ -n ${DEPS[$subject]+1} ]] || die "$name tests $subject, which isn't a module here"
        [[ $LAYER[$subject] != test* ]] || die "$name tests $subject, a $LAYER[$subject] target: a test is of a module"
        [[ -n ${DEPS[${name%Tests}]+1} ]] && die "$name is named after ${name%Tests}, so it tests that: drop 'of $subject'"
        (( ${${(A)=DEPS[$name]}[(Ie)$subject]} )) || die "$name tests $subject, so it depends on $subject"
    else
        subject=${name%Tests}
        [[ $LAYER[$name] == test && $subject != $name && -n ${DEPS[$subject]+1} ]] || continue
    fi
    for dep in ${=DEPS[$name]}; do
        [[ $dep == $subject || $LAYER[$dep] == (testsupport|ui) ]] && continue
        (( ${${(A)=CLOSURE[$subject]}[(Ie)$dep]} )) ||
            die "$name tests $subject, so it may use only $subject, $subject's dependencies, and testsupport and ui modules; not $dep"
    done
done

# --- 4. SwiftPM must read the same graph ---------------------------------------------------------
# Package.swift is Swift, so code below the targets (or a target inside /* */) could give SwiftPM
# and Xcode a different graph than the table above. Evaluate it the way SwiftPM does, and require
# the same targets, kinds, paths and dependencies. Cached by the file's content.
check_manifest() {
    local cache=build/manifest
    if ! cmp -s Package.swift $cache/Package.swift || [[ ! -s $cache/package.json ]]; then
        local api=${$(xcrun --find swiftc 2>/dev/null):h:h}/lib/swift/pm/ManifestAPI
        [[ -d $api ]] || api=/Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI
        [[ -d $api ]] || die "can't find SwiftPM's ManifestAPI, so can't check Package.swift"
        [[ "$(head -1 Package.swift)" =~ '^// swift-tools-version: *([0-9.]+)' ]] || die "Package.swift doesn't start with its swift-tools-version"
        rm -rf -- $cache; mkdir -p $cache
        swiftc -sdk $(pick_sdk) -I $api -L $api -lPackageDescription -Xlinker -rpath -Xlinker $api \
            -package-description-version $match[1] -swift-version 6 Package.swift -o $cache/manifest ||
            die "Package.swift isn't a valid SwiftPM manifest"
        $cache/manifest -fileno 1 > $cache/package.json || die "Package.swift failed when run as SwiftPM runs it"
        cp Package.swift $cache/Package.swift
    fi
    (( ${+commands[jq]} )) || die "reading SwiftPM's evaluation of Package.swift needs jq"
    local table=$(for name in $NAMES; do
        print -r -- $name ${${KIND[$name]/executableTarget/executable}/target/regular} ${PATH_ARG[$name]:-default} ${=DEPS[$name]}
    done)
    # One line per target, as above; any other dependency form or target setting is printed whole.
    local swiftpm=$(jq -r '
        (.package.dependencies[] | "package dependency: \(tojson)"),
        (.package.targets[] |
            [.name, (.type | keys[0]), (.path // "default")]
            + [.dependencies[] | if ((.byName // {}) | keys) == ["name"] then .byName.name else tojson end]
            + [del(.name, .type, .path, .dependencies, .packageAccess, .swiftSettings)
               | with_entries(select(.value != null and .value != [])) | select(length > 0) | tojson]
            | join(" "))' $cache/package.json)
    [[ $table == "$swiftpm" ]] ||
        die "Package.swift, as SwiftPM evaluates it, isn't the one-line table build.sh reads:\n$(diff <(print -r -- $table) <(print -r -- $swiftpm) | grep '^[<>]' | sed 's/^</  table: /; s/^>/  SwiftPM:/')"
}
check_manifest

# --- 5. Audit the sources against the table ------------------------------------------------------
# What the checks read of each module (its imports, and its code without comments) is kept in
# build/audit, and read again only for a module whose sources changed, or when this script or the
# compiler did. A pass is kept too, by every input's name, size and mtime, so auditing what already
# passed costs one stat.
AUDIT=$(mktemp -d -t build-audit)
# However this script ends (an error, ^C, a TERM), what it started stops with it, compilers too, so
# nothing goes on writing into build/ after it. (zsh runs the EXIT trap on a signal only if the
# signal is trapped too.)
typeset -A READING RUNNING  # the audit's reads, and the build's jobs, running: their processes
stop_tree() {  # a process and every process under it
    local child
    for child in ${(f)"$(pgrep -P $1)"}; do [[ -n $child ]] && stop_tree $child; done
    kill -TERM $1
}
stop_all() {
    setopt local_options no_err_exit no_unset
    local pid
    for pid in ${(v)READING} ${(v)RUNNING}; do stop_tree $pid; done 2> /dev/null
    rm -rf -- "$AUDIT"
}
trap stop_all EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
AUDITED=build/audit
COMPILER=(${(f)"$(swiftc --version 2>&1)"})
SOURCES=(); for name in $NAMES; do SOURCES+=($DIR[$name]/**/*.swift(N)); done
READ_BY="$COMPILER[1]"$'\n'"$(stat -f '%Fm %z %N' -- $SELF)"
typeset -A READS            # each module's sources, as stat prints them
for line in ${(f)"$(stat -f '%Fm %z %N' -- $SOURCES)"}; do
    file=${line#* * }
    READS[${${file#*/}%%/*}]+=$'\n'$line
done
PASSED="$READ_BY"$'\n'"$MANIFEST_READ"
for name in $NAMES; do PASSED+=$'\n'"$name$READS[$name]"; done

# JSON Schema's keywords (draft 2020-12, less those that start with `$`), which schemas write as members'
# names wherever they're built or read.
SCHEMA_KEYWORDS='(prefixItems|items|contains|additionalProperties|properties|patternProperties|dependentSchemas|propertyNames|if|then|else|allOf|anyOf|oneOf|not|unevaluatedItems|unevaluatedProperties|type|const|enum|multipleOf|maximum|exclusiveMaximum|minimum|exclusiveMinimum|maxLength|minLength|pattern|maxItems|minItems|uniqueItems|maxContains|minContains|maxProperties|minProperties|required|dependentRequired|title|description|default|deprecated|readOnly|writeOnly|examples|format|contentEncoding|contentMediaType|contentSchema)'

# Every source line of the files given with its comments removed, as `file:line:code`. The checks
# below read this, so a comment can neither trip them nor satisfy them. The same pass lists imports
# inside #if, in the file $1.
strip_comments() {
    awk -v conditional=$1 '
        FNR == 1 { nested = 0; depth = 0 }
        {
            code = ""; bare = ""; quoted = 0          # bare: code without string contents
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1); two = substr($0, i, 2)
                if (nested) {                         # inside /* */, which nests in Swift
                    if (two == "*/") { nested--; i++ } else if (two == "/*") { nested++; i++ }
                    continue
                }
                if (quoted) {
                    code = code c
                    if (c == "\\") { i++; code = code substr($0, i, 1) } else if (c == "\"") quoted = 0
                    continue
                }
                if (two == "//") break
                if (two == "/*") { nested = 1; i++; continue }
                if (c == "\"") quoted = 1
                code = code c; bare = bare c
            }
            print FILENAME ":" FNR ":" code
            if (bare ~ /^[ \t]*#if/) depth++
            else if (bare ~ /^[ \t]*#endif/) depth--
            else if (depth > 0 && bare ~ /(^|[^A-Za-z0-9_])import([^A-Za-z0-9_]|$)/) print FILENAME ":" FNR ":" $0 > conditional
        }' "${@:2}"
}

# Where the id check looks for uses (see Ids, below), from `file:line:code` lines on standard input.
# Not uses: symbols' and a kind's own properties' names. Then, for JSON members named by a schema
# keyword, the colons that can't follow a member's name become semicolons: all of a `case`'s, on its
# line and on the lines its pattern list (ending in a comma) or `where` goes on to, and those of a
# line after one ending in a ternary's `?`; and a ternary's on its own line. Last, a subscript's key,
# and a key before a colon where a member's name can start: the start of a line or of a raw string's
# JSON (`#"`), or after a `[`, a `{` or a comma.
id_uses() {
    sed -E -e 's/(^|[^A-Za-z0-9_])(systemImage|systemName|systemSymbolName|named):[[:space:]]*"[^"]*"/\1\2: ""/g' \
           -e 's/(^|[^A-Za-z0-9_])Property\([[:space:]]*"[^"]*"/\1Property(""/g' |
    awk '{
        split($0, part, ":"); prefix = part[1] ":" part[2] ":"; code = substr($0, length(prefix) + 1)
        line = code; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
        isCase = code ~ /(^[ \t]*|[{};][ \t]*|[^A-Za-z0-9_](if|guard|while|for)[ \t]+)case([^A-Za-z0-9_]|$)/
        goesOn = part[1] == file && (last == "?" || (inCase && (last == "," || line ~ /^where([^A-Za-z0-9_]|$)/)))
        if (isCase || goesOn || line ~ /^where([^A-Za-z0-9_]|$)/) gsub(/:/, ";", code)
        inCase = isCase || (goesOn && inCase)
        file = part[1]; last = substr(line, length(line), 1)
        print prefix code
    }' |
    sed -E -e 's/(\?[[:space:]]*"[^"]*"[[:space:]]*):/\1;/g' \
           -e "s/([]A-Za-z0-9_)?!])\\[\"$SCHEMA_KEYWORDS\"\\]/\\1[\"\"]/g" \
           -e "s/(^[^:]*:[0-9]+:[[:space:]]*|[[{,][[:space:]]*|#\")\"$SCHEMA_KEYWORDS\"[[:space:]]*:/\\1\"\":/g"
}

# What the checks read of module $1, into build/audit/modules/$1.*: its imports, as the compiler
# parses them (a grep misses `import A; import B`, `@_spi(S) import B`, `import /* x */ B`, an import
# split over two lines, backticks...; this is parse-only, no SDK, no -I, so it's quick), its code
# without comments, the imports inside #if, and where the id check looks for uses.
read_module() {
    local name=$1 read=$AUDITED/modules/$1 srcs=($DIR[$1]/**/*.swift(N))
    rm -f -- $read.*(N)
    swiftc -emit-imported-modules $srcs -o $read.imports 2> $read.errors || return 1
    strip_comments $read.conditional $srcs > $read.code || return 1
    id_uses < $read.code > $read.uses || return 1
    print -r -- "$READ_BY$READS[$name]" > $read.read
}

# Prints `file:line` of a `file:line:code` line.
at() { print -r -- "${1%%:*}:${${1#*:}%%:*}" }
# The lines of $CODE that match an extended regex.
matching() { grep -E -- $1 $CODE || true }

audit_sources() {
    typeset -aU problems=()     # unique: two checks may report the same line

    # Read the modules that changed since they were last read, all at once.
    mkdir -p $AUDITED/modules
    for name in $NAMES; do
        [[ -f $AUDITED/modules/$name.read && "$(<$AUDITED/modules/$name.read)" == "$READ_BY$READS[$name]" ]] && continue
        read_module $name &
        READING[$name]="$!"
    done
    typeset -a unparsed=()
    for name in ${(k)READING}; do wait $READING[$name] || unparsed+=$name; done
    READING=(); unparsed=(${NAMES:*unparsed})
    (( ${#unparsed} )) && die "${(j:, :)unparsed} doesn't parse:\n$(cat $AUDITED/modules/${^unparsed}.errors)"
    CODE=$AUDIT/code
    cat -- $AUDITED/modules/${^NAMES}.code > $CODE

    # The compiler's parse has no -I and no -D, so every import must be unconditional, and nothing
    # may ask whether a project module is on the include path.
    for hit in ${(f)"$(cat -- $AUDITED/modules/${^NAMES}.conditional(N) /dev/null)"}; do
        problems+="$hit  <- an import inside #if; imports must not depend on the build"
    done
    for hit in ${(f)"$(matching "canImport\([[:space:]]*(${(j:|:)NAMES})([^A-Za-z0-9_]|\$)")"}; do
        problems+="$hit  <- canImport of a project module; depend on it in Package.swift instead"
    done
    for hit in ${(f)"$(matching '@(_exported|_implementationOnly|testable)([^A-Za-z0-9_]|$)')"}; do
        problems+="$hit  <- this attribute hides or bends a dependency edge; use a plain import"
    done

    # Imports must be exactly the declared dependencies: none missing, none extra.
    import_site() {  # "file:line: " of module $1's import of $2 (or of a line that starts with $2)
        local hits=(${(f)"$(matching "^$DIR[$1]/[^:]*:[0-9]+:((.*[^A-Za-z0-9_])?import([^A-Za-z0-9_].*)?[^A-Za-z0-9_]|[[:space:]\`]*)$2([^A-Za-z0-9_]|\$)")"})
        (( ${#hits} )) || return 0
        print -rn -- "$(at $hits[1]): "
    }
    # What + shipped adds to a line is linked, not imported: the app and its extension import none
    # of it (they name no plugin), and the tests of what ships, and their support, import the modules
    # they call and no more need be said.
    for name in $ORDER; do
        typeset -aU used=()
        for imported in ${(f)"$(<$AUDITED/modules/$name.imports)"}; do
            (( ${+DEPS[$imported]} )) || continue                      # a system module
            used+=$imported
            if (( ${${(A)=LITERAL[$name]}[(Ie)$imported]} )); then
                continue
            elif (( ${+SHIPS[$name]} && ${SHIPPED_MODULES[(Ie)$imported]} )); then
                [[ $LAYER[$name] == app ]] &&
                    problems+="$(import_site $name $imported)$name imports $imported, a module of what ships: the $LAYER[$name] names no plugin (what it takes of one comes through the registry)"
            else
                problems+="$(import_site $name $imported)$name imports $imported, but Package.swift doesn't list it as a dependency of $name"
            fi
        done
        for dep in ${=LITERAL[$name]}; do
            (( ${used[(Ie)$dep]} )) || problems+="$name lists $dep in Package.swift but never imports it"
        done
    done

    # Every plugin that ships is a public struct of its module that can be made with no arguments
    # (a ListedPlugin, or an OutwardPlugin, which is one): the core makes it by its name, so a name
    # with nothing behind it would be found only when the product starts.
    for plugin in $SHIPPED_PLUGINS; do
        declared=$(matching "^$DIR[${plugin%%.*}]/[^:]*:[0-9]+:[[:space:]]*public[[:space:]]+struct[[:space:]]+${plugin#*.}[[:space:]]*:[^{]*[^A-Za-z0-9_](ListedPlugin|OutwardPlugin)([^A-Za-z0-9_]|\$)")
        [[ -n $declared ]] || problems+="Package.swift:$SHIPPED_AT[$plugin]: $plugin ships, but ${plugin%%.*} declares no \`public struct ${plugin#*.}: ListedPlugin\` (a plugin made with no arguments)"
    done

    SHADOWING="${(j:|:)NAMES}|${(j:|:)RESERVED_TYPE_NAMES}"
    for hit in ${(f)"$(matching "^[^:]+:[0-9]+:[[:space:]]*(@[A-Za-z]+[[:space:]]+)*(public|open)[[:space:]]+(final[[:space:]]+)?(struct|class|enum|protocol|actor|typealias)[[:space:]]+($SHADOWING)([^A-Za-z0-9_]|\$)")"}; do
        [[ $hit =~ "(struct|class|enum|protocol|actor|typealias)[[:space:]]+($SHADOWING)" ]] || continue
        [[ $match[2] == (Task|Span) ]] && what="Swift's $match[2]" || what="the module $match[2]"
        problems+="$(at $hit): a public type named $match[2] shadows $what"
    done

    # Ids: a module may write another module's ShapeKind, PluginID, ToolID, PropertyKey, ChannelID
    # (Connections') or EdgeTypeID (Topology's) as a string only if it depends on that module. The graph
    # already keeps a module from naming another's types; this keeps it from reaching that module's
    # shapes, tools, plugins, added properties, channels or edge types by string instead. A module owns
    # the ids its non-test code declares: as a static member (`static let kind: ShapeKind = "sticky-note"`,
    # `static let arrow: ToolID = "arrow"`, `static let key: PropertyKey = "title"`,
    # `static let id: ChannelID = "note-link"`, `static let id: EdgeTypeID = "mention"`) or as a
    # plugin's `id` (`var id: PluginID { "sticky-notes" }`). Test fixtures' ids
    # ("box", "card") are ordinary words, so they own nothing. Any other string literal is a use,
    # except an SF Symbol or asset name (the argument of systemImage:, systemName:, systemSymbolName:
    # or named:), which only looks like one, and a kind's own property's name (`Property("title", ...)`),
    # which is only that kind's; nor is a JSON member named by one of JSON Schema's keywords, which ids
    # may be too (Titles' `title`): a subscript's key (`json["title"]`), or a key before a colon where
    # a member's name can start (`["title": ...]`, `, "title": ...`, `"title" : ...` beginning a line
    # of JSON text), but never in a `case`'s patterns or its `where` (on its line, or the lines a
    # pattern list or a `where` goes on to) or a ternary's (after its `?`, on its line or the next).
    # Any other member's name is a use: a module can't read another's property out of a shape's JSON
    # (`json["locked"]`) without depending on it. (`id_uses`, above, finds where uses can be.) An id
    # spelled as the core's own member every box kind has (`BoxShapeProps.frame`), as Frames' kind is,
    # can't be told from it by its spelling, and every box's props write it: it's an ordinary word, as
    # a fixture's id is, and owns nothing. So is one spelled as a board's own member that records its
    # kinds' versions (`schema`, before format 3), as Types' property is, which every board written by
    # hand in a test, and `canvas kinds --schema`'s answer, say. And one that is an English word every
    # message uses, as Types' `is` is ("a note is a", and the query engine's own "is" in its messages).
    # And one that is a word of the data any test or message may hold, as Colors' `color` is (a field
    # called color, the text "color" searched for).
    #
    # The forms a module declares an id in are written once, here: the regex below takes the id's types
    # (`id_declaration`), and the layer checks, after, read the same forms for ShapeKind and PropertyKey,
    # and the forms of an extension point (POINT_DECL), through `declarations`.
    ORDINARY_IDS=(color frame is schema)
    id_declaration() {  # a regex for a declaration of an id of one of the types $1 (alternatives, in a group)
        print -r -- '((let|var)[[:space:]]+id|static[[:space:]]+(let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*)[[:space:]]*(:[[:space:]]*('$1')[[:space:]]*(=|\{)|=[[:space:]]*('$1')\((rawValue:)?)[[:space:]]*"[^"\\]+"'
    }
    ID_DECL=$(id_declaration 'ShapeKind|PluginID|ToolID|PropertyKey|ChannelID|EdgeTypeID')
    KIND_DECL=$(id_declaration ShapeKind)
    KEY_DECL=$(id_declaration PropertyKey)
    # A type that conforms to ExtensionPoint or KeyedExtensionPoint in the inheritance clause of its own
    # declaration or of an extension of it (on one line: the form every point is written in). The
    # protocols themselves, Canvas's, are not a declaration of a point.
    POINT_DECL='(^|[^A-Za-z0-9_])(enum|struct|class|actor|extension)[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*(<[^>{]*>)?[[:space:]]*:([^{]*[^A-Za-z0-9_])?(Keyed)?ExtensionPoint([^A-Za-z0-9_]|$)'
    declarations() {  # a line `module<TAB>file:line<TAB>text` for each declaration of regex $1 in a non-test module
        local hit rest owner
        for hit in ${(f)"$(matching $1)"}; do
            owner=${${hit#*/}%%/*}                  # Sources/Canvas/Model/Identity.swift:3:... -> Canvas
            [[ $LAYER[$owner] == test* ]] && continue
            rest=${hit#*:*:}
            while [[ $rest =~ $1 ]]; do
                print -r -- "$owner"$'\t'"$(at $hit)"$'\t'"$MATCH"
                rest=${rest[MEND+1,-1]}
            done
        done
    }
    typeset -A ID_OWNERS
    for decl in ${(f)"$(declarations $ID_DECL)"}; do
        fields=("${(@ps:\t:)decl}")
        id=${${fields[3]%\"}##*\"}
        (( ${ORDINARY_IDS[(Ie)$id]} )) || ID_OWNERS[$id]+=" $fields[1]"
    done
    if (( ${#ID_OWNERS} )); then
        print -rl -- \"${(k)^ID_OWNERS}\" > $AUDIT/ids
        for hit in ${(f)"$(cat -- $AUDITED/modules/${^NAMES}.uses | grep -F -f $AUDIT/ids || true)"}; do
            user=${${hit#*/}%%/*}
            for id in ${(k)ID_OWNERS}; do
                [[ ${hit#*:*:} == *\"$id\"* ]] || continue
                for owner in ${=ID_OWNERS[$id]}; do
                    [[ $owner == $user ]] || (( ${${(A)=VISIBLE[$user]}[(Ie)$owner]} )) ||
                        problems+="$(at $hit): \"$id\" is $owner's id, but $user doesn't depend on $owner"
                done
            done
        done
    fi
    # What a layer is for. Each plugin layer but a language says what its modules declare,
    # so the layer a module is in can be told from its code (Package.swift's header gives each layer's
    # question). A vertical is a kind: it declares a ShapeKind. A concern gives shapes a meaning: it
    # declares an extension point or a property (a PropertyKey). A surface is something others build
    # on: it declares an extension point, or another plugin module imports it. A feature is none of
    # those: it declares no kind, no point and no property (and no layer but test may import a feature,
    # so no plugin does). The scan reads the forms above, so a declaration in another form
    # (a typealias, a macro) would be missed: that fails safe for the three layers that need a
    # declaration, and lets a feature pass, so a new form is added to the declarations above.
    typeset -A KIND_AT KEY_AT POINT_AT BUILT_ON
    for decl in ${(f)"$(declarations $KIND_DECL)"}; do
        fields=("${(@ps:\t:)decl}"); : ${KIND_AT[$fields[1]]:=$fields[2]: ${${fields[3]%\"}##*\"}}
    done
    for decl in ${(f)"$(declarations $KEY_DECL)"}; do
        fields=("${(@ps:\t:)decl}"); : ${KEY_AT[$fields[1]]:=$fields[2]: ${${fields[3]%\"}##*\"}}
    done
    for decl in ${(f)"$(declarations $POINT_DECL)"}; do
        fields=("${(@ps:\t:)decl}"); : ${POINT_AT[$fields[1]]:=$fields[2]}
    done
    for name in $NAMES; do
        (( ${+PLUGIN_LAYER[$LAYER[$name]]} )) || continue
        for dep in ${=LITERAL[$name]}; do BUILT_ON[$dep]=$name; done
    done
    for name in $NAMES; do
        case $LAYER[$name] in
        vertical)
            (( ${+KIND_AT[$name]} )) ||
                problems+="$name is a vertical, and a vertical is a kind: $name declares no ShapeKind; a cross-cutting behavior is a feature" ;;
        feature)
            (( ${+KIND_AT[$name]} )) &&
                problems+="$KIND_AT[$name]  <- $name is a feature but declares a ShapeKind; a shape kind is a vertical"
            (( ${+POINT_AT[$name]} )) &&
                problems+="$POINT_AT[$name]  <- $name is a feature but declares an extension point; what others fill or build on is a surface, or a concern if it gives shapes a meaning"
            (( ${+KEY_AT[$name]} )) &&
                problems+="$KEY_AT[$name]  <- $name is a feature but declares a PropertyKey; a property shapes carry is a concern's" ;;
        concern)
            (( ${+POINT_AT[$name]} || ${+KEY_AT[$name]} )) ||
                problems+="$name is a concern, and a concern gives shapes a meaning: $name declares neither an extension point nor a PropertyKey; is it a feature?" ;;
        surface)
            (( ${+POINT_AT[$name]} || ${+BUILT_ON[$name]} )) ||
                problems+="$name is a surface, but nothing builds on it: $name declares no extension point and no plugin module imports it; is it a feature?" ;;
        esac
    done
    # The core's host API (what CanvasView calls: input, cursor, drawing) is `@_spi(Host)`. Only the
    # hosting view and tests may `@_spi(Host) import` it; foundation modules declare it. No plugin may
    # use @_spi at all, so the host API stays out of every plugin's reach. Loading the list of what
    # ships whole, its plugins that reach outside the process (the network, the user's pasteboard) as
    # the product has them, is `@_spi(Product)`: the app's and its extension's alone, so a test can't
    # get the real model or the user's pasteboard by leaving an argument out.
    for hit in ${(f)"$(matching '@_spi[[:space:]]*\(')"}; do
        user=${${hit#*/}%%/*}
        if [[ $hit =~ '@_spi[[:space:]]*\([[:space:]]*Product[[:space:]]*\)' ]]; then
            [[ $LAYER[$user] == (foundation|app) ]] ||
                problems+="$hit  <- only the app and its extension load what ships whole (@_spi(Product)); hand over your own plugins for the ones that reach outside the process: ShippedList.plugins(supplying:)"
            # What loads the list is made of it: without + shipped it would link no plugin and carry no list.
            [[ $LAYER[$user] != app ]] || (( ${+SHIPS[$user]} )) ||
                problems+="$hit  <- $user loads what ships, so its line in Package.swift ends + shipped"
        else
            [[ $LAYER[$user] == (foundation|ui|testsupport|test) ]] ||
                problems+="$hit  <- only the ui, testsupport and test layers may import SPI (the core's host API)"
        fi
    done
    (( ${#problems} )) && { print -u2 -l -- $problems; die "audit failed (${#problems} problems)" }
    print -r -- "$PASSED" > $AUDITED/passed
}
# One audit at a time reads and writes build/audit; builds of other configurations can run beside it.
zmodload zsh/system
mkdir -p $AUDITED; : >> $AUDITED/.lock
zsystem flock -f AUDIT_LOCK $AUDITED/.lock
[[ -f $AUDITED/passed && "$(<$AUDITED/passed)" == "$PASSED" ]] || audit_sources
zsystem flock -u $AUDIT_LOCK

# --- 6. Read-only modes ---------------------------------------------------------------------------
MODE=${1:-app}
case $MODE in
audit) print "audit passed: ${#NAMES} modules, acyclic, layers respected, SwiftPM agrees, imports and ids match Package.swift, ${#SHIPPED_PLUGINS} plugins ship${PARTED:+ (the parts of ${(j:, :)PARTED} are checked by a build, not here)}"; exit 0 ;;
graph)
    # A line's own dependencies; what + shipped links is the product's membership, not a design
    # dependency, so it's said once, as the list, after the modules.
    for name in $ORDER; do
        typeset -a users=()
        for other in $ORDER; do (( ${${(A)=LITERAL[$other]}[(Ie)$name]} )) && users+=$other; done
        print "${(r:12:)LAYER[$name]} ${(r:17:)name} -> ${${LITERAL[$name]:-(nothing)}// /, }${SHIPS[$name]:+ + shipped}    <- ${${(j:, :)users}:-(nothing)}"
    done
    print "\nshipped (${#SHIPPED_PLUGINS} plugins, in order): ${(j:, :)SHIPPED_PLUGINS}"
    for module in $PARTED; do
        print "\nparts of $module, each with the parts it uses:"
        for part in ${=PARTS[$module]}; do print "  ${(r:10:)part} -> ${${PART_USES[$module/$part]:-(nothing)}// /, }"; done
    done
    exit 0 ;;
dot)
    print "digraph modules {\n  rankdir=BT; node [shape=box];"
    for name in $ORDER; do
        print "  \"$name\" [label=\"$name\\\\n$LAYER[$name]${SHIPS[$name]:+\\\\n+ shipped}\"];"
        for dep in ${=LITERAL[$name]}; do print "  \"$name\" -> \"$dep\";"; done
    done
    print "}"; exit 0 ;;
list)
    for name in $ORDER; do [[ $LAYER[$name] == ${2:-test} ]] && print $name; done; exit 0 ;;
app|tests|api|bench) ;;
*) die "unknown mode '$MODE'" ;;
esac

# --- 7. Compile ---------------------------------------------------------------------------------
SDK=$(pick_sdk)
ARCH=$(uname -m)
CONFIG=release; [[ $MODE == (tests|api) ]] && CONFIG=debug
OUT=build/$CONFIG
: >> build/.$CONFIG.lock; zsystem flock build/.$CONFIG.lock    # one build of a configuration at a time
SWIFTC=(swiftc -sdk $SDK -target $ARCH-apple-macosx14.0 -swift-version 6 -wmo -warnings-as-errors
        -enable-upcoming-feature MemberImportVisibility)
[[ $CONFIG == release ]] && SWIFTC+=(-O) || SWIFTC+=(-Onone -g -D DEBUG)
# Products built by another compiler, or with other flags, are stale.
FLAGS="$COMPILER[1]: ${SWIFTC[*]}"
mkdir -p $OUT
[[ -f $OUT/.flags && "$(<$OUT/.flags)" == "$FLAGS" ]] || { rm -rf -- "${OUT:?}"; mkdir -p $OUT; print -r -- "$FLAGS" > $OUT/.flags }
# Libraries with no dates in them, so a module rebuilt the same comes out byte for byte the same.
export ZERO_AR_DATE=1

typeset -aU WANTED=()
case $MODE in
app)   WANTED=(InfiniteCanvas ${=CLOSURE[InfiniteCanvas]})
       for name in $NAMES; do
           if [[ $LAYER[$name] == cli && $KIND[$name] == executableTarget ]] || carried $name; then WANTED+=($name ${=CLOSURE[$name]}); fi
       done ;;
tests) for name in $NAMES; do [[ $LAYER[$name] == app ]] && ! carried $name || WANTED+=$name; done ;;
bench) WANTED=(BenchmarkTests ${=CLOSURE[BenchmarkTests]}) ;;
api)   target=${2:?usage: build.sh api MODULE}; (( ${+DEPS[$target]} )) || die "no module $target"
       WANTED=($target ${=CLOSURE[$target]}) ;;
esac

# Whether the command `$@` last ran with exactly these inputs: the command, and the files in
# INPUTS, by name, size and mtime (compared for equality, so a file added, removed, or restored with
# an older mtime counts), as the file $STAMP keeps them. If not, forgets that it ran, and leaves
# what $STAMP should say once it has in $RAN_WITH.
typeset -a INPUTS
up_to_date() {
    RAN_WITH="${(j: :)${(q)@}}"$'\n'"$(stat -f '%Fm %z %N' -- $INPUTS)"
    [[ -f $STAMP && "$(<$STAMP)" == "$RAN_WITH" ]] && return 0
    rm -f -- $STAMP
    return 1
}

# Moves the files a compile left in the directory $1 into the directory $2, but only those that
# differ: a file that came out the same keeps its mtime, so whatever was built from it stays built.
# With `only`, what $2 holds that $1 didn't make goes (an object of a source that's gone).
keep_changed() {
    local file
    if [[ ${3:-} == only ]]; then
        for file in $2/*(DN.); do [[ -e $1/${file:t} ]] || rm -f -- $file; done
    fi
    for file in $1/*(DN.); do cmp -s -- $file $2/${file:t} || mv -f -- $file $2/; done
    rm -rf -- $1
}

# A module is built in up to three jobs, each run only if what it's built from changed:
#   interface  its .swiftmodule, from its sources and its dependencies' interfaces: what compiling
#              anything that imports it reads. The bodies of its functions are skipped (as in the
#              job swiftc splits off itself), so it's quick, and what depends on the module starts
#              compiling long before the module's own code is done. In release that's also why
#              other modules can inline only what it keeps of the module (public static lets'
#              values), never what cross-module optimization makes of its functions: nothing is
#              @inlinable, and the benchmarks measured no difference.
#   object     its code, from the same, an object per source (LLVM's work on them spread over
#              OBJECT_THREADS threads) at fixed paths, so the same inputs make the same bytes; a
#              library's are archived (lib<name>.a), in the order of its sources. In debug an
#              executable's job emits its module too, which its link names for the debugger (as
#              swiftc -g does when it compiles and links at once).
#   link       an executable, from its objects and every library it depends on, and, for one that
#              is the product, the product's text files (SHIPPED_TEXTS).
#   parts      for a module that has parts (Package.swift's table), each part type-checked with only
#              its own sources and those of the parts its line names, in the table's order, stopping
#              at the first that fails: a part that names anything else of the module doesn't
#              compile, as a module that names one it doesn't depend on doesn't. Nothing is made, and
#              nothing waits for it; a part is checked again when a source it compiles with changed.
# What comes out the same as before isn't replaced (keep_changed), so an edit that leaves a module's
# interface as it was (inside a function) compiles none of the modules that depend on it, and one
# that changes nothing it compiles to (a touch, a checkout) links nothing again either. Every
# library links whole (-force_load), even one nothing references by symbol (say, a module that only
# adds protocol conformances), so no code that nothing names is dropped (where `as? any Capability`
# would then quietly fail). Each prints "compiled" or "linked" when it did.
OBJECT_THREADS=4
# Fails the job if module $1's sources ($2...) aren't as they were when this build began (READS): an
# interface and an object compiled from different edits would link, and run wrong.
as_begun() {
    [[ $'\n'"$(stat -f '%Fm %z %N' -- ${@:2})" == "${READS[$1]:-}" ]] && return 0
    print -u2 "build.sh: $1's sources changed while it built; build again"
    return 1
}
build_job() {
    local name=${1%:*} stage=${1##*:} dir=$OUT/${1%:*} dep src
    [[ -n ${DIR[$name]:-} ]] || { print -u2 "build.sh: no module $name (job $1)"; return 1 }
    local srcs=($DIR[$name]/**/*.swift(N)) includes=(${(@)${=VISIBLE[$name]}/#/-I$OUT/})
    INPUTS=($srcs); for dep in ${=VISIBLE[$name]}; do INPUTS+=($OUT/$dep/$dep.swiftmodule); done
    case $stage in
    interface)
        local emit=($SWIFTC -parse-as-library -emit-module -Xfrontend -experimental-skip-non-inlinable-function-bodies-without-types
                    -module-name $name -emit-module-path $dir/interface/$name.swiftmodule $includes $srcs)
        STAMP=$dir/.interface
        [[ -e $dir/$name.swiftmodule ]] || rm -f -- $STAMP
        up_to_date $emit && return 0
        rm -rf -- $dir/interface; mkdir -p $dir/interface
        $emit || return 1
        as_begun $name $srcs || return 1
        keep_changed $dir/interface $dir
        print -r -- "$RAN_WITH" > $STAMP ;;
    object)
        local entry=(-parse-as-library) objects=() products=($dir/lib$name.a) module=()
        if [[ $KIND[$name] != target ]]; then
            products=($dir/objects)
            [[ -n ${(M)srcs:#*/main.swift} ]] && entry=()
            # In debug, the executable's own module too, for the debugger (the link says where it is).
            if [[ $CONFIG == debug ]]; then
                module=(-emit-module -emit-module-path $dir/object/module/$name.swiftmodule)
                products+=($dir/$name.swiftmodule)
            fi
        fi
        # Each source's object, named by its place in the list, so two sources of one name don't collide.
        for src in $srcs; do objects+=$dir/object/$(( ${#objects} + 1 )).o; done
        local compile=($SWIFTC $entry -c -num-threads $OBJECT_THREADS $module -module-name $name $includes
                       -output-file-map $dir/object/objects.json $srcs)
        STAMP=$dir/.object
        local product; for product in $products; do [[ -e $product ]] || rm -f -- $STAMP; done
        up_to_date $compile && return 0
        rm -rf -- $dir/object; mkdir -p $dir/object
        { print '{'; for src in $srcs; do print -r -- "  \"$src\": {\"object\": \"$objects[1]\"},"; shift objects; done; print '  "": {}'; print '}' } > $dir/object/objects.json
        $compile || return 1
        as_begun $name $srcs || return 1
        rm -f -- $dir/object/objects.json
        if [[ $KIND[$name] == target ]]; then
            objects=($dir/object/*.o(Nn))
            libtool -static -o $dir/object/lib$name.a $objects || return 1
            rm -f -- $objects
            keep_changed $dir/object $dir
        else
            [[ -d $dir/object/module ]] && keep_changed $dir/object/module $dir
            mkdir -p $dir/objects
            keep_changed $dir/object $dir/objects only
        fi
        print -r -- "$RAN_WITH" > $STAMP
        print compiled ;;
    parts)
        local part used
        for part in ${=PARTS[$name]}; do
            local with=()
            for used in $part ${=PART_USES[$name/$part]}; do with+=($DIR[$name]/$used/**/*.swift(N)); done
            INPUTS=($with); for dep in ${=VISIBLE[$name]}; do INPUTS+=($OUT/$dep/$dep.swiftmodule); done
            local check=($SWIFTC -parse-as-library -typecheck -module-name $name $includes $with)
            STAMP=$dir/.part.$part
            up_to_date $check && continue
            if ! $check; then
                print -u2 "build.sh: $name/$part doesn't compile with only the parts it uses (${${PART_USES[$name/$part]:-none}// /, }): it names something of another part of $name, or of the sources beside the parts. Package.swift's table of parts says what each may use."
                return 1
            fi
            as_begun $name $srcs || return 1
            print -r -- "$RAN_WITH" > $STAMP
        done ;;
    link)
        local libs=() objects=($dir/objects/*.o(Nn)) debugger=() entry=()
        # An app extension has no main: it starts in Foundation's NSExtensionMain, as Xcode links one.
        carried $name && entry=(-Xlinker -e -Xlinker _NSExtensionMain)
        INPUTS=($objects)
        if [[ $CONFIG == debug ]]; then
            debugger=(-Xlinker -add_ast_path -Xlinker $dir/$name.swiftmodule)
            INPUTS+=($dir/$name.swiftmodule)
        fi
        for dep in ${=CLOSURE[$name]}; do
            libs+=(-Xlinker -force_load -Xlinker $OUT/$dep/lib$dep.a)
            INPUTS+=($OUT/$dep/lib$dep.a)
        done
        # The product's text files and its list of plugins, each a section of the binary (above:
        # SHIPPED_TEXTS).
        local texts=() shipped
        if is_product $name; then
            for shipped in $SHIPPED_TEXTS; do
                texts+=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __${${shipped:t:r}//-/_} -Xlinker $shipped)
                INPUTS+=($shipped)
            done
        fi
        local link=($SWIFTC $objects $libs $debugger $entry $texts -o $dir/$name)
        STAMP=$dir/.linked
        [[ -e $dir/$name ]] || rm -f -- $STAMP
        up_to_date $link && return 0
        $link || return 1
        print -r -- "$RAN_WITH" > $STAMP
        print linked ;;
    esac
    return 0
}

# The jobs, and what each waits for: a module's interface and object, its dependencies' interfaces;
# an executable's link, its object and its dependencies' objects.
typeset -A WAITING USERS     # a job: how many jobs it still waits for; the jobs that wait for it
typeset -a READY=()
add_job() {
    local job=$1 dep; shift
    WAITING[$job]=$#
    for dep; do USERS[$dep]+=" $job"; done
    (( $# )) || READY+=$job
}
for name in $ORDER; do
    (( ${WANTED[(Ie)$name]} )) || continue
    # Braces around each name: `$name:link` would be $name lowercased (zsh's :l), then "ink". Arrays,
    # so ${^...} of no dependencies is no jobs.
    deps=(${=DEPS[$name]}); closure=(${=CLOSURE[$name]}); visible=(${=VISIBLE[$name]})
    if [[ $KIND[$name] == target ]]; then
        add_job ${name}:interface ${^deps}:interface
        add_job ${name}:object ${^deps}:interface
    else
        add_job ${name}:object ${^visible}:interface
        add_job ${name}:link ${name}:object ${^closure}:object
    fi
    (( ${+PARTS[$name]} )) && add_job ${name}:parts ${^deps}:interface
done

# Runs the jobs, as many at once as there are cores (BUILD_JOBS to change that), each as soon as
# what it waits for is done, interfaces first (everything else waits for them). Each one's output is
# printed once it's done; the first failure lets what's running finish, starts nothing more, and
# fails the build.
JOBS=${BUILD_JOBS:-$(sysctl -n hw.ncpu)}
[[ $JOBS == <1-> ]] || die "BUILD_JOBS is how many jobs run at once, 1 or more; not '$JOBS'"
mkfifo $AUDIT/done
exec {DONE}<>$AUDIT/done    # each job writes "job status" here as it ends
typeset -a COMPILED=() LINKED=()
typeset -aU FAILED=()
typeset -A SHOWN            # a module: the output of its jobs last printed (two often say the same)
integer running=0 finished=0
while true; do
    if (( ! ${#FAILED} )); then
        for job in ${(M)READY:#*:interface} ${READY:#*:interface}; do
            (( running < JOBS )) || break
            READY=(${READY:#${(b)job}}); running+=1
            log=$OUT/${job%:*}/.${job##*:}; mkdir -p ${log:h}
            # With errexit and nounset off, and the job in a subshell of its own, so it always says
            # how it ended, even after an error zsh won't go on from.
            ( unsetopt err_exit no_unset; ( build_job $job > $log.did 2> $log.log ); print -r -- "$job $?" >&$DONE ) &
            RUNNING[$job]="$!"
        done
    fi
    (( running )) || break
    # A job says how it ended as its last act, so once none is left alive, what's to read is there.
    until read -r -t 2 -u $DONE job rc; do
        for pid in ${(v)RUNNING}; do kill -0 $pid 2> /dev/null && continue 2; done
        read -r -t 1 -u $DONE job rc && break
        die "${(j:, :)${(k)RUNNING}} ended without saying how (build.sh's own mistake)"
    done
    running+=-1; finished+=1; unset "RUNNING[$job]"
    log=$OUT/${job%:*}/.${job##*:}
    if [[ -s $log.log ]]; then
        text=$(<$log.log)
        [[ ${SHOWN[${job%:*}]:-} == "$text" ]] || print -u2 -r -- "$text"
        SHOWN[${job%:*}]=$text
    fi
    if (( rc )); then
        FAILED+=${job%:*}
        continue
    fi
    case "$(<$log.did)" in
    compiled) COMPILED+=${job%:*} ;;
    linked) LINKED+=${job%:*} ;;
    esac
    for user in ${=USERS[$job]:-}; do
        WAITING[$user]=$(( WAITING[$user] - 1 ))
        (( WAITING[$user] )) || READY+=$user
    done
done
exec {DONE}>&-
(( ${#FAILED} )) && die "${(j:, :)FAILED} failed to build"
(( finished == ${#WAITING} )) || die "$(( ${#WAITING} - finished )) jobs never ran (build.sh's own mistake)"
COMPILED=(${ORDER:*COMPILED}); LINKED=(${ORDER:*LINKED})
if (( ${#COMPILED} + ${#LINKED} )); then
    print -u2 "built ${${(j:, :)COMPILED}:-nothing}${LINKED:+; linked ${(j:, :)LINKED}}"
else
    print -u2 "built nothing (up to date)"
fi

case $MODE in
bench)
    $OUT/BenchmarkTests/BenchmarkTests
    ;;
api)
    xcrun swift-synthesize-interface -sdk $SDK -target $ARCH-apple-macosx14.0 -module-name $target \
        -I$OUT/$target ${(@)${=CLOSURE[$target]}/#/-I$OUT/}
    ;;
app)
    APP=build/InfiniteCanvas.app
    # The bundle changes only where its files do, each replaced by a new file (so a copy of the app
    # that's running keeps its own): macOS checks an executable it hasn't seen the first time it
    # runs, which costs a launch a quarter of a second, and an app that didn't change skips that.
    typeset -a bundled=()
    integer replaced=0      # how many of the bundle's files this build replaced
    install_changed() {  # copies the file $1 to $2, in the bundle, if they differ
        bundled+=$2
        cmp -s -- $1 $2 || { cp -- $1 $2.new && mv -f -- $2.new $2 && replaced+=1 }
    }
    mkdir -p $APP/Contents/MacOS $APP/Contents/Helpers
    install_changed $OUT/InfiniteCanvas/InfiniteCanvas $APP/Contents/MacOS/InfiniteCanvas
    # The command line goes with the app, so the two always speak the same protocol.
    typeset -a clis=()
    for name in $NAMES; do
        if [[ $LAYER[$name] == cli && $KIND[$name] == executableTarget ]]; then clis+=$name; fi
    done
    (( ${#clis} == 1 )) || die "the cli layer should have one executable, the command line; it has ${#clis}"
    install_changed $OUT/$clis[1]/$clis[1] $APP/Contents/Helpers/$CLI_NAME
    ln -sf InfiniteCanvas.app/Contents/Helpers/$CLI_NAME build/$CLI_NAME
    cat > $AUDIT/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Infinite Canvas</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.InfiniteCanvas</string>
    <key>CFBundleExecutable</key>
    <string>InfiniteCanvas</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Infinite Canvas Board</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.example.InfiniteCanvas.board</string>
            </array>
            <key>NSDocumentClass</key>
            <string>BoardDocument</string>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.example.InfiniteCanvas.board</string>
            <key>UTTypeDescription</key>
            <string>Infinite Canvas Board</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.json</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>canvasboard</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.example.InfiniteCanvas.contents-rows</string>
            <key>UTTypeDescription</key>
            <string>Infinite Canvas Shapes</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
    install_changed $AUDIT/Info.plist $APP/Contents/Info.plist
    # Quick Look's preview of a board file (space in the Finder) and its thumbnail (its icon), an
    # extension each (Contents/PlugIns), each the one executable the app carries with its extension
    # point, its principal class and what it says to that point. Quick Look runs an extension only
    # in the sandbox, so each is signed with that entitlement: ad hoc, to run on this Mac (the app
    # isn't signed, and needn't be). Each is signed as a copy, then what changed is installed: ad hoc,
    # the same files sign to the same bytes. Opening the app registers them.
    typeset -a appexes=()
    for name in $NAMES; do
        if carried $name; then appexes+=$name; fi
    done
    (( ${#appexes} == 1 )) || die "the app carries one extension, the Quick Look one; it has ${#appexes}"
    cat > $AUDIT/appex.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
</dict>
</plist>
PLIST
    for appex point principal attributes in \
        QuickLookPreview com.apple.quicklook.preview PreviewProvider \
            '<key>QLIsDataBasedPreview</key><true/><key>QLSupportsSearchableItems</key><false/>' \
        QuickLookThumbnail com.apple.quicklook.thumbnail ThumbnailProvider \
            '<key>QLThumbnailMinimumDimension</key><integer>32</integer>'
    do
        staged=$AUDIT/$appex.appex
        mkdir -p $staged/Contents/MacOS
        cp -- $OUT/$appexes[1]/$appexes[1] $staged/Contents/MacOS/$appexes[1]
        cat > $staged/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$appex</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.InfiniteCanvas.$appex</string>
    <key>CFBundleExecutable</key>
    <string>$appexes[1]</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>$point</string>
        <key>NSExtensionPrincipalClass</key>
        <string>$appexes[1].$principal</string>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>QLSupportedContentTypes</key>
            <array>
                <string>com.example.InfiniteCanvas.board</string>
            </array>
            $attributes
        </dict>
    </dict>
</dict>
</plist>
PLIST
        codesign --force --sign - --entitlements $AUDIT/appex.entitlements $staged 2> $AUDIT/codesign.log ||
            die "signing $appex.appex failed:\n$(<$AUDIT/codesign.log)"
        for file in $staged/**/*(.DN); do
            installed=$APP/Contents/PlugIns/$appex.appex/${file#$staged/}
            mkdir -p ${installed:h}
            install_changed $file $installed
        done
    done
    for file in $APP/**/*(.DN); do (( ${bundled[(Ie)$file]} )) || { rm -f -- $file; replaced+=1 }; done
    # Copies of the app that are gone. Every checkout's build is a copy of the app, and macOS
    # registers one, with its Quick Look extensions, when it's opened; removing a worktree
    # unregisters nothing. LaunchServices hands Quick Look one copy's extension, whichever it picks,
    # and when it picks a copy that's gone it hands over none, however many copies that are still
    # there have theirs registered: a board file shows as its JSON. So a build that changed the app,
    # and the first one here, unregisters every registered copy whose folder is gone: LaunchServices
    # takes a second to list them, which a build that changed nothing doesn't spend. When one of
    # them had extensions, what was handed none has to ask again: a host (the Finder) asks only when
    # an extension is registered, so the copies still there register theirs again, and Quick Look's
    # thumbnail agent keeps to what it found until it restarts, so it's restarted (launchd starts it
    # again the next time a thumbnail is asked for).
    forget_copies_gone() {
        : > build/.copies
        local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
        [[ -x $lsregister ]] || return 0
        # Each copy LaunchServices has of the app (a bundle with its identifier, above) on a volume
        # that's mounted, a line: whether it has extensions, a tab, its path. And `unread` when the
        # dump has no bundle's path or identifier where this looks for them: its form is documented
        # nowhere, and reading nothing from it would be this bug again, unsaid.
        local copies line copy holder appex had_extensions=0
        typeset -a gone=() there=()
        copies=$($lsregister -dump Bundle 2> /dev/null | awk '
            function copy() {
                if (id == "com.example.InfiniteCanvas" && path != "" && !unmounted) print (plugins ? "extensions" : "none") "\t" path
                path = ""; id = ""; plugins = 0; unmounted = 0
            }
            /^-+$/ { copy(); next }
            /^path: / && path == "" { paths++; path = $0; sub(/^path: +/, "", path); sub(/ \(0x[0-9a-f]+\)$/, "", path) }
            /^identifier: / && id == "" { ids++; id = $0; sub(/^identifier: +/, "", id) }
            /^mount state: / && !/: +mounted$/ { unmounted = 1 }
            /^plugin Identifiers: / { plugins = 1 }
            END { copy(); if (NR && !(paths && ids)) print "unread" }') || return 0
        for line in ${(f)copies}; do
            if [[ $line == unread ]]; then
                print -u2 "build.sh: lsregister's dump isn't in the form forget_copies_gone reads, so copies of the app that are gone stay registered (they can hide its Quick Look extensions)"
                return 0
            fi
            copy=${line#*$'\t'}
            if [[ -e $copy ]]; then
                if [[ $line == extensions$'\t'* ]]; then there+=$copy; fi
                continue
            fi
            # Gone, and not only out of reach: the nearest folder above it that's there can be
            # listed (one the shell isn't let into, Desktop or Documents without permission, can't).
            holder=${copy:h}
            while [[ ! -e $holder ]]; do holder=${holder:h}; done
            ls -- $holder > /dev/null 2>&1 || continue
            gone+=$copy
            if [[ $line == extensions$'\t'* ]]; then had_extensions=1; fi
        done
        (( ${#gone} )) || return 0
        if ! $lsregister -u $gone > /dev/null 2>&1; then
            print -u2 "build.sh: lsregister -u failed, so ${#gone} of the app's copies whose folders are gone stay registered"
            return 0
        fi
        print "Unregistered ${#gone} of the app's copies whose folders are gone"
        (( had_extensions )) || return 0
        for copy in $there; do
            for appex in $copy/Contents/PlugIns/*.appex(N); do pluginkit -a $appex > /dev/null 2>&1 || true; done
        done
        # The agent alone, its path from the start: a bare name would match any command line with
        # the name in it (a `log stream` watching the agent).
        pkill -KILL -U $UID -f '^/System/Library/Frameworks/QuickLookThumbnailing\.framework/Support/com\.apple\.quicklook\.ThumbnailsAgent' || true
        print "One had Quick Look extensions: the copies still here registered theirs again, and Quick Look's thumbnail agent was restarted"
    }
    if (( replaced )) || [[ ! -e build/.copies ]]; then forget_copies_gone; fi
    print "Built $APP, with its Quick Look extensions, and build/$CLI_NAME (its command line)"
    ;;
esac
