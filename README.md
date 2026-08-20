# linux-ck-pkgbuild

Auto-generated Arch PKGBUILD for [linux-ck](https://github.com/ckolivas/linux) (Con Kolivas patched kernel).

A daily GitHub Action (`.github/workflows/update-pkgbuild.yml`) packages **every
kernel line ck still maintains**, not just the newest release.

### Why lines, and not just "the latest release"

ck maintains more than one kernel series at a time, and does not publish them in
version order. `v7.1.9-ck3` shipped on 2026-08-20, three days *after* `v7.2-ck1`.
So GitHub's `releases/latest` — which means most recently *published* — would
have moved this package backwards from 7.2 to 7.1.9.

A **line** is `major.minor`. Within a line only the newest ck revision is
packaged, ranked by base version first and ck revision second, so line `7.1`
resolves to `v7.1.9-ck3` rather than `v7.1-ck3`. The highest kernel version
across all lines is the **primary**.

- Each line is rendered to `lines/<line>/` and released as `v<pkgver>`.
- The primary line is also copied to the repo root, so `makepkg -si` in a fresh
  clone still builds the newest kernel.
- Only the primary release is marked **Latest**. Older lines stay fetchable but
  never take the badge — set explicitly, since GitHub would otherwise give it to
  whatever was published most recently.

### What a run does, per line

1. Resolves the newest kernel.org **point release** for that line via
   `https://www.kernel.org/releases.json` — `7.2.3` if that is current, just
   `7.2` if kernel.org has not shipped one yet. kernel.org keeps shipping
   bugfixes long after ck stops tagging, so this is what keeps a line from
   silently going stale.
2. Skips the line entirely if `lines/<line>/PKGBUILD` already sits at the
   computed `pkgver` — checked before any download, so a run with nothing to do
   costs under a second.
3. Obtains the -ck diff (see below), pulls the point release's published sha256
   from kernel.org, and computes the diff's sha256 itself since ck publishes
   none.
4. **Downloads the tarball and dry-run applies the diff against it**
   (`patch -Np1 --dry-run`) before writing anything. A failure here fails the
   run rather than committing something that cannot build.
5. Pulls Arch's current base kernel `config.x86_64` and renders `PKGBUILD` from
   `PKGBUILD.template`, with `pkgver` of `<point release>.<ck revision>` — e.g.
   `7.2.ck1`, `7.1.9.ck3`.

Anything that changed is committed to `main` in one commit, and each changed
line gets its own tagged GitHub Release with its `PKGBUILD`, `config`, and (when
applicable) `ck.patch` attached.

### Where the -ck diff comes from

`ckolivas/linux` is a full source-tree fork of `torvalds/linux`, not a repo that
ships diffs, so there is no patch file to download. Normally the diff comes from
GitHub's cross-fork compare endpoint —
`.../compare/torvalds:v7.2...ckolivas:v7.2-ck1.diff` — which returns a few
hundred KB instead of the whole tree.

That needs the tag ck branched from to exist in `torvalds/linux`, which is only
true for `major.minor` tags. For a **point-release ck tag there is no usable
compare base at all**:

| Compare base for `v7.1.9-ck3` | Result |
|---|---|
| `torvalds:v7.1.9...` | 404 — point releases are not tagged in `torvalds/linux`, they live on the stable tree |
| `gregkh:v7.1.9...` | 404 — `gregkh/linux` has the tag but is not a fork, so it is outside ckolivas's fork network and cross-network compare is refused |
| `torvalds:v7.1...` | 200, but 6.9 MB: every upstream 7.1→7.1.9 stable fix *plus* ck's changes. Applying that onto the 7.1.9 tarball conflicts with fixes already in it. Wrong diff. |

So for those tags the diff is computed locally instead: ck's own tag tarball is
downloaded and `diff -ruN`'d against the kernel.org tarball already extracted for
verification. The result is committed as `lines/<line>/ck.patch` and referenced
by filename in `source=()`, because a computed diff has no URL to point at. It is
attached to the release too, so a release download stays self-sufficient.

As a sanity check on that path, the computed 7.1.9 diff came out at 527 KB
against the compare endpoint's 522 KB for 7.2 — a multi-MB result would mean
upstream changes had leaked in, and the script fails rather than commit one.

Source tarballs are fetched through the API endpoint with a token, because
anonymous archive downloads of a repo this size get HTTP 429 (confirmed from a
clean container).

## Subscribing to updates

Rather than polling commits, use GitHub's native release notifications:

- **Watch → Custom → Releases** on the repo page for notifications whenever
  a new version ships (only fires when something actually changed).

  Note this now includes **older lines**, not just the newest kernel — a
  `7.1.9.ck3` release will notify even while `7.2.ck1` is the current primary.
  Only the primary carries the **Latest** badge, so that is what to check if you
  only care about the newest kernel.
- Or subscribe to `https://github.com/Pross/linux-ck-pkgbuild/releases.atom`
  in any RSS/Atom reader.

## Important caveats

- **Patch may not apply cleanly.** A compare-endpoint diff is generated against
  the exact tag ck branched from (`v7.2`), but it's applied on top of whatever
  the newest point release is (`7.2.3`'s tarball, not `7.2`'s). If a point
  release's own upstream bugfixes touch the same files ck's diff does,
  `patch -Np1` can fail or apply with fuzz, and this gets more likely the
  further kernel.org drifts from ck's branch point. A locally computed diff
  doesn't have this problem — it is generated against the exact tarball it will
  be applied to. Either way the dry-run catches it before any commit, so a
  failure means the Action goes red rather than committing something unbuildable
  — check the run log for which hunks failed. This is still a dry-run of
  `prepare()`, not a full `makepkg` build, so config/build-time issues past that
  point aren't caught.
- **One line failing fails the whole run.** The script exits on the first line
  whose patch won't apply, so a broken older line blocks a good primary from
  being published that day. Acceptable while ck maintains two lines; worth
  revisiting if that grows.
- **No CI build/test.** Adding a real build step would need an Arch container
  and a lot more time/resources than a free-tier Actions runner budget allows
  for a full kernel compile on a schedule. If you want that, it belongs in a
  separate manually-triggered workflow, not the daily cron.
- **`config` is Arch's stock config**, not ck-tuned, and the *same* config is
  used for every line — Arch only publishes one, tracking their current kernel.
  It's regenerated with `make olddefconfig` against the patched source each
  build, so it'll pick up new patched-in options with their defaults, but an
  older line is getting a config written for a newer kernel.
- **Scoped down vs the real Arch `linux`/`linux-mainline` PKGBUILD**, which
  this was checked against ([AUR `linux-mainline`](https://aur.archlinux.org/cgit/aur.git/tree/PKGBUILD?h=linux-mainline)).
  Deliberately kept, since they matter for the kernel to boot correctly and
  coexist with other installed kernels:
  - `pkgbase` marker file in `/usr/lib/modules/$kernver/` (mkinitcpio names
    the initramfs per-kernel off this)
  - `DEPMOD=/doesnt/exist` on `modules_install` (real depmod runs later via
    kmod's pacman hook against the real root, not the build chroot)
  - `version`/`localversion.*` files (stable `uname -r` string per pkgrel,
    avoids `/usr/lib/modules/$kernver` collisions across rebuilds)
  - `make -s image_name` for the vmlinuz path instead of a hardcoded
    `arch/x86/boot/bzImage`
  Deliberately dropped, out of scope for "build a working -ck kernel + headers":
  - `-docs` subpackage
  - BTF/`vmlinux`, `tools/bpf/bpftool` build, Rust support
  - non-x86_64 arch handling

## Known issue: v7.2-ck1 fails to build with CONFIG_PSI=y

Confirmed on real hardware (not emulation), reproduced twice from a clean
build: compiling against `linux-7.2` + the `v7.2-ck1` diff fails in
`kernel/sched/build_muqss.c`:

```
kernel/sched/psi.c: In function 'psi_account_irqtime':
kernel/sched/psi.c:1025:33: error: 'struct rq' has no member named 'psi_irq_time'; did you mean 'prev_irq_time'?
```

**Root cause:** `build_muqss.c` does `#include "psi.c"` under
`#ifdef CONFIG_PSI`, pulling in vanilla `psi.c` unmodified. Vanilla `psi.c`
references `rq->psi_irq_time` (added by upstream's 2022 PSI-IRQ-tracking
commit). The -ck diff's changes to `struct rq` never add that field — it only
carries MuQSS's own long-standing, separately-named `prev_irq_time` field,
used by MuQSS's own irq-time accounting. The two were never reconciled, so
**any build with `CONFIG_PSI=y` fails**, including Arch's stock desktop
config (`CONFIG_PSI` defaults off in vanilla Kconfig — no `default` line —
which is almost certainly why this hasn't been widely reported: most people
testing -ck likely don't have PSI enabled).

Verified this isn't an artifact of how this repo builds the patch (three-dot
GitHub compare, resolved merge-base checked directly against the `v7.2` tag's
actual commit — they match) and isn't a stale-config issue either (checked
against Arch's real, current `linux` package `PKGBUILD`, which builds the
same way we do: `cp config; make olddefconfig`, no PSI-specific handling).

Reported: [comment on the linux-7.2-ck1 announcement](https://ck-hack.blogspot.com/2026/08/linux-72-ck1-muqss-v0310-for-linux-72.html)
(issues are disabled on `ckolivas/linux`, so the blog is the live channel).

**Status (2026-08-20):** Con reproduced it using the stock Arch config and has
pushed a fix to the `7.2-ck` branch — but has **not tagged a ck2**. This repo
only ever consumes releases, so nothing picks the fix up until he cuts one. When
he does, the daily Action takes it automatically with no change here.

The fallback, if a fix never lands, is building with `CONFIG_PSI=n` — patching
the stock Arch config before `olddefconfig` runs (e.g. `scripts/config --disable
PSI` in `prepare()`). Not done, and not worth doing while an upstream fix is
already written.

## Manual run

```bash
# deps: jq, gettext-base, patch, curl, xz-utils, diffutils
GH_TOKEN="$(gh auth token)" bash scripts/update-pkgbuild.sh
```

`GH_TOKEN` is optional but recommended: without it, the source-tarball download
needed for locally computed diffs gets HTTP 429.

Downloads a full kernel tarball per changed line to verify the patch applies, and
a second source tarball for any line needing a local diff — expect a few minutes
and a couple of GB of temp space (cleaned up on exit). A run with nothing to do
skips all of that and finishes in under a second.

The script is written for GNU userland, matching the Ubuntu Actions runner. On
macOS it won't run as-is (`sort -V`, `sha256sum`); use a container:

```bash
docker run --rm -e GH_TOKEN="$(gh auth token)" -v "$PWD":/repo -w /repo ubuntu:24.04 \
  bash -c "apt-get update -qq && apt-get install -y -qq jq gettext-base patch curl \
  ca-certificates xz-utils diffutils && bash scripts/update-pkgbuild.sh"
```

## Building the package yourself

The repo root always holds the newest kernel line:

```bash
makepkg -si
```

For an older line, build from its directory instead — each one is
self-contained:

```bash
cd lines/7.1 && makepkg -si
```

Or download a release's attached `PKGBUILD`, `config` (and `ck.patch`, if
present) into one directory and build there.

Do this in a clean Arch chroot/container, not on a production machine, until
you've confirmed a given PKGBUILD revision builds and boots.
