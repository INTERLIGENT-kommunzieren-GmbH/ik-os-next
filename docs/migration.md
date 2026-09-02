# Migrating from Bluefin

Bluefin is Fedora-based and ik-os is Debian-based, so this is a distribution
migration, not `bootc switch` (SDD §28).

## Why not `bootc switch`

Asked and answered on 2026-08-31, because the question comes back whenever the
reinstall looks expensive. Three blockers, each sufficient alone:

**The Secure Boot trust chain changes.** Bluefin boots a Microsoft-signed shim
which validates Fedora-signed grub. This image ships **systemd-boot signed with
the company Machine Owner Key** (`build/scripts/40-boot.sh`), and its kernel is
signed the same way. Moving a machine onto that chain means enrolling a MOK in
firmware — an action no in-place image update can perform, because it is not a
filesystem operation.

**SELinux gives way to AppArmor.** Fedora deployments are SELinux-labelled and
policy-enforcing. This image ships `apparmor` and `apparmor-profiles`
(`packages/base/packages.list`) and no SELinux policy at all. A switched machine
would carry Fedora's labels and `/etc/selinux` with nothing to interpret them.

**The `/etc` three-way merge runs across two distributions.** `bootc` merges the
machine's `/etc` onto the new image's. Fedora's `passwd`/`shadow`/`group` carry
different system UIDs, and its PAM stack, `nsswitch.conf` and unit names differ
from Debian's. The merge would succeed and produce a system nobody designed.

**The signing key is not one of the blockers**, though it was once written down
as if it were. The old image installs a public key to `/etc/pki/containers/` and
never writes a policy that references it — no `policy.json`, no `sigstoreSigned`,
no `keyPath` anywhere in that repository — so the deployed fleet does not verify
image signatures, and a signature could never have blocked a switch. This matters
because it removes the only argument for signing ik-os-next with the fleet's old
key: `ik-os-next` keeps its own rotated key, which is the stronger credential
(`docs/releases.md`).

    ik-os-migrate check                # non-destructive; reports readiness
    ik-os-migrate backup               # records what will be restored
    ik-os-migrate install --dry-run    # shows the plan, changes nothing
    ik-os-migrate install              # replaces the OS, preserves /home
    ik-os-migrate reboot

## What is preserved and what is not (SDD §30)

**Preserved:** `/home`, user accounts and UID/GID, SSH keys, git and shell
configuration, browser profiles, Flatpak user data, documents.

**Recorded and recreated, not copied:** Flatpak application list (reinstalled
from Flathub), Docker images (re-pulled), containers (recreated), named volumes
(exported and restored), Compose files (preserved), Homebrew packages
(reinstalled from a `brew bundle dump`).

**Never copied:** `/usr`, Fedora system configuration and systemd units, the
RPM database, rpm-ostree state, the Fedora kernel configuration, Fedora GNOME
system configuration, and the Fedora-era Homebrew install tree.

Docker's internal state is never copied between Fedora and Debian (SDD §25,
§32). Images and containers are cheap to recreate; volumes are exported as tar
archives rather than moved as raw storage.

## The desktop is not imported wholesale (SDD §34)

Personal preferences migrate; Bluefin's GNOME *system* configuration does not.
The ik-os defaults win for managed settings, so ArcMenu, the hidden button and
`Super+Space` are established the way SDD §13 requires regardless of what the
old machine did.

## If it goes wrong (SDD §35)

`ik-os-migrate install` aborts if preflight fails, refuses to run without a
recorded backup, and requires you to type the machine's hostname before
touching the disk. `ik-os-migrate rollback` queues the previous deployment if
one still exists; if it does not, the tool prints the recovery path. `/home` is
not modified by the migration in either case.

## Enrolling the Secure Boot key, and the password everybody asks about

ik-os signs systemd-boot with a company Machine Owner Key (ADR 0002), so a
machine with Secure Boot enabled will not start ik-os until that certificate is
enrolled. `ik-os-migrate check` says so before the install; the enrolment itself
happens after it:

    ik-os enroll-mok status      # state, certificate, whether it is enrolled
    sudo ik-os enroll-mok import # record the request, then reboot

**There is no ik-os Secure Boot password.** `mokutil --import` asks for one and
asks for it twice, which reads like a credential you were supposed to have been
given. It is not. You invent it at that moment; it is stored hashed in a UEFI
variable, MokManager asks for it once on the next boot to prove the same person
is still at the keyboard, and then it is discarded. Any short string you can
retype works. It is not the root password, not the user password, and it is not
reused between machines.

The reboot is the part that actually enrols:

1. `sudo ik-os enroll-mok import` — records the request. Nothing is enrolled yet.
2. Reboot. MokManager (a blue text screen from shim) appears before the boot menu.
3. **Enroll MOK → Continue → Yes**, then type the password from step 1.
4. The machine reboots and starts the signed bootloader.

Miss the MokManager screen and the request stays pending — `ik-os enroll-mok
status` reports that state explicitly, because "nothing happened yet" is
otherwise indistinguishable from "it did not work".

The fleet-wide alternative is for IT to place `/usr/share/ik-os/ik-os-mok.crt`
in the firmware `db` during provisioning, which skips all of the above. On
Framework hardware that is a per-machine firmware visit, so it is worth it only
at scale.

If the image has no `/usr/share/ik-os/ik-os-mok.crt`, its bootloader is
unsigned and there is nothing to enrol — that machine needs an image built with
the MOK secrets configured, not a firmware change.

## The VPN identity comes from the new image

A migrated machine does not inherit the bundle it was running under Bluefin. It
gets the identity from the ik-os image itself, which carries it at
`/usr/lib/ik-os/vpn/certs/` (ADR 0018), and `ik-os-provision-vpn` renders the
profile against it on first boot. Nothing to set and nothing to copy.

One case still needs attention: a machine that was given its own bundle in
`/var/lib/ik-os/vpn/` keeps it, because `/var` survives the migration and a
local bundle overrides the image's. `ik-os diagnostics` reports which identity
is in use.

This is not a rotation, and none is planned — the previously published key and
`tls-crypt` material stay in service. See `config/company/vpn/README.md` for why
that is defensible and what it costs.
