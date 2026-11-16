#!/usr/bin/env bash
# Plain-shell tests for scripts/. Run: tests/test.sh
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
check() { # check <name> <expected-exit> <cmd...>
  local name="$1" want="$2"; shift 2
  "$@" >"$tmp/out" 2>&1; local got=$?
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name (exit $got, want $want)"; cat "$tmp/out"; fails=$((fails+1)); fi
}
has() { if grep -qF -- "$2" "$1"; then echo "ok   $3"; else echo "FAIL $3"; fails=$((fails+1)); fi; }

# OS/arch mapping (explicit versions avoid network)
# shellcheck disable=SC2329 # invoked through check
res() { FG_OS="$1" FG_ARCH="$2" INPUT_VERSION="${3:-5.0.0}" "$root/scripts/resolve.sh"; }
check "linux x64" 0 res Linux x86_64;      has "$tmp/out" target=x86_64-unknown-linux-gnu "x64 target"
check "linux arm64" 0 res Linux aarch64;   has "$tmp/out" target=aarch64-unknown-linux-gnu "arm64 target"
check "macOS arm64" 0 res Darwin arm64;    has "$tmp/out" target=aarch64-apple-darwin "mac target"
check "macOS x64 rejected" 1 res Darwin x86_64
check "windows rejected" 1 res MINGW64_NT x86_64
check "bare version" 0 res Linux x86_64 5.0.0;  has "$tmp/out" tag=v5.0.0 "bare version -> v5.0.0"
check "v-prefixed version" 0 res Linux x86_64 v5.1.2; has "$tmp/out" tag=v5.1.2 "v version kept"
check "latest stays in major 6" 0 env FG_OS=Linux FG_ARCH=x86_64 INPUT_VERSION=latest FG_RELEASES=$'v7.0.0\nv6.2.0\nv6.10.1\nv6.9.0\nv5.9.0' "$root/scripts/resolve.sh"
has "$tmp/out" tag=v6.10.1 "latest = highest 6.x (version sort)"
check "latest with no 6.x fails" 1 env FG_OS=Linux FG_ARCH=x86_64 INPUT_VERSION=latest FG_RELEASES=v7.0.0 "$root/scripts/resolve.sh"
check "pre-5.0 version rejected" 1 res Linux x86_64 4.1.0
check "bad version rejected" 1 res Linux x86_64 '4.0;rm'

# checksums
echo payload > "$tmp/a.tar.gz"
h="$(shasum -a 256 "$tmp/a.tar.gz" | awk '{print $1}')"
echo "$h  a.tar.gz" > "$tmp/good"; echo "$(printf '%064d' 0)  a.tar.gz" > "$tmp/bad"; echo "$h  other.tar.gz" > "$tmp/missing"
check "checksum ok" 0 "$root/scripts/verify-checksum.sh" "$tmp/a.tar.gz" "$tmp/good"
check "checksum mismatch fails" 1 "$root/scripts/verify-checksum.sh" "$tmp/a.tar.gz" "$tmp/bad"
check "checksum entry missing fails" 1 "$root/scripts/verify-checksum.sh" "$tmp/a.tar.gz" "$tmp/missing"

# sticky comment against a fake gh that records calls
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$*" in
  *--paginate*) [ -z "${FAKE_EXISTING:-}" ] || echo "$FAKE_EXISTING" ;;
  *) [ -z "${FAKE_FAIL:-}" ] || exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
echo '<!-- ferrograph -->' > "$tmp/report.md"
# shellcheck disable=SC2329 # invoked through check
cm() { PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" REPORT="$tmp/report.md" REPO=o/r PR_NUMBER=7 GITHUB_STEP_SUMMARY="$tmp/sum" "$root/scripts/comment.sh"; }
: > "$tmp/log"; : > "$tmp/sum"
check "creates when none" 0 cm;                    has "$tmp/log" "POST repos/o/r/issues/7/comments" "POST used"
: > "$tmp/log"
FAKE_EXISTING=42 check "updates existing" 0 cm;    has "$tmp/log" "PATCH repos/o/r/issues/comments/42" "PATCH used"
grep -q POST "$tmp/log" && { echo "FAIL duplicate POST"; fails=$((fails+1)); }
check "api failure never fails" 0 env FAKE_FAIL=1 PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" REPORT="$tmp/report.md" REPO=o/r PR_NUMBER=7 GITHUB_STEP_SUMMARY="$tmp/sum" "$root/scripts/comment.sh"
has "$tmp/sum" ferrograph "summary fallback on api failure"
: > "$tmp/sum"; : > "$tmp/log"
check "fork -> summary" 0 env IS_FORK=true PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" REPORT="$tmp/report.md" REPO=o/r PR_NUMBER=7 GITHUB_STEP_SUMMARY="$tmp/sum" "$root/scripts/comment.sh"
has "$tmp/sum" ferrograph "fork summary written"
if [ -s "$tmp/log" ]; then echo "FAIL fork made API calls"; fails=$((fails+1)); else echo "ok   fork makes no API calls"; fi
# findings mode: empty report -> no POST (summary only); existing comment -> PATCH
echo '{"newly_dead_count":0,"changed_functions":[]}' > "$tmp/report.json"
: > "$tmp/log"; : > "$tmp/sum"
COMMENT_MODE=findings check "findings: empty report is quiet" 0 cm
if grep -q POST "$tmp/log"; then echo "FAIL findings posted empty"; fails=$((fails+1)); else echo "ok   findings makes no POST"; fi
has "$tmp/sum" ferrograph "findings: summary still written"
: > "$tmp/log"
COMMENT_MODE=findings FAKE_EXISTING=42 check "findings: updates stale comment" 0 cm; has "$tmp/log" "PATCH repos/o/r/issues/comments/42" "findings PATCH existing"
: > "$tmp/log"
echo '{"newly_dead_count":0,"changed_functions":[{}]}' > "$tmp/report.json"
COMMENT_MODE=findings check "findings: posts on changed fn" 0 cm; has "$tmp/log" "POST repos/o/r/issues/7/comments" "findings POST with changes"
rm "$tmp/report.json"

# run.sh against a fake ferrograph: one invocation, every report from it
cat > "$tmp/bin/ferrograph" <<'FG'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_FG_LOG"
for a in "$@"; do
  case "$a" in
    json=*) if [ -n "${FAKE_IMPACT:-}" ]; then echo '{"newly_dead_count":3,"blast":{"count":9},"impacted":{"count":4,"tests":{"count":3,"files":[{"file":"tests/a.rs","count":2},{"file":"tests/b.rs","count":1}]}}}' > "${a#json=}"; else echo '{"newly_dead_count":3,"blast":{"count":9}}' > "${a#json=}"; fi ;;
    markdown=*) echo '<!-- ferrograph -->' > "${a#markdown=}" ;;
    sarif=*) echo '{}' > "${a#sarif=}" ;;
  esac
done
echo "warn: from fake" >&2
exit "${FAKE_FG_EXIT:-0}"
FG
chmod +x "$tmp/bin/ferrograph"
repo="$tmp/repo"; mkdir "$repo"
git -C "$repo" init -q -b main && git -C "$repo" -c user.email=a@b -c user.name=t commit -q --allow-empty -m base
git -C "$repo" checkout -q -b feature && git -C "$repo" -c user.email=a@b -c user.name=t commit -q --allow-empty -m change
mkdir -p "$repo/tests"; printf '[package]\nname = "p"\n' > "$repo/Cargo.toml"; touch "$repo/tests/a.rs" "$repo/tests/b.rs"
# shellcheck disable=SC2329 # invoked through check
runsh() { (cd "$repo" && : > "$tmp/fglog" && : > "$tmp/gho" && PATH="$tmp/bin:$PATH" FAKE_FG_LOG="$tmp/fglog" GITHUB_OUTPUT="$tmp/gho" FG_OUT="$tmp/fgout" IN_BASE=main "$@" "$root/scripts/run.sh"); }
check "run.sh succeeds" 0 runsh env
has "$tmp/gho" "exit-code=0" "exit code recorded"
has "$tmp/gho" "new-dead-count=3" "count from report.json"
has "$tmp/gho" "blast-count=9" "blast from report.json"
if [ "$(wc -l < "$tmp/fglog" | tr -d ' ')" = 1 ]; then echo "ok   ferrograph invoked once"; else echo "FAIL ferrograph invoked more than once"; fails=$((fails+1)); fi
has "$tmp/fglog" "--out json=$tmp/fgout/report.json" "json report via --out"
has "$tmp/fglog" "--out markdown=$tmp/fgout/report.md" "markdown report via --out"
grep -q sarif "$tmp/fglog" && { echo "FAIL sarif requested by default"; fails=$((fails+1)); }
check "run.sh impacted outputs" 0 runsh env FAKE_IMPACT=1
has "$tmp/gho" "impacted-count=4" "impacted-count output"
has "$tmp/gho" "impacted-tests-count=3" "impacted-tests-count output"
has "$tmp/gho" "tests/b.rs" "impacted-test-files output"
has "$tmp/gho" "test-filter=--workspace --test a --test b" "test-filter output"
has "$tmp/gho" 'test-filter-json=[{"package":"p","args":["--test","a","--test","b"]}]' "test-filter-json output"
check "run.sh old report" 0 runsh env
grep -q impacted "$tmp/gho" && { echo "FAIL impacted outputs set for an old report"; fails=$((fails+1)); }
grep -q test-filter "$tmp/gho" && { echo "FAIL test-filter set for an old report"; fails=$((fails+1)); }
check "run.sh passes impact-depth" 0 runsh env IN_IMPACT_DEPTH=2
has "$tmp/fglog" "--impact-depth 2" "impact-depth forwarded"
check "run.sh passes max-impacted" 0 runsh env IN_MAX_IMPACTED=5
has "$tmp/fglog" "--max-impacted 5" "max-impacted forwarded"
check "run.sh without impact-depth" 0 runsh env
grep -q impact-depth "$tmp/fglog" && { echo "FAIL impact-depth sent by default"; fails=$((fails+1)); }
check "run.sh with sarif" 0 runsh env IN_SARIF=true
has "$tmp/fglog" "--out sarif=$tmp/fgout/ferrograph.sarif" "sarif via --out when enabled"
check "threshold exit 1 is not a failure here" 0 runsh env FAKE_FG_EXIT=1
has "$tmp/gho" "exit-code=1" "threshold exit code recorded"
check "ferrograph error fails" 2 runsh env FAKE_FG_EXIT=2
has "$tmp/gho" "exit-code=2" "error exit code recorded"

check "pr flag inputs" 0 runsh env IN_EXCLUDE_LOW_CONFIDENCE=true IN_BLAST_LIMIT=50 IN_MARKDOWN_LIMIT=20 IN_RESTRICTED_VIS_NOT_ROOT=false IN_BIN_PUB_NOT_ROOT=true IN_EXTRA_ARGS=$'--max-impacted\n10'
has "$tmp/fglog" "--exclude-low-confidence --blast-limit 50 --markdown-limit 20 --no-restricted-vis-not-root --bin-pub-not-root" "flags passed"
has "$tmp/fglog" "--max-impacted 10 --out" "extra-args appended before --out"
check "tri-state default adds nothing" 0 runsh env IN_RESTRICTED_VIS_NOT_ROOT=default
grep -q "vis-not-root" "$tmp/fglog" && { echo "FAIL default tri-state emitted a flag"; fails=$((fails+1)); }
check "bad tri-state rejected" 2 runsh env IN_BIN_PUB_NOT_ROOT=maybe

# test-filter.sh: integration targets, unit tests per package, helper modules, skipped files
tf="$tmp/ws"; mkdir -p "$tf/a/src" "$tf/a/tests" "$tf/b/src" "$tf/b/tests/dir" "$tf/c/src" "$tf/d/tests"
printf '[package]\nname = "a"\n' > "$tf/a/Cargo.toml"; touch "$tf/a/src/lib.rs" "$tf/a/tests/x.rs"
printf '[package]\nname = "b"\n' > "$tf/b/Cargo.toml"; touch "$tf/b/src/main.rs" "$tf/b/tests/dir/main.rs" "$tf/b/tests/dir/helper.rs"
printf '[package]\nname = "c"\n' > "$tf/c/Cargo.toml"; touch "$tf/c/src/lib.rs"
printf '[package]\nname = "d"\n' > "$tf/d/Cargo.toml"; touch "$tf/d/tests/helper.rs"; mkdir "$tf/d/tests/sub"; touch "$tf/d/tests/sub/m.rs"
# shellcheck disable=SC2329 # invoked through check
tfilter() { (cd "$tf" && echo "$1" > r.json && "$root/scripts/test-filter.sh" r.json); }
rep() { printf '{"impacted":{"tests":{"files":[%s]}}}' "$(printf '{"file":"%s"},' "$@" | sed 's/,$//')"; }
check "test-filter maps files" 0 tfilter "$(rep a/tests/x.rs a/src/lib.rs b/tests/dir/helper.rs b/src/main.rs c/src/lib.rs a/examples/e.rs)"
has "$tmp/out" '"flat": "--workspace --test dir --test x"' "flat has --workspace and integration targets only"
has "$tmp/out" '"--bins"' "binary package gets --bins"
check "test-filter: unit tests only" 0 tfilter "$(rep c/src/lib.rs)"
has "$tmp/out" '"flat": ""' "no integration test -> empty flat"
has "$tmp/out" '"package": "c"' "unit test package listed"
check "test-filter: unknown helper module -> --tests" 0 tfilter "$(rep d/tests/sub/m.rs a/tests/x.rs)"
has "$tmp/out" '"flat": "--workspace --tests"' "helper module selects all test targets"
check "test-filter: empty report" 0 tfilter '{"impacted":{"tests":{"files":[]}}}'
has "$tmp/out" '"packages": []' "empty packages"
check "test-filter: file outside any package is skipped" 0 tfilter "$(rep nowhere/tests/q.rs)"
has "$tmp/out" '"packages": []' "no package -> skipped"

# hostile and odd layouts
mkdir -p "$tf/e/src" "$tf/e/tests/deep/inner" "$tf/f/tests"
printf '[package] # comment\nname = "e"\n' > "$tf/e/Cargo.toml"; touch "$tf/e/src/lib.rs" "$tf/e/src/main.rs" "$tf/e/src/cli.rs" "$tf/e/tests/deep/inner/main.rs"
printf '[package]\nname = "f"\n' > "$tf/f/Cargo.toml"
check "test-filter: lib and bin package, nested main.rs, commented [package]" 0 tfilter "$(rep e/src/cli.rs e/tests/deep/inner/main.rs)"
has "$tmp/out" '"--lib"' "module of a lib+bin package selects --lib"
has "$tmp/out" '"--bins"' "module of a lib+bin package selects --bins"
has "$tmp/out" '"flat": "--workspace --tests"' "nested main.rs under a directory without main.rs -> --tests"
# shellcheck disable=SC2016 # the literal is the point
hostile='f/tests/$(touch pwned).rs'
check "test-filter: shell metacharacters are skipped" 0 tfilter "$(rep "$hostile" 'f/tests/a b.rs' 'f/tests/ok.rs')"
has "$tmp/out" '"flat": "--workspace --test ok"' "only the plain name survives"
grep -qF 'pwned' "$tmp/out" && { echo "FAIL hostile name reached the output"; fails=$((fails+1)); }
check "test-filter: newline in a name is skipped" 0 tfilter '{"impacted":{"tests":{"files":[{"file":"f/tests/a\nf/tests/b.rs"}]}}}'
has "$tmp/out" '"flat": ""' "a name with a newline is dropped whole"

exit "$fails"
