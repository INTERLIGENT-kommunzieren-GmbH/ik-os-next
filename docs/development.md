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

### draw.io is not a Flatpak, and nothing updates it for you

Every other GUI application comes from Flathub. draw.io is the one exception
(ADR 0016): its Flathub package went end-of-life frozen at 30.0.4 while upstream
kept shipping, so the image installs a pinned upstream `.deb` instead.

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
