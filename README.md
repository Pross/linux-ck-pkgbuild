# linux-ck-pkgbuild

Auto-generated Arch PKGBUILD for [linux-ck](https://github.com/ckolivas/linux) (Con Kolivas patched kernel).

A daily GitHub Action (`.github/workflows/update-pkgbuild.yml`) does:

1. Reads the latest release from `ckolivas/linux` (e.g. tag `v7.2-ck1`) and
   parses out the exact upstream tag it branched from (`v7.2`) and the ck
   revision (`ck1`).

   `ckolivas/linux` doesn't publish a standalone patch file as a release
   asset — it's a full source-tree fork of `torvalds/linux` (confirmed via
   the GitHub API `parent`/`source` fields), not a repo that ships diffs. So
   the actual -ck patch is pulled via GitHub's cross-fork compare endpoint —
   `.../compare/torvalds:v7.2...ckolivas:v7.2-ck1.diff` — which returns just
   the diff (a few hundred KB), not the whole kernel tree.
2. Resolves the newest kernel.org **point release** for that branch via
   `https://www.kernel.org/releases.json` — `7.2.3` if that's current, just
   `7.2` if kernel.org hasn't shipped a point release yet. ck only ever tags
   major.minor and never follows up with its own point-release tags, but
   kernel.org keeps shipping point-release bugfixes, so this is what keeps
   the package from silently going stale for months at a time.

   The compare base for the ck diff itself (step 1) always stays the exact
   tag ck branched from (`v7.2`), never the point release — point releases
   only exist on the separate linux-stable tree, not as tags on
   `torvalds/linux`, so `v7.2` is the only valid compare anchor either way.
3. Pulls that point release's published sha256 from kernel.org, and computes
   the small ck diff's sha256 itself (ck doesn't publish checksums).
4. **Downloads the point-release tarball and dry-run applies the ck diff
   against it** (`patch -Np1 --dry-run`) before touching `PKGBUILD` at all.
   If it doesn't apply cleanly, the script fails here and nothing gets
   committed — see the caveat below for why this can happen and what it
   means when it does.
5. Pulls Arch's current base kernel `config.x86_64` from their packaging repo.
6. Renders `PKGBUILD` from `PKGBUILD.template` — `pkgver` is
   `<kernel.org point release>.<ck revision>`, e.g. `7.2.3.ck1` — and commits
   it straight to `main` if anything changed.
7. If (and only if) that commit happened, tags it `v<pkgver>` and creates a
   GitHub Release with `PKGBUILD` + `config` attached, so you can grab a
   given version's exact files without cloning.

## Subscribing to updates

Rather than polling commits, use GitHub's native release notifications:

- **Watch → Custom → Releases** on the repo page for notifications whenever
  a new version ships (only fires when something actually changed, per the
  no-op check in step 6/7 above).
- Or subscribe to `https://github.com/Pross/linux-ck-pkgbuild/releases.atom`
  in any RSS/Atom reader.

## Important caveats

- **Patch may not apply cleanly.** ck's diff is generated against the exact
  tag it branched from (`v7.2`), but it's applied on top of whatever the
  newest point release is (`7.2.3`'s tarball, not `7.2`'s). If a point
  release's own upstream bugfixes touch the same files ck's diff does,
  `patch -Np1` can fail or apply with fuzz. This gets more likely the further
  kernel.org drifts from ck's original branch point. Step 4 above catches
  this with a real dry-run against the real tarball before any commit
  happens, so a failure here means the Action goes red (no silent bad
  commit) — check the run log for which hunks failed and why. This is still
  a dry-run of `prepare()`, not a full `makepkg` build (see below), so
  config/build-time issues past that point aren't caught.
- **No CI build/test.** Adding a real build step would need an Arch container
  and a lot more time/resources than a free-tier Actions runner budget allows
  for a full kernel compile on a schedule. If you want that, it belongs in a
  separate manually-triggered workflow, not the daily cron.
- **`config` is Arch's stock config**, not ck-tuned. It's regenerated with
  `make olddefconfig` against the patched source each build, so it'll pick up
  new patched-in options with their defaults.
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

Two ways this resolves:
- **Con fixes it in a ck2+ release** — this repo's daily Action already
  tracks the latest ck tag automatically, so nothing changes here; the next
  run just picks up the fix.
- **Told to build with `CONFIG_PSI=n`** — would mean patching the stock Arch
  config in `scripts/update-pkgbuild.sh` before `olddefconfig` runs (e.g.
  `scripts/config --disable PSI` in `prepare()`), which isn't done yet.

## Manual run

```bash
jq --version && envsubst --version && patch --version   # deps: jq, gettext-base, patch
bash scripts/update-pkgbuild.sh
```

Downloads the full kernel tarball to verify the patch applies — expect this to
take a minute or two and use ~200MB of temp disk space (cleaned up on exit).

## Building the package yourself

```bash
makepkg -si
```

Do this in a clean Arch chroot/container, not on a production machine, until
you've confirmed a given PKGBUILD revision builds and boots.
