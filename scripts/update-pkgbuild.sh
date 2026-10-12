#!/usr/bin/env bash
# Regenerates a PKGBUILD per ck kernel line, each rebased onto the newest
# kernel.org point release for that line.
#
# ck maintains more than one kernel line at a time and does not publish them in
# version order -- v7.1.9-ck3 shipped three days after v7.2-ck1 -- so "newest
# release" is not "newest kernel". Every line ck still tags gets packaged; the
# highest kernel version is the primary and is what lands at the repo root.
#
# ck pushes tags, not GitHub releases, so lines are discovered from the tag list.
# Tags below $ck_min_line are ignored: ck tagged old longterm kernels once and
# those are not lines he maintains.
#
# A "line" is major.minor. Within a line only the newest ck revision is built,
# ranked by base version first and ck revision second.
#
# A major.minor ck tag is rebased onto the newest kernel.org point release. A
# point-release ck tag (v7.2.10-ck1) is packaged on exactly that base: its diff
# is computed against that tree, so applying it to a newer point release would
# silently revert the stable fixes in between.
#
# A line that fails (patch does not apply, download fails) is reported and
# skipped; the other lines still publish, and the script exits non-zero at the
# end so the run still goes red.
#
# The -ck diff normally comes from GitHub's cross-fork compare endpoint
# (torvalds:<base tag>...ckolivas:<ck tag>), which returns a few hundred KB
# instead of the whole tree. That needs the tag ck branched from to exist in
# torvalds/linux, which is only true for major.minor tags: point releases live
# on the stable tree, and the stable mirror is outside ckolivas's fork network,
# so neither torvalds:v7.1.9 nor gregkh:v7.1.9 is a usable compare base. For
# those tags the diff is computed locally instead, by diffing ck's own tag
# tarball against the kernel.org tarball, and the result is committed and
# consumed as a local source.
#
# Whichever way the diff is obtained, it is dry-run applied against the real
# tarball before anything is written -- see the README caveat, since kernel.org
# point-release fixes can touch the same files ck's diff does.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ck_repo_url="https://github.com/ckolivas/linux.git"
# Oldest kernel line to package; older ck tags are ignored.
ck_min_line="7.1"
kernel_org_releases="https://www.kernel.org/releases.json"
arch_config_url="https://gitlab.archlinux.org/archlinux/packaging/packages/linux/-/raw/main/config.x86_64"
# The API tarball endpoint rather than github.com/.../archive/: both redirect to
# codeload, but the API one accepts a token, and anonymous codeload archive
# fetches of a repo this size get 429'd (confirmed from a clean container).
ck_tarball_api="https://api.github.com/repos/ckolivas/linux/tarball"

# A locally computed diff that comes out this large is upstream changes leaking
# in, not ck's patch -- fail rather than commit it.
max_patch_bytes=$((3 * 1024 * 1024))

# Unauthenticated GitHub API calls are capped at 60/hr per IP, shared across
# every other job on the runner pool -- easy to exhaust. Sent with every
# api.github.com request, not just the tarball fetch, to actually get the
# 5000/hr authenticated limit.
gh_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
gh_auth=()
[[ -n "$gh_token" ]] && gh_auth=(-H "Authorization: Bearer $gh_token")

manifest="$repo_root/.build-manifest"
: > "$manifest"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# ---------------------------------------------------------------- line picking

echo "Fetching ck tags..."
ck_tags="$(git ls-remote --tags --refs "$ck_repo_url" | awk '{ sub("refs/tags/", "", $2); print $2 }')"

# tag -> "<line> <kbase> <ckrev> <tag>", skipping anything not vX.Y[.Z]-ckN or
# older than $ck_min_line
candidates="$(
  while read -r tag; do
    [[ "$tag" =~ ^v?([0-9]+\.[0-9]+)(\.[0-9]+)?-ck([0-9]+)$ ]] || continue
    line="${BASH_REMATCH[1]}"
    [[ "$(printf '%s\n%s\n' "$ck_min_line" "$line" | sort -V | head -n1)" == "$ck_min_line" ]] || continue
    kbase="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    ckrev="${BASH_REMATCH[3]}"
    printf '%s %s %s %s\n' "$line" "$kbase" "$ckrev" "$tag"
  done <<<"$ck_tags"
)"

if [[ -z "$candidates" ]]; then
  echo "No usable ck release tags found" >&2
  exit 1
fi

# Best tag per line: highest base version, then highest ck revision.
lines="$(
  sort -t' ' -k1,1V -k2,2V -k3,3n <<<"$candidates" |
  awk '{ best[$1] = $0 } END { for (l in best) print best[l] }' |
  sort -t' ' -k2,2V
)"

primary_line="$(tail -n1 <<<"$lines" | cut -d' ' -f1)"
echo "Lines to track (primary: $primary_line):"
sed 's/^/  /' <<<"$lines"

echo "Fetching current Arch base kernel config..."
curl -sfL "$arch_config_url" -o "$work_dir/config"

# ------------------------------------------------------------------- per line

# Newest kernel.org point release on a line's base, e.g. 7.1 -> 7.1.9.
resolve_kver() {
  local kbase="$1"
  jq -r --arg kb "$kbase" \
    '.releases[] | select(.version == $kb or (.version | startswith($kb + "."))) | .version' \
    <<<"$kernel_org_json" | sort -V | tail -n1
}

# Fetches ck's diff via the compare endpoint. Fails if the base tag isn't in
# torvalds/linux, which is the normal case for point-release ck tags.
fetch_compare_diff() {
  local base_tag="$1" ck_tag="$2" out="$3"
  local url="https://github.com/ckolivas/linux/compare/torvalds:${base_tag}...ckolivas:${ck_tag}.diff"
  local code
  code="$(curl -sL -o "$out" -w '%{http_code}' "$url")"
  [[ "$code" == "200" ]] || return 1
  # A 404 still writes GitHub's HTML error page, so check it looks like a diff.
  head -n1 "$out" | grep -q '^diff --git ' || return 1
  echo "$url"
}

# Source tarball for a ck tag. Sends a token when one is in the environment,
# because unauthenticated archive downloads of this repo get rate limited, and
# retries since a 429 is transient.
fetch_ck_tarball() {
  local ck_tag="$1" out="$2"
  local attempt code
  for attempt in 1 2 3; do
    code="$(curl -sL "${gh_auth[@]}" -o "$out" -w '%{http_code}' "${ck_tarball_api}/${ck_tag}")"
    if [[ "$code" == "200" ]]; then
      return 0
    fi
    echo "  ck tarball fetch got HTTP $code (attempt $attempt/3)" >&2
    sleep $((attempt * 15))
  done
  echo "  Could not download ck tarball for $ck_tag after 3 attempts (last HTTP $code)" >&2
  return 1
}

# Computes the diff locally by comparing ck's tag tarball against the kernel.org
# tree already extracted for verification.
compute_local_diff() {
  local ck_tag="$1" src_tree="$2" out="$3"
  local tarball="$work_dir/ck-${ck_tag}.tar.gz"
  local extract="$work_dir/ck-${ck_tag}"

  echo "  No compare base for $ck_tag -- computing diff from ck's tag tarball" >&2
  mkdir -p "$extract"
  fetch_ck_tarball "$ck_tag" "$tarball" || return 1
  tar -C "$extract" -xzf "$tarball"

  local ck_tree
  ck_tree="$(find "$extract" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "$ck_tree" ]] || { echo "  ck tarball extracted no directory" >&2; return 1; }

  # diff exits 1 when it finds differences, which is the expected outcome here.
  ( cd "$(dirname "$src_tree")" \
    && diff -ruN --exclude=.git "$(basename "$src_tree")" "$ck_tree" > "$out" ) || true

  local size
  size="$(wc -c < "$out")"
  if [[ "$size" -eq 0 ]]; then
    echo "  Computed diff is empty -- tree layout is wrong, not 'ck changed nothing'" >&2
    return 1
  fi
  if [[ "$size" -gt "$max_patch_bytes" ]]; then
    echo "  Computed diff is ${size} bytes, over the ${max_patch_bytes} limit -- upstream changes are leaking in" >&2
    return 1
  fi
  return 0
}

kernel_org_json="$(curl -sfL "$kernel_org_releases")"

record_manifest() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$manifest"
}

# Kernel version to package: ck's own base for a point-release tag, the newest
# kernel.org point release for a major.minor tag.
pick_kver() {
  local line="$1" kbase="$2"
  if [[ "$kbase" != "$line" ]]; then
    echo "$kbase"
  else
    resolve_kver "$kbase"
  fi
}

# Downloads and verifies the kernel.org tarball into $line_dir, extracts it, and
# sets kernel_url and kernel_sha256 for the PKGBUILD.
fetch_kernel() {
  local kver="$1" line_dir="$2"
  local kmajor
  kmajor="$(cut -d. -f1 <<<"$kver")"
  kernel_url="https://cdn.kernel.org/pub/linux/kernel/v${kmajor}.x/linux-${kver}.tar.xz"
  local checksums_url="https://cdn.kernel.org/pub/linux/kernel/v${kmajor}.x/sha256sums.asc"

  kernel_sha256="$(curl -sfL "$checksums_url" | grep "linux-${kver}.tar.xz" | awk '{print $1}' | head -n1)"
  if [[ -z "$kernel_sha256" ]]; then
    echo "  Could not find sha256 for linux-${kver}.tar.xz" >&2
    exit 1
  fi

  echo "  Downloading linux-${kver} tarball..."
  mkdir -p "$line_dir"
  curl -sfL "$kernel_url" -o "$line_dir/linux-${kver}.tar.xz"
  echo "${kernel_sha256}  ${line_dir}/linux-${kver}.tar.xz" | sha256sum -c - > /dev/null
  tar -C "$line_dir" -xf "$line_dir/linux-${kver}.tar.xz"
}

# Obtains ck's diff, sets patch_url (empty for a local diff) and patch_sha256,
# and dry-run applies it against the extracted tree before anything is written.
obtain_patch() {
  local kbase="$1" ck_tag="$2" src_tree="$3" patch_file="$4" line_dir="$5"

  if patch_url="$(fetch_compare_diff "v${kbase}" "$ck_tag" "$patch_file")"; then
    echo "  Patch from compare endpoint ($(wc -c < "$patch_file") bytes)"
  else
    patch_url=""
    compute_local_diff "$ck_tag" "$src_tree" "$patch_file"
    echo "  Patch computed locally ($(wc -c < "$patch_file") bytes)"
  fi
  patch_sha256="$(sha256sum "$patch_file" | awk '{print $1}')"

  echo "  Dry-run applying against $(basename "$src_tree")..."
  if ! patch -Np1 --dry-run -d "$src_tree" < "$patch_file" > "$line_dir/dryrun.log" 2>&1; then
    echo "  ck diff does NOT apply cleanly against $(basename "$src_tree") -- refusing to update this line:" >&2
    cat "$line_dir/dryrun.log" >&2
    exit 1
  fi
  echo "  Patch verified"
}

# Writes lines/<line>/ from the template. A locally computed diff has no
# upstream URL, so it ships in the repo and is referenced by filename; makepkg
# checksums local sources the same way.
render_line() {
  local out_dir="$1" kver="$2" pkgver="$3" patch_file="$4"
  local patch_source

  mkdir -p "$out_dir"
  cp "$work_dir/config" "$out_dir/config"

  if [[ -n "$patch_url" ]]; then
    patch_source="ck.patch::${patch_url}"
    rm -f "$out_dir/ck.patch"
  else
    patch_source="ck.patch"
    cp "$patch_file" "$out_dir/ck.patch"
  fi

  KVER="$kver" PKGVER="$pkgver" KERNEL_URL="$kernel_url" KERNEL_SHA256="$kernel_sha256" \
  PATCH_SOURCE="$patch_source" PATCH_SHA256="$patch_sha256" \
  envsubst '${KVER} ${PKGVER} ${KERNEL_URL} ${KERNEL_SHA256} ${PATCH_SOURCE} ${PATCH_SHA256}' \
    < PKGBUILD.template > "$out_dir/PKGBUILD"
}

process_line() {
  local line="$1" kbase="$2" ckrev="$3" ck_tag="$4"
  local out_dir="$repo_root/lines/$line" line_dir="$work_dir/$line"
  local is_primary=0 kver pkgver
  [[ "$line" == "$primary_line" ]] && is_primary=1

  echo
  echo "=== line $line ($ck_tag) ==="

  kver="$(pick_kver "$line" "$kbase")"
  if [[ -z "$kver" ]]; then
    echo "  kernel.org has no tarball for $kbase yet -- ck is ahead of release, skipping line"
    return 0
  fi
  pkgver="${kver}.ck${ckrev}"

  # Checked before any download so steady-state runs are close to free.
  if [[ -f "$out_dir/PKGBUILD" ]] && grep -qx "pkgver=${pkgver}" "$out_dir/PKGBUILD"; then
    echo "  Already at $pkgver, skipping"
    record_manifest "$line" "$pkgver" "$is_primary" 0
    return 0
  fi

  echo "  Target: $pkgver (kernel.org $kver, ck $ck_tag)"
  fetch_kernel "$kver" "$line_dir"
  obtain_patch "$kbase" "$ck_tag" "$line_dir/linux-${kver}" "$line_dir/ck.patch" "$line_dir"
  render_line "$out_dir" "$kver" "$pkgver" "$line_dir/ck.patch"

  record_manifest "$line" "$pkgver" "$is_primary" 1
  echo "  Wrote lines/$line/"
}

# Each line runs in its own subshell so one failing line cannot stop the rest.
# set -e is switched off around the call and back on inside it, because errexit
# is ignored for anything run in a conditional context.
failed_lines=()
while read -r line kbase ckrev ck_tag; do
  set +e
  ( set -e; process_line "$line" "$kbase" "$ckrev" "$ck_tag" )
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "!! line $line FAILED (exit $rc), continuing with the other lines" >&2
    failed_lines+=("$line")
  fi
done <<<"$lines"

# --------------------------------------------------------------- primary copy

primary_dir="$repo_root/lines/$primary_line"
if [[ -d "$primary_dir" ]]; then
  echo
  echo "Copying primary line $primary_line to repo root..."
  cp "$primary_dir/PKGBUILD" "$repo_root/PKGBUILD"
  cp "$primary_dir/config" "$repo_root/config"
  if [[ -f "$primary_dir/ck.patch" ]]; then
    cp "$primary_dir/ck.patch" "$repo_root/ck.patch"
  else
    rm -f "$repo_root/ck.patch"
  fi
fi

echo
if awk -F'\t' '$4 == 1 { found = 1 } END { exit !found }' "$manifest"; then
  echo "Done. Changed lines:"
  awk -F'\t' '$4 == 1 { printf "  %s -> %s%s\n", $1, $2, ($3 == 1 ? " (primary)" : "") }' "$manifest"
else
  echo "Done. Nothing changed."
fi

if [[ "${#failed_lines[@]}" -gt 0 ]]; then
  echo "FAILED lines: ${failed_lines[*]}" >&2
  exit 1
fi
