#!/usr/bin/env bash
# Prints "tag=<vX.Y.Z>" and "target=<triple>" for this runner.
# Env: INPUT_VERSION (latest|vX.Y.Z|X.Y.Z), GH_TOKEN. Test hooks: FG_OS, FG_ARCH, FG_RELEASES (tag list).
# `latest` is the newest stable release of the supported major, so a ferrograph 7 never reaches this action version.
set -euo pipefail

SUPPORTED_MAJOR=6

os="${FG_OS:-$(uname -s)}"
arch="${FG_ARCH:-$(uname -m)}"
case "$os/$arch" in
  Linux/x86_64) target=x86_64-unknown-linux-gnu ;;
  Linux/aarch64 | Linux/arm64) target=aarch64-unknown-linux-gnu ;;
  Darwin/arm64) target=aarch64-apple-darwin ;;
  *) echo "::error::Unsupported runner $os/$arch. Supported: linux x64, linux arm64, macOS arm64." >&2; exit 1 ;;
esac

version="${INPUT_VERSION:-latest}"
if [ "$version" = latest ]; then
  releases="${FG_RELEASES:-$(gh release list --repo GarthDB/ferrograph --limit 100 --exclude-drafts --exclude-pre-releases --json tagName --jq '.[].tagName')}"
  tag="$(grep -E "^v$SUPPORTED_MAJOR\\.[0-9]+\\.[0-9]+\$" <<< "$releases" | sort -V | tail -n 1 || true)"
  [ -n "$tag" ] || { echo "::error::No stable ferrograph v$SUPPORTED_MAJOR release found; set the 'version' input." >&2; exit 1; }
else
  tag="v${version#v}"
fi
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || { echo "::error::Invalid version '$version'" >&2; exit 1; }

# `pr --out` (one run, several reports) arrived in 5.0.0.
major="${tag#v}"; major="${major%%.*}"
[ "$major" -ge 5 ] || { echo "::error::ferrograph $tag is too old: this action needs v5.0.0 or later (pr --out)." >&2; exit 1; }

echo "tag=$tag"
echo "target=$target"
