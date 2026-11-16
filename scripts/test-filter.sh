#!/usr/bin/env bash
# Turns the impacted test files of a ferrograph report into cargo test selectors.
# Usage: test-filter.sh report.json   (run from the analysed directory; paths in the report are relative to it)
# Prints JSON: {"flat": "--test a --test b", "packages": [{"package": "p", "args": ["--lib", "--test", "a"]}]}
#  - tests/<name>.rs and tests/<name>/main.rs select `--test <name>`; flat works from the workspace root.
#  - files under src/ (unit tests) can only be selected per package: `--lib` (`--bins` without a library).
#  - another file under tests/ may be a module of any test target: `--tests` for that package.
#  - benches/ and examples/ are not tests and are skipped.
set -euo pipefail

pkg_of() { # pkg_of <file>: prints "<package dir>\t<package name>" of the nearest Cargo.toml with a [package]
  local d
  d="$(dirname "$1")"
  while :; do
    if [ -f "$d/Cargo.toml" ]; then
      name="$(awk '/^\[/{p=($0=="[package]")} p && /^name[ \t]*=/{gsub(/^name[ \t]*=[ \t]*"|"[ \t]*(#.*)?$/,""); print; exit}' "$d/Cargo.toml")"
      [ -z "$name" ] || { printf '%s\t%s\n' "$d" "$name"; return 0; }
    fi
    [ "$d" != . ] && [ "$d" != / ] || return 1
    d="$(dirname "$d")"
  done
}

rows=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  info="$(pkg_of "$f")" || continue
  dir="${info%%$'\t'*}"; pkg="${info#*$'\t'}"
  rel="${f#"$dir"/}"
  [ "$dir" != . ] || rel="$f"
  case "$rel" in
    tests/*/main.rs) arg="--test ${rel#tests/}"; arg="${arg%/main.rs}" ;;
    tests/*/*) # module of a directory test target, or of a top-level one
      t="${rel#tests/}"; t="${t%%/*}"
      if [ -f "$dir/tests/$t/main.rs" ]; then arg="--test $t"; else arg="--tests"; fi ;;
    tests/*.rs) arg="--test $(basename "$rel" .rs)" ;;
    src/main.rs | src/bin/*) arg="--bins" ;;
    src/*) if [ -f "$dir/src/lib.rs" ]; then arg="--lib"; else arg="--bins"; fi ;;
    *) continue ;;
  esac
  rows+=("$pkg	$arg")
done < <(jq -r '.impacted.tests.files[]?.file' "$1")

printf '%s\n' "${rows[@]+"${rows[@]}"}" | jq -R -s '
  [split("\n")[] | select(length > 0) | split("\t") | {package: .[0], arg: .[1]}] as $r
  | ($r | map(.arg) | unique) as $all
  | {
      flat: (if ($all | index("--tests")) then "--tests"
             else [$all[] | select(startswith("--test "))] | join(" ") end),
      packages: [$r | group_by(.package)[] | {package: .[0].package,
                 args: (map(.arg) | unique | map(split(" ")) | add)}]
    }'
