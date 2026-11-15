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
check "run.sh old report" 0 runsh env
grep -q impacted "$tmp/gho" && { echo "FAIL impacted outputs set for an old report"; fails=$((fails+1)); }
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

exit "$fails"
