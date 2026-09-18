# Developing ik-os

## Build

    just build                # container image  -> ik-os:testing
    just verify               # in-image acceptance checks (SDD §63)
    just build-qcow2          # bootable VM image
    just build-iso            # UEFI live installer ISO
    just run-vm               # boot the qcow2 under QEMU

`just build` needs `podman`. The disk and ISO recipes need `sudo` because
`bootc install` and `mmdebstrap` require real privileges.

## Check before you build

    just lint                 # shellcheck
    just check-packages       # every package list resolves against the archive
    just check-flatpaks       # every Flatpak resolves on Flathub
    just check-brewfile       # every formula and cask resolves
    just check-devpod         # the DevPod pin, and whether upstream still ships
    just check-sidra          # the Sidra pin against upstream
    just check-teams          # the Teams pin, its backgrounds, and one Teams only
    just check                # Justfile formatting

`just check-packages` runs in seconds and catches the most common breakage — a
package that was renamed or dropped between Debian releases — without waiting
for a full image build.

## Build order

`Containerfile` runs `build/scripts/` in numeric order. The order matters:

| Script | Why it sits there |
| --- | --- |
| `00-preflight` | resolves the floating `stable` suite and refuses an unapproved release transition |
| `10-ostree-layout` | must precede package installs so packages land in the right place |
| `20-packages` | base first, so apt satisfies the kernel's initramfs dependency with dracut rather than initramfs-tools |
| `25-kernel` | pinned Backports kernel; fails if the exact version is gone |
| `30-bootc` | composefs, ostree and bootc from the builder stage; asserts the pinned ostree won over Debian's |
| `40-boot` | signs systemd-boot |
| `50-desktop` | GNOME config; installs both dconf profiles (`user` **and** `gdm`) |
| `55-branding` | os-release, logos, Plymouth theme, kernel arguments |
| `57-initramfs` | **must follow branding** — the Plymouth theme and watermark are baked into the initramfs, so building it earlier ships the stock Debian splash |
| `60`-`90` | docker, printing, company, flatpak, homebrew, units, CLI |
| `95-finalize` | **last**. Captures `/var`, relocates the dpkg database, lays down the ostree root. Anything after it is lost. |

## Adding a package

1. Add it to the right list under `packages/`, with a comment saying why
   (Rule 11 — no speculative dependencies).
2. If it comes from Backports, pin it in `config/apt/99-ik-os-backports.pref`
   and record the justification (SDD §3).
3. Run `just check-packages`.

Prefer not adding it at all: a GUI application belongs in
`config/desktop/system-flatpaks.list`, a CLI tool in `config/desktop/Brewfile`,
and a project dependency in that project's container (SDD §54). Adding a Flatpak
is `just check-flatpaks`, and it is the cheaper change: it does not enlarge the
immutable host, and it can be updated without an image release.

## Changing the desktop

Edit `desktop/gnome/dconf/ik-os.d/`. `build/scripts/50-desktop.sh` validates
every key against the installed schemas and fails the build on a key that does
not exist, so a renamed gsettings key cannot silently disable company policy.

Extensions go in `desktop/gnome/extensions/enabled.txt` **and**
`versions.lock`. The build fails if a listed extension is not installed.

GNOME has no setting for the Activities overview that opens at every login — it
is a branch on `Main.sessionMode.hasOverview` in the shell's startup animation,
which is why the usual answer is a `no-overview` extension. ArcMenu carries that
code already, so ik-os sets `hide-overview-on-startup` in `10-arcmenu` instead of
shipping a second extension. Dropping ArcMenu would bring the overview back as a
side effect.

It takes two keys, not one: dash-to-dock's `disable-overview-on-startup` in
`20-extensions` (shown inverted in its prefs as "Show overview on startup") does
not skip the overview itself — it resets the `OverviewAdjustment`, which is
constructed at `WINDOW_PICKER` and is only walked back to `HIDDEN` by the startup
animation ArcMenu just skipped.

And the order of `enabled.txt` is load-bearing because of it. GNOME enables
extensions serially in that order; dash-to-dock and ArcMenu both save
`hasOverview` at enable time and restore it on `startup-complete`, so the one
enabled second captures what the first already changed and its restore runs last.
dash-to-dock must come first, or the session ends up with no overview at all.
`50-desktop.sh` fails the build if that order is reversed.

**Known limitation: this is a race, and slow machines lose it.** GNOME enables
extensions only after `extensionManager.init()` has scanned the extension
directories and `await import()`ed every extension, while the startup animation
waits only for the background to load. Whichever finishes first decides whether
the flag is still `true` when `LayoutManager._startupAnimationSession()` reads it.
Measured on the qcow2 VM (2026-08-25, GNOME 50.3, software rendering), with a
probe extension logging its own enable:

    43.62  gnome-shell starts
    44.478 extensions enabling  — startingUp=true but overviewVisible=true already
    44.547 ArcMenu enables, flips the flag (too late)
    44.700 startup-complete

Extensions were ready ~860ms in and needed ~580ms, so the overview still opens at
login there. Nothing in the configuration is wrong when that happens — do not go
looking for a broken key. Two ways out were examined and rejected: a
`modes/user.json` drop-in cannot work, because `sessionMode.js` skips any mode
file whose name is already built in; and a custom session mode with
`hasOverview:false` makes `Overview.init()` return early and mark itself
`isDummy`, so the overview is never constructed and only private API can bring it
back — a far worse failure than the one it fixes. The remaining option is an ik-os
extension that also calls `Main.overview.hide()` when it arrives late, at the cost
of a visible flash; not shipped.

## Deviating from the SDD

Rule 15: document it before implementing it. Add an ADR under `docs/adr/`.
Existing deviations are recorded there.

## Debian-on-bootc gotchas

Every item here cost a failed build during the initial implementation. They are
guarded by a check now; do not remove the guard without removing the cause.

**The dpkg database lives in `/var`, which ostree discards.** It is relocated to
`/usr/lib/dpkg` at the end of the build (ADR 0004). Do **not** set
`admindir=/usr/lib/dpkg` in `dpkg.cfg` during the build: dpkg then reads an
empty database and every pre-dependency fails on the first package.

**`--no-install-recommends` drops the Docker CLI.** Debian's `docker.io` only
*Recommends* `docker-cli`, so the daemon installs without a client. Both are
listed explicitly. `dockerd` is in `/usr/sbin`, not `/usr/bin`.

**Extension UUIDs are not the upstream ones.** Debian's
`gnome-shell-extension-appindicator` installs `ubuntu-appindicators@ubuntu.com`,
not `appindicatorsupport@rgcjonas.gmail.com`. Check the package's file list
before adding a UUID to `enabled.txt`.

**ArcMenu's schema lands in `/usr/share/glib-2/schemas`** — no `.0`. Nothing
scans that path, so `gsettings` cannot see it. `50-desktop.sh` relocates any
stray schema and recompiles.

**Half of `/var` is symlinks.** Ghostscript's CMap tree is ~230 symlinks under
`/var/lib/ghostscript`, and CUPS filters break without them. `95-finalize.sh`
captures directories, symlinks *and* seeded files.

**`grep -q` in a pipeline breaks under `pipefail`.** The producer takes SIGPIPE
and a successful match is reported as a failure. Use `output_matches` from
`lib.sh`.

**Generated env files must quote their values.** Debian's `VERSION` is
`14 (forky)` and the VPN search-domain list is semicolon-separated; both are
syntax errors when sourced unquoted.

**`brew bundle` evaluates casks before it clones the taps that provide them.**
A cask that exists only in a third-party tap is therefore resolved against
homebrew/cask on the first run, discarded with `Skipping cask <name> (requires
macOS)` — on Linux, for a Linux cask — and `brew bundle` still prints
`complete!` and exits 0. It works from the second run onwards, once the tap is
already on disk, which makes it look intermittent. `ik-os-homebrew` runs
`brew tap` explicitly before bundling, and `brew bundle check` afterwards,
because the install exit code does not mean the Brewfile was satisfied.

**Homebrew will not load a third-party tap's casks until the tap is trusted.**
`brew trust ublue-os/tap` writes `~/.homebrew/trust.json`; without it `brew
bundle` prints `Refusing to load cask ... from untrusted tap`, installs
everything else, and still exits 0. Trust is per-user, so it has to run as the
user rather than root. `just check-brewfile` cannot detect this — the Brewfile
entries are correct; the failure is a runtime policy decision.

**A Brewfile is Ruby, and Homebrew only runs at first boot.** Both facts matter:
the first lets `config/desktop/Brewfile` gate `framework-tool` on DMI vendor; the
second means a wrong entry is not caught by the image build, it fails on every
laptop. `just check-brewfile` resolves every entry against homebrew/core and the
declared taps, and distinguishes formulae from casks — `brew "x"` for something
the tap ships as a cask silently installs nothing. Bluefin has this exact bug
today: its Framework hook asks for `framework_tool`, but the cask is
`framework-tool`.

**A Flatpak id that does not exist on Flathub also fails silently, and takes
most of the desktop with it.** SDD §54 routes every GUI application to
`system-flatpaks.list`, so that file — not the package lists — is where the
desktop is defined. None of it is installed during the image build:
`ik-os-firstboot` installs it on the machine, logs one failure per app, and
carries on. A typo therefore produces a working image that simply has no PDF
viewer. `just check-flatpaks` resolves every id against the Flathub API, rejects
an app marked end-of-life (it installs, launches, and never updates again) or one
with no x86_64 build, and prints the runtime footprint — each distinct runtime is
a separate ~1 GB download at first boot, so one straggler app pinned to an old
GNOME branch costs more than a dozen apps sharing the current one.

**`/var` in the image is applied once, at install, and never again.** That is
why `95-finalize.sh` moves package `/var` state into `tmpfiles.d` and
`/usr/share/factory`, and why `verify-image.sh` asserts `/var` is empty. There is
exactly one deliberate exception: `/var/lib/flatpak`, holding the Flatpaks from
`config/desktop/preinstalled-flatpaks.list` (ADR 0014). A Flatpak has nowhere
else to be installed. Adding a second exception is a decision, not a fix — the
check names this directory specifically so anything else still fails.

**A Flatpak that offers to "set up" the host cannot succeed here.** Mission
Center's first-run script starts with `setcap` on the nethogs binary, and `/usr`
is read-only — so the user gets a dialog titled *Setup Script Failed*. The fix is
never to make the script work; it is to ship what the script would have done and
answer the prompt in advance (ADR 0013). Watch for this shape in any monitoring
or hardware app: if it wants file capabilities, a udev rule or a kernel module
loaded, that belongs in the image. `bootc usr-overlay` is not an answer — the
change survives until the next reboot, which is the worst of both.

**A polkit rule that names a non-existent action fails silently.** polkit
ignores the clause; the panel just keeps prompting for a password with no
diagnostic anywhere. Two of the five ids in `49-ik-os-printers.rules` were
wrong — the real names are `printeraddremove` and `job-not-owned-edit`, not
`printer-add` and `job-cancel-any`. `verify-image.sh` now checks every id in the
rule against the installed `.policy` file.

**`--no-install-recommends` drops things the desktop assumes.**
`cups-pk-helper` is only a *Recommends* of `gnome-control-center`, so GNOME
Settings → Printers reported "some settings cannot be unlocked" and greyed out
Add Printer. Anything a GNOME panel talks to over D-Bus is worth checking for
this; the panel degrades quietly rather than reporting a missing package.

**`/opt` is a symlink into `/var`, so it is wiped at finalize.** Vendor software
that installs to `/opt` disappears from the committed image, having passed every
check that ran before `95-finalize.sh`. Ship the tree in `/usr/lib/opt` and
restore `/opt/<vendor>` with a tmpfiles symlink — Brother's CUPS wrapper parses
its own `/opt/.../Printers/<model>/` path to learn its model name, so the path
has to exist at runtime even though the files live in `/usr`. See ADR 0008.

**The first user does not exist when `ik-os-firstboot.service` runs.**
`gnome-initial-setup` creates the account from inside the GDM session, long
after `multi-user.target`. A first-boot step that needs a user and returns
success when it finds none gets stamped `.done` and never runs again — that is
how docker group membership silently never happened. Either fail (so the step
retries next boot, as `setup_homebrew` now does) or trigger off the account
appearing, with a `.path` unit on `/etc/passwd`, as
`ik-os-user-groups.service` does.

**`/var` survives a bootc update, so a first-boot stamp never expires.** `/var`
is wiped and re-created at *install*, not at every deployment. An empty
`.done` file therefore means "this machine once did this", which is the wrong
question: an image that adds a Flatpak to `system-flatpaks.list` or ships a new
VPN template needs those steps to run again. Steps declare a scope (`once` or
`image`) and image-scoped stamps record the image id they were satisfied on. See
ADR 0010.

**Versions are `<channel>.<YYYYMMDD>.<build>`** — `testing.20260825.42` from CI
(`GITHUB_RUN_NUMBER` as the build segment) and `testing.20260825.local` from
`just build`. It is passed as a build arg because the `Containerfile` default is
the bare string `dev`, and a build that forgets to pass it ships an image whose
`bootc status` says `dev` on every machine that runs it. The build segment is
deliberately not a counter or a timestamp: the version becomes an `ENV` ahead of
the single `RUN` that executes every build script, so a string that changed per
build would turn even a no-op `just build` into a full rebuild. Use the image
digest to tell same-day builds apart — `ik-os version` prints it.

**Do not use `IK_OS_VERSION` or `IK_OS_BUILD_ID` to detect that the image
changed.** They default to `dev` and `local`, so every locally built image
shares a string — a change detector keyed to them works in CI and silently never
fires on the VM you are testing in. Use `bootc status`, falling back to the
ostree deployment checksum in `/proc/cmdline`.

**Nothing may touch Plymouth before deciding there is work.** `ik-os-firstboot`
called `splash_begin` ahead of reading any stamp, so *"Setting up this machine —
do not turn off your computer"* appeared on every boot of a fully provisioned
machine. Worse, gating it on "is anything pending" would not have been enough:
a step that can never succeed is pending on every boot, so an offline machine
would still show the setup screen forever. The splash is gated on the booted
image differing from `.last-run-image`; retries of earlier failures run silently
and surface through `ik-os diagnostics`.

**Plymouth's progress-bar modes suppress messages.** `SuppressMessages=true` and
`UseProgressBar=true` are set only in `[updates]`, `[system-upgrade]`,
`[firmware-upgrade]` and `[system-reset]` — never in `[boot-up]`. So
`plymouth change-mode --updates` buys a progress bar at the cost of the loader
animation *and* of every `display-message`, which then vanish with no error
anywhere. If you want to say what is happening during boot, stay in `[boot-up]`.
See ADR 0012.

**Plymouth has no "update this message" verb.** Both `display-message` and
`hide-message` take `--text=<string>` and key on it, so replacing a line means
hiding the previous text first. Skip that and each step's line stays up and they
stack.

**A system service cannot notify a session that does not exist yet.**
`ik-os-homebrew.path` and `ik-os-user-groups.path` fire on `PathChanged=/etc/passwd`,
which is when gnome-initial-setup *creates* the account — before it has logged in
and therefore before `/run/user/<uid>/bus` exists. `ik-os-notify` returns 0 when
there is no bus, so every opening message was discarded and only the closing one
landed, minutes later. Pass `--wait <seconds>` for a one-shot message, and for
anything long-running publish state to `/run/ik-os/provisioning.status` and let
`ik-os-provisioning.service` — a *user* unit — render it. See ADR 0011.

**`set -euo pipefail` kills a script on a pipeline you expect to fail.** In
`ik-os-homebrew` the failure branch re-ran `brew bundle check` through `| sed` to
log what was missing. With `pipefail` that non-zero status ended the script on
that line, so the two statements after it — recording which Brewfile failed and
publishing `state=failed` — never ran, and the progress window sat at "Checking
developer tools" forever. A pipeline whose command is *supposed* to fail needs an
explicit `|| true`.

**Diagnostics probes fail on healthy machines.** No Secure Boot, no VPN yet, no
printer, no systemd in a container — all normal. Under the script's `set -e` the
first such failure truncated the whole report at the point it stopped being
useful, and the output still looked plausible. The report block runs in a
`set +e` subshell, and `verify-image.sh` checks the last section is present.

**The `ssl-cert` package generates a snakeoil private key in its postinst.**
Shipping it would put the same private key on every machine. It is removed in
`95-finalize.sh` and regenerated per installation by first boot.

**No apt cache mount.** `95-finalize.sh` has to empty `/var`, and a live mount
under `/var/cache` cannot be unlinked from inside the build.

**GDM has its own dconf profile.** `/etc/dconf/profile/user` is not enough —
the login screen reads `/etc/dconf/profile/gdm`. Without that file the `gdm.d`
database is compiled and then ignored, so the login-screen logo silently does
nothing.

**Plymouth needs `splash` on the kernel command line.** The theme can be set
correctly and the watermark installed, and you still get no splash at all.
Kernel arguments ship in `/usr/lib/bootc/kargs.d/` — whose schema is strict
(`kargs`, `match-architectures`, nothing else).

**`podman save` defaults to docker-archive**, which rewrites an OCI image as
Docker v2s2. bootc's composefs backend accepts OCI only and fails with
"Invalid splitstream content type". Always pass `--format oci-archive`. Note
that podman's image *ID* is the config digest and does not change with the
manifest format, so a stale v2s2 copy can look identical to an OCI one.

**`dpkg -l` needs `--admindir` inside a bare `podman run` of the image.** The
database lives at `/usr/lib/dpkg` (ADR 0004) and `/var/lib/dpkg` is a tmpfiles
symlink that only materialises when systemd runs at boot. On a booted machine
plain `dpkg -l` works; when poking at the image with `podman run`, pass
`--admindir=/usr/lib/dpkg` or read `/usr/share/ik-os/packages.manifest`.

**Never grep binary output through a command substitution.** `$(cat file)`
discards null bytes, so a compiled dconf database or an initramfs never
matches, and the check fails while the thing it checks is perfectly fine. Use
`grep -qaF pattern file` on the file itself. (Note also that some hosts alias
`grep` to `ugrep`, which skips binary matches entirely without `-a`.)

**`podman build` warns that `SHELL` is ignored for OCI images.** Harmless: the
build steps are `&&`-chained and each script sets its own `set -euo pipefail`.

### The Lansweeper agent is installed, but reporting is a separate question

ADR 0017. Two traps, both of which look like bugs and are not.

**"Installed but never reported" is the correct state on most laptops.** The
scanning server answers only over a VPN, and `ik-os-firstboot` runs at
`network-online.target` — before any user has logged in, and before either
tunnel exists. So the install step deliberately does **not** check reachability:
if it did, every laptop would carry a `lansweeper.failed` stamp and
`ik-os diagnostics` would report a permanent failure on a perfectly healthy
machine. Reporting is triggered instead by
`/usr/lib/NetworkManager/dispatcher.d/50-ik-os-lansweeper` on `up`/`vpn-up`,
which starts `ik-os-lansweeper-report.service`; that unit probes, stamps
`/var/lib/ik-os/lansweeper/last-reachable`, and does nothing on failure.

**The probe must treat a timeout as unreachable, not just a refused connection.**
Measured against the real server: ports 80 and 443 connect instantly while 9524
times out with no RST, because it is dropped rather than closed. A
`connect`-refused check would read a firewall drop rule as "reachable" and hand
data to a black hole.

**`systemctl start` + `is-active` is not a health check for this unit.** The
vendor unit is `Type=simple` with `Restart=always`, so `start` returns as soon as
the process is forked. Measured on a VM with a deliberately broken `ExecStart`:
`is-active` said *active* immediately and *failed* three seconds later. So
`ensure_service` settles for up to three seconds, bails early once systemd has
decided, and reports `NRestarts` — because with `Restart=always` a crash loop
looks healthy at any single instant. This mattered in practice: the first
version returned success over a dead daemon.

**Presence is not health, and the idempotent path has to know that.** An install
that failed its own checks still left a registered unit behind, so the next boot
took the "already installed" shortcut, re-checked nothing, and stamped the step
done — observed for real as `lansweeper: FAILED` on one boot and `lansweeper: ok`
on the next with nothing fixed in between. Every path now goes through
`ensure_service`.

Two smaller things worth knowing. The dispatcher hook lives in `config/network/`,
and its filename is dictated by NetworkManager (`50-ik-os-lansweeper`) — it
matches neither `*.sh` nor `ik-os-*`, so `just lint` and the CI shell job carry
an extra `find` clause for it or it would never be shellchecked. And the vendor
unit name has changed between LsAgent versions (`ls-agent.service`,
`LansweeperAgentService`), so every place that touches it resolves the name at
runtime rather than hardcoding one.

### The installer owns tty1, and nothing else may

`getty@tty1.service` is enabled by Debian's preset, restarts instantly and
forever (`Restart=always`, `RestartSec=0`), and resets its TTY on every start
(`TTYReset`, `TTYVTDisallocate`). `ik-os-installer.service` runs on the same
`/dev/tty1` with `StandardInput=tty-force`. Both therefore hold the console,
and the keyboard does not control the installer: keystrokes are split between
agetty and whiptail, so the installer answers some of what is typed, or none of
it. In a VM, `systemctl restart getty@tty1` while the disk-selection dialog is
up replaces it with `ik-os-live login:` — the installer is still running behind
that prompt, waiting for an answer it can no longer receive.

`iso/build-iso.sh` masks `getty@tty1` in the live system, which also covers
`autovt@tty1` (an alias for it). The installer unit carries
`Conflicts=getty@tty1.service` as a backstop only: with `Restart=always` a
conflicted getty is restarted and stopped in a loop, so the mask is what
actually fixes it.

The live shell moved with it: root is still passwordless, but on **Alt+F2** and
up, which logind spawns on demand.

### Two things Recommends-off broke, and one of them shipped

`config/apt/99-ik-os-immutable.conf` sets `APT::Install-Recommends "false"`.
That is right for an image — every package is named on purpose — and it has a
failure mode worth knowing, because it already cost a deployed machine its
Wi-Fi.

`wpasupplicant` is only a *Recommends* of `network-manager`. Without it
NetworkManager cannot scan or associate: the driver loads, the card appears in
`nmcli device`, and **no network is ever listed**. On a Dell XPS 13 with an
Intel AX201 that looked exactly like missing firmware, and the firmware was
fine — `firmware-iwlwifi` and `wireless-regdb` were both installed. Nothing
about the symptom points at the supplicant, which is why `verify-image.sh` now
checks for it by binary.

The live ISO had the same hole for the same reason, and both lists have to name
it: neither inherits from the other.

### SSH is installed and switched off, not absent

Reported as "I cannot activate SSH via GNOME Settings", and it was true three
times over: no `openssh-server`, `systemctl mask ssh.service`, and a firewall
zone that did not open 22. The Remote Login switch cannot work against any one
of those and cannot say why.

Now (ADR 0023) the package is installed, both units ship disabled, the mask is
gone, and a drop-in adds `ssh` to the firewalld zone at runtime for as long as
sshd runs. A stock machine still listens on nothing; the difference is that the
person in front of it can change that from the panel they would reach for.

Three details that will bite anyone touching this:

- **The postinst generates host keys at build time.** That would put the same
  four private keys on every machine. They are deleted in `85-systemd.sh`, and
  `verify-image.sh` fails the build if any survive.
- **`sshd-keygen.service` is `ConditionFirstBoot=yes`.** On an image that ships
  SSH disabled that condition is never true when it matters, so enabling Remote
  Login weeks later would skip key generation and sshd would fail its own
  `sshd -t`. A drop-in clears the condition.
- **`openssh-server`'s postinst runs before `50-ik-os.preset` exists**, so it
  enables `ssh.service` with no preset to stop it, and the `preset-all` that
  should undo that runs in a container where systemd is not pid 1 and may fail.
  The build therefore removes the `.wants` symlinks and *dies* if either unit
  is still enabled. Whether a fleet laptop listens on 22 out of the box is not
  a question to leave to a best-effort `systemctl`.

`ik-os ssh disable` no longer masks the unit either — that would break the
GNOME switch permanently, for a reason nobody would trace to a command they ran
once.

### First boot needs a network, so the installer asks for one

A laptop's first boot has no network unless someone gave it Wi-Fi, and first
boot is when every application is downloaded. That used to be punished rather
than handled: `network-online.target` timed out, the Flatpak step made three
passes over all 55 applications with each install failing on DNS and 30s
sleeps between passes, `TimeoutStartSec=15min` eventually killed the unit, and
the machine reached the login screen with nothing installed. Up to a quarter of
an hour of held splash to achieve nothing.

Two changes, and the second one matters even when the first works.

**The installer asks for Wi-Fi** and copies the profile into the installed
system. It shells out to `nmtui` rather than growing a Wi-Fi dialog of its
own — `nmtui` already handles WPA2/WPA3, WPA-Enterprise (802.1X) and hidden
SSIDs, so the installer needs no opinion about what the company runs and no
credential handling to get wrong. It only asks when there is a wireless card
and the machine is not already on a cable, and it proves the answer by
connecting before accepting it.

It asks **even when the machine is already online**, defaulting to no. That
looks redundant and is not: a laptop installed on a cable at the office has no
Wi-Fi at all the first time somebody opens it at home, which is the normal life
of these machines. Skipping the question whenever a cable was plugged in would
have produced exactly that.

This needed packages on the medium: the live system had NetworkManager and no
way to use a wireless card at all — no `wpasupplicant` (only a Recommends,
which mmdebstrap does not install), no `wireless-regdb`, no firmware, no
`nmtui`. `firmware-iwlwifi` alone is 180 MB; `firmware-realtek` is
deliberately left out, so a Realtek USB adaptor works on the installed system
but not during installation.

**Carrying the profile over is not a copy into `${MNT}/etc`.** A bootc system
keeps a per-deployment `/etc`, and with the composefs backend it is nowhere
near where the ostree backend puts it. Read off a real installed image with
`virt-ls`:

    /                     boot  composefs  ostree  state
    /state/deploy/<id>/etc/NetworkManager

The writable `/etc` is `/state/deploy/<id>/etc` — not
`/ostree/deploy/<stateroot>/deploy/<csum>.0/etc` — and the physical root has no
`/etc` at all. The installer searches for `*/etc/NetworkManager` instead of
hardcoding that, because it is a layout bootc may well change, and warns and
continues if it finds nothing rather than failing an install that has already
written the disk.

**First boot no longer depends on any of that working.** `ik-os-firstboot`
probes for a network once, and marks the three steps that need one —
enrollment, Lansweeper, Flatpak — as failed without attempting them. The login
screen comes up in seconds instead of fifteen minutes. A NetworkManager
dispatcher hook then resumes provisioning the moment a network appears, so a
machine imaged at the office and first booted at home finishes setting itself
up when the user joins their home Wi-Fi, with no reboot and nothing to know.

Two traps in that hook, both commented where they live. It keys off the
`.failed` stamps, so a healthy machine does not restart a unit on every network
event. And it uses `systemctl restart`, not `start`: the unit is `Type=oneshot`
with `RemainAfterExit=yes`, so it is still "active (exited)" from boot and
`start` would do nothing at all while looking like it had worked.

### The `@` characters in the boot menu are GRUB's, not the installer's

The stray `@` reported in "the borders of the windows" are in the **GRUB menu
on the ISO** — the first screen of the boot, before the installer exists. They
were first blamed on the TTY contention above, on the theory that two writers
interleave mid-escape-sequence and leave the tail of a sequence on screen as
literal text. That theory was wrong. Masking `getty@tty1` fixed the keyboard
and changed nothing about the glyphs, which is how it was caught.

`iso/config/grub.cfg` selects `gfxterm`, which renders text from a `.pf2` font.
Nothing loaded one, so GRUB fell back to its built-in font, which covers ASCII
only, and drew every other codepoint as its missing-glyph placeholder: a small
box with a question mark inside. The menu frame is U+2500-family box drawing
and the help line reads "Use the ↑ and ↓ keys", so the whole frame and both
arrows came out as placeholders. At native size on a real screen that
placeholder reads as an `@`.

The fix is one `loadfont` before `terminal_output gfxterm`. Nothing had to be
added to the medium: `grub-mkstandalone` already embeds `unicode.pf2` at
`boot/grub/fonts/unicode.pf2` (`--fonts=FONTS [default=unicode]`), so the font
shipped in every ISO built so far and simply went unused. Name it through
`$prefix`, not `$root`: it lives in the memdisk that grub-mkstandalone wraps
around the config, and the `search` further down repoints `$root` at the
installation medium. If the font ever does go missing the config falls back to
`terminal_output console`, whose frame glyphs come from the firmware — plainer
than gfxterm, but never wrong-looking.

Verified by building the EFI image on its own and booting it under OVMF: frame
continuous, both arrows rendered, with the ISO build script untouched.

Two things this is *not*, both checked. The live console renders DEC
line-drawing correctly in UTF-8 and 8-bit mode, so whiptail was never
mis-drawing; and the live system has no locale set at all (`LC_CTYPE=POSIX`),
which is untidy but did not affect drawing in testing.

### The installer partitions the disk, because bootc will not encrypt it

Every install is encrypted: LUKS2, passphrase, whole disk, no unencrypted path
(ADR 0022). That moves partitioning out of bootc and into
`iso/installer/ik-os-installer`, so the installer is no longer the thin wrapper
it used to be.

`bootc install to-disk` cannot do it. Its `--block-setup` takes only `direct`
or `tpm2-luks`, and `tpm2-luks` opens the disk whenever it is in that machine,
with no passphrase asked. bootc's help sends LUKS layouts to
`install to-filesystem`, so the installer builds the layout and bootc deploys
into it:

    GPT
      p1  1024 MiB  ESP, FAT32, mounted at <root>/boot/efi
      p2  rest      LUKS2 -> btrfs, mounted at <root>

Both of those numbers come from bootc, not from taste. 1024 MiB is
`CFS_EFIPN_SIZE_MB`, the ESP size bootc's own composefs installs use;
`boot/efi` is `bootloader::EFI_DIR` joined to `boot`, which is where bootc
looks for the ESP. Change either and the deployment either cramps itself or is
not found. There is no BIOS boot partition — ik-os is UEFI only and the
installer refuses to run otherwise.

The initramfs is told to unlock with `--karg rd.luks.uuid=<uuid>`; `root=` is
left to bootc, which writes the btrfs UUID, so nothing depends on the name the
unlocked mapper gets. `config/boot/dracut-ik-os.conf` carries `crypt`,
`systemd-cryptsetup` and `plymouth` for the themed prompt — all three modules
were already in the image and simply unused, so this cost no packages.

**The trap, if you touch this code.** The passphrase is piped in with
`printf '%s'`, with no trailing newline, because `--key-file -` takes the bytes
it reads as the key verbatim. Use `echo` and the newline becomes part of the
key, so the boot prompt — which sends only what was typed — can never open the
disk. It installs cleanly and fails at first boot, on someone else's machine.

**Testing it without an ISO.** The script can be driven under stubbed
`sgdisk`, `cryptsetup`, `mkfs.*`, `mount` and `bootc` to check the gates, the
message wording and the exact commands it builds, including the byte length of
the key handed to `luksFormat`. That covers everything except the part that
matters most — whether the result boots — which needs an ISO and a VM, because
stubs create no LUKS container and never run an initramfs.

Disks are also size-checked now, from measurement rather than guesswork: the
deployment is 12 GiB and the approved Flatpaks are about 10.2 GiB (5.6 GiB of
applications plus 4.5 GiB of the five runtimes they share), so anything under
32 GiB is refused and anything under 128 GiB warns. A 24 GiB VM disk installed
fine and then died at application group 5 of 7 with `No space left on device`,
which is the failure this replaces.

### Four applications are not Flatpaks, and nothing updates them for you

Most GUI applications come from Flathub. Four do not, and each unpacks a
pinned upstream `.deb` instead:

| | why | pin | updater |
| --- | --- | --- | --- |
| draw.io | Flathub package end-of-life at 30.0.4 while upstream kept shipping (ADR 0016) | `drawio.env` | `update-drawio.sh` |
| DevPod | Flathub package end-of-life at 0.6.10; upstream's own newest stable is 0.6.15 and over a year old (ADR 0021) | `devpod.env` | `update-devpod.sh` |
| Sidra | on no Flatpak remote at all (ADR 0019) | `sidra.env` | `update-sidra.sh` |
| Teams | a Flatpak cannot read `/etc/teams-for-linux/config.json` (ADR 0020) | `teams-for-linux.env` | `update-teams-for-linux.sh` |

draw.io is the one the rest of this section uses as its example, because it came
first and Sidra and teams-for-linux copy it almost line for line. DevPod is the
odd one out and much simpler: its payload is already a `/usr` tree, it ships no
maintainer scripts, and its launcher is left exactly as upstream wrote it (both
binaries have a space in the name, and the desktop entry is consistent about
it). What `51-devpod.sh` adds is a `/usr/bin/devpod` symlink to the
`devpod-cli` the `.deb` installs, and one dependency: DevPod is Tauri rather
than Electron, so it renders through Debian's GTK3 WebKit.

The consequence is that no update mechanism reaches it. Flathub does not, `apt`
does not, and the image ships whatever `config/desktop/drawio.env` pins. To move
it:

    scripts/maintenance/update-drawio.sh          # latest upstream release
    scripts/maintenance/update-drawio.sh 31.4.0   # a specific one

That rewrites the version and the sha256 together — never edit the checksum by
hand, because a version bumped without its checksum fails the build with a
message about a corrupt download rather than about a stale pin.

Two things about that `.deb` are worth knowing before touching
`build/scripts/52-drawio.sh`. Its `Depends` are transcribed into
`packages/desktop/packages.list` by hand, because unpacking a `.deb` means apt
never reads them — and two of the names upstream declares do not exist in forky
(`libgtk-3-0`, `libatspi2.0-0`; the `time_t` transition renamed both). And its
postinst decides whether `chrome-sandbox` is setuid root by testing whether it
can create a user namespace — which always fails in a rootless build container,
so running it would bake a setuid binary into the image based on how the image
was built. That is why maintainer scripts are skipped (ADR 0008), and the build
asserts afterwards that no setuid bit survived.

DevPod is the one to keep questioning rather than updating: `just check-devpod`
warns when upstream's newest stable release is over a year old, which it is
today. Replacing an end-of-life Flatpak with a `.deb` nobody ships either is not
a fix, and ADR 0021 says what to do about it.

Teams is the one to keep an eye on. It used to update itself from Flathub and no
longer does, and it is a chat client rendering untrusted content in its own
bundled Chromium. `just check-teams` warns when upstream is ahead.

Two details specific to the other two. Sidra's payload arrives at **0775**, not
0755 like draw.io's, so `53-sidra.sh` sets the mode rather than only asserting
it — the group-write bit is stripped from the whole tree at the same time.
teams-for-linux bundles **musl** builds of a native node module beside the glibc
ones (`node.abi137.musl.node`), which can never resolve `libc.so` here and are
not meant to; `54-teams.sh` skips those in its `ldd` sweep, but only when the
glibc sibling is actually present.

### The Teams video backgrounds

Teams builds its background picker itself and offers no way to add to it. What
`teams-for-linux` can do is redirect every image request the picker makes, so a
company background gets in by being served **in place of** one of Microsoft's
own assets — the names in `branding/teams-backgrounds/slots.txt`, paired with
the images in sorted order. `ik-os-teams-backgrounds.service` on
`127.0.0.1:8421` answers those and proxies everything else back to Microsoft's
CDN; without the proxy the redirect turns every unclaimed tile into an empty
box.

Adding one:

    scripts/maintenance/render-teams-backgrounds.sh ~/Pictures/ik-kitchen.png

That writes the 1920x1080 background and the 280x158 thumbnail into
`branding/teams-backgrounds/`. They are committed already rendered because
resizing during the build would mean shipping ImageMagick in every image for a
step that runs once per photograph. Each image consumes one Microsoft asset
name, so add a spare to `slots.txt` when they run out — the build fails rather
than install an image that can never be seen.

When a background stops appearing, Microsoft retired the name it was mapped to.
The service logs every asset the client asks for, marked `ik` (served from the
image) or `ms` (proxied):

    journalctl -u ik-os-teams-backgrounds

Pick a live name from that log and replace the dead line in `slots.txt`.

Two behaviours of the client are load-bearing and easy to break by tidying:
every response must carry `Access-Control-Allow-Origin` (the picker draws the
image into a canvas and otherwise silently refuses to apply it, logging
nothing), and the manifest must be a bare JSON **array** — the documented
`{"videoBackgroundImages": [...]}` object makes the app throw *"configJSON is
not iterable"*.

Finally, one note about installs rather than builds. Nothing is deployed from
this image yet, so no machine is holding the Flatpak that the packaged client
replaces. A Bluefin machine migrated with `ik-os-migrate` is the exception: it
runs `bootc install to-existing-root`, which leaves `/var` alone — that is what
preserves `/home` — so anything already in `/var/lib/flatpak` comes through the
migration. First boot will not reinstall Teams, because the id is out of
`system-flatpaks.list`, but it will not remove a surviving copy either, and two
Teams in the launcher is the visible symptom:

    flatpak uninstall --system com.github.IsmaelMartinez.teams_for_linux

The profile moves too, from `~/.var/app/…/config/teams-for-linux` to
`~/.config/teams-for-linux`; copy it across to keep the session.
