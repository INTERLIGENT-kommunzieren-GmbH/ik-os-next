# ADR 0017 — the Lansweeper agent is installed into /var at first boot

**Status:** accepted
**SDD:** §27 (secrets), §37 (first boot), §38 (enrolment), §40 (updates), §50
(security), §54 (application policy); Rules 4, 12, 13, 15, 17

## Context

IT wants ik-os machines to appear in the company asset inventory alongside the
Windows fleet. That fleet is scanned **agentless** — no LsAgent anywhere — with
`LsPush.exe` in `C:\Windows\LSDeployment` as the fallback path.

Neither half of that method transfers to ik-os.

**LsPush is Windows-only.** There is no Linux build and never has been; it is a
standing wishlist item, and Lansweeper's own LsPush-vs-LsAgent page names LsAgent
as the Linux answer. Even a hypothetical Linux LsPush would need something to
invoke it — on Windows, the domain — and ik-os machines are not domain-joined.

**Agentless Linux scanning means inbound SSH.** Lansweeper's requirements are an
SSH daemon on the target, port 22 by default, plus credentials or a key mapped in
the console. ik-os ships `openssh-client` only, and `85-systemd.sh` deliberately
*masks* `ssh.service` so a stray dependency arrives already disabled (SDD §50).
Running an sshd on every developer laptop, plus a credential on the scanning
server able to log into all of them, to serve inventory is a bad trade. It would
also not work: agentless scanning has to reach the laptop, and these laptops roam
behind NAT — which is precisely why LsPush fallback exists on the Windows side.

So LsAgent is not one option among several. It is the only mechanism that can put
an ik-os machine into Lansweeper, and adopting it means IT enabling a scanning
method they have not used before.

Three properties of LsAgent then collide with the image model.

**1. It is not a Debian package.** The routes, in the order SDD §54 and Rule 17
prefer them:

| Source | Status |
| --- | --- |
| Debian archive | **not packaged** — no source package, no binary in forky |
| Flathub | not applicable — a system daemon, not a GUI application |
| An upstream APT repository | **does not exist** (unlike Claude Desktop, ADR 0007) |
| Vendor self-extractor (`.run`) | **available**, first-party, current |

So the vendor ships a BitRock/InstallBuilder self-extractor
(`LsAgent-linux-x64_<ver>.run`, 33 MB, bundling .NET 6) plus its own `uninstall`
binary, and nothing better exists. This ADR is Rule 17's required documented
exception (Rule 15), on the same footing as ADR 0016 for draw.io — and pinned the
same way, by version and sha256, so the payload is verified before it runs.

**2. It cannot live in `/usr`.** The default prefix is `/opt/LansweeperAgent`,
and `/opt` is a symlink to `var/opt` here, which `95-finalize.sh` empties. ADR
0008's answer for the Brother driver — ship the tree in `/usr/lib/opt` and
restore `/opt/<vendor>` with a tmpfiles symlink — does **not** work for LsAgent,
because the agent writes into its own directory: `LsAgent.ini` carries `AssetId`,
`LastScan`, `LastSent` and `Status`, and the agent supports self-update from the
scanning server. A read-only prefix breaks both. That makes the install machine
state, not image content (SDD §23), so it belongs in `/var` and is created at
first boot — the Homebrew pattern (`80-homebrew.sh` plus
`scripts/firstboot/ik-os-homebrew`), not the Brother pattern.

**3. The scanning server is reachable only over a VPN.**
`lansweeper.intern.interligent.com:9524` answers over the ik-office VPN or over a
second, user-configured tunnel to the datacenter, and is unreachable otherwise.
`ik-os-firstboot` runs at `network-online.target`, before any user has logged in
and before either tunnel exists — the ik-office profile needs a per-device
certificate that may not be present yet, and the datacenter tunnel is created by
the user. The server is therefore unreachable on essentially every first boot.

## Decision

**LsAgent is installed at first boot into `/var/opt/LansweeperAgent`**, from the
vendor `.run` pinned by version and SHA256 in `config/image.env` and fetched over
the internet (not from behind the VPN, which first boot cannot reach, and not
vendored in git — 33 MB is ~250× the largest binary this repo carries).

**Installing and reporting are separate concerns.**

- Installing is local work and always runs. It needs the internet, not the VPN.
  Its success condition is: agent installed, `LsAgent.ini` names the configured
  server, daemon enabled. It is *not* "the asset appears in Lansweeper". An
  unreachable server during install is logged, never fatal. The step still fails
  for what is genuinely broken: download failure, SHA mismatch, installer
  non-zero exit, unresolved shared library, daemon not running afterwards.
- Reporting is gated on an explicit reachability probe, event-driven.
  `/usr/lib/NetworkManager/dispatcher.d/50-ik-os-lansweeper` fires on `up` and
  `vpn-up` and does nothing but `systemctl start --no-block
  ik-os-lansweeper-report.service`; that unit probes the server with a 3-second
  timeout and acts only on success. Dispatcher scripts are serialized by
  NetworkManager under a 90-second budget, so no probing happens in the hook.

  **The daemon is enabled and started at install time, not held back until the
  first successful probe.** The stricter reading — leave it stopped until the
  probe succeeds — was rejected: the second tunnel to the datacenter is
  user-configured and may not be a NetworkManager connection at all, in which
  case no `vpn-up` is ever emitted and a probe-gated daemon would never start.
  An agent running with an unreachable server is harmless; it retries on its own
  schedule, which is the vendor's design. So the probe is not what permits the
  agent to run. What it does is (a) act the moment a tunnel appears, instead of
  waiting out the agent's scan interval, and (b) produce
  `/var/lib/ik-os/lansweeper/last-reachable`, which is the only local evidence
  that the path to the server has ever worked. An unreachable probe deliberately
  does **not** stop the daemon.

The probe treats **timeout as unreachable**, not merely connection-refused:
measured against `192.168.77.12:9524`, a blocked port times out with no RST. A
refused-only check would read a firewall drop rule as reachable.

**Only the on-prem scanning server is supported.** LsAgent's other mode,
Lansweeper's Cloud Relay, takes an `--agentkey` company auth token. IT does not
use the cloud, and the direct mode needs no credential at all, so SDD §27 and
Rule 13 are satisfied trivially rather than by careful handling. Relay support is
deliberately absent, and `verify-image.sh` asserts `--agentkey` appears nowhere:
adding it would drag in the per-device provisioning the VPN certificate needs,
and is a new ADR rather than a config line.

**The first-boot step is `image`-scoped** (ADR 0010). Its inputs — server
address, the enabled flag — ship in the image, so a new image with changed policy
re-runs it instead of skipping forever.

**The version pin is deliberately not the vendor's "latest".** IT states 10.4.2.1
is the current Linux release. Measured 2026-09-01, the vendor's
`content.lansweeper.com/lsagent-{linux,windows,mac}/` pointers redirect to
12.3.0.1, 12.6.3.3 and 10.2.0 — the version lines are per-platform, and the CDN
carries a Linux build ahead of what the download page publishes. Do not bump this
pin by chasing that redirect; the constraint is what the scanning server accepts.

## Consequences

- The agent is not in the dpkg database. `dpkg -l` will not list it;
  `ik-os diagnostics` reports the installed version instead. A deliberate Rule 17
  deviation, logged here.
- The vendor installer registers its own systemd unit under
  `/etc/systemd/system`. That is writable and persistent under ostree's `/etc`
  merge, so it survives updates. The unit name has changed between versions
  (`ls-agent.service`, `LansweeperAgentService`), so it is resolved at runtime
  rather than hardcoded.
- **The vendor unit hardcodes `/opt`, whatever `--prefix` says.** Observed on a
  VM boot of 10.4.2.1: the payload landed in `/var/opt/LansweeperAgent` as
  instructed, but the generated unit reads

      ExecStart=/opt/LansweeperAgent/LSAgent
      WorkingDirectory=/opt/LansweeperAgent

  That works here only because `/opt` is a symlink to `var/opt` in the ostree
  layout — the same property ADR 0008 leans on for the Brother driver. It is
  load-bearing and undocumented by the vendor, so it is asserted rather than
  assumed: `ensure_service` checks that the path the unit actually names is
  executable, and `tests/provisioning` checks it on a booted machine. A prefix
  outside `/opt` or `/var/opt` would produce a unit pointing at nothing.
- **One unresolved library is tolerated, exactly one.**
  `libcoreclrtraceptprovider.so` wants `liblttng-ust.so.0`; it is .NET's LTTng
  tracing provider and the runtime loads it only when tracing is explicitly
  enabled. On the same VM boot it was the only unresolved object in the payload,
  `LSAgent` itself resolved everything, and the service came up active. The
  first version of this integration failed the install over it, which blocked a
  working agent; pulling `liblttng-ust` onto the host to satisfy a tracing
  feature nobody uses would need a Rule 11 justification it does not have. The
  exemption is a one-entry allowlist, so any other missing library still fails.
- **LsAgent self-updates from the scanning server, outside the image lifecycle.**
  This is the main ongoing cost of the integration and is contrary to the spirit
  of SDD §40: one component on the machine changes without a new image. It is
  accepted because the alternative — a read-only install — is not possible at all
  (see 2 above). Self-update can be disabled server-side if the trade stops being
  acceptable.
- A laptop that never brings up a tunnel never appears in the inventory. With no
  cloud relay there is deliberately no second route; the fixes, if this matters,
  are a VPN prompt in the provisioning UI or accepting stale inventory for those
  devices.
- Setting `LANSWEEPER_ENABLED="false"` in a later image stops and disables the
  service but does **not** uninstall it. Removal is
  `/var/opt/LansweeperAgent/uninstall`, plus retiring the asset server-side.
- **Reimaged machines mostly keep their identity, and that is not an accident.**
  `LsAgent.ini` lives in `/var/opt`, so the `AssetId` is discarded by a
  reinstall and the agent re-registers. What lets the server recognise the
  machine anyway is that `scripts/firstboot/ik-os-hostname` derives the name
  from the DMI product serial — stable across reinstalls — rather than from
  anything per-installation, and the MAC addresses are hardware too. So the two
  fields dedup usually keys on are unchanged.

  The exception is hardware with no usable DMI serial (VMs, some hypervisors),
  where that script falls back to the first eight characters of
  `/etc/machine-id`, which *is* regenerated per installation. Those machines will
  come back under a new name and may appear as a second asset.

  Prompting the user for a hostname was considered and rejected as a fix. It
  would make matching worse, not better — a free-text name differs between
  reinstalls in a way a serial does not — and it cannot run where it is needed:
  `ik-os-hostname.service` deliberately runs before NetworkManager and before
  GDM so the name is correct at the login prompt and DHCP cannot override it,
  which is earlier than any user can be asked anything. For the no-serial case
  there is no local fix at all, because a reinstall wipes `/var` as well: it is
  server-side dedup or an IT-assigned name.
- Scanning collects installed software and the logged-on user. The flag ships
  enabled, so this takes effect with the image; the DSGVO/works-council sign-off
  belongs with IT before the first stable image.
