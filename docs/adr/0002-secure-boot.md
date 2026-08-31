# ADR 0002 — Secure Boot with systemd-boot signed by a company MOK

**Status:** accepted
**SDD:** §5, §50; Rules 15, 18

## Context

SDD §5 requires *both* systemd-boot and Secure Boot.

On Debian these two requirements do not compose out of the box:

- Debian ships `shim-signed` and `grub-efi-amd64-signed`, both signed by
  Microsoft's UEFI CA via Debian's shim.
- Debian ships `systemd-boot` and `systemd-boot-efi` **unsigned**. There is no
  `systemd-boot-signed` package.

So an unmodified Debian systemd-boot will not start on a machine with Secure
Boot enabled. Rule 18 forbids silently swapping in GRUB and calling §5 done.

## Decision

ik-os signs `systemd-bootx64.efi` at build time with a company Machine Owner
Key. `shim-signed` stays in the image so the chain is:

    firmware -> shim (Microsoft-signed) -> systemd-boot (ik-os MOK) -> kernel

The two halves are stored differently, because only one of them is a secret:

    config/company/ik-os-mok.crt      committed
    SECURE_BOOT_MOK_KEY (CI secret)   never in the repository

Committing the certificate is deliberate, and mirrors `config/company/cosign.pub`
next to the private `SIGNING_SECRET`. It is public by construction — it ships in
every signed image and every booting machine has it enrolled — and putting it in
the tree buys a guard that nothing else can provide: the build compares the key
it was handed against the certificate the fleet trusts, and refuses to sign if
they differ. Without that comparison a MOK replaced by accident builds green and
then fails to boot on every enrolled machine.

`40-boot.sh` makes the same comparison for a local signed build, and treats a
readable key with a missing certificate as an error rather than a reason to fall
back to unsigned: the two halves go missing for different reasons, and answering
a broken tree with a silently unbootable image is the wrong trade.

`config/boot/secure-boot.env` controls the policy:

- `SECURE_BOOT_SIGNING=required` — the build **fails** without a key. CI sets
  this for the testing and stable channels.
- `SECURE_BOOT_SIGNING=optional` — an unsigned bootloader is produced. Local
  developer builds only; the resulting image will not Secure Boot.

The MOK is enrolled per machine, either by IT placing it in the firmware `db`
during provisioning, or via `mokutil --import` at install time. The public
certificate therefore ships in the image at `/usr/share/ik-os/ik-os-mok.crt`
(and `.der`, because `mokutil --import` accepts only DER): a machine cannot
enrol a key it was never given, and telling operators to fetch it out of band is
how fleets end up with Secure Boot switched off instead. It is written only when
the bootloader in that image was actually signed, so its presence is a fact
about the image rather than a promise.

`ik-os enroll-mok` wraps the enrolment. See `docs/migration.md` for the
procedure and for the one thing everybody asks first: the password `mokutil`
prompts for is invented on the spot and used once.

## The guard has to be reachable

`SECURE_BOOT_SIGNING=required` is only worth anything if it is set when the key
is missing, which is exactly the case it exists for. It was not. `build.yml`'s
staging step both set `required` **and** carried `if: … && env.MOK_KEY != ''`,
so an absent secret skipped the step, left the committed default of `optional`
in place, and published an image with an unsigned bootloader and a green tick.
The condition meant to enforce signing was the condition that disabled the
enforcement. Every image published before 2026-08-31 is unsigned for this
reason, including the one the first green pipeline produced.

Three changes so the policy cannot be silently absent again:

1. The staging step always runs off a pull request and decides in the open. With
   no key it **fails**, unless the repository variable
   `ALLOW_UNSIGNED_BOOTLOADER=yes` is set — one deliberate, auditable way past
   Rule 18, because a build that is silently red is no better than one that is
   silently unsigned. Setting a repository variable is a recorded act; a skipped
   step was not.
2. `40-boot.sh` records the **intent** next to the outcome, and
   `verify-image.sh` fails the build if `required` did not produce a signed
   binary. The image can no longer disagree with the policy it was built under.
3. `build.yml` labels the image `com.interligent.ik-os.secureboot`, and
   `promote.yml` refuses to make an unsigned candidate `stable` unless the
   person promoting types the acknowledgement. Reading a label costs one
   registry request; reading the file inside the image would cost a seven-
   gigabyte pull.

The key is also validated before the build starts — readable, unencrypted (nothing
can type a passphrase for `sbsign`), and matching the committed certificate. A
mismatched pair signs happily and produces a binary the firmware rejects, which
is otherwise discovered one machine at a time.

## Alternatives rejected

- **Use Debian's signed GRUB instead.** Meets Secure Boot, violates §5's
  systemd-boot requirement. If the company later decides GRUB is acceptable,
  that is an SDD change, not an implementation decision.
- **Ship unsigned and tell users to disable Secure Boot.** Violates §50.

## Related

The bootloader *installation* mechanism is a separate decision: systemd-boot is
only installable through bootc's composefs backend. See
[ADR 0005](0005-composefs-backend.md).

## Consequences

- Machines need the ik-os MOK enrolled once. `ik-os-migrate check` reports
  Secure Boot state and names the command, because this is the one preflight
  item whose consequence is a black screen *after* a successful install rather
  than a failed install.
- Until `config/company/ik-os-mok.crt` is committed and `SECURE_BOOT_MOK_KEY` is
  set, builds fail by default. That is the intended behaviour of Rule 18 and not a
  regression; `ALLOW_UNSIGNED_BOOTLOADER=yes` is the way to keep building
  meanwhile, at the cost of images that cannot Secure Boot and cannot be
  promoted without an explicit acknowledgement.
- `tests/boot/test-boot.sh` fails on a machine with Secure Boot disabled, which
  is deliberate: acceptance criterion 2 is not satisfied by a machine that
  merely *could* Secure Boot.
