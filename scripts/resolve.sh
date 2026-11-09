#!/usr/bin/env bash
# Prints "tag=<vX.Y.Z>" and "target=<triple>" for this runner.
# Env: INPUT_VERSION (latest|vX.Y.Z|X.Y.Z), GH_TOKEN. Test hooks: FG_OS, FG_ARCH.
set -euo pipefail

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
  tag="$(gh release view --repo GarthDB/ferrograph --json tagName --jq .tagName)"
else
  tag="v${version#v}"
fi
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || { echo "::error::Invalid version '$version'" >&2; exit 1; }

echo "tag=$tag"
echo "target=$target"
