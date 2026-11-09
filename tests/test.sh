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
has() { if grep -q "$2" "$1"; then echo "ok   $3"; else echo "FAIL $3"; fails=$((fails+1)); fi; }

# OS/arch mapping (explicit versions avoid network)
# shellcheck disable=SC2329 # invoked through check
res() { FG_OS="$1" FG_ARCH="$2" INPUT_VERSION="${3:-4.0.0}" "$root/scripts/resolve.sh"; }
check "linux x64" 0 res Linux x86_64;      has "$tmp/out" target=x86_64-unknown-linux-gnu "x64 target"
check "linux arm64" 0 res Linux aarch64;   has "$tmp/out" target=aarch64-unknown-linux-gnu "arm64 target"
check "macOS arm64" 0 res Darwin arm64;    has "$tmp/out" target=aarch64-apple-darwin "mac target"
check "macOS x64 rejected" 1 res Darwin x86_64
check "windows rejected" 1 res MINGW64_NT x86_64
check "bare version" 0 res Linux x86_64 4.0.0;  has "$tmp/out" tag=v4.0.0 "bare version -> v4.0.0"
check "v-prefixed version" 0 res Linux x86_64 v4.0.0; has "$tmp/out" tag=v4.0.0 "v version kept"
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

exit "$fails"
