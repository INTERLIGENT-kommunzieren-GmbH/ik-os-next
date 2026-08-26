# ik-os tests

| Suite | Where it runs | Covers |
| --- | --- | --- |
| `image/test-image.sh` | build host, against a built image | SDD §63 criteria verifiable without booting |
| `boot/test-boot.sh` | booted ik-os | criteria 1-6, 30 |
| `hardware/test-hardware.sh` | booted ik-os, per hardware class | SDD §9 validation matrix (M4) |
| `docker/test-docker.sh` | booted ik-os | criteria 13-15, SDD §17-§19 |
| `printing/test-printing.sh` | booted ik-os | criteria 19-20, SDD §20-§23, §52 |
| `provisioning/test-provisioning.sh` | booted ik-os | hostname, group membership, Homebrew — SDD §16, §17, §23, §37 |
| `migration/test-migration.sh` | a Bluefin machine | criteria 21-25 |

`provisioning/` exists because none of what it covers can be ordered by boot
targets: `gnome-initial-setup` creates the first account from inside the GDM
session, long after `multi-user.target`, so anything needing a user is triggered
by `/etc/passwd` changing instead. Every check in it corresponds to a way that
went wrong — a step that "succeeded" with no user and stamped itself done, a
`.path`-triggered unit left permanently active by `RemainAfterExit`, and a
login-shell-only PATH snippet. Run it after any change to those units.

Items marked `?` are manual: a script cannot honestly assert that suspend/resume
worked or that a page came out of a printer. A hardware class is signed off only
when every automatic check passes and every manual item has been recorded in
`docs/hardware.md`.
