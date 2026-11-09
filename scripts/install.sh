#!/usr/bin/env bash
# Downloads, verifies and extracts ferrograph into $FG_BIN_DIR (skips if cached).
# Env: TAG, TARGET, FG_BIN_DIR, GH_TOKEN.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
if [ ! -x "$FG_BIN_DIR/ferrograph" ]; then
  tmp="$(mktemp -d)"
  archive="ferrograph-$TARGET.tar.gz"
  gh release download "$TAG" --repo GarthDB/ferrograph --dir "$tmp" --pattern "$archive" --pattern SHA256SUMS
  "$here/verify-checksum.sh" "$tmp/$archive" "$tmp/SHA256SUMS"
  mkdir -p "$FG_BIN_DIR"
  tar -xzf "$tmp/$archive" -C "$FG_BIN_DIR" ferrograph
  rm -rf "$tmp"
fi
[ -z "${GITHUB_PATH:-}" ] || echo "$FG_BIN_DIR" >> "$GITHUB_PATH"
"$FG_BIN_DIR/ferrograph" --version
