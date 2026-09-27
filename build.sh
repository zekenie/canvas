#!/bin/zsh
# Builds the module graph declared in Package.swift with swiftc directly (SwiftPM is broken on
# this machine). Every module becomes a static library plus a .swiftmodule, compiled in
# dependency order with only its own dependency closure on the include path. Every mode first
# audits Package.swift and the sources, and stops if the real graph differs from the declared one.
#
#   ./build.sh              build build/InfiniteCanvas.app (release)
#   ./build.sh tests        build every module but the app, test executables included (debug)
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
    foundation  "foundation"
    ui          "foundation"
    horizontal  "foundation horizontal"
    vertical    "foundation horizontal"
    bridge      "foundation horizontal vertical"
    composition "foundation horizontal vertical bridge"
    app         "foundation ui composition"
    testsupport "foundation testsupport"
    test        "foundation ui horizontal vertical bridge composition testsupport"
)
typeset -A EXECUTABLE_LAYER=(app 1 test 1)
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
AUDIT=$(mktemp -d -t build-audit)
trap 'rm -rf -- "$AUDIT"' EXIT
typeset -aU problems=()     # unique: two checks may report the same line

# Each module's imports, as the compiler parses them: a grep misses `import A; import B`,
# `@_spi(S) import B`, `import /* x */ B`, an import split over two lines, backticks... This is
# parse-only (no SDK, no -I), so it's quick, and the modules run in parallel.
typeset -A PARSING
for name in $NAMES; do
    swiftc -emit-imported-modules $DIR[$name]/**/*.swift(N) -o $AUDIT/$name.imports 2> $AUDIT/$name.errors &
    PARSING+=($name $!)
done
typeset -a unparsed=()
for name in $NAMES; do wait $PARSING[$name] || unparsed+=$name; done
(( ${#unparsed} )) && die "${(j:, :)unparsed} doesn't parse:\n$(cat $AUDIT/${^unparsed}.errors)"

# Every source line with its comments removed, as `file:line:code`. The checks below read this,
# so a comment can neither trip them nor satisfy them. The same pass lists imports inside #if.
SOURCES=(); for name in $NAMES; do SOURCES+=($DIR[$name]/**/*.swift(N)); done
CODE=$AUDIT/code
awk -v conditional=$AUDIT/conditional '
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
    }' $SOURCES > $CODE
# Prints `file:line` of a `file:line:code` line.
at() { print -r -- "${1%%:*}:${${1#*:}%%:*}" }
# The lines of $CODE that match an extended regex.
matching() { grep -E -- $1 $CODE || true }

# The compiler's parse has no -I and no -D, so every import must be unconditional, and nothing
# may ask whether a project module is on the include path.
[[ -f $AUDIT/conditional ]] && for hit in ${(f)"$(<$AUDIT/conditional)"}; do
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
    for imported in ${(f)"$(<$AUDIT/$name.imports)"}; do
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

# Ids: a module may write another module's ShapeKind, PluginID or ToolID as a string only if it
# depends on that module. The graph already keeps a module from naming another's types; this
# keeps it from reaching that module's shapes, tools or plugins by string instead.
# A module owns the ids its non-test code declares: as a static member (`static let kind:
# ShapeKind = "ellipse"`, `static let arrow: ToolID = "arrow"`) or as a plugin's `id` (`var id:
# PluginID { "ellipses" }`). Test fixtures' ids ("box", "card") are ordinary words, so they own
# nothing. Any other string literal is a use, except an SF Symbol or asset name (the argument of
# systemImage:, systemName:, systemSymbolName: or named:), which only looks like one.
ID_DECL='((let|var)[[:space:]]+id|static[[:space:]]+(let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*)[[:space:]]*(:[[:space:]]*(ShapeKind|PluginID|ToolID)[[:space:]]*(=|\{)|=[[:space:]]*(ShapeKind|PluginID|ToolID)\((rawValue:)?)[[:space:]]*"[^"\\]+"'
module_of() { print -r -- ${${1#*/}%%/*} }       # Sources/Canvas/Model/Identity.swift:3:... -> Canvas
typeset -A ID_OWNERS
for hit in ${(f)"$(matching $ID_DECL)"}; do
    owner=$(module_of $hit)
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
    sed -E 's/(systemImage|systemName|systemSymbolName|named):[[:space:]]*"[^"]*"/\1: ""/g' $CODE > $AUDIT/uses
    for hit in ${(f)"$(grep -F -f $AUDIT/ids $AUDIT/uses || true)"}; do
        user=$(module_of $hit)
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
    user=$(module_of $hit)
    [[ $LAYER[$user] == (foundation|ui|testsupport|test) ]] ||
        problems+="$hit  <- only the ui, testsupport and test layers may import SPI (the core's host API)"
done
(( ${#problems} )) && { print -u2 -l -- $problems; die "audit failed (${#problems} problems)" }

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
app|tests|api) ;;
*) die "unknown mode '$MODE'" ;;
esac

# --- 7. Compile ---------------------------------------------------------------------------------
SDK=$(pick_sdk)
ARCH=$(uname -m)
CONFIG=release; [[ $MODE == (tests|api) ]] && CONFIG=debug
OUT=build/$CONFIG
SWIFTC=(swiftc -sdk $SDK -target $ARCH-apple-macosx14.0 -swift-version 6 -wmo -warnings-as-errors
        -enable-upcoming-feature MemberImportVisibility)
[[ $CONFIG == release ]] && SWIFTC+=(-O) || SWIFTC+=(-Onone -g -D DEBUG)
# Products built by another compiler, or with other flags, are stale.
COMPILER=(${(f)"$(swiftc --version 2>&1)"})
FLAGS="$COMPILER[1]: ${SWIFTC[*]}"
mkdir -p $OUT
[[ -f $OUT/.flags && "$(<$OUT/.flags)" == "$FLAGS" ]] || { rm -rf -- "${OUT:?}"; mkdir -p $OUT; print -r -- "$FLAGS" > $OUT/.flags }

typeset -aU WANTED=()
case $MODE in
app)   WANTED=(InfiniteCanvas ${=CLOSURE[InfiniteCanvas]}) ;;
tests) for name in $NAMES; do [[ $LAYER[$name] == app ]] || WANTED+=$name; done ;;
api)   target=${2:?usage: build.sh api MODULE}; (( ${+DEPS[$target]} )) || die "no module $target"
       WANTED=($target ${=CLOSURE[$target]}) ;;
esac

typeset -a REBUILT=()
for name in $ORDER; do
    (( ${WANTED[(Ie)$name]} )) || continue
    dir=$OUT/$name; mkdir -p $dir
    srcs=($DIR[$name]/**/*.swift(N))
    includes=(${(@)${=CLOSURE[$name]}/#/-I$OUT/})
    product=$dir/lib$name.a; [[ $KIND[$name] == executableTarget ]] && product=$dir/$name
    # Rebuild unless it was last built from exactly these inputs (name, size and mtime, compared
    # for equality, so a file added, removed, or restored with an older mtime counts): its
    # sources, the manifest, this script, and its dependencies' products.
    inputs=($srcs Package.swift ${SELF:t})
    for dep in ${=CLOSURE[$name]}; do inputs+=($OUT/$dep/$dep.swiftmodule $OUT/$dep/lib$dep.a); done
    stamp=$(stat -f '%Fm %z %N' -- $inputs)
    [[ -e $product && -f $dir/.inputs && "$(<$dir/.inputs)" == "$stamp" ]] && continue
    rm -f -- $dir/.inputs
    if [[ $KIND[$name] == target ]]; then
        $SWIFTC -parse-as-library -emit-library -static -emit-module -module-name $name \
            -emit-module-path $dir/$name.swiftmodule $includes $srcs -o $product
    else
        # Two flags keep code that nothing names from being dropped at link time (where
        # `as? any Capability` would then quietly fail): -wmo makes each module a single object,
        # so a file nothing references still links whenever something in its module is
        # referenced; -force_load links every module whole, even one nothing references by
        # symbol (say, a module that only adds protocol conformances).
        libs=()
        for dep in ${=CLOSURE[$name]}; do libs+=(-Xlinker -force_load -Xlinker $OUT/$dep/lib$dep.a); done
        entry=(); [[ -n ${(M)srcs:#*/main.swift} ]] || entry=(-parse-as-library)
        $SWIFTC $entry -module-name $name $includes $srcs $libs -o $product
    fi
    print -r -- "$stamp" > $dir/.inputs
    REBUILT+=$name
done
print -u2 "built ${${(j:, :)REBUILT}:-nothing (up to date)}"

case $MODE in
api)
    xcrun swift-synthesize-interface -sdk $SDK -target $ARCH-apple-macosx14.0 -module-name $target \
        -I$OUT/$target ${(@)${=CLOSURE[$target]}/#/-I$OUT/}
    ;;
app)
    APP=build/InfiniteCanvas.app
    rm -rf -- "${APP:?}"; mkdir -p $APP/Contents/MacOS
    cp $OUT/InfiniteCanvas/InfiniteCanvas $APP/Contents/MacOS/InfiniteCanvas
    cat > $APP/Contents/Info.plist <<'PLIST'
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
</dict>
</plist>
PLIST
    print "Built $APP"
    ;;
esac
