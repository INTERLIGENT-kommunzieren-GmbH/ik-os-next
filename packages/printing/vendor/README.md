# Vendor printer drivers

Level 3 in SDD §22: drivers that are neither driverless (Level 1) nor packaged
by Debian (Level 2). One directory per vendor, matching SDD §24:

    packages/printing/vendor/
    ├── brother/
    ├── canon/
    ├── epson/
    ├── hp/
    └── xerox/

Each directory holds the vendor `.deb` files, a `SHA256SUMS`, and whatever index
file named them. `build/scripts/67-printer-vendor.sh` unpacks everything it finds
here; an empty tree is a clean no-op.

## Do not run the vendor's installer

Brother's `linux-brprinter-installer` (archived in `hardware/printer/`) — and
its equivalents from other vendors — must **not** run during the build or on a
deployed host. It is interactive, downloads packages at run time so the build
stops being reproducible (SDD §47), and calls `lpadmin` to create a queue for
one specific printer at one specific address, which is machine state rather than
image content. Rule 5 forbids installing arbitrary vendor `.deb`s into `/usr`
this way.

## Nor the `.deb`'s own maintainer scripts

The same `lpadmin` call is in the package. Brother's postinst chains into
`cupswrapper<model>`, which ends:

    if [ "$URI" = '' ]; then URI="usb://dev/usb/lp0"; fi
    lpadmin -p ${printer_name} -E -v $URI -P $ppd_file_name

Nothing guards that call — when the printer is not found, and in a build
container it never is, the script invents a URI and creates the queue anyway.

So the build does not use `dpkg -i` or `apt install ./x.deb`. It extracts the
payload with `dpkg-deb -x` and does the wiring itself, which also lets the tree
ship in `/usr/lib/opt` instead of `/opt` — `/opt` is a symlink into `/var`, and
`/var` does not survive `95-finalize.sh`. A tmpfiles symlink restores
`/opt/brother` on boot, because the CUPS wrapper parses that path to recover its
own model name. See [ADR 0008](../../../docs/adr/0008-vendor-printer-drivers-unpacked.md).

## Adding a driver

```
scripts/maintenance/fetch-brother-driver.sh MFC-L3740CDWE
```

That performs the same lookup the vendor installer would — model → normalised
name → index → exact package filenames — and writes the `.deb`s, the index, and
`SHA256SUMS` here. Review them, commit them, and record the printer model in
`docs/printing.md` (SDD §22 wants a documented reason for every Level 2/3
driver). Then `just build`.

## What the build checks

`67-printer-vendor.sh` covers the parts of SDD §24 a build can verify:

- **origin** — `SHA256SUMS` must exist and match;
- **placement** — the tree lands in `/usr/lib/opt`, so it survives the `/var`
  wipe, and the boot-time tmpfiles symlink is written;
- **dependency compatibility** — `ldd` over every filter binary that gets
  linked. These packages routinely declare no dependencies, so without this they
  install cleanly and fail at print time with a missing shared library;
- **no queue** — `/etc/cups/printers.conf` must still be empty afterwards.

`build/validation/verify-image.sh` re-checks all of that in the finished image,
plus that the filter symlinks kept their `/opt` shape and the PPDs are where
CUPS looks. `tests/printing/` then confirms on a booted system that tmpfiles
really did restore `/opt` and that `cupsd` offers the PPD. Removal and an actual
printed page remain manual.

## The architecture catch

Brother tags its packages `Architecture: i386` while shipping **both** `x86_64`
and `i686` binaries, and the `.inf` for the MFC-L3740CDWE says `REQUIRE32LIB=no`.
Because dpkg is bypassed entirely, that tag is irrelevant: no foreign
architecture is enabled and no `:i386` libraries are pulled in. The build picks
the native set, links only those, and skips the other architecture's binaries in
the `ldd` sweep (it says how many it skipped). If a native filter is missing a
library, the build fails and lists it — add it to
`packages/printing/packages.list`.
