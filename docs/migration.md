# Migrating from Bluefin

Bluefin is Fedora-based and ik-os is Debian-based, so this is a distribution
migration, not `bootc switch` (SDD §28).

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

## Before you migrate the fleet

Rotate the ik-office VPN credentials first — see
`config/company/vpn/README.md`. The previous Bluefin image published the client
private key inside the container image; ik-os deliberately does not carry it,
but the exposure already happened and only a reissue fixes it.
