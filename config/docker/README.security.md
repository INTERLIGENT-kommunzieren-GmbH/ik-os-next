# Docker access on ik-os

SDD §51 requires this to be stated plainly:

**Membership in the `docker` group is equivalent to root on this machine.**
The Docker daemon runs as root and will bind-mount any path, including `/`, into
a container on request. There is no meaningful privilege boundary between a
member of the `docker` group and the root account.

ik-os accepts this trade-off because SDD §51 also requires the initial
implementation to prioritise compatibility with normal Docker workflows.

Under the default `first-user` policy the practical change is small: the account
`gnome-initial-setup` creates is an administrator and is already in `sudo`, so
it can become root anyway. The escalation matters for the `all-users` policy,
where a *non-administrator* account would gain root-equivalent access without
ever being granted sudo — and without appearing in any sudo audit trail. Do not
set `all-users` on a machine with accounts that are deliberately unprivileged.

## Who gets added, and when

Company policy decides, not the image — `config/company/policy.env`, key
`DOCKER_GROUP_POLICY`:

| Value | Effect |
| --- | --- |
| `first-user` | the lowest-uid human account joins the group (the default) |
| `all-users` | every human account joins the group |
| `none` | nobody; IT grants membership by hand |

`ik-os-user-groups.service` applies it. It runs at every boot **and** is
triggered by `ik-os-user-groups.path` whenever `/etc/passwd` changes — because
on a fresh install `gnome-initial-setup` creates the first account from inside
the GDM session, long after `multi-user.target`. A boot-ordered unit would find
no user, do nothing, and never run again. Re-deriving membership from
`/etc/passwd` each time also makes it idempotent and picks up accounts added
later. The same unit grants `lpadmin`, which is *not* root-equivalent and is
required by SDD §23 so that adding a printer does not need root.

**A new member must log out and back in.** Group membership is read when a
session starts, so the shell that was already open when the account was created
still gets `permission denied` on `/var/run/docker.sock`.

If stronger isolation becomes a requirement, the options to evaluate, in the
order SDD §51 lists them, are rootless Docker, rootless Podman, and controlled
privileged development environments. `uidmap` is already in the image so the
rootless path can be tested without rebuilding.
