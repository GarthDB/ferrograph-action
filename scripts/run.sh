#!/usr/bin/env bash
# Runs `ferrograph pr`, writes reports to $FG_OUT and step outputs to $GITHUB_OUTPUT.
# Exit 0 for ferrograph exit 0 or 1 (threshold enforcement is a later step); fails on error.
# Env: IN_BASE, BASE_REF, IN_FAIL_ON_NEW_DEAD, IN_MAX_NEW_DEAD, IN_MAX_BLAST, IN_ENTRY, IN_IGNORE,
#      IN_STRICT, IN_SARIF, IN_DB, FG_OUT.
set -euo pipefail

mkdir -p "$FG_OUT"
base="${IN_BASE:-}"
if [ -z "$base" ]; then
  [ -n "${BASE_REF:-}" ] || { echo "::error::No PR base ref; set the 'base' input." >&2; exit 2; }
  base="origin/$BASE_REF"
fi

hint="Use actions/checkout with 'fetch-depth: 0' so the base ref and history are available."
git rev-parse --verify --quiet "$base^{commit}" >/dev/null ||
  { echo "::error::Base ref '$base' not found. $hint" >&2; exit 2; }
git merge-base HEAD "$base" >/dev/null 2>&1 ||
  { echo "::error::No merge base between HEAD and '$base' (shallow clone?). $hint" >&2; exit 2; }

args=(pr --base "$base" --index-head)
[ "${IN_FAIL_ON_NEW_DEAD:-false}" = true ] && args+=(--fail-on-new-dead)
[ -z "${IN_MAX_NEW_DEAD:-}" ] || args+=(--max-new-dead "$IN_MAX_NEW_DEAD")
[ -z "${IN_MAX_BLAST:-}" ] || args+=(--max-blast "$IN_MAX_BLAST")
[ "${IN_STRICT:-false}" = true ] && args+=(--strict)
[ -z "${IN_DB:-}" ] || args+=(--base-db "$IN_DB")
while IFS= read -r line; do [ -z "$line" ] || args+=(--entry "$line"); done <<< "${IN_ENTRY:-}"
while IFS= read -r line; do [ -z "$line" ] || args+=(--ignore "$line"); done <<< "${IN_IGNORE:-}"

run() { # run <format> <outfile>; sets $code, stderr in $FG_OUT/stderr.txt
  set +e
  ferrograph "${args[@]}" --format "$1" > "$2" 2> "$FG_OUT/stderr.txt"
  code=$?
  set -e
  cat "$FG_OUT/stderr.txt" >&2
  if [ "$code" -gt 1 ]; then
    echo "::error::ferrograph failed (exit $code): $(tr '\n' ' ' < "$FG_OUT/stderr.txt")" >&2
    echo "exit-code=$code" >> "$GITHUB_OUTPUT"
    exit "$code"
  fi
}

run json "$FG_OUT/report.json"
run markdown "$FG_OUT/report.md"
# shortcut: each format re-indexes HEAD and base, ferrograph has no single-pass multi-format output; upgrade if it gains one
if [ "${IN_SARIF:-false}" = true ]; then
  run sarif "$FG_OUT/ferrograph.sarif"
fi

{
  echo "exit-code=$code"
  echo "new-dead-count=$(jq .newly_dead_count "$FG_OUT/report.json")"
  echo "blast-count=$(jq .blast.count "$FG_OUT/report.json")"
  echo "report-path=$FG_OUT/report.md"
} >> "$GITHUB_OUTPUT"
