#!/bin/zsh
# Builds the module graph declared in Package.swift with swiftc directly (SwiftPM is broken on
# this machine). Every module becomes a static library plus a .swiftmodule, compiled with only its
# own dependency closure on the include path, as many at once as there are cores (BUILD_JOBS), and
# only as far as a change reaches. Every mode first audits Package.swift and the sources, and stops
# if the real graph differs from the declared one.
#
#   ./build.sh              build build/InfiniteCanvas.app (release), with the command line in it
#                           (build/canvas links to it)
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

# Which layers each layer may depend on (Package.swift's header says the same in prose).
typeset -A MAY_USE=(
    wire        "wire"
    foundation  "foundation"
    ui          "foundation wire"
    horizontal  "foundation horizontal wire"
    vertical    "foundation horizontal"
    bridge      "foundation horizontal vertical"
    composition "foundation horizontal vertical bridge wire"
    app         "foundation ui composition wire"
    cli         "wire"
    testsupport "foundation testsupport"
    test        "wire foundation ui horizontal vertical bridge composition testsupport"
)
typeset -A EXECUTABLE_LAYER=(app 1 test 1 cli 1)
# What the command line's executable (the cli layer's) is called once it's built: in the app's
# bundle, at Contents/Helpers/canvas, and build/canvas, a link to it.
CLI_NAME=canvas
# Public types that would shadow a module (`Observation` breaks @Observable's expansion), or
# Swift's `Task`: a public `Task` would shadow it in every module that imports the declaring one.
RESERVED_TYPE_NAMES=(Observation Foundation AppKit SwiftUI CoreGraphics Swift Task)

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
typeset -A DEPS KIND DIR LAYER PATH_ARG
integer lineno=0
TARGET_RE='^[[:space:]]*\.(target|executableTarget)\(name: "([A-Za-z][A-Za-z0-9]*)", dependencies: \[(("[A-Za-z][A-Za-z0-9]*"(, "[A-Za-z][A-Za-z0-9]*")*)?)\](, path: "([^"]+)")?\),[[:space:]]*// layer: ([a-z]+)[[:space:]]*$'
while IFS= read -r line || [[ -n $line ]]; do
    lineno+=1
    [[ $line =~ '^[[:space:]]*//' ]] && continue
    if [[ $line =~ $TARGET_RE ]]; then
        name=$match[2]
        (( ${+DEPS[$name]} )) && die "Package.swift:$lineno: $name is declared twice"
        NAMES+=$name
        KIND[$name]=$match[1]
        DEPS[$name]=${${match[3]//\"/}//,/}
        PATH_ARG[$name]=$match[7]
        DIR[$name]=${match[7]:-Sources/$name}
        LAYER[$name]=$match[8]
        (( ${+MAY_USE[$LAYER[$name]]} )) || die "Package.swift:$lineno: unknown layer '$LAYER[$name]' (layers: ${(k)MAY_USE})"
    elif [[ $line =~ '\.[A-Za-z]+\([[:space:]]*name:' || $line == *[Tt]arget\(* ]]; then
        die "Package.swift:$lineno: this target doesn't match the one-line form at the top of the file:\n    $line"
    fi
done < Package.swift
(( ${#NAMES} )) || die "no targets in Package.swift"

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
    typeset -a deps=(${=DEPS[$name]})
    typeset -aU distinct=($deps)
    (( ${#deps} == ${#distinct} )) || die "$name lists a dependency twice"
    for dep in $deps; do
        (( ${+DEPS[$dep]} )) || die "$name depends on $dep, which Package.swift doesn't declare"
        [[ $dep != $name ]] || die "$name depends on itself"
        [[ $KIND[$dep] == target ]] || die "$name depends on $dep, an executable"
        (( ${${=MAY_USE[$layer]}[(Ie)$LAYER[$dep]]} )) ||
            die "$name ($layer) may not depend on $dep ($LAYER[$dep]); $layer may use: $MAY_USE[$layer]"
    done
done
for dir in {Sources,Examples,Tests}/*(/N); do
    [[ ${DIR[${dir:t}]:-} == $dir ]] || die "$dir isn't a target in Package.swift"
done
for file in {Sources,Examples,Tests}/*.swift(N); do die "$file isn't in any target's directory"; done

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

# A test target named after a module (<M>Tests) tests M on its own: it may use M, what M uses,
# and testsupport and ui modules, so that (say) ArrowsTests can't lean on a shape kind.
for name in $NAMES; do
    subject=${name%Tests}
    [[ $LAYER[$name] == test && $subject != $name && -n ${DEPS[$subject]+1} ]] || continue
    for dep in ${=DEPS[$name]}; do
        [[ $dep == $subject || $LAYER[$dep] == (testsupport|ui) ]] && continue
        (( ${${=CLOSURE[$subject]}[(Ie)$dep]} )) ||
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
    for name in $ORDER; do
        typeset -aU used=()
        for imported in ${(f)"$(<$AUDITED/modules/$name.imports)"}; do
            (( ${+DEPS[$imported]} )) || continue                      # a system module
            used+=$imported
            (( ${${=DEPS[$name]}[(Ie)$imported]} )) ||
                problems+="$(import_site $name $imported)$name imports $imported, but Package.swift doesn't list it as a dependency of $name"
        done
        for dep in ${=DEPS[$name]}; do
            (( ${used[(Ie)$dep]} )) || problems+="$name lists $dep in Package.swift but never imports it"
        done
    done

    SHADOWING="${(j:|:)NAMES}|${(j:|:)RESERVED_TYPE_NAMES}"
    for hit in ${(f)"$(matching "^[^:]+:[0-9]+:[[:space:]]*(@[A-Za-z]+[[:space:]]+)*(public|open)[[:space:]]+(final[[:space:]]+)?(struct|class|enum|protocol|actor|typealias)[[:space:]]+($SHADOWING)([^A-Za-z0-9_]|\$)")"}; do
        [[ $hit =~ "(struct|class|enum|protocol|actor|typealias)[[:space:]]+($SHADOWING)" ]] || continue
        [[ $match[2] == Task ]] && what="Swift's Task" || what="the module $match[2]"
        problems+="$(at $hit): a public type named $match[2] shadows $what"
    done

    # Ids: a module may write another module's ShapeKind, PluginID, ToolID, PropertyKey or ChannelID
    # (Ports') as a string only if it depends on that module. The graph already keeps a module from
    # naming another's types; this keeps it from reaching that module's shapes, tools, plugins, added
    # properties or channels by string instead. A module owns the ids its non-test code declares: as a
    # static member (`static let kind: ShapeKind = "rectangle"`, `static let arrow: ToolID = "arrow"`,
    # `static let key: PropertyKey = "checklist"`, `static let id: ChannelID = "note-link"`) or as a
    # plugin's `id` (`var id: PluginID { "rectangles" }`). Test fixtures' ids
    # ("box", "card") are ordinary words, so they own nothing. Any other string literal is a use,
    # except an SF Symbol or asset name (the argument of systemImage:, systemName:, systemSymbolName:
    # or named:), which only looks like one, and a kind's own property's name (`Property("title", ...)`),
    # which is only that kind's; nor is a JSON member named by one of JSON Schema's keywords, which ids
    # may be too (Titles' `title`): a subscript's key (`json["title"]`), or a key before a colon where
    # a member's name can start (`["title": ...]`, `, "title": ...`, `"title" : ...` beginning a line
    # of JSON text), but never in a `case`'s patterns or its `where` (on its line, or the lines a
    # pattern list or a `where` goes on to) or a ternary's (after its `?`, on its line or the next).
    # Any other member's name is a use: a module can't read another's property out of a shape's JSON
    # (`json["locked"]`) without depending on it. (`id_uses`, above, finds where uses can be.)
    ID_DECL='((let|var)[[:space:]]+id|static[[:space:]]+(let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*)[[:space:]]*(:[[:space:]]*(ShapeKind|PluginID|ToolID|PropertyKey|ChannelID)[[:space:]]*(=|\{)|=[[:space:]]*(ShapeKind|PluginID|ToolID|PropertyKey|ChannelID)\((rawValue:)?)[[:space:]]*"[^"\\]+"'
    typeset -A ID_OWNERS
    for hit in ${(f)"$(matching $ID_DECL)"}; do
        owner=${${hit#*/}%%/*}                  # Sources/Canvas/Model/Identity.swift:3:... -> Canvas
        [[ $LAYER[$owner] == test* ]] && continue
        rest=${hit#*:*:}
        while [[ $rest =~ $ID_DECL ]]; do
            id=${${MATCH%\"}##*\"}
            ID_OWNERS[$id]+=" $owner"
            rest=${rest[MEND+1,-1]}
        done
    done
    if (( ${#ID_OWNERS} )); then
        print -rl -- \"${(k)^ID_OWNERS}\" > $AUDIT/ids
        for hit in ${(f)"$(cat -- $AUDITED/modules/${^NAMES}.uses | grep -F -f $AUDIT/ids || true)"}; do
            user=${${hit#*/}%%/*}
            for id in ${(k)ID_OWNERS}; do
                [[ ${hit#*:*:} == *\"$id\"* ]] || continue
                for owner in ${=ID_OWNERS[$id]}; do
                    [[ $owner == $user ]] || (( ${${=CLOSURE[$user]}[(Ie)$owner]} )) ||
                        problems+="$(at $hit): \"$id\" is $owner's id, but $user doesn't depend on $owner"
                done
            done
        done
    fi
    # The core's host API (what CanvasView calls: input, cursor, drawing) is `@_spi(Host)`. Only the
    # hosting view and tests may `@_spi(Host) import` it; foundation modules declare it. No plugin may
    # use @_spi at all, so the host API stays out of every plugin's reach.
    for hit in ${(f)"$(matching '@_spi[[:space:]]*\(')"}; do
        user=${${hit#*/}%%/*}
        [[ $LAYER[$user] == (foundation|ui|testsupport|test) ]] ||
            problems+="$hit  <- only the ui, testsupport and test layers may import SPI (the core's host API)"
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
audit) print "audit passed: ${#NAMES} modules, acyclic, layers respected, SwiftPM agrees, imports and ids match Package.swift"; exit 0 ;;
graph)
    for name in $ORDER; do
        typeset -a users=()
        for other in $ORDER; do (( ${${=DEPS[$other]}[(Ie)$name]} )) && users+=$other; done
        print "${(r:12:)LAYER[$name]} ${(r:17:)name} -> ${${DEPS[$name]:-(nothing)}// /, }    <- ${${(j:, :)users}:-(nothing)}"
    done
    exit 0 ;;
dot)
    print "digraph modules {\n  rankdir=BT; node [shape=box];"
    for name in $ORDER; do
        print "  \"$name\" [label=\"$name\\\\n$LAYER[$name]\"];"
        for dep in ${=DEPS[$name]}; do print "  \"$name\" -> \"$dep\";"; done
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
           if [[ $LAYER[$name] == cli && $KIND[$name] == executableTarget ]]; then WANTED+=($name ${=CLOSURE[$name]}); fi
       done ;;
tests) for name in $NAMES; do [[ $LAYER[$name] == app ]] || WANTED+=$name; done ;;
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
#   link       an executable, from its objects and every library it depends on.
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
    local srcs=($DIR[$name]/**/*.swift(N)) includes=(${(@)${=CLOSURE[$name]}/#/-I$OUT/})
    INPUTS=($srcs); for dep in ${=CLOSURE[$name]}; do INPUTS+=($OUT/$dep/$dep.swiftmodule); done
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
    link)
        local libs=() objects=($dir/objects/*.o(Nn)) debugger=()
        INPUTS=($objects)
        if [[ $CONFIG == debug ]]; then
            debugger=(-Xlinker -add_ast_path -Xlinker $dir/$name.swiftmodule)
            INPUTS+=($dir/$name.swiftmodule)
        fi
        for dep in ${=CLOSURE[$name]}; do
            libs+=(-Xlinker -force_load -Xlinker $OUT/$dep/lib$dep.a)
            INPUTS+=($OUT/$dep/lib$dep.a)
        done
        local link=($SWIFTC $objects $libs $debugger -o $dir/$name)
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
    deps=(${=DEPS[$name]}); closure=(${=CLOSURE[$name]})
    if [[ $KIND[$name] == target ]]; then
        add_job ${name}:interface ${^deps}:interface
        add_job ${name}:object ${^deps}:interface
    else
        add_job ${name}:object ${^deps}:interface
        add_job ${name}:link ${name}:object ${^closure}:object
    fi
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
    install_changed() {  # copies the file $1 to $2, in the bundle, if they differ
        bundled+=$2
        cmp -s -- $1 $2 || { cp -- $1 $2.new && mv -f -- $2.new $2 }
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
    </array>
</dict>
</plist>
PLIST
    install_changed $AUDIT/Info.plist $APP/Contents/Info.plist
    for file in $APP/**/*(.DN); do (( ${bundled[(Ie)$file]} )) || rm -f -- $file; done
    print "Built $APP, and build/$CLI_NAME (its command line)"
    ;;
esac
