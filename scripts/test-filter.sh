#!/usr/bin/env bash
# Turns the impacted test files of a ferrograph report into cargo test selectors.
# Usage: test-filter.sh report.json   (run from the analysed directory; paths in the report are relative to it)
# Prints JSON: {"flat": "--workspace --test a --test b", "packages": [{"package": "p", "args": ["--lib", "--test", "a"]}]}
#  - tests/<name>.rs and tests/<name>/** select `--test <name>`; `flat` starts with `--workspace` so the target is found
#    in any member, also when the root is a package or `default-members` is set.
#  - a directory under tests/ without main.rs is not a target: `--tests` (every test target, unit tests included).
#  - files under src/ (unit tests) can only be selected per package: `--lib` and/or `--bins`.
#  - benches/ and examples/ are not tests and are skipped.
#  - names that are not plain cargo target names ([A-Za-z0-9_-]) are skipped: they end up in shell commands.
set -euo pipefail

pkg_of() { # pkg_of <file>: prints "<package dir>\t<package name>" of the nearest Cargo.toml with a [package]
  local d name
  d="$(dirname "$1")"
  while :; do
    if [ -f "$d/Cargo.toml" ]; then
      name="$(awk '/^\[/{p=($0 ~ /^\[package\][ \t]*(#.*)?$/)} p && /^name[ \t]*=/{gsub(/^name[ \t]*=[ \t]*"|"[ \t]*(#.*)?$/,""); print; exit}' "$d/Cargo.toml")"
      [ -z "$name" ] || { printf '%s\t%s\n' "$d" "$name"; return 0; }
    fi
    [ "$d" != . ] && [ "$d" != / ] || return 1
    d="$(dirname "$d")"
  done
}

safe() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

rows=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  info="$(pkg_of "$f")" || continue
  dir="${info%%$'\t'*}"; pkg="${info#*$'\t'}"
  safe "$pkg" || continue
  rel="${f#"$dir"/}"
  [ "$dir" != . ] || rel="$f"
  args=()
  case "$rel" in
    tests/*)
      t="${rel#tests/}"
      if [[ "$t" != */* ]]; then
        t="${t%.rs}"; safe "$t" && args=("--test $t")
      else
        t="${t%%/*}"
        if ! safe "$t"; then :; elif [ -f "$dir/tests/$t/main.rs" ]; then args=("--test $t"); else args=("--tests"); fi
      fi ;;
    src/*)
      has_lib=false; has_bin=false
      [ -f "$dir/src/lib.rs" ] && has_lib=true
      { [ -f "$dir/src/main.rs" ] || [ -d "$dir/src/bin" ]; } && has_bin=true
      case "$rel" in
        src/main.rs | src/bin/*) args=("--bins") ;;
        *) # a module may belong to the library, to a binary, or to both
          $has_lib && args+=("--lib"); $has_bin && args+=("--bins")
          [ ${#args[@]} -gt 0 ] || args=("--lib") ;;
      esac ;;
    *) continue ;;
  esac
  for a in "${args[@]+"${args[@]}"}"; do rows+=("$pkg	$a"); done
done < <(jq -r '.impacted.tests.files[]?.file | select(contains("\n") | not)' "$1")

printf '%s\n' "${rows[@]+"${rows[@]}"}" | jq -R -s '
  [split("\n")[] | select(length > 0) | split("\t") | {package: .[0], arg: .[1]}] as $r
  | ($r | map(.arg) | unique) as $all
  | {
      flat: (if ($all | index("--tests")) then "--workspace --tests"
             elif ([$all[] | select(startswith("--test "))] | length) > 0
             then "--workspace " + ([$all[] | select(startswith("--test "))] | join(" "))
             else "" end),
      packages: [$r | group_by(.package)[] | {package: .[0].package,
                 args: (map(.arg) | unique | map(split(" ")) | add)}]
    }'
