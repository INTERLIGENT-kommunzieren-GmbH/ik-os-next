# Hardware support and validation

## Target hardware (SDD §2)

| Class | Profile reported by `ik-os hardware` |
| --- | --- |
| Intel 11th / 12th / 13th Gen | `framework-intel` |
| Intel Core Ultra, Core Ultra Series 3 | `framework-core-ultra` |
| AMD Ryzen 7040 | `framework-amd` |
| AMD Ryzen AI | `framework-ryzen-ai` |

Profiles describe hardware. They do **not** fork the OS: one image, hardware
detection, compatible packages (SDD §49).

## Validation matrix (SDD §9)

Run `tests/hardware/test-hardware.sh` on each class and record the result here
before promoting a kernel to stable.

| | boot | Wi-Fi | BT | audio | webcam | suspend | USB | USB-C | ext. display | dock | battery | keyboard | touchpad | fingerprint |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| framework-intel | | | | | | | | | | | | | | |
| framework-core-ultra | | | | | | | | | | | | | | |
| framework-amd | | | | | | | | | | | | | | |
| framework-ryzen-ai | | | | | | | | | | | | | | |

Record: kernel release, ik-os version, date, tester.

## Firmware (SDD §10)

Firmware comes from the target Debian release. Once `forky-backports` exists
it becomes the source for newer firmware, pinned in
`config/apt/99-ik-os-backports.pref`. Either way the exact versions are tracked
in each release's `packages.manifest`. `fwupd` handles vendor firmware updates via LVFS; run
`ik-os hardware` to see current device firmware versions.
