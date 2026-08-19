#!/usr/bin/env bash
# Regenerates PKGBUILD + config for the latest ckolivas/linux (linux-ck) release,
# rebased onto the latest kernel.org point release for that branch.
#
# ck only ever tags major.minor (e.g. v7.2-ck1) and never follows up with
# point-release tags of its own (no v7.2.1-ck1) -- but kernel.org keeps
# shipping point releases with upstream bugfixes. So this always builds
# against the newest point release kernel.org has for ck's branch (7.2.3
# if that's current, just 7.2 if no point release exists yet), not the
# exact version ck last tagged.
#
# ckolivas/linux doesn't publish a standalone patch file as a release asset --
# it's a GitHub fork of torvalds/linux, so the actual -ck diff is pulled via
# GitHub's cross-fork compare endpoint (torvalds:<base tag>...ckolivas:<ck tag>),
# which returns only the diff (a few hundred KB), not the whole tree. The
# compare base is always the exact tag ck branched from (v7.2) -- point
# releases only exist on the separate linux-stable tree, not as tags on
# torvalds/linux, so v7.2 is the only valid compare anchor regardless of
# which point release we're building against. That diff is then applied on
# top of the newer point-release tarball in prepare() -- see the "Patch may
# not apply cleanly" caveat in the README, since kernel.org's own bugfixes in
# the point release can touch the same files ck's diff does.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ck_api="https://api.github.com/repos/ckolivas/linux/releases/latest"
kernel_org_releases="https://www.kernel.org/releases.json"
arch_config_url="https://gitlab.archlinux.org/archlinux/packaging/packages/linux/-/raw/main/config.x86_64"

echo "Fetching latest ck release info..."
ck_json="$(curl -sfL -H 'Accept: application/vnd.github+json' "$ck_api")"
ck_tag="$(jq -r '.tag_name' <<<"$ck_json")"

if [[ -z "$ck_tag" || "$ck_tag" == "null" ]]; then
  echo "Could not read tag_name from latest ckolivas/linux release" >&2
  exit 1
fi

# v7.2-ck1 -> kbase=7.2 ckrel=ck1
if [[ "$ck_tag" =~ ^v?([0-9]+\.[0-9]+(\.[0-9]+)?)-([a-zA-Z0-9]+)$ ]]; then
  kbase="${BASH_REMATCH[1]}"
  ckrel="${BASH_REMATCH[3]}"
else
  echo "Could not parse kernel base version out of tag: $ck_tag" >&2
  exit 1
fi
base_tag="v${kbase}"
echo "ck release: $ck_tag -> based on upstream $base_tag ($ckrel)"

echo "Resolving newest kernel.org point release for the $kbase branch..."
releases_json="$(curl -sfL "$kernel_org_releases")"
kver="$(jq -r --arg kb "$kbase" \
  '.releases[] | select(.version == $kb or (.version | startswith($kb + "."))) | .version' \
  <<<"$releases_json" | sort -V | tail -n1)"
if [[ -z "$kver" ]]; then
  echo "kernel.org has no released tarball for $kbase yet -- ck is tracking an -rc ahead of release. Nothing to build against." >&2
  exit 1
fi
if [[ "$kver" != "$kbase" ]]; then
  echo "kernel.org has moved past ck's base: building $kver (ck's diff is still generated against v$kbase, its actual branch point)"
else
  echo "kernel.org has no point release beyond $kbase yet"
fi

major="$(cut -d. -f1 <<<"$kver")"
kernel_url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${kver}.tar.xz"
checksums_url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/sha256sums.asc"

echo "Fetching kernel tarball checksum..."
kernel_sha256="$(curl -sfL "$checksums_url" | grep "linux-${kver}.tar.xz" | awk '{print $1}' | head -n1)"
if [[ -z "$kernel_sha256" ]]; then
  echo "Could not find sha256 for linux-${kver}.tar.xz in $checksums_url" >&2
  exit 1
fi

echo "Fetching -ck diff via GitHub compare (torvalds:${base_tag}...ckolivas:${ck_tag})..."
patch_url="https://github.com/ckolivas/linux/compare/torvalds:${base_tag}...ckolivas:${ck_tag}.diff"
patch_sha256="$(curl -sfL "$patch_url" | tee ck.patch | sha256sum | awk '{print $1}')"
patch_size="$(wc -c < ck.patch)"
if [[ "$patch_size" -lt 100 ]]; then
  echo "Diff came back suspiciously small ($patch_size bytes) -- compare probably failed silently." >&2
  exit 1
fi
echo "Patch fetched: $patch_size bytes"

verify_dir="$(mktemp -d)"
trap 'rm -rf "$verify_dir"' EXIT

echo "Downloading kernel tarball to verify the patch actually applies (same tarball a real build needs anyway)..."
curl -sfL "$kernel_url" -o "$verify_dir/linux-${kver}.tar.xz"
echo "${kernel_sha256}  ${verify_dir}/linux-${kver}.tar.xz" | sha256sum -c -

echo "Extracting..."
tar -C "$verify_dir" -xf "$verify_dir/linux-${kver}.tar.xz"

echo "Dry-run applying ck diff against linux-${kver}..."
if ! patch -Np1 --dry-run -d "$verify_dir/linux-${kver}" < ck.patch > "$verify_dir/patch-dryrun.log" 2>&1; then
  echo "ck diff does NOT apply cleanly against linux-${kver} -- refusing to update PKGBUILD. Dry-run output:" >&2
  cat "$verify_dir/patch-dryrun.log" >&2
  exit 1
fi
echo "Patch verified: applies cleanly against linux-${kver}"

pkgver="${kver}.${ckrel}"

rm -f ck.patch

echo "Fetching current Arch base kernel config..."
curl -sfL "$arch_config_url" -o config

echo "Rendering PKGBUILD..."
KVER="$kver" PKGVER="$pkgver" KERNEL_URL="$kernel_url" KERNEL_SHA256="$kernel_sha256" \
PATCH_URL="$patch_url" PATCH_SHA256="$patch_sha256" \
envsubst '${KVER} ${PKGVER} ${KERNEL_URL} ${KERNEL_SHA256} ${PATCH_URL} ${PATCH_SHA256}' \
  < PKGBUILD.template > PKGBUILD

echo "Done: pkgver=$pkgver (ck tag $ck_tag, ck base $base_tag, kernel.org source $kver)"
