# Printing

## The three levels (SDD §22)

**Level 1 — driverless.** IPP Everywhere, AirPrint, IPP-over-USB. No driver.
This is the only level a user needs for a modern printer, and adding one needs
no root (SDD §23): GNOME Settings → Printers → Add.

That last part has three moving pieces, and all three must be present or the
panel reports *"some settings cannot be unlocked"* and greys out Add Printer:
`cups-pk-helper` (the polkit mechanism GNOME talks to),
`config/cups/49-ik-os-printers.rules` (grants its actions to the local active
session), and `SystemGroup lpadmin` in `cupsd.conf` with the user in that group
— done by `ik-os-user-groups.service` when the account is created. A new member
must log out and back in.

**Level 2 — Debian driver packages.** Only for printers the company actually
operates. Add the package to `packages/printing/packages.list` *and* record the
printer model in the table below. `printer-driver-gutenprint` is present as the
broad fallback.

**Level 3 — vendor drivers.** Not installed into the immutable root by users
(Rule 5), and the vendor's own installer is never run — see
`packages/printing/vendor/README.md` for why. Capture the packages instead:

    scripts/maintenance/fetch-brother-driver.sh MFC-L3740CDWE

then commit what lands in `packages/printing/vendor/brother/` and add a row to
the table below. `build/scripts/67-printer-vendor.sh` takes it from there.

It **unpacks** the `.deb` rather than installing it, and never runs the vendor's
maintainer scripts — Brother's postinst ends in an unconditional `lpadmin` that
invents a USB URI when it cannot find the printer, so installing it normally
bakes a bogus queue into every laptop. The driver tree also has to ship in
`/usr/lib/opt`, because `/opt` is a symlink into `/var` and `/var` does not
survive the build. [ADR 0008](adr/0008-vendor-printer-drivers-unpacked.md) has
the full reasoning; the short version is that `/opt/brother/Printers/<model>/`
is restored by tmpfiles on boot, because the CUPS wrapper parses that path to
learn its own model name.

The build verifies checksums, that the tree landed in `/usr`, that the filter
symlinks keep their `/opt` shape, that the PPDs are where CUPS looks, that the
filters resolve their shared libraries, and that no queue was created. Removal
and an actual printed page stay manual (`tests/printing/`). Prefer a PAPPL
printer application over a legacy vendor `.deb` where one exists.

## Supported printers

| Model | Level | Package / application | Validated |
| --- | --- | --- | --- |
| Brother MFC-L3740CDWE | 3 | `mfcl3740cdwpdrv` 3.5.1-1 (vendored) | build checks only — no printed page yet |

Brother indexes this model as `MFC-L3740CDW`, without the regional `E` suffix;
the capture script resolves that automatically. The device is a multifunction
unit and **scanning is not covered** by the vendored package — that needs
`brscan5`, which has not been added.

Level 2 and 3 entries without a row here should not be in the package lists:
Rule 11 requires a documented reason for every package.

## Security (SDD §52)

CUPS listens on `localhost` and the local socket only, `Browsing` is off, and
queues are not advertised to the LAN. The firewalld zone opens mDNS so
*discovery* works, and nothing else. Remote CUPS administration is disabled.

## Troubleshooting

    ik-os diagnostics | sed -n '/Printing/,/Networking/p'
    avahi-browse -rt _ipp._tcp        # what the network is advertising
    journalctl -u cups -u cups-browsed -b
