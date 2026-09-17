# ADR 0022 — The installer encrypts the disk with a passphrase, and uses the whole disk

**Status:** accepted
**SDD:** §4, §5, §36, §50; Rules 13, 18
**Amends:** the SDD is silent on disk encryption; this ADR adds the requirement

## Context

A company laptop leaves the building. Without disk encryption, everything on it
— source, credentials in `~`, the company VPN identity, mail caches — is
readable by anyone who takes it, with no password needed: pull the drive, mount
it, read it. The SDD says nothing about encryption at all, which is the gap this
ADR closes rather than a decision it overturns.

The requirement, as given: encrypt the disk, ask for the passphrase during
installation, prompt for it at boot with the same branding as the rest of the
boot, and require the whole disk — if the operator will not give up the whole
disk, abort rather than attempt anything partial.

## What bootc can and cannot do

`bootc install to-disk` has a `--block-setup` flag, and LUKS is one of its
values, so the first question was whether this is a one-word change:

    --block-setup <BLOCK_SETUP>
        direct: Filesystem written directly to block device
        tpm2-luks: Bind unlock of filesystem to presence of the default tpm2 device
        [possible values: direct, tpm2-luks]

It is not. `tpm2-luks` binds the unlock to the TPM, which means the disk opens
whenever it is in that machine, with **no passphrase asked**. That is a real
design — it is roughly what BitLocker does by default — but it is not what was
asked for, and on its own it protects only against the drive being removed, not
against the laptop being taken intact.

bootc says where to go instead, in its own help text:

> Use `install to-filesystem` for anything more complex such as RAID, LVM,
> LUKS etc.

and in the source (`crates/lib/src/install.rs`):

> storage layouts (RAID, LVM, custom LUKS configurations). The caller is
> responsible …

So the installer partitions and encrypts, and bootc deploys into the result.

## Decision

**LUKS2 with an operator-chosen passphrase, on the whole disk, always.** There
is no unencrypted install path and no prompt offering one.

The installer:

1. refuses a disk that is too small (see below) before anything is written;
2. asks whether ik-os may use the **whole** disk, and aborts if not;
3. keeps the existing erase confirmation and the typed `ERASE`;
4. asks for the passphrase twice, requiring at least 12 characters;
5. writes a GPT with an ESP and one LUKS2 container, formats btrfs inside it,
   and mounts the ESP at `<root>/boot/efi`;
6. runs `bootc install to-filesystem … --karg rd.luks.uuid=<uuid>`.

Sizes and paths are not invented. The ESP is **1024 MiB** because that is
`CFS_EFIPN_SIZE_MB`, the size bootc's own composefs installs use, so the
deployment gets the room bootc would have given it. The ESP goes to
`boot/efi` because that is `bootloader::EFI_DIR` joined to `boot`, which is
where bootc looks for it. There is no BIOS boot partition: ik-os is UEFI only
(SDD §5) and the installer already refuses to run otherwise.

`root=` is left to bootc, which writes the btrfs UUID. That is deliberate: it
stays correct regardless of what the unlocked mapper device ends up being
called, so nothing depends on a name chosen at install time.

### The passphrase is passed with no trailing newline

    printf '%s' "$PASSPHRASE" | cryptsetup luksFormat --type luks2 \
        --batch-mode --key-file - "$LUKS_DEV"

With `--key-file -`, cryptsetup takes the bytes it reads as the key verbatim. A
trailing newline would therefore become part of the key, and the boot prompt —
which sends only what was typed — could then **never** open the disk. The
failure would appear at first boot, on the operator's machine, with the disk
already written. `printf '%s'` rather than `echo` is the whole defence, so it
is commented at the call site as well as here.

The passphrase reaches the script on whiptail's file descriptor 3, never in a
command line, so it does not appear in the process table.

### Discards are allowed, persistently

    cryptsetup open --allow-discards --persistent …

`--persistent` records the flag in the LUKS2 header, so TRIM reaches the SSD on
every boot without a kernel argument to carry it. The cost is that the *amount*
of used space inside the container becomes visible to someone holding the raw
device. For a company laptop on NVMe, the drive's write lifetime is worth more
than hiding how full it is.

### The prompt at boot

`config/boot/dracut-ik-os.conf` gains `crypt`, `systemd-cryptsetup` and
`plymouth`. All three modules were already in the image
(`/usr/lib/dracut/modules.d/70crypt`, `71systemd-cryptsetup`, `45plymouth`) and
simply went unused, so this adds no packages.

`crypt` and `systemd-cryptsetup` are both requested on purpose. systemd is in
this initramfs, so systemd-cryptsetup's generator is what honours
`rd.luks.uuid=`; `crypt` carries the cryptsetup binary and udev rules. Fedora
ships both together, which is the configuration Bluefin's prompt comes from.

## Consequences

**A lost passphrase is a lost disk.** There is no recovery key, no escrow, and
no second keyslot. This is the one consequence that is not a trade-off but a
policy question, and it belongs to IT, not to this repository — see below.

**No unattended reboot.** A machine cannot come back up on its own after an
update or a power cut; someone has to type the passphrase. For a laptop that is
the point. If it ever becomes a problem, TPM2 enrolment as a *second* keyslot
(`systemd-cryptenroll`) would restore unattended boot without giving up the
passphrase, and is the obvious follow-up.

**`ik-os-migrate` is not covered by this.** It rebases a running Bluefin
machine in place and leaves `/var` alone, which is what preserves `/home`; it
cannot encrypt a disk underneath a running system. A migrated machine is
therefore unencrypted, and the only route to encryption is a reinstall from the
ISO. Nothing is deployed at the time of this decision, so no machine is in that
state yet, but it will not fix itself later either.

**Whole-disk only.** ik-os cannot share a disk with another operating system.
It could not before this ADR either — bootc's `to-disk --wipe` took the whole
device — but the installer now says so and stops, instead of the operator
discovering it from the partition table afterwards.

## Minimum disk size

The same change refuses disks that are too small, which is a separate defect
found in the same VM run: a 24 GiB disk installed **successfully** and then ran
out of space during first boot, at application group 5 of 7, leaving a
half-provisioned system and no message explaining it.

Measured, not estimated:

| | |
| --- | --- |
| Deployment written by the installer | **12 GiB** |
| Approved Flatpak applications (55) | **5.63 GB** |
| Runtimes they share (5) | **4.53 GB** |

The five runtimes are `org.freedesktop.Platform` 24.08 **and** 25.08,
`org.gnome.Platform` 49 **and** 50, and `org.kde.Platform` 5.15-25.08 — about
1.8 GB of that total is older runtime versions kept alive by applications that
have not moved to the current one.

So first boot needs roughly 23 GiB before Homebrew, container images, logs or
any user data. The thresholds follow: **refuse below 32 GiB**, the smallest
disk on which first boot finishes with room to spare, and **warn below
128 GiB**, below which there is little room for the containers and files a
developer workstation actually holds. Framework hardware ships well above both,
so in practice only VMs see either message.

## What IT must confirm

1. **Passphrase policy.** 12 characters is this ADR's floor, chosen to be
   defensible rather than authoritative. If there is a company standard, it
   belongs here instead.
2. **Recovery.** Today a forgotten passphrase means reinstalling and losing
   local data. If that is unacceptable, the options are an IT-held recovery key
   in a second LUKS keyslot, or escrow of the operator's passphrase. Both are
   deliberately absent rather than forgotten: adding either puts a key that
   opens every company laptop somewhere, and where that somewhere is, is IT's
   decision and not one Rule 13 lets this repository make.
3. **Whether encryption is mandatory for every machine**, including desk-bound
   ones. This ADR assumes yes, because the fleet is laptops.

## Verified

The installer was driven end to end against stubbed `sgdisk`, `cryptsetup`,
`mkfs.*`, `mount` and `bootc`, in four scenarios: a 24 GiB disk (refused, with
**no** destructive command reached), a 64 GiB disk (warned, then installed), a
256 GiB disk (installed), and a passphrase entered wrongly twice — mismatched,
then too short — before a good one. The stub recorded the key handed to
`luksFormat` as 21 bytes for a 21-character passphrase, confirming no trailing
newline, and recorded the final command as

    bootc install to-filesystem --source-imgref oci:…:ik-os \
        --target-imgref ik-os:testing \
        --karg rd.luks.uuid=<uuid> \
        --bootloader systemd --composefs-backend /run/ik-os-install-target

What that harness **cannot** prove is that the result boots: stubs do not
create LUKS containers, and the initramfs is not exercised at all. Unlocking at
boot, the Plymouth prompt, and the deployment coming up on an encrypted root
are unverified until an ISO carrying this installer is booted in a VM.
