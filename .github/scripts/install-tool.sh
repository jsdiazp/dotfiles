#!/usr/bin/env bash
# install-tool.sh — install one pinned CI tool on a Linux x86_64 runner.
#
# Usage: install-tool.sh <shellcheck|shfmt|actionlint|gitleaks>
#
# Every download is verified against the SHA-256 digest GitHub publishes for
# the release asset, so CI runs exactly the versions this repo is kept clean
# against and a swapped or truncated binary fails the job. No third-party
# actions are involved. All versions and digests live in this one file.
#
# To bump a tool, change its version, URL and digest TOGETHER:
#   gh api repos/<owner>/<repo>/releases/tags/<tag> --jq '.assets[] | {name, digest}'
#
# Env: INSTALL_DIR (default ~/.local/bin). On GitHub Actions the directory is
# also appended to $GITHUB_PATH so later steps can call the tool by name.

set -euo pipefail

tool="${1:-}"
dest="${INSTALL_DIR:-$HOME/.local/bin}"

case "$tool" in
  shellcheck)
    url="https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.gz"
    sha="b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6"
    member="shellcheck-v0.11.0/shellcheck"
    version_cmd="--version"
    ;;
  shfmt)
    url="https://github.com/mvdan/sh/releases/download/v3.14.1/shfmt_v3.14.1_linux_amd64"
    sha="76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf"
    member=""
    version_cmd="--version"
    ;;
  actionlint)
    url="https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz"
    sha="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
    member="actionlint"
    version_cmd="-version"
    ;;
  gitleaks)
    url="https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz"
    sha="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
    member="gitleaks"
    version_cmd="version"
    ;;
  *)
    echo "usage: $(basename "$0") <shellcheck|shfmt|actionlint|gitleaks>" >&2
    exit 2
    ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --retry 3 -o "$tmp/asset" "$url"
echo "${sha}  ${tmp}/asset" | sha256sum -c -

mkdir -p "$dest"
if [ -n "$member" ]; then
  tar -xzf "$tmp/asset" -C "$tmp" "$member"
  install -m 0755 "$tmp/$member" "$dest/$tool"
else
  install -m 0755 "$tmp/asset" "$dest/$tool"
fi

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$dest" >>"$GITHUB_PATH"
fi
"$dest/$tool" "$version_cmd"
