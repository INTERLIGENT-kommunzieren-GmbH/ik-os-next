# Framework hardware enablement

There is one ik-os image. Hardware differences are handled by detection and by
shipping compatible packages, not by forking the OS (SDD §49).

- Firmware and kernel come from `stable-backports`, pinned in
  `config/apt/99-ik-os-backports.pref` and `config/image.env`.
- Storage, graphics and Thunderbolt drivers are forced into the initramfs in
  `config/boot/dracut-ik-os.conf` so a Framework boots without a hostonly
  initramfs.
- `ik-os hardware` reports the detected profile; `tests/hardware/` validates it.

Add a quirk here only when it cannot be expressed as a package or a kernel
parameter, and record why — an entry in this directory is a deviation from "one
common image" and needs the justification SDD §49 asks for.
