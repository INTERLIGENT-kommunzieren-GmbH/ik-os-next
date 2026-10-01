# ADR 0024 — A persistent apt overlay on /usr, one per deployment

**Status:** accepted
**SDD:** §4, §24, §40; Rules 4, 5, 12, 15
**Amends:** SDD §4 ("Developers MUST NOT normally modify `/usr`"), §40 ("MUST
NOT normally execute `apt` against the host"), Rule 4; the `bootc usr-overlay`
paragraph in `docs/development.md`

## Context

RakuOS (a Fedora bootc desktop) calls itself *hybrid atomic*: the base is an
image that updates as a whole, and on top of it the user installs native
packages with `dnf`. Those packages survive image updates. We want the same
thing on ik-os, with apt.

On ik-os today the only ways to add software are Flatpak, Homebrew, containers,
or a change to the image (SDD §54). That covers most needs. It leaves out a
Debian package that is only in the archive, and anything that only works when
installed natively.

### How RakuOS does it

Read from `RakuOS/rakuos-base`, `system_files/usr/libexec/rakuos/`:

- A sysinit service mounts
  `overlay lowerdir=/usr,upperdir=/var/lib/rakuos/overlay/upper` on `/usr`.
- `rakuos install` wraps `dnf5`, appends the package name to
  `/var/lib/rakuos/packages.list`, and refuses packages that the base image
  owns.
- After an image update, `rakuos-overlay-sync` (about 640 lines) reconciles the
  old upper directory with the new base. It re-seeds the rpm database from the
  base, re-registers the overlay packages, "hands back" files once the base has
  caught up to them, and reinstalls anything missing. It holds back the display
  manager while it waits for DNS.

The project calls the overlay experimental. The reconciliation is why: an upper
directory built against image N is mounted over image N+1. Its files, and its
copied-up package database, shadow whatever N+1 changed.

`bootc usr-overlay` is a different thing. It is transient, and it has already
been rejected twice (ADR 0013, ADR 0023): a change that holds until the next
reboot is the worst of both.

## Decision

`/usr` gets a persistent, writable overlay. **Each upper directory belongs to
exactly one deployment.** The user's package list is replayed into a fresh
upper for every new deployment. An upper is never carried from one base to
another.

| | |
| --- | --- |
| Key | the composefs deployment digest, `composefs=<sha>` on the kernel command line |
| Upper, work | `/var/lib/ik-os/usr-overlay/<digest>/{upper,work}` |
| User intent | `/var/lib/ik-os/usr-overlay/packages.list`, shared by all deployments |
| apt lists, cache | `/var/lib/ik-os/usr-overlay/apt-lists`, `/var/cache/apt` — outside the upper |
| Mounted | before switch-root when an upper for this digest exists, so systemd sees units shipped by overlay packages natively |
| New deployment | boots clean base and is fully usable; `ik-os-usr-overlay-rebuild.service` replays the list after the network is up, then notifies |
| Failed replay | the overlay is unmounted, the machine stays on clean base, the user is told |
| Rollback | the previous deployment's upper is still on disk and mounts as it was |
| GC | at boot, uppers whose digest `bootc status` no longer lists are deleted |
| Interface | `ik-os pkg install / remove / list / search / show / status / reset / rebuild` |
| Raw apt/dpkg | refused unless `ik-os pkg` holds the lock: a dpkg `pre-invoke` hook covers dpkg and everything that calls it, and apt hooks (`AptCli::Hooks::Install`/`Upgrade`, `APT::Update::Pre-Invoke`) stop `apt install/remove/upgrade/update` before they resolve anything, with a message pointing at `ik-os pkg` or `ik-os update`. `apt search` gets a hint only |
| Sources | the Debian archive and company repositories the image already configures; no local `.deb` files |

Replay costs a download after every image update. That is the price of never
reconciling, and it buys three things:

- Stale shadowing cannot happen. The new upper starts from the new base's
  `/usr/lib/dpkg/status` (ADR 0004), so apt sees the new base as it is.
- Rollback is exact.
- None of RakuOS's hand-back logic is needed.

Replay does not hold back the login screen. RakuOS does; ADR 0012 decided that
the first boot of an image narrates rather than waits, and this follows it.
For the minutes before replay finishes, overlay packages are absent. The user
is told when they are back.

### The base is not the overlay's to change

`ik-os pkg install` simulates the transaction first (`apt-get -s`). It refuses
if the transaction would do any of these:

- upgrade, downgrade or remove a package listed in
  `/usr/share/ik-os/base-packages.list`, which the build generates from
  `dpkg-query`. This covers dependencies, not only the packages named, and it
  stops the overlay quietly upgrading a base library from a newer archive.
- install anything matched by `/usr/share/ik-os/usr-overlay-denylist`, whose
  source is `config/security/usr-overlay-denylist`:
  - **kernels and DKMS** — the initramfs is not rebuilt, and modules not signed
    by the company MOK do not load (ADR 0002)
  - **GNOME Shell extensions** — the set is pinned (`versions.lock`)
  - **the boot and update stack** — `bootc`, `ostree`, `composefs`, `systemd`,
    `dracut`, bootloaders
  - **`podman-docker`** — Docker must not be replaced

A package the base already contains cannot be installed through the overlay.
To change a base package, change the image.

### Local `.deb` files stay prohibited

RakuOS accepts local `.rpm` files. We deliberately do not: SDD §24 and Rule 5
prohibit arbitrary vendor `.deb` files on the host, and nothing about this
decision weakens the reason for that. Parity stops here.

## Consequences

**The overlay is not covered by fs-verity.** The composefs base still is
(ADR 0005), and `/` stays read-only. `prepare-root.conf` does not change.
Anything in an upper, however, can shadow a verified file, and a root user who
writes there directly is not stopped by anything but the apt hook. This is the
main security cost, and it is the thing to revisit if the fleet's threat model
ever includes a hostile local administrator.

**Two laptops on the same image may no longer be identical.** Rule 12 still
holds for the *OS*: the base is reproducible from Git. The overlay is
per-machine state in `/var`, like a Flatpak installation. `ik-os diagnostics`
includes `packages.list` so that IT can see it.

**Rule 4 is narrowed, not dropped.** A development dependency still belongs in
a container, Homebrew or Flatpak first. The overlay is for the cases where none
of those works. Anything every developer needs still goes into the image.

**Overlay packages follow the image's apt and dpkg policy:** no recommends, and
no man pages or docs (`config/apt/`, installed by `00-preflight.sh`). A user who
needs a recommended package names it.

**Updates need the network to be complete.** A machine that updates offline
boots clean base and replays when it can.

**`bootc status` calls the overlay transient.** bootc's composefs backend
assumes that any mount on `/usr` came from `bootc usr-overlay`, so it reports
`usrOverlay: transient, read-write`. This is cosmetic: `bootc upgrade` does not
consult it. `ik-os pkg status` is the authoritative view.

## Where it lives

- **Initramfs:** the dracut module `config/boot/dracut/90ik-os-usr-overlay/`.
  Its unit, `ik-os-usr-overlay.service`, runs `After=bootc-root-setup.service`
  and `Before=initrd-root-fs.target`. It mounts only an upper marked `ready`, and
  it never fails the boot.
- **Running system:** `ik-os-usr-overlay-rebuild.service`, plus `ik-os pkg` in
  `scripts/diagnostics/ik-os`. Both source `scripts/overlay/ik-os-usr-overlay-lib`.
- **The base-package list** is the existing release manifest,
  `/usr/share/ik-os/packages.manifest`, which `95-finalize.sh` writes from the
  final dpkg database. There is no second list to keep in step.
  `verify-image.sh` checks that it matches `dpkg-query`.

## What is verified, and what is not

Read from bootc v1.16.9 (`crates/initramfs/src/lib.rs`,
`crates/lib/src/bootc_composefs/state.rs`):

- `bootc-root-setup.service` assembles the whole root at `/sysroot` before
  `initrd-root-fs.target`.
- It binds `/sysroot/var` from `state/deploy/<digest>/var`. Every deployment's
  `var` is a symlink to one shared `state/os/default/var`, which is what lets
  `packages.list` follow the user across images.
- The deployment id is the `composefs=` digest on the command line. A `?` prefix
  marks a deployment booted without verity. It is the same value as
  `.composefs.verity` in `bootc status --json`.

Seen on a booted VM (2026-09-30):

- **Stack depth.** The overlay on the composefs overlay on EROFS mounts; that
  is two stacked filesystems, the kernel's limit. Enabling `[root] transient`
  in `setup-root-conf.toml` would add a third, and must not be combined with
  this.
- **The upper's xattrs.** An upper on the LUKS-backed `/var` works.
- **The initrd mount.** After a reboot the overlay is mounted about 2 s into
  boot, the rebuild unit finds it ready and does nothing, and the installed
  package is there. The fallback (a `DefaultDependencies=no` service before
  `sysinit.target`, then `systemctl daemon-reload`) is not needed.

Not yet seen: the replay after a real image update, and `bootc rollback`
mounting the previous deployment's overlay.

## What IT must confirm

1. **Whether users may install archive packages on the host at all** without a
   ticket. This ADR assumes yes, as with Homebrew. The alternative is a polkit
   or sudoers restriction on `ik-os pkg`, which is a small change from here.
2. **Whether the denylist is enough**, or should become an allowlist.
