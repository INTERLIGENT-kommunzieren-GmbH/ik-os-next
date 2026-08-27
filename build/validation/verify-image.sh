#!/bin/bash
# In-image acceptance checks (SDD §63). Anything verifiable without booting is
# verified here, so a broken image never reaches a registry.
set -uo pipefail

PASS=0; FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no()   { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }
# Under pipefail `producer | grep -q` reports a successful match as a FAILURE:
# grep exits at the first hit and the producer dies on SIGPIPE. Capture first.
out_has(){ local pat="$1"; shift; local o; o=$("$@" 2>&1) || true; grep -qF -- "$pat" <<<"$o"; }

echo "== ik-os image verification =="

echo "-- immutable OS model (SDD §4) --"
check "/ostree points at sysroot/ostree"     test "$(readlink /ostree)" = "sysroot/ostree"
check "/home is a symlink into /var"         test "$(readlink /home)" = "var/home"
check "/root is a symlink into /var"         test "$(readlink /root)" = "var/roothome"
check "/usr/local is a symlink into /var"    test "$(readlink /usr/local)" = "../var/usrlocal"
check "composefs is enabled"                 grep -q 'enabled = yes' /usr/lib/ostree/prepare-root.conf
check "sysroot is read-only"                 grep -q 'readonly = true' /usr/lib/ostree/prepare-root.conf
# /var is machine-local state, so package state left there would be applied once
# at install and never updated again. 95-finalize.sh moves it to tmpfiles.d and
# /usr/share/factory. The ONE exception is /var/lib/flatpak: a Flatpak has
# nowhere else to be installed, and that is a deliberate decision with its own
# ADR (0014), not drift. Listing it by name here means a SECOND directory
# appearing in /var still fails this check.
var_is_empty_of_package_state() {
    local extra
    extra=$(find /var -mindepth 1 -maxdepth 1 \
        -not -name home -not -name roothome -not -name opt -not -name srv \
        -not -name mnt -not -name usrlocal -not -name tmp -not -name lib)
    [[ -z "$extra" ]] || { echo "unexpected in /var: $extra"; return 1; }
    # /var/lib may contain flatpak and nothing else.
    extra=$(find /var/lib -mindepth 1 -maxdepth 1 -not -name flatpak 2>/dev/null)
    [[ -z "$extra" ]] || { echo "unexpected in /var/lib: $extra"; return 1; }
}
check "/var is empty of package state"       var_is_empty_of_package_state
check "the dpkg database survives in /usr"   test -s /usr/lib/dpkg/status
check "machine-id is empty"                  test ! -s /etc/machine-id
# The Debian base image ships /etc/hostname = "debuerreotype". Shipping it means
# every machine in the fleet has the same name; first boot derives one instead.
hostname_not_inherited() {
    # podman bind-mounts /etc/hostname over this container, so read the file the
    # image actually ships rather than whatever the runtime substituted.
    local h; h=$(cat /usr/share/ik-os/hostname 2>/dev/null || true)
    [[ "$h" == "ik-os" ]]
}
check "hostname is not the base image's"     hostname_not_inherited
check "hostname helper installed"            test -x /usr/libexec/ik-os/ik-os-hostname
check "hostname service enabled"             test -L /etc/systemd/system/multi-user.target.wants/ik-os-hostname.service
# It must not inherit ik-os-firstboot's ordering, or the machine still calls
# itself "ik-os" at the login prompt while the network and Docker come up.
hostname_unit_is_early() {
    local u=/usr/lib/systemd/system/ik-os-hostname.service
    ! grep -qE '^After=.*(network-online|docker)' "$u" \
        && grep -qE '^Before=.*systemd-user-sessions' "$u"
}
check "hostname is set before login"         hostname_unit_is_early
# glibc silently ignores an NSS module whose shared library is absent, so a
# nsswitch.conf naming one is a lie that only shows up as "unable to resolve
# host" on every sudo. Scoped to the hosts line because that is the one
# 65-printing.sh rewrites; Debian's stock "db" and "nis" entries for
# protocols/services/netgroup are absent by default upstream and fall back to
# /etc files, which is normal and not ours to fix.
nss_hosts_modules_present() {
    local libdir mod
    libdir=$(dirname "$(ls /usr/lib/*/libc.so.6 2>/dev/null | head -1)")
    [[ -d "$libdir" ]] || return 1
    while IFS= read -r mod; do
        # Built into libc since glibc 2.34; they ship no standalone .so.
        case "$mod" in files|dns|compat) continue ;; esac
        [[ -e "${libdir}/libnss_${mod}.so.2" ]] || return 1
    done < <(sed -e 's/#.*//' /etc/nsswitch.conf \
             | sed -nE 's/^hosts:[[:space:]]*(.*)$/\1/p' \
             | tr ' ' '\n' | grep -vE '^\[|^$' | sort -u)
    return 0
}
check "every NSS host module exists"         nss_hosts_modules_present
# The specific one that broke sudo: the machine must be able to resolve itself.
check "myhostname NSS module installed"      bash -c 'ls /usr/lib/*/libnss_myhostname.so.2'
check "resolve NSS module installed"         bash -c 'ls /usr/lib/*/libnss_resolve.so.2'

echo "-- boot (SDD §5) --"
KVER=$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort -V | tail -1)
check "kernel present (${KVER})"             test -f "/usr/lib/modules/${KVER}/vmlinuz"
check "initramfs present"                    test -s "/usr/lib/modules/${KVER}/initramfs.img"
check "branding is inside the initramfs"     bash -c "lsinitrd /usr/lib/modules/${KVER}/initramfs.img 2>/dev/null | grep -q watermark"
check "kargs enable the boot splash"         bash -c 'grep -q "\"splash\"" /usr/lib/bootc/kargs.d/10-ik-os.toml'
check "/boot is empty"                       test -z "$(ls -A /boot)"
check "no dangling kernel symlinks at /"     bash -c '! test -e /vmlinuz -o -L /vmlinuz -o -L /initrd.img'
check "systemd-boot present"                 test -f /usr/lib/systemd/boot/efi/systemd-bootx64.efi
check "bootc is installed"                   command -v bootc
# shellcheck disable=SC1091
. /usr/share/ik-os/build-bootc.env
check "ostree is new enough for bootc"        bash -c 'ostree --version | awk -F"\x27" "/Version/{split(\$2,a,\".\"); exit !(a[1]>2025 || (a[1]==2025 && a[2]>=3))}"'
check "composefs tooling present"            command -v mkcomposefs
# bootc imports container layers through ostree's libarchive support; without
# it `bootc install` dies on the first layer.
for feat in libarchive composefs selinux systemd; do
    check "ostree built with ${feat}" bash -c "ostree --version | grep -qF '${feat}'"
done

echo "-- install toolchain (SDD §36) --"
# `bootc install` shells out to these. A missing one does not surface until
# somebody tries to install the image, which is far too late to find out.
for tool in sfdisk losetup wipefs blkid partx mount \
            mkfs.btrfs mkfs.vfat mkfs.ext4 btrfs \
            bootctl udevadm ostree bootc mkcomposefs; do
    check "${tool} available" command -v "$tool"
done

echo "-- kernel channel (SDD §9) --"
# shellcheck disable=SC1091
. /usr/share/ik-os/build-kernel.env
check "kernel came from the pinned suite"    bash -c '[ -n "'"${KERNEL_SUITE}"'" ]'
check "kernel version is pinned"             test -n "${KERNEL_VERSION}"

echo "-- desktop (SDD §11, §13) --"
check "GNOME Shell installed"                test -x /usr/bin/gnome-shell
check "ArcMenu installed"                    test -d /usr/share/gnome-shell/extensions/arcmenu@arcmenu.com
check "Search Light absent (Rule 7)"         bash -c '! compgen -G "/usr/share/gnome-shell/extensions/search-light*"'
check "dconf database built"                 test -f /etc/dconf/db/ik-os
check "greeter config in Debian's location"  test -f /usr/share/gdm/dconf/95-ik-os
check "login-screen logo is set"             grep -q 'ik-os-logo.png' /usr/share/gdm/dconf/95-ik-os
check "the greeter database compiles"        bash -c 'd=$(mktemp -u); dconf compile "$d" /usr/share/gdm/dconf && grep -qaF ik-os-logo.png "$d"; r=$?; rm -f "$d"; exit $r'
check "wallpapers installed"                 bash -c '[ "$(ls /usr/share/backgrounds/ik-os/ 2>/dev/null | wc -l)" -ge 1 ]'
check "wallpapers are real images, not the logo" \
    bash -c 'for f in /usr/share/backgrounds/ik-os/*; do [ "$(stat -c%s "$f")" -gt 100000 ] || exit 1; done'
check "registered in GNOME's chooser"        test -s /usr/share/gnome-background-properties/ik-os.xml
check "chooser XML is well-formed" \
    python3 -c "import xml.dom.minidom;xml.dom.minidom.parse('/usr/share/gnome-background-properties/ik-os.xml')"
check "default wallpaper is set"             bash -c 'grep -q "picture-uri=.file:///usr/share/backgrounds/ik-os/" /etc/dconf/db/ik-os.d/05-background'
check "the default file exists"              bash -c 'f=$(sed -n "s|^picture-uri=.file://\(.*\).|\1|p" /etc/dconf/db/ik-os.d/05-background | head -1); test -f "$f"'
check "wallpaper is a default, not locked"   bash -c '! grep -q "desktop/background" /etc/dconf/db/ik-os.d/locks/* 2>/dev/null'
check "ArcMenu button hidden (Rule 8)"       grep -q "menu-button-appearance='None'" /etc/dconf/db/ik-os.d/10-arcmenu
check "Super+Space bound (Rule 9)"           grep -q "runner-hotkey=\['<Super>space'\]" /etc/dconf/db/ik-os.d/10-arcmenu
check "the binding is locked"                grep -q 'runner-hotkey' /etc/dconf/db/ik-os.d/locks/00-ik-os-managed
check "overview hidden at login"             grep -q 'hide-overview-on-startup=true' /etc/dconf/db/ik-os.d/10-arcmenu
check "the overview default is not locked"  bash -c '! grep -q "hide-overview-on-startup" /etc/dconf/db/ik-os.d/locks/* 2>/dev/null'
check "dash-to-dock clears the overview"     grep -q 'disable-overview-on-startup=true' /etc/dconf/db/ik-os.d/20-extensions
# Both extensions save and restore Main.sessionMode.hasOverview around the
# startup animation, and the one enabled second wins. ArcMenu first leaves the
# session with no overview at all.
dtd_enabled_before_arcmenu() {
    local list
    list=$(grep '^enabled-extensions=' /etc/dconf/db/ik-os.d/21-enabled-extensions)
    [[ "${list%%arcmenu@arcmenu.com*}" == *dash-to-dock@micxgx.gmail.com* ]]
}
check "dash-to-dock is enabled first"       dtd_enabled_before_arcmenu

echo "-- first login is possible (SDD §36, §37) --"
# The image deliberately contains no accounts and a locked root (SDD §27).
# Something must therefore create the first user, or the installed machine
# cannot be logged into at all.
check "no human accounts baked in"           bash -c '[ -z "$(awk -F: "\$3>=1000 && \$3<65000" /etc/passwd)" ]'
check "root has no usable password"          bash -c 'awk -F: "\$1==\"root\"{exit (\$2==\"*\"||\$2==\"!\")?0:1}" /etc/shadow'
check "gnome-initial-setup is installed" \
    bash -c 'test -x /usr/libexec/gnome-initial-setup || test -x /usr/lib/gnome-initial-setup/gnome-initial-setup'
check "GDM runs initial setup"               grep -q '^InitialSetupEnable=true' /etc/gdm3/daemon.conf
check "systemd-firstboot will prompt"        bash -c 'grep -q -- "--prompt-root-password" /usr/lib/systemd/system/systemd-firstboot.service'

echo "-- containers (SDD §17, §18) --"
check "Docker Engine present"                test -x /usr/sbin/dockerd
check "Docker CLI present"                   test -x /usr/bin/docker
check "docker compose plugin wired up"       test -e /usr/libexec/docker/cli-plugins/docker-compose
check "docker buildx plugin wired up"        test -e /usr/libexec/docker/cli-plugins/docker-buildx
check "docker.service enabled"               test -L /etc/systemd/system/multi-user.target.wants/docker.service
check "Podman did not replace Docker"        bash -c 'test -x /usr/sbin/dockerd && test -x /usr/bin/docker && test -x /usr/bin/podman'
# SDD §17 requires developer access to Docker to be configured, and §51 requires
# the root-equivalence to be documented. Membership itself is machine state, so
# what the image must ship is the group, the policy, and the mechanism.
check "docker group exists in the image"     bash -c 'getent group docker'
check "docker security note shipped"         test -s /usr/share/doc/ik-os/docker-security.md
check "DOCKER_GROUP_POLICY is set"           bash -c 'grep -q "^DOCKER_GROUP_POLICY=" /usr/lib/ik-os/policy.env'
check "group helper installed"               test -x /usr/libexec/ik-os/ik-os-user-groups
check "group service enabled"                test -L /etc/systemd/system/multi-user.target.wants/ik-os-user-groups.service
# gnome-initial-setup creates the first account long after multi-user.target, so
# a boot-ordered unit alone would find no user. The .path unit is the mechanism.
check "group path watcher enabled"           test -L /etc/systemd/system/multi-user.target.wants/ik-os-user-groups.path
check "the watcher watches /etc/passwd"      bash -c 'grep -q "^PathChanged=/etc/passwd" /usr/lib/systemd/system/ik-os-user-groups.path'
# The bug this replaced: firstboot ran before the user existed, "succeeded", and
# stamped itself done forever. Make sure it cannot come back.
check "firstboot no longer grants docker"    bash -c '! grep -q "usermod -aG docker" /usr/libexec/ik-os/ik-os-firstboot' 
# The CLI runs under `set -u` from units and containers where $USER is unset.
# Shipping a diagnostics command that aborts on its own first line is worse than
# not shipping one, so run it and reject any shell-level error in the output.
diagnostics_runs() {
    local o; o=$(ik-os diagnostics 2>&1) || true
    ! grep -qE 'unbound variable|syntax error|command not found' <<<"$o"
}
check "ik-os diagnostics runs cleanly"       diagnostics_runs
check "diagnostics reports docker policy"    bash -c "ik-os diagnostics 2>/dev/null | grep -q 'Policy'"
# Every line of the report is a probe, and probes fail on healthy machines. If
# one truncates the report the output still looks plausible — it just silently
# stops. Assert the last section is present.
check "diagnostics report is not truncated"  bash -c "ik-os diagnostics 2>/dev/null | grep -q 'Failed units'"
# Groups and Homebrew leave no firstboot stamp, so the report is the only place
# their state is visible.
check "diagnostics report account setup"     bash -c "ik-os diagnostics 2>/dev/null | grep -q 'Out-of-band provisioning'"
# SDD §63 — the booted half of the acceptance criteria must be runnable on a
# deployed machine, not only from a checkout.
check "booted test suites shipped"           test -x /usr/share/ik-os/tests/provisioning/test-provisioning.sh
check "the suites can find their lib"        test -f /usr/share/ik-os/tests/lib.sh
check "ik-os selftest is wired up"           bash -c "ik-os --help | grep -q selftest"
# A first boot that swallows Flatpak install failures stamps itself done and
# never retries, leaving an empty app store forever. The step must be able to
# report failure.
check "firstboot reports Flatpak failures" \
    bash -c 'grep -q "the step stays unfinished" /usr/libexec/ik-os/ik-os-firstboot'
# Installing apps does not fetch appstream, and without it every app store on
# the machine shows an empty catalogue while `flatpak list` looks perfect.
check "firstboot fetches appstream data" \
    bash -c 'grep -q "update --appstream" /usr/libexec/ik-os/ik-os-firstboot'
# Every step declares a scope. "once" is machine-local state; "image" re-runs
# when the booted image changes. A step with no scope, or a typo'd one, would be
# silently treated as pending on every boot -- which is the setup screen the user
# reported seeing on every boot, back again by another route.
step_scopes_declared() {
    local f=/usr/libexec/ik-os/ik-os-firstboot line n=0
    while IFS= read -r line; do
        case "$line" in
            once:*|image:*) n=$((n+1)) ;;
            *) return 1 ;;
        esac
    done < <(sed -n '/^STEPS=(/,/^)/p' "$f" | sed -n 's/^[[:space:]]*"\(.*\)"$/\1/p')
    (( n > 0 ))
}
check "every first-boot step has a scope"    step_scopes_declared
# /var survives a bootc update, so a stamp that records nothing is a stamp that
# can never expire: the machine keeps the Flatpak list it first booted with,
# forever. Stamps must name the image they were satisfied on.
stamps_record_image() {
    local f=/usr/libexec/ik-os/ik-os-firstboot body
    body=$(sed -n '/^stamp_value()/,/^}/p' "$f")
    [[ -n "$body" ]] || return 1
    grep -qF 'image_id' <<<"$body" \
        && grep -qF 'stamp_value "$scope" > "${STATE}/${name}.done"' "$f"
}
check "first-boot stamps record the image"   stamps_record_image
# IK_OS_VERSION defaults to "dev" and IK_OS_BUILD_ID to "local", so a build-time
# identifier makes every locally built image look identical and a test VM would
# never re-provision. The change detector has to be a runtime one.
image_id_is_runtime() {
    local f=/usr/libexec/ik-os/ik-os-firstboot body
    body=$(sed -n '/^image_id()/,/^}/p' "$f")
    [[ -n "$body" ]] || return 1
    grep -qF "bootc status" <<<"$body" && ! grep -qF "IK_OS_BUILD_ID" <<<"$body"
}
check "image id comes from runtime state"    image_id_is_runtime
# The whole point of the change. SHOW_SPLASH defaults to no and every splash
# helper returns early unless it was flipped to yes, so a code path that reaches
# plymouth without deciding first cannot exist. Checking the call site instead
# would pass on a script whose helpers had lost their guard.
splash_helpers_gated() {
    local f=/usr/libexec/ik-os/ik-os-firstboot fn body total=0 inside=0
    grep -qx 'SHOW_SPLASH=no' "$f" || return 1
    # The one gate every caller goes through.
    grep -qF '[[ "$SHOW_SPLASH" == yes ]] && plymouth --ping' "$f" || return 1
    for fn in splash_banner splash_detail splash_end; do
        body=$(sed -n "/^${fn}()/,/^}/p" "$f")
        grep -qF 'splash_up || return 0' <<<"$body" || return 1
    done
    # And no plymouth call may live anywhere else. Naming the helpers is not
    # enough on its own: a call added straight into a step would bypass all of
    # them and narrate the splash on boots that are supposed to be silent.
    #
    # Counted over the whole splash section rather than per function, because
    # splash_up is a one-liner: a /^name()/,/^}/ range on it runs to the next
    # line starting with "}" -- the end of the NEXT function -- and double-counts
    # everything in between. Comments are stripped so prose about plymouth does
    # not register as a call.
    total=$(sed 's/#.*//' "$f" | grep -c 'plymouth ') || true
    inside=$(sed -n '/^# --- splash/,/^# --- steps/p' "$f" \
             | sed 's/#.*//' | grep -c 'plymouth ') || true
    (( total > 0 && total == inside ))
}
check "plymouth is never touched ungated"    splash_helpers_gated
check "a boot with no work exits early" \
    bash -c 'grep -q "nothing to do for image" /usr/libexec/ik-os/ik-os-firstboot'
# Showing the splash for a retry of a step that failed earlier would mean an
# offline machine displays the setup screen on every boot forever.
check "the splash is gated on the image, not on work" \
    bash -c 'grep -q "retrying quietly" /usr/libexec/ik-os/ik-os-firstboot'
# First boot holds the login screen so nobody starts work on a half-configured
# machine, and tells the user what is happening so rebooting is not the obvious
# move. Ordering only: if it fails, GDM still starts.
check "first boot delays the login screen" \
    bash -c 'grep -q "^Before=.*gdm.service" /usr/lib/systemd/system/ik-os-firstboot.service'
check "the boot splash is held open" \
    bash -c 'grep -q "^Before=.*plymouth-quit.service" /usr/lib/systemd/system/ik-os-firstboot.service'
# ik-os stays in plymouth's boot-up mode and narrates onto the normal boot
# animation (ADR 0012). These checks are the inverse of the ones they replace:
# the earlier design entered [updates] mode for its progress bar, which in
# two-step costs the loader AND silently discards every message.
check "first boot says what it is doing" \
    bash -c 'grep -q "plymouth display-message" /usr/libexec/ik-os/ik-os-firstboot'
# Replacing a message means hiding the old text first -- there is no update verb,
# so without this the lines pile up on screen instead of replacing each other.
# Specifically the DETAIL line, not just any hide-message: the banner has its own
# hide in splash_end, so a loose grep still passes with the detail hide deleted --
# and then every step's line stays on screen and they pile up on top of each
# other. Checked with that exact mutation.
detail_line_is_replaced() {
    grep -qF 'plymouth hide-message --text="$SPLASH_DETAIL"' /usr/libexec/ik-os/ik-os-firstboot
}
check "first boot replaces its status line" detail_line_is_replaced
check "first boot uses no progress bar" \
    bash -c '! grep -q "system-update --progress" /usr/libexec/ik-os/ik-os-firstboot'
# Never switching modes is what keeps the normal loader turning, and means there
# is no mode to hand back if the script dies partway.
check "first boot never changes plymouth mode" \
    bash -c '! grep -q "plymouth change-mode" /usr/libexec/ik-os/ik-os-firstboot'
check "the ik-os plymouth theme is default" \
    bash -c '[ "$(plymouth-set-default-theme)" = "ik-os" ]'
# The bug this whole design exists to undo: SuppressMessages=true in the mode we
# render in makes every display-message a no-op, on screen, with no error
# anywhere. Upstream sets it only in the progress-bar modes.
bootup_renders_messages() {
    local f=/usr/share/plymouth/themes/ik-os/ik-os.plymouth
    ! sed -n '/^\[boot-up\]/,/^\[/p' "$f" | grep -qi '^SuppressMessages=true'
}
check "boot-up mode still renders messages"  bootup_renders_messages
# Every step's label is what the splash says; an empty one shows "(4 of 6)" with
# nothing in front of it.
step_labels_present() {
    local f=/usr/libexec/ik-os/ik-os-firstboot line n=0
    while IFS= read -r line; do
        case "$line" in
            once:*:*:?*|image:*:*:?*) n=$((n+1)) ;;
            *) return 1 ;;
        esac
    done < <(sed -n '/^STEPS=(/,/^)/p' "$f" | sed -n 's/^[[:space:]]*"\(.*\)"$/\1/p')
    (( n > 0 ))
}
check "every step has a splash label"        step_labels_present
# Rebooting mid-transaction is recoverable but wastes minutes and looks broken.
for u in ik-os-firstboot ik-os-homebrew; do
    check "${u} inhibits shutdown" \
        bash -c "grep -q 'systemd-inhibit' /usr/lib/systemd/system/${u}.service"
done
check "ik-os ssh is wired up"                bash -c "ik-os --help | grep -q 'ik-os ssh'"

echo "-- applications (SDD §15, §16) --"
check "Flatpak present"                      test -x /usr/bin/flatpak
check "Flathub repo definition shipped"      test -f /usr/lib/ik-os/flatpak/flathub.flatpakrepo
# A bogus key does not fail the build — it fails every install at first boot.
# Written as a function: this needs awk and gpg, and cramming that into a
# nested `bash -c '...'` mangles the quoting (it did, twice).
flathub_key_ok() {
    # gpg needs a writable home, and in the finished image /root is a symlink
    # into an empty /var — so give it an explicit temporary homedir or it dies
    # with "can't create directory '/root/.gnupg'" and the key looks invalid.
    local home rc
    home=$(mktemp -d)
    awk -F= '/^GPGKey=/{print substr($0, index($0,"=")+1)}' \
        /usr/lib/ik-os/flatpak/flathub.flatpakrepo \
        | base64 -d 2>/dev/null \
        | gpg --homedir "$home" --show-keys >/dev/null 2>&1
    rc=$?
    rm -rf "$home"
    return $rc
}
check "Flathub key is a real OpenPGP key"    flathub_key_ok
check "Bazaar is the app store"              grep -q 'io.github.kolunmi.Bazaar' /usr/share/ik-os/system-flatpaks.list
# Browsers go through Flatpak (SDD §54): sandboxed, and updated independently of
# the image. Asserted here so a browser cannot quietly reappear in the immutable
# host — nothing in the OS image may provide one.
browsers_are_flatpaks() {
    local l=/usr/share/ik-os/system-flatpaks.list
    grep -q '^org.mozilla.firefox$' "$l" && grep -q '^com.google.Chrome$' "$l"
}
check "browsers are Flatpaks"                browsers_are_flatpaks
check "no browser in the OS image"           bash -c '! test -e /usr/bin/firefox && ! test -e /usr/bin/firefox-esr && ! test -e /usr/bin/google-chrome' 
# Firefox is the company default browser, and the dash carries it plus Bazaar.
# The compiled dconf database is binary GVariant, so grep it with -a — the same
# reason the greeter check above does.
check "Firefox is the default browser"       grep -q '^x-scheme-handler/https=org.mozilla.firefox.desktop$' /etc/xdg/mimeapps.list
check "https has a default handler"          grep -q '^x-scheme-handler/http=' /etc/xdg/mimeapps.list
favorites_carry_browser_and_store() {
    grep -qaF 'org.mozilla.firefox.desktop' /etc/dconf/db/ik-os \
        && grep -qaF 'io.github.kolunmi.Bazaar.desktop' /etc/dconf/db/ik-os
}
check "dash carries Firefox and Bazaar"      favorites_carry_browser_and_store
check "gnome-software is not installed"      bash -c '! test -x /usr/bin/gnome-software'
# The image deliberately ships no image viewer, PDF viewer, archive manager or
# calculator: SDD §54 puts GUI applications in Flatpak. That only works if they
# are actually on the list — otherwise a JPEG, a PDF or a .zip has nothing to
# open it with, which is the kind of gap nobody notices until a user hits it.
desktop_essentials_are_listed() {
    local l=/usr/share/ik-os/system-flatpaks.list app
    for app in org.gnome.Loupe org.gnome.Papers org.gnome.FileRoller org.gnome.Calculator; do
        grep -q "^${app}\$" "$l" || return 1
    done
}
check "viewer/PDF/archiver/calculator listed" desktop_essentials_are_listed
# The task manager moved out of the image to Mission Center for the same reason.
check "gnome-system-monitor is not installed" bash -c '! test -x /usr/bin/gnome-system-monitor'
check "Mission Center replaces it"           grep -q '^io.missioncenter.MissionCenter$' /usr/share/ik-os/system-flatpaks.list
# Mission Center's own setup script cannot run here — it starts with setcap on a
# read-only /usr — so the image ships what it would have configured (ADR 0013).
# The capability set is the load-bearing part: without it the app shows no
# per-process network usage, and says nothing about why.
check "nethogs is in the image"              test -x /usr/sbin/nethogs
nethogs_has_capabilities() {
    local caps cap
    caps=$(getcap /usr/sbin/nethogs 2>/dev/null) || return 1
    for cap in cap_net_admin cap_net_raw cap_dac_read_search cap_sys_ptrace; do
        [[ "$caps" == *"$cap"* ]] || return 1
    done
}
check "nethogs kept its capabilities"        nethogs_has_capabilities
check "sensors-detect is in the image"       test -x /usr/sbin/sensors-detect
check "the powercap udev rule ships"         test -f /usr/lib/udev/rules.d/99-powercap.rules
# Byte-identical to the app's own rule on purpose, so running the setup script
# anyway produces the same rule in /etc instead of a conflicting one.
powercap_rule_matches_upstream() {
    grep -qxF 'SUBSYSTEM=="powercap", KERNEL=="intel-rapl*", RUN+="/usr/bin/chmod a+r /sys/%p/energy_uj"' \
        /usr/lib/udev/rules.d/99-powercap.rules
}
check "the powercap rule is the app's own"   powercap_rule_matches_upstream
check "the first-run prompt is answered"     bash -c 'grep -q "^first-time-running=false$" /etc/skel/.var/app/io.missioncenter.MissionCenter/config/glib-2.0/settings/keyfile'
# Preinstalled Flatpaks (ADR 0014). A machine that cannot reach Flathub on first
# boot still gets an app store and a task manager. Each has to be BOTH deployed
# and exported: without the .desktop symlink the app is installed and invisible,
# which is the failure the build stage's bwrap warnings could plausibly cause.
preinstalled_flatpaks_are_deployed() {
    local app
    while read -r app; do
        [[ -n "$app" ]] || continue
        test -d "/var/lib/flatpak/app/${app}" || { echo "not deployed: ${app}"; return 1; }
        test -e "/var/lib/flatpak/exports/share/applications/${app}.desktop" \
            || { echo "not exported: ${app}"; return 1; }
    done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' \
             /usr/share/ik-os/preinstalled-flatpaks.list | grep -v '^$')
}
check "preinstalled Flatpaks are deployed"   preinstalled_flatpaks_are_deployed
check "the preinstall list ships"            test -f /usr/share/ik-os/preinstalled-flatpaks.list
check "their shared runtime is preinstalled" test -d /var/lib/flatpak/runtime/org.gnome.Platform/x86_64/50
# The remote has to be the image's pinned Flathub definition, not whatever the
# build stage happened to have: first boot adds it with --if-not-exists, so a
# wrong remote baked in here would never be corrected.
check "the baked remote is Flathub"          grep -q 'url=https://dl.flathub.org/repo/' /var/lib/flatpak/repo/config
claude_desktop_ok() {
    compgen -G '/usr/share/applications/*[Cc]laude*.desktop' >/dev/null
}
claude_desktop_from_anthropic() {
    # It must come from Anthropic's own repository, not a downloaded .deb.
    grep -q 'downloads.claude.ai' /etc/apt/sources.list.d/claude-desktop.sources
}
check "Claude Desktop present"               claude_desktop_ok
check "Claude Desktop is the vendor package" claude_desktop_from_anthropic
check "Anthropic signing key installed"      test -f /usr/share/keyrings/claude-desktop-archive-keyring.asc
check "company Brewfile shipped"             test -f /usr/share/ik-os/Brewfile
# Debian leaves the /etc/profile.d loop commented out in /etc/bash.bashrc, and
# GNOME Terminal starts an interactive non-login shell. A profile.d snippet
# alone puts brew on PATH under `sudo -i` and nowhere else.
check "brew reaches non-login shells"        bash -c 'grep -q ik-os-homebrew /etc/bash.bashrc'
check "Homebrew is not in /usr"              bash -c '! test -e /usr/bin/brew'
# Casks are not served by homebrew/core. Font casks do install on Linux from
# homebrew/cask, but a cask from a third-party tap resolves to nothing on first
# boot unless that tap is declared alongside it. This is the cheap in-image
# smoke test; `just check-brewfile` resolves each entry properly against the
# taps and is what catches a genuinely wrong token.
brewfile_casks_have_a_tap() {
    local bf=/usr/share/ik-os/Brewfile
    grep -q '^cask ' "$bf" || return 0
    grep -q '^tap ' "$bf"
}
check "every Brewfile cask has a tap"        brewfile_casks_have_a_tap
# ADR 0009 — the tap Framework and JetBrains tooling come from.
check "the ublue-os cask tap is declared"    grep -q '^tap "ublue-os/tap"' /usr/share/ik-os/Brewfile
# Homebrew installs as the first user, who does not exist until
# gnome-initial-setup runs — long after multi-user.target. Installing it from
# ik-os-firstboot meant `brew` was simply absent after a first boot, so it is
# triggered by the account appearing instead.
check "homebrew helper installed"            test -x /usr/libexec/ik-os/ik-os-homebrew
# A third-party tap's casks are refused until the tap is trusted, and
# `brew bundle` reports success anyway — so the absence of this is invisible
# until someone looks for the app.
check "homebrew trusts its declared taps" \
    bash -c 'grep -q "brew.*trust\|\"\$BREW\" trust" /usr/libexec/ik-os/ik-os-homebrew'
# Within one `brew bundle` run the cask is evaluated before the tap is cloned,
# so a tap-only cask is skipped as "requires macOS" and bundle still exits 0.
check "homebrew taps before bundling" \
    bash -c 'grep -q "\"\$BREW\" tap" /usr/libexec/ik-os/ik-os-homebrew'
# ...and bundle install's exit code does not mean the Brewfile is satisfied.
check "homebrew verifies the bundle"         bash -c 'grep -q "bundle check" /usr/libexec/ik-os/ik-os-homebrew'
# The boot splash covers provisioning that runs before login. Anything needing a
# user account runs after it, while the desktop is up and apparently idle — so
# it has to say so, or a multi-minute download reads as a broken machine.
check "notify helper installed"              test -x /usr/libexec/ik-os/ik-os-notify
check "notify-send is available"             command -v notify-send
# These units are triggered by /etc/passwd changing, i.e. while
# gnome-initial-setup is still creating the account -- so at the moment they run
# the user has no session bus and an unwaited notify-send goes nowhere. That is
# why nothing appeared during first-boot provisioning.
check "user-groups waits for the session"    bash -c 'grep -q -- "--wait" /usr/libexec/ik-os/ik-os-user-groups'
check "the notify helper supports waiting"   bash -c 'grep -q -- "--wait" /usr/libexec/ik-os/ik-os-notify'

# Homebrew does not notify at all any more: a toast cannot show progress for a
# multi-minute download, and it could not be delivered at the time it starts
# anyway. It publishes state and a user unit renders it.
check "homebrew publishes provisioning state" \
    bash -c 'grep -q "provisioning.status" /usr/libexec/ik-os/ik-os-homebrew'
check "the progress renderer is installed"   test -x /usr/libexec/ik-os/ik-os-provisioning-monitor
# The renderer draws with zenity. A renderer whose UI binary is absent fails
# exactly the way the missing cups-pk-helper did: silently, at runtime, on the
# user's machine.
check "zenity is installed"                  command -v zenity
check "the progress user unit is installed"  test -f /usr/lib/systemd/user/ik-os-provisioning.service
# A user unit with no .wants symlink never starts: presets only apply if
# `systemctl --user preset-all` happens to run for that account, and nothing
# guarantees it does.
check "the progress unit starts with the session" \
    test -L /usr/lib/systemd/user/graphical-session.target.wants/ik-os-provisioning.service
# The whole point of gating on `bundle check`: a settled machine must do no work
# and show no window, while a release that adds a package is noticed and shown.
homebrew_gates_the_bundle() {
    local f=/usr/libexec/ik-os/ik-os-homebrew
    grep -qF 'bundle check --file="$BREWFILE" >/dev/null 2>&1; then' "$f" \
        && grep -qF 'Brewfile already satisfied' "$f"
}
check "homebrew gates the bundle on a check" homebrew_gates_the_bundle
# `set -euo pipefail` plus a pipeline whose command is EXPECTED to fail killed
# the script before it could record the failure or publish state=failed, leaving
# the progress window up forever.
failing_check_cannot_abort() {
    grep -qF "| sed 's/^/  /' || true" /usr/libexec/ik-os/ik-os-homebrew
}
check "the failing bundle check cannot abort" failing_check_cannot_abort
check "homebrew service enabled"             test -L /etc/systemd/system/multi-user.target.wants/ik-os-homebrew.service
check "homebrew path watcher enabled"        test -L /etc/systemd/system/multi-user.target.wants/ik-os-homebrew.path
check "homebrew watcher watches /etc/passwd" bash -c 'grep -q "^PathChanged=/etc/passwd" /usr/lib/systemd/system/ik-os-homebrew.path'
check "firstboot no longer installs brew"    bash -c '! grep -q "setup_homebrew" /usr/libexec/ik-os/ik-os-firstboot' 

# A oneshot that a .path unit triggers must not set RemainAfterExit=yes: the
# boot-time run leaves it "active (exited)", and systemd then silently ignores
# every later path activation. That is exactly how Homebrew came to never
# install. Check every path-triggered unit in the image, not just that one.
path_triggered_units_rerunnable() {
    local pathunit target
    for pathunit in /usr/lib/systemd/system/*.path; do
        [[ -f "$pathunit" ]] || continue
        target=$(awk -F= '/^Unit=/{print $2; exit}' "$pathunit")
        [[ -n "$target" ]] || target="$(basename "$pathunit" .path).service"
        [[ -f "/usr/lib/systemd/system/${target}" ]] || continue
        grep -qE '^RemainAfterExit=(yes|true|1|on)' "/usr/lib/systemd/system/${target}" && return 1
    done
    return 0
}
check "path-triggered units can re-run"      path_triggered_units_rerunnable

echo "-- printing (SDD §20-§22) --"
for p in cups cups-browsed ipp-usb avahi-daemon; do
    check "${p} installed" bash -c "dpkg-query --admindir=/usr/lib/dpkg -W ${p}"
done
check "CUPS listens on localhost only"       bash -c '! grep -E "^Listen +[0-9]" /usr/lib/ik-os/cups/cupsd.conf | grep -qv localhost'
check "queues are not shared to the LAN"     grep -q '^Browsing Off' /usr/lib/ik-os/cups/cupsd.conf

# SDD §23 — adding a printer must not require root. GNOME Settings does it
# through cups-pk-helper's polkit mechanism.
check "cups-pk-helper installed"             test -x /usr/libexec/cups-pk-helper-mechanism
check "the ik-os printer polkit rule ships"  test -f /usr/share/polkit-1/rules.d/49-ik-os-printers.rules
# The rule that broke this: cups-pk-helper is only a Recommends of
# gnome-control-center and the build uses --no-install-recommends, so the rule
# shipped while the actions it grants did not exist. GNOME then reported "some
# settings cannot be unlocked" and greyed out Add Printer. A polkit rule naming
# an action nobody registers is silently dead, so check every id resolves.
polkit_rule_actions_exist() {
    local rule=/usr/share/polkit-1/rules.d/49-ik-os-printers.rules id
    [[ -f "$rule" ]] || return 1
    while IFS= read -r id; do
        grep -qF "id=\"${id}\"" /usr/share/polkit-1/actions/*.policy || return 1
    done < <(grep -oE '"org\.opensuse\.cupspkhelper\.mechanism\.[A-Za-z0-9-]+"' "$rule" \
             | tr -d '"' | sort -u)
    return 0
}
check "every polkit action it names exists"  polkit_rule_actions_exist
# "Require user @SYSTEM" is meaningless unless SystemGroup names a real group.
check "cupsd.conf sets SystemGroup"          grep -q '^SystemGroup ' /usr/lib/ik-os/cups/cupsd.conf
system_group_exists() {
    local g; g=$(awk '/^SystemGroup /{print $2; exit}' /usr/lib/ik-os/cups/cupsd.conf)
    [[ -n "$g" ]] && getent group "$g" >/dev/null
}
check "the SystemGroup it names exists"      system_group_exists
# Vendor drivers are optional; when present they must actually be usable.
# Note /opt is empty in a container: it is a symlink to var/opt and the tmpfiles
# symlink that populates it only runs on a booted system. Every check below
# therefore inspects the real location in /usr, never /opt.
vendored() { [[ -s /usr/share/ik-os/printer-drivers.list ]]; }

vendor_tree_in_usr() {
    vendored || return 0
    [[ -d /usr/lib/opt/brother/Printers ]]
}
check "vendor driver tree survives /var wipe" vendor_tree_in_usr

vendor_tmpfiles_ok() {
    vendored || return 0
    out_has 'L /var/opt/brother' cat /usr/lib/tmpfiles.d/ik-os-printer-vendor.conf
}
check "/opt/brother is restored on boot"     vendor_tmpfiles_ok

# The wrapper recovers its own model name with s|^/opt/.*/Printers/||, applied to
# readlink($0). A filter symlink pointing into /usr computes a garbage model and
# fails at print time, so the /opt-shaped target is a requirement, not a style.
vendor_filter_links_ok() {
    vendored || return 0
    local link target found=0
    for link in /usr/lib/cups/filter/brother_lpdwrapper_*; do
        [[ -L "$link" ]] || continue
        found=1
        target="$(readlink "$link")"
        [[ "$target" == /opt/*/Printers/* ]] || return 1
        # ...and that /opt path must resolve to a real file once tmpfiles has
        # run, i.e. /opt/brother/... is served from /usr/lib/opt/brother/...
        [[ -f "/usr/lib${target}" ]] || return 1
    done
    (( found ))
}
check "CUPS filter links are /opt-shaped"    vendor_filter_links_ok

vendor_ppds_ok() {
    vendored || return 0
    compgen -G '/usr/share/ppd/Brother/*.ppd' >/dev/null \
        && compgen -G '/usr/share/cups/model/Brother/*.ppd' >/dev/null
}
check "vendor PPDs are where CUPS looks"     vendor_ppds_ok

# Brother tags packages Architecture: i386 but ships x86_64 and i686 binaries and
# declares almost no dependencies, so a driver installs cleanly and then dies at
# print time on a missing library. Only the architecture we linked matters.
vendor_drivers_ok() {
    vendored || return 0
    local bin other
    case "$(dpkg --print-architecture)" in
        amd64) other=i686 ;;
        *)     other=x86_64 ;;
    esac
    while IFS= read -r bin; do
        [[ "$bin" == */${other}/* ]] && continue
        out_has 'ELF' file "$bin" || continue
        out_has 'not found' ldd "$bin" && return 1
    done < <(find /usr/lib/opt -type f -perm -u+x 2>/dev/null)
    return 0
}
check "vendor driver filters resolve libs"   vendor_drivers_ok
no_queue_baked() {
    # A queue names one printer at one address — machine state, never image
    # content (SDD §23). The vendor installer would create one; we must not.
    [[ ! -s /etc/cups/printers.conf ]]
}
check "no print queue baked into the image"  no_queue_baked

echo "-- image signature policy (SDD §45) --"
# A global "reject" default silently breaks `bootc install` (containers-storage)
# and the installer ISO (oci-archive). Both failures only surface at install
# time, so assert the shape of the policy here.
check "policy.json is valid JSON"            jq -e . /etc/containers/policy.json
# containers/image rejects the whole policy on ANY unrecognised top-level key
# (a "_comment" did exactly this), and only reports it mid-install.
check "policy.json has no unknown keys" \
    bash -c '[ -z "$(jq -r "keys[] | select(. != \"default\" and . != \"transports\")" /etc/containers/policy.json)" ]'
check "default is not a blanket reject"      bash -c '[ "$(jq -r ".default[0].type" /etc/containers/policy.json)" != "reject" ]'
check "containers-storage is permitted"      jq -e '.transports["containers-storage"]' /etc/containers/policy.json
check "oci-archive is permitted (ISO path)"  jq -e '.transports["oci-archive"]' /etc/containers/policy.json
check "the ik-os repo requires a signature" \
    bash -c 'jq -e ".transports.docker[\"ghcr.io/interligent-kommunzieren-gmbh/ik-os-next\"][0].type == \"sigstoreSigned\"" /etc/containers/policy.json'
check "the signing key it names is present" \
    bash -c 'test -f "$(jq -r ".transports.docker[\"ghcr.io/interligent-kommunzieren-gmbh/ik-os-next\"][0].keyPath" /etc/containers/policy.json)"'
# `test -f` passes on an empty or truncated file, which then fails every
# signature check on every machine with a message about the signature rather
# than about the key. Parse it as a real public key instead.
signing_key_is_usable() {
    local path
    path=$(jq -r '.transports.docker["ghcr.io/interligent-kommunzieren-gmbh/ik-os-next"][0].keyPath' \
        /etc/containers/policy.json)
    [[ -s "$path" ]] || return 1
    openssl pkey -pubin -in "$path" -noout 2>/dev/null
}
check "the signing key is a usable public key" signing_key_is_usable

echo "-- networking (SDD §12) --"
check "NetworkManager is enabled" \
    test -L /etc/systemd/system/multi-user.target.wants/NetworkManager.service
# Two network managers is a configuration error, not redundancy: whichever loses
# the race still owns a wait-online unit that can never succeed.
check "systemd-networkd is not enabled" \
    bash -c '! compgen -G "/etc/systemd/system/*.wants/systemd-networkd.service"'
check "networkd socket is not enabled" \
    bash -c '! compgen -G "/etc/systemd/system/*.wants/systemd-networkd.socket"'
# The costly one: it waits its full timeout, fails, and delays
# network-online.target — and therefore first boot and the login screen.
check "only NetworkManager provides wait-online" \
    bash -c '! compgen -G "/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service"'
check "NetworkManager-wait-online is enabled" \
    test -L /etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service

echo "-- security (SDD §27, §50) --"
check "no private keys in the image"         bash -c '! grep -rlq "BEGIN.*PRIVATE KEY" /etc /usr/lib/ik-os /usr/share/ik-os 2>/dev/null'
check "no shared snakeoil key"               bash -c '! test -e /etc/ssl/private/ssl-cert-snakeoil.key'
check "no VPN client key baked in"           bash -c '! test -e /etc/openvpn/certs/ik-office-key.pem'
check "no SSH host keys in the image"        bash -c '! compgen -G "/etc/ssh/ssh_host_*"'
check "CA-IK is trusted"                     bash -c 'grep -rq "CA-IK" /etc/ca-certificates.conf'
check "sysctl hardening shipped"             test -f /usr/lib/sysctl.d/90-ik-os.conf
check "sshd is masked"                       bash -c 'test -L /etc/systemd/system/ssh.service || ! test -x /usr/sbin/sshd'

echo "-- tooling and identity (SDD §43, §57) --"
check "ik-os CLI"                            test -x /usr/bin/ik-os
check "ik-os-migrate"                        test -x /usr/bin/ik-os-migrate
check "first-boot service"                   test -f /usr/lib/systemd/system/ik-os-firstboot.service
check "release manifest"                     test -s /usr/share/ik-os/release.env
check "package manifest (SDD §46)"           test -s /usr/share/ik-os/packages.manifest
check "os-release identifies ik-os"          grep -q '^ID=ik-os' /usr/lib/os-release

# <channel>.<YYYYMMDD>.<build> -- "testing.20260825.42" from CI,
# "testing.20260825.local" from `just build`. The bare "dev" fallback baked into
# the Containerfile is what a build that forgot to pass IK_OS_VERSION produces,
# and nothing else would fail: the image would just ship to the fleet claiming to
# be "dev", and `bootc status` would say so on every machine.
os_release_field() {
    awk -F'"' -v k="$1" '$0 ~ "^" k "=" { print $2 }' /usr/lib/os-release
}
version_scheme_ok() {
    local v; v=$(os_release_field VERSION_ID)
    [[ "$v" =~ ^[a-z]+\.[0-9]{8}\.[a-z0-9]+$ ]]
}
check "the version follows the scheme"       version_scheme_ok
# 55-branding.sh writes both from IK_OS_VERSION. OSTREE_VERSION is the one bootc
# and ostree display, so a drift between them means the machine reports one
# version to the user and another to the tooling.
ostree_version_matches() {
    local a b
    a=$(os_release_field VERSION_ID)
    b=$(os_release_field OSTREE_VERSION)
    [[ -n "$a" && "$a" == "$b" ]]
}
check "ostree and os-release agree"          ostree_version_matches

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || { echo "image verification FAILED"; exit 1; }
