#!/usr/bin/env bash
# Publishes one branch per kernel line named in .build-manifest (7.1, 7.2, ...).
# Each branch holds only that line's PKGBUILD, config and ck.patch (when it has
# one) at the root, so `git checkout 7.2 && makepkg -si` builds that line.
#
# History is kept: a line's branch gets a new commit only when its files change.
# Branches never contain the generator, workflow or other lines.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

manifest="$repo_root/.build-manifest"
[[ -s "$manifest" ]] || { echo "No manifest, nothing to publish."; exit 0; }

work_dir="$(mktemp -d)"
trap 'git worktree prune; rm -rf "$work_dir"' EXIT

# Checks out the line's branch (or a fresh orphan one, on a temp local branch)
# into $1, emptied.
prepare_worktree() {
  local dir="$1" line="$2"
  if git ls-remote --exit-code --heads origin "$line" > /dev/null 2>&1; then
    git fetch -q origin "$line"
    git worktree add -q --detach "$dir" FETCH_HEAD
  else
    git worktree add -q --detach "$dir" HEAD
    git -C "$dir" checkout -q --orphan "publish/$line"
  fi
  git -C "$dir" rm -rfq --ignore-unmatch .
  find "$dir" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
}

while IFS=$'\t' read -r line pkgver _primary _changed; do
  src="$repo_root/lines/$line"
  if [[ ! -f "$src/PKGBUILD" ]]; then
    echo "lines/$line has no PKGBUILD, skipping branch"
    continue
  fi

  dir="$work_dir/$line"
  prepare_worktree "$dir" "$line"
  cp "$src"/* "$dir"/
  git -C "$dir" add -A

  if git -C "$dir" diff --cached --quiet; then
    echo "Branch $line already at $pkgver"
    continue
  fi

  git -C "$dir" commit -q -m "chore: linux-ck $pkgver" \
    -m "Generated from lines/$line on main."
  git -C "$dir" push -q origin "HEAD:refs/heads/$line"
  echo "Branch $line updated to $pkgver"

  # The orphan case leaves a temp local branch; drop it so a local run does not
  # leave branches that collide with the developer's own.
  git worktree remove --force "$dir"
  git branch -D "publish/$line" > /dev/null 2>&1 || true
done < "$manifest"
