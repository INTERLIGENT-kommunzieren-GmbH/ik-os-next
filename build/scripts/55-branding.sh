#!/bin/bash
# SDD §57 — the OS identifies itself as ik-os everywhere.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Applying ik-os branding"
# shellcheck disable=SC1091
. /usr/share/ik-os/build-base.env

cat > /usr/lib/os-release <<EOF
NAME="${IK_OS_PRETTY_NAME}"
PRETTY_NAME="${IK_OS_PRETTY_NAME} (Debian ${DEBIAN_CODENAME})"
ID=${IK_OS_ID}
ID_LIKE=${IK_OS_ID_LIKE}
VERSION_ID="${IK_OS_VERSION:-dev}"
VERSION_CODENAME=${DEBIAN_CODENAME}
VARIANT="Developer Workstation"
VARIANT_ID=workstation
HOME_URL="${IK_OS_HOME_URL}"
SUPPORT_URL="${IK_OS_HOME_URL}/issues"
BUG_REPORT_URL="${IK_OS_HOME_URL}/issues"
VENDOR_NAME="${IK_OS_VENDOR}"
DEFAULT_HOSTNAME=ik-os
OSTREE_VERSION="${IK_OS_VERSION:-dev}"
EOF
ln -sf ../usr/lib/os-release /etc/os-release

install -Dm0644 "${CTX}/branding/gdm/ik-os-logo.png" /usr/share/pixmaps/ik-os-logo.png

log "Installing the Plymouth watermark"
install -Dm0644 "${CTX}/branding/plymouth/watermark.png" /usr/share/plymouth/themes/spinner/watermark.png
install -Dm0644 "${CTX}/branding/plymouth/watermark.png" /usr/share/plymouth/themes/bgrt/watermark.png
# Our own theme rather than stock bgrt, purely so the first-boot progress screen
# says what is happening. It is bgrt (ModuleName=two-step) with the [updates]
# mode's Title/SubTitle rewritten; ImageDir still points at spinner/, which is
# where the watermark installed above is read from.
install -Dm0644 "${CTX}/branding/plymouth/ik-os/ik-os.plymouth" \
    /usr/share/plymouth/themes/ik-os/ik-os.plymouth
install -Dm0644 "${CTX}/branding/plymouth/watermark.png" /usr/share/plymouth/themes/ik-os/watermark.png
plymouth-set-default-theme ik-os || info "plymouth theme not switched (ik-os unavailable)"
output_matches_fixed 'ik-os' plymouth-set-default-theme \
    || die "the plymouth default theme is not ik-os. The first-boot progress
       screen depends on our [updates] mode, so a stock theme would show
       'Installing Updates...' or nothing at all."

log "Desktop wallpapers"
# Every image in branding/wallpaper/ is installed and registered with GNOME so
# it appears in Settings -> Appearance -> Background. One of them is the
# company default; the rest are choices (SDD §53 — developers may customise).
WP_SRC="${CTX}/branding/wallpaper"
WP_DIR=/usr/share/backgrounds/ik-os

shopt -s nullglob
WALLPAPERS=( "${WP_SRC}"/*.jpg "${WP_SRC}"/*.jpeg "${WP_SRC}"/*.png )
shopt -u nullglob

if (( ${#WALLPAPERS[@]} == 0 )); then
    info "no wallpapers in branding/wallpaper/; keeping the GNOME default"
else
    install -d -m0755 "$WP_DIR"
    for wp in "${WALLPAPERS[@]}"; do
        install -Dm0644 "$wp" "${WP_DIR}/$(basename "$wp")"
    done
    info "installed ${#WALLPAPERS[@]} wallpapers ($(du -sh "$WP_DIR" | cut -f1))"

    DEFAULT_WP="${IK_OS_DEFAULT_WALLPAPER:-}"
    [[ -n "$DEFAULT_WP" && -f "${WP_DIR}/${DEFAULT_WP}" ]] || die \
        "IK_OS_DEFAULT_WALLPAPER='${DEFAULT_WP}' is not present in
       branding/wallpaper/. Available:
$(cd "$WP_DIR" && printf '         %s\n' *)"

    # Register them with GNOME's background chooser. Without this XML the files
    # sit on disk and never appear in Settings.
    prettify() {
        local n
        n=$(basename "$1"); n="${n%.*}"
        # The company-branded one keeps its name; the rest become title case.
        if [[ "$n" == "ik-os" ]]; then
            printf 'ik-os'
            return
        fi
        printf '%s' "${n#ik-}" | sed -e 's/-/ /g' -e 's/\b\(.\)/\u\1/g'
    }
    XML=/usr/share/gnome-background-properties/ik-os.xml
    mkdir -p "$(dirname "$XML")"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">'
        echo '<wallpapers>'
        for wp in "${WALLPAPERS[@]}"; do
            f="${WP_DIR}/$(basename "$wp")"
            printf '  <wallpaper deleted="false">\n'
            printf '    <name>%s</name>\n' "$(prettify "$wp")"
            printf '    <filename>%s</filename>\n' "$f"
            printf '    <filename-dark>%s</filename-dark>\n' "$f"
            printf '    <options>zoom</options>\n'
            printf '    <shade_type>solid</shade_type>\n'
            printf '    <pcolor>#1a1a1a</pcolor>\n'
            printf '    <scolor>#1a1a1a</scolor>\n'
            printf '  </wallpaper>\n'
        done
        echo '</wallpapers>'
    } > "$XML"
    chmod 0644 "$XML"

    cat > /etc/dconf/db/ik-os.d/05-background <<EOF
# Company default wallpaper (SDD §14). A default, not a locked setting:
# developers may pick any of the others in Settings (SDD §53).
[org/gnome/desktop/background]
picture-uri='file://${WP_DIR}/${DEFAULT_WP}'
picture-uri-dark='file://${WP_DIR}/${DEFAULT_WP}'
picture-options='zoom'
primary-color='#1a1a1a'

[org/gnome/desktop/screensaver]
picture-uri='file://${WP_DIR}/${DEFAULT_WP}'
picture-options='zoom'
EOF
    dconf update
    info "default wallpaper: ${DEFAULT_WP}"
fi

log "Installing kernel arguments"
# Plymouth only runs when `splash` is on the kernel command line.
install -Dm0644 "${CTX}/config/boot/kargs.toml" /usr/lib/bootc/kargs.d/10-ik-os.toml

# NOTE: 57-initramfs.sh runs immediately after this script, and must. The
# Plymouth theme and watermark are baked into the initramfs, so generating it
# before branding produces a boot splash with the stock Debian theme.
