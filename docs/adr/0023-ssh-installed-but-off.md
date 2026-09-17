# ADR 0023 — sshd ships installed and switched off, not absent and masked

**Status:** accepted
**SDD:** §36, §50; Rule 18
**Amends:** the posture set in `build/scripts/85-systemd.sh` and
`config/security/firewalld-ik-os.xml`

## Context

Reported from a deployed machine: *"I cannot activate ssh via GNOME settings."*

That was true, and it was true three times over. The image shipped
`openssh-client` only; `85-systemd.sh` ran `systemctl mask ssh.service`; and
the `ik-os` firewalld zone did not open port 22. The Remote Login switch in
GNOME Settings cannot work against any one of those, and the panel has no way
to explain why — it fails, or does nothing, and the user is left guessing.

The intended route was `ik-os ssh enable`, which installed `openssh-server`
transiently through `bootc usr-overlay` and opened the firewall at runtime.
That is a good debugging command and a bad discovery story: nobody looking for
"turn SSH on" finds it in a diagnostics subcommand, and GNOME Settings is
precisely where someone looks.

## Decision

`openssh-server` is installed, and everything that makes it *run* is off:

| | |
| --- | --- |
| Package | installed |
| `ssh.service`, `ssh.socket` | **disabled** in `50-ik-os.preset`, and asserted not enabled at build time |
| Mask | **removed** — a masked unit is what made the switch unusable |
| Firewall | zone unchanged; port 22 closed |
| While sshd runs | a drop-in adds the `ssh` service to the zone at **runtime**, and removes it on stop |

So a machine that nobody has touched listens on nothing, which is what SDD §50
asks for — "avoid unnecessary listening network ports". The difference is that
the port *can* be opened by the person sitting in front of the machine, through
the switch they would naturally reach for, and that opening it is a state
someone chose rather than a state the image shipped.

Nothing is `--permanent`. Disable Remote Login, or reboot without it enabled,
and the firewall is back to the file as written.

### Masking was load-bearing, and its replacement has to be

The old mask did real work: it meant that if `openssh-server` ever arrived as
somebody's dependency, it arrived unable to start. Deleting the mask gives that
up, so the replacement is deliberately more than a preset line:

- `50-ik-os.preset` disables both the service and the socket. The socket
  matters on its own — disabling only the service leaves socket activation to
  start sshd on the first connection.
- `85-systemd.sh` removes the `.wants` symlinks and then **fails the build** if
  either is still enabled. This is not paranoia for its own sake:
  `openssh-server`'s postinst runs in `20-packages.sh`, *before*
  `50-ik-os.preset` exists, so it enables `ssh.service` with no preset to stop
  it, and the `systemctl preset-all` that should undo that runs in a build
  container where systemd is not pid 1 and is allowed to fail. Whether a fleet
  laptop listens on 22 out of the box is not a question to leave to a
  best-effort command.
- `verify-image.sh` checks the same thing again from inside the built image,
  along with the drop-ins and the unmasked state.

### Host keys

Two problems, both of which would have shipped quietly.

`openssh-server`'s postinst generates host keys **at build time**. That would
put the same four private keys on every machine installed from the image, which
is the one thing a host key must not be. They are deleted in `85-systemd.sh`,
and `verify-image.sh` already failed the build on any `/etc/ssh/ssh_host_*`
before this ADR — that check is what would have caught it.

Debian then has `sshd-keygen.service` to generate them per machine, wanted by
every path that starts sshd. It carries `ConditionFirstBoot=yes`, and on this
image that condition is never true when it matters: SSH ships disabled, so
nothing pulls the unit in on the one boot where the condition holds, and by the
time someone enables Remote Login weeks later the condition is false, the unit
is skipped, and sshd fails its own `ExecStartPre=/usr/sbin/sshd -t` for want of
a host key. A drop-in clears the condition; `ssh-keygen -A` creates only what
is missing, so every later start is a no-op.

## Consequences

**The attack surface grows by one reachable service, when a user asks for it.**
That is the honest cost. A stolen or lost laptop is no worse off — the disk is
encrypted (ADR 0022) and sshd is not running — but a machine on a hostile
network with Remote Login switched on is exposed to whatever sshd's
configuration allows.

**sshd's configuration is Debian's default**, which is not nothing: password
authentication is permitted, and `PermitRootLogin prohibit-password` applies to
a root account that has no password on ik-os, so root is effectively key-only.
Hardening it further — key-only for everyone, `AllowGroups`, a non-standard
port — is deliberately *not* done here, because it is policy and belongs to IT
rather than to this repository.

**`ik-os ssh disable` no longer masks the unit.** It would otherwise break the
GNOME switch permanently, on one machine, for a reason nobody would connect to
a command they ran once. It disables, stops, and closes the firewall.

## What IT must confirm

1. **Whether Remote Login may be switched on at all**, by the user, without a
   ticket. This ADR assumes yes; the alternative is a polkit rule that denies
   it, which is a small change from here.
2. **Whether password authentication over SSH is acceptable.** If not, the
   change is one `sshd_config` drop-in, and it should be made before any
   machine has the switch.
3. **Whether the firewall should open 22 to the whole zone or a management
   subnet only.** Today it is the zone, for as long as sshd runs.

## Verified

The disabled-by-default state is asserted twice, once in the build and once in
the image, and the build now fails rather than warns if either unit is enabled.

What is **not** verified is the part that prompted this: that GNOME Settings'
Remote Login switch drives `ssh.service` on Debian 14 and therefore picks up
these drop-ins. `ssh.socket` is covered with the same firewall handling for
that reason — if the panel turns out to drive the socket instead, the port
still opens and closes correctly. Confirming which one it uses needs a booted
desktop.
