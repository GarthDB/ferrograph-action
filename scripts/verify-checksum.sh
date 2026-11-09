#!/usr/bin/env bash
# Usage: verify-checksum.sh <file> <SHA256SUMS>; exits non-zero on mismatch or missing entry.
set -euo pipefail

file="$1" sums="$2"
name="$(basename "$file")"
expected="$(awk -v n="$name" '{f=$2; sub(/^\*/, "", f); if (f == n) print $1}' "$sums")"
[ -n "$expected" ] || { echo "::error::No checksum for $name in $sums" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$file" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
fi
if [ "$actual" != "$expected" ]; then
  echo "::error::Checksum mismatch for $name (expected $expected, got $actual)" >&2
  exit 1
fi
echo "Checksum OK: $name"
