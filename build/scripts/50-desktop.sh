#!/bin/bash
# SDD §11-§14 — GNOME desktop configuration.
# shellcheck source=build/scripts/lib.sh
. "${CTX:-/ctx}/build/scripts/lib.sh"
load_env

log "Configuring GNOME"

install -Dm0644 "${CTX}/desktop/gnome/defaults/ik-os-profile" /etc/dconf/profile/user
mkdir -p /etc/dconf/db/ik-os.d/locks
cp -a "${CTX}/desktop/gnome/dconf/ik-os.d/." /etc/dconf/db/ik-os.d/

# The login screen is NOT configured through /etc/dconf/db/gdm.d — that is the
# upstream/Fedora mechanism and Debian's gdm3 ignores it. Debian's
# /usr/share/gdm/generate-config runs
#     dconf compile /var/lib/gdm3/greeter-dconf-defaults /usr/share/gdm/dconf
# as the Debian-gdm user at service start, so settings belong in that directory
# with a prefix above 00-upstream-settings.
# Prefix 95: gdm3's postinst generates /usr/share/gdm/dconf/90-debian-settings
# from /etc/gdm3/greeter.dconf-defaults, and that file sets `logo`. A lower
# prefix loses to it, and the company logo silently never appears.
install -Dm0644 "${CTX}/desktop/gnome/greeter/95-ik-os" /usr/share/gdm/dconf/95-ik-os

log "Normalising GNOME schema locations"
# Debian's gnome-shell-extension-arc-menu installs its gschema to
# /usr/share/glib-2/schemas — note the missing ".0". Nothing scans that path,
# so `gsettings` cannot see the schema even though the extension itself works
# (it loads the copy in its own directory). Move any stray schema into the
# standard location and recompile, so gsettings, diagnostics and the checks
# below all agree with what the desktop actually reads.
SYSTEM_SCHEMAS=/usr/share/glib-2.0/schemas
mkdir -p "$SYSTEM_SCHEMAS"
shopt -s nullglob
for stray in /usr/share/glib-2/schemas/*.gschema.xml; do
    info "relocating $(basename "$stray") from the non-standard glib-2 path"
    install -Dm0644 "$stray" "${SYSTEM_SCHEMAS}/$(basename "$stray")"
done
for ext in /usr/share/gnome-shell/extensions/*/schemas/*.gschema.xml; do
    [[ -f "${SYSTEM_SCHEMAS}/$(basename "$ext")" ]] && continue
    install -Dm0644 "$ext" "${SYSTEM_SCHEMAS}/$(basename "$ext")"
done
shopt -u nullglob
glib-compile-schemas "$SYSTEM_SCHEMAS"

log "Verifying the desktop configuration against the installed schemas"
# Rule 18 — a typo'd or renamed gsettings key must fail the build, not silently
# produce a desktop that ignores company policy. This is what makes SDD
# acceptance criteria 10 and 12 (hidden ArcMenu, Super+Space) enforceable.
#
# The schema XML is checked directly rather than via `gsettings`, so the check
# does not depend on where a given Debian package chose to install it.
find_schema() {
    local id="$1" d f
    for d in "$SYSTEM_SCHEMAS" /usr/share/glib-2/schemas \
             /usr/share/gnome-shell/extensions/*/schemas; do
        f="${d}/${id}.gschema.xml"
        [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

ARCMENU_SCHEMA=$(find_schema org.gnome.shell.extensions.arcmenu) \
    || die "the ArcMenu gschema is not present in this image. ArcMenu is
       mandatory (SDD §13, Rule 7)."
info "ArcMenu schema: ${ARCMENU_SCHEMA}"

DTD_SCHEMA=$(find_schema org.gnome.shell.extensions.dash-to-dock) \
    || die "the dash-to-dock gschema is not present in this image. It is a
       required extension (SDD §11, desktop/gnome/extensions/enabled.txt)."
info "dash-to-dock schema: ${DTD_SCHEMA}"

check_key() {
    local schema="$1" key="$2" ext
    ext=$(basename "$schema" .gschema.xml)
    # Match on the name= attribute alone, not on `<key name=`: these schemas
    # write the attributes in whichever order they like — `<key
    # name="runner-hotkey" type="as">` but `<key type="b"
    # name="hide-overview-on-startup">` — and anchoring on the element start
    # silently "loses" every key of the second shape.
    grep -q "name=\"${key}\"" "$schema" \
        || die "${ext} no longer has the '${key}' key.
       The extension was renamed or upgraded incompatibly; fix
       desktop/gnome/dconf/ik-os.d/ before shipping."
}
check_key "$ARCMENU_SCHEMA" menu-button-appearance
check_key "$ARCMENU_SCHEMA" runner-hotkey
check_key "$ARCMENU_SCHEMA" arcmenu-hotkey
# These two are a pair, and neither GNOME setting nor either extension does the
# job alone: ArcMenu skips the startup overview by flipping
# Main.sessionMode.hasOverview, and dash-to-dock resets the OverviewAdjustment
# that skipping it leaves stuck at WINDOW_PICKER. dconf accepts a key that no
# longer exists without complaint, so an upgrade that renamed either one would
# silently bring the overview back — or leave the first Super press misbehaving.
check_key "$ARCMENU_SCHEMA" hide-overview-on-startup
check_key "$DTD_SCHEMA" disable-overview-on-startup

# 'None' must remain a valid value of the menu-button-appearance enum (Rule 8).
grep -q 'nick="None"' "$ARCMENU_SCHEMA" \
    || die "ArcMenu no longer offers menu-button-appearance='None'; the launcher
       button cannot be hidden as SDD §13 requires."

# And gsettings must now be able to see it, so runtime tooling works too.
output_matches '^menu-button-appearance$' \
    gsettings list-keys org.gnome.shell.extensions.arcmenu \
    || die "the ArcMenu schema is still not visible to gsettings after
       relocation; dconf defaults would not be introspectable."

log "Setting the default applications and dash favourites"
# SDD §14 — Firefox as the default browser. /etc/xdg is the sysadmin tier of the
# XDG association spec, so a user's ~/.config/mimeapps.list still wins and GNOME
# Settings > Default Applications keeps working.
install -Dm0644 "${CTX}/config/desktop/mimeapps.list" /etc/xdg/mimeapps.list

SHELL_SCHEMA=$(find_schema org.gnome.shell) \
    || die "the org.gnome.shell gschema is not present in this image."
check_key "$SHELL_SCHEMA" favorite-apps

# Every desktop id named by the dash or by a default association must be real.
# Both failure modes are silent: GNOME drops an unknown favourite without a word,
# and an association pointing at a missing .desktop just opens nothing. A typo
# would therefore ship as "the dock lost an icon" and never be traced back here.
#
# Flatpak applications are NOT installed at build time — first boot does that —
# so their ids are checked against the approved Flatpak list instead. A Flatpak
# exports its app id as <app-id>.desktop, which is what makes this comparable.
FAVOURITES=/etc/dconf/db/ik-os.d/40-favorites
[[ -f "$FAVOURITES" ]] || die "desktop/gnome/dconf/ik-os.d/40-favorites is missing."
desktop_id_is_known() {
    local id="$1"
    [[ -f "/usr/share/applications/${id}" ]] && { printf 'image'; return 0; }
    if read_pkglist "${CTX}/config/desktop/system-flatpaks.list" \
        | grep -qxF "${id%.desktop}"; then
        printf 'flatpak'; return 0
    fi
    return 1
}
while read -r id; do
    origin=$(desktop_id_is_known "$id") || die "${id} is named in the dash
       favourites or in config/desktop/mimeapps.list, but it is neither
       installed in this image nor listed in config/desktop/system-flatpaks.list.
       Fix the id, ship the application, or drop the reference."
    info "${id} (${origin})"
done < <( { sed -nE 's/.*favorite-apps=\[(.*)\]/\1/p' "$FAVOURITES"
            sed -nE 's/^[a-zA-Z0-9/.+-]+=(.*)$/\1/p' /etc/xdg/mimeapps.list
          } | tr ",;'" '\n\n\n' | tr -d ' ' | grep '\.desktop$' | sort -u )

log "Setting up the Mission Center host helpers"
# Mission Center replaces gnome-system-monitor, and it offers a first-run
# "setup script" that it runs on the host through pkexec. On ik-os that script
# always fails: its first action is `setcap` on the nethogs binary, and /usr is
# read-only. Everything the script would do therefore ships in the image, and
# the first-run prompt is answered in advance — see
# docs/adr/0013-mission-center-host-helpers.md.
#
# The helper is looked up on a PATH the app hardcodes for its own subprocesses
# (/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin), so
# Debian's /usr/sbin location is found even though a user's PATH omits /usr/sbin
# in this release. That also means the Homebrew nethogs cannot serve: it lives
# under /home/linuxbrew, which is on no root PATH at all.
NETHOGS=/usr/sbin/nethogs
[[ -x "$NETHOGS" ]] || die "nethogs is not installed at ${NETHOGS}.
       Mission Center resolves it on its own hardcoded PATH, so a different
       location will not be found. Check packages/desktop/packages.list."

# The exact capability set the app's setup script asks for. cap_net_admin and
# cap_net_raw are for the packet capture; cap_dac_read_search and
# cap_sys_ptrace are how it maps sockets back to the owning process.
setcap "cap_net_admin,cap_net_raw,cap_dac_read_search,cap_sys_ptrace+pe" "$NETHOGS" \
    || die "could not set file capabilities on ${NETHOGS}."
# Capabilities are an xattr, and an xattr that the build sets but the image does
# not carry is worse than none: the app would silently fall back to no
# per-process network data. Assert it round-trips here, and again in
# verify-image.sh once the layer is committed.
CAPS=$(getcap "$NETHOGS")
for cap in cap_net_admin cap_net_raw cap_dac_read_search cap_sys_ptrace; do
    [[ "$CAPS" == *"$cap"* ]] || die "${cap} is missing from ${NETHOGS} after setcap.
       Got: ${CAPS:-<none>}
       The build filesystem is dropping security.capability xattrs."
done
info "nethogs capabilities: ${CAPS#* }"

command -v sensors-detect >/dev/null \
    || die "sensors-detect is not installed — add lm-sensors to
       packages/desktop/packages.list. The app's setup script probes for it, and
       reports its absence to the user as a failure."

# Vendor directory, not /etc/udev/rules.d: this is an image-owned default, and
# leaving /etc free means a machine-local rule can still override it.
install -Dm0644 "${CTX}/config/desktop/99-powercap.rules" \
    /usr/lib/udev/rules.d/99-powercap.rules

# Answer the first-run prompt before it is ever shown. Without dconf access a
# Flatpak's GSettings go to a per-app keyfile rather than the dconf database, so
# this cannot be a dconf default like every other setting in this image — it has
# to be seeded into the user's home, and /etc/skel is the supported way to do
# that for accounts gnome-initial-setup has not created yet.
#
# The trade-off is that this is the app's private state file: if a future release
# renames the key, the seed quietly stops working and a user sees the dialog once.
# It cannot be validated at build time either, because the schema that defines
# the key ships inside the Flatpak, which is not installed until first boot.
MC_KEYFILE=/etc/skel/.var/app/io.missioncenter.MissionCenter/config/glib-2.0/settings/keyfile
install -d "$(dirname "$MC_KEYFILE")"
cat > "$MC_KEYFILE" <<'KEYFILE'
[io/missioncenter/MissionCenter]
first-time-running=false
KEYFILE
chmod 0600 "$MC_KEYFILE"
info "Mission Center prerequisites installed; first-run prompt pre-answered"

log "Enabling extensions"
EXT_DIR=/usr/share/gnome-shell/extensions
ENABLED=()
while read -r uuid; do
    [[ -d "${EXT_DIR}/${uuid}" ]] \
        || die "extension ${uuid} is listed in desktop/gnome/extensions/enabled.txt
       but is not installed. Add its Debian package to
       packages/desktop/extensions.list or vendor it with a pinned revision."
    ENABLED+=("'${uuid}'")
done < <(read_pkglist "${CTX}/desktop/gnome/extensions/enabled.txt")

# GNOME enables extensions serially in this order, and that is load-bearing for
# exactly one pair: dash-to-dock and ArcMenu both save Main.sessionMode.hasOverview
# during startup and restore it on startup-complete, so whichever is enabled
# second captures what the first already changed and its restore wins. ArcMenu
# first means dash-to-dock captures `false` and the session has no overview at
# all — Super does nothing until a lock/unlock happens to repair it.
index_of() {
    local uuid="$1" i
    for i in "${!ENABLED[@]}"; do
        [[ "${ENABLED[$i]}" == "'${uuid}'" ]] && { printf '%s' "$i"; return 0; }
    done
    return 1
}
DTD_AT=$(index_of dash-to-dock@micxgx.gmail.com) \
    || die "dash-to-dock is not in desktop/gnome/extensions/enabled.txt."
ARCMENU_AT=$(index_of arcmenu@arcmenu.com) \
    || die "ArcMenu is not in desktop/gnome/extensions/enabled.txt (Rule 7)."
(( DTD_AT < ARCMENU_AT )) || die "dash-to-dock must be listed before ArcMenu in
       desktop/gnome/extensions/enabled.txt. Both save and restore
       Main.sessionMode.hasOverview around the startup animation; with ArcMenu
       first, dash-to-dock captures the flipped value and leaves the session
       without an overview. See the comment at the top of that file."

printf "[org/gnome/shell]\nenabled-extensions=[%s]\n" \
    "$(IFS=,; echo "${ENABLED[*]}")" > /etc/dconf/db/ik-os.d/21-enabled-extensions
info "enabled: ${ENABLED[*]}"

# Rule 7 — Search Light must not be present.
if compgen -G "${EXT_DIR}/search-light*" > /dev/null; then
    die "a Search Light extension is present. Rule 7 forbids it; ArcMenu is the
       search interface."
fi

dconf update
[[ -f /etc/dconf/db/ik-os ]] || die "dconf database was not generated"

# Prove the greeter settings actually compile and carry our logo, rather than
# trusting that dropping a file in the right directory was enough.
GREETER_TEST=$(mktemp -u)
dconf compile "$GREETER_TEST" /usr/share/gdm/dconf \
    || die "the GDM greeter dconf directory does not compile"
# The compiled database is binary GVariant: grep the file directly with -a.
# Do NOT route it through a command substitution — that silently drops the null
# bytes and the match always fails.
if ! grep -qaF 'ik-os-logo.png' "$GREETER_TEST"; then
    info "contents of /usr/share/gdm/dconf:"
    ls -la /usr/share/gdm/dconf/ | sed 's/^/      /'
    info "logo settings found in that directory:"
    grep -rn "logo" /usr/share/gdm/dconf/ | sed 's/^/      /' || true
    info "resolved value in the compiled database:"
    dconf dump / 2>/dev/null | sed 's/^/      /' | head -20 || true
    die "the compiled GDM greeter database does not contain the ik-os logo.
       Something in /usr/share/gdm/dconf with a higher prefix is overriding
       95-ik-os (see the listing above)."
fi
rm -f "$GREETER_TEST"
info "GDM greeter configuration verified"

log "Setting GDM defaults"
# SDD §37 — with no accounts in the image, GDM must run the initial-setup
# wizard on first boot or the machine is unreachable.
GIS=/usr/libexec/gnome-initial-setup
[[ -x "$GIS" ]] || GIS=/usr/lib/gnome-initial-setup/gnome-initial-setup
[[ -x "$GIS" ]] || die "gnome-initial-setup is not installed. The image has no
       user accounts and a locked root, so GDM would start with nothing to log
       in as. Add it to packages/desktop/packages.list."

if ! grep -q '^InitialSetupEnable' /etc/gdm3/daemon.conf; then
    sed -i 's/^\[daemon\]/[daemon]\nInitialSetupEnable=true/' /etc/gdm3/daemon.conf
fi
grep -q '^InitialSetupEnable=true' /etc/gdm3/daemon.conf \
    || die "could not enable GDM initial setup in /etc/gdm3/daemon.conf"
info "GDM initial setup enabled"

systemctl set-default graphical.target
