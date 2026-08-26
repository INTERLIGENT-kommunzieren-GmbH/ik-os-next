# ADR 0008 — vendor printer drivers are unpacked, not installed

**Status:** accepted
**SDD:** §22 (Level 3), §23, §24; Rules 5, 15, 17, 18

## Context

Rule 17 prefers Debian packages, and Level 3 of SDD §22 is the last resort. The
Brother MFC-L3740CDWE has no Debian driver package and is not driverless for the
duplex/colour features the office uses, so it needs the vendor `.deb`.

Two properties of that `.deb` make `apt install ./x.deb` the wrong tool.

**1. Its maintainer scripts create a print queue.** The postinst chains into
`cupswrappermfcl3740cdw`, which ends:

    if [ "$URI" = '' ]; then URI="usb://dev/usb/lp0"; fi
    lpadmin -p ${printer_name} -E -v $URI -P $ppd_file_name

There is no conditional around the `lpadmin`. When it cannot find the printer —
which is always, in a build container — it invents a USB URI and creates the
queue anyway. A queue names one printer at one address: machine state, not image
content (SDD §23). It would also be baked identically into every laptop.

**2. It installs into `/opt`, which does not survive the build.** In an ostree
layout `/opt` is a symlink to `var/opt`, and `95-finalize.sh` empties `/var`
because ostree does not ship it. The driver would install cleanly, pass every
check that ran before finalize, and be absent from the committed image.

The obvious fix — install to `/usr` instead — does not work either. The CUPS
wrapper recovers its own model name from its path:

    my $basedir = `readlink $0`;
    $PRINTER =~ s/^\/opt\/.*\/Printers\///g;

Under any path not matching `/opt/*/Printers/*` it computes a garbage model name
and fails at print time. The `/opt` path is load-bearing.

## Decision

`build/scripts/67-printer-vendor.sh` does not run the vendor `.deb` through dpkg
or apt. It unpacks the payload with `dpkg-deb -x` — no maintainer scripts — and
performs the wiring itself:

- the tree ships at **`/usr/lib/opt/brother/...`**, which is image content;
- `/usr/lib/tmpfiles.d/ik-os-printer-vendor.conf` restores
  `/var/opt/brother -> /usr/lib/opt/brother` on boot, so `/opt/brother` resolves
  at runtime and the wrapper's path assumption holds;
- the CUPS filter symlink deliberately **targets the `/opt` path**, not `/usr`,
  for the `readlink` above. It is dangling in the container by design;
- PPDs are copied into `/usr/share/ppd/Brother` and `/usr/share/cups/model/Brother`;
- the architecture symlinks the postinst would have made are created directly;
- **no `lpadmin` call is made**, and the build asserts `/etc/cups/printers.conf`
  is still empty afterwards.

This is the bootc idiom for vendor software in `/opt` (Fedora bootc images use
`/usr/lib/opt` with the same tmpfiles symlink).

## Consequences

- The driver is not in the dpkg database. `dpkg -l` will not list it;
  `/usr/share/ik-os/printer-drivers.list` records what shipped instead. This is
  a deliberate deviation from Rule 17, logged here per Rule 15.
- Upgrades are re-captures: run `scripts/maintenance/fetch-brother-driver.sh`
  again, commit the new checksummed files, rebuild.
- The build only knows Brother's ESP layout. Another vendor's payload makes
  `67-printer-vendor.sh` fail loudly rather than silently drop files.
- Brother tags the package `Architecture: i386` but ships both `x86_64` and
  `i686` binaries. Because dpkg is bypassed, no foreign architecture has to be
  enabled; the build selects the native set, links only those, and runs `ldd`
  over them so a missing library fails the build instead of the first print job.
- Adding the queue stays a user action in GNOME Settings, needing no root
  (SDD §23).
