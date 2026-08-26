#!/bin/bash
# Validate config/desktop/system-flatpaks.list against Flathub (SDD §15, §54).
#
# Flatpaks are installed at first boot, not during the image build, so a wrong
# id here cannot fail the build: ik-os-firstboot logs one failed app and carries
# on, and the machine simply ships without that application. Since §54 routes
# every GUI application to this file, that is most of the desktop — so the list
# is checked here instead, against the same remote the image defines.
#
# Flathub's API needs no token and has no per-IP request budget to spend, unlike
# the GitHub API used by check-brewfile.sh.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LIST="${REPO}/config/desktop/system-flatpaks.list"
[[ -r "$LIST" ]] || { echo "no Flatpak list at ${LIST}"; exit 1; }

API=https://flathub.org/api/v2

# Same comment/blank-line handling as read_pkglist() in build/scripts/lib.sh, so
# this reads the file exactly the way the image build does.
mapfile -t APPS < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$LIST" | grep -v '^$')

echo "system-flatpaks.list: ${#APPS[@]} application(s)"

fail=0
note() { echo "  ✗ $*"; fail=1; }

# A duplicate is harmless at install time but means two sections disagree about
# where an app belongs, which is how one of them later gets edited alone.
dupes=$(printf '%s\n' "${APPS[@]}" | sort | uniq -d)
[[ -z "$dupes" ]] || note "listed more than once:
$(printf '       %s\n' $dupes)"

# The preinstall list is a delivery decision layered on top of the approved list:
# same ids, baked into the image instead of downloaded at first boot. Checked
# here so a stale entry fails in CI in seconds rather than in a 2.4 GB build
# stage (ADR 0014).
PRE="${REPO}/config/desktop/preinstalled-flatpaks.list"
if [[ -r "$PRE" ]]; then
    mapfile -t PREINSTALLED < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$PRE" | grep -v '^$')
    echo "preinstalled in the image: ${#PREINSTALLED[@]}"
    for app in "${PREINSTALLED[@]}"; do
        if printf '%s\n' "${APPS[@]}" | grep -qxF "$app"; then
            echo "  ✓ ${app} (also in system-flatpaks.list)"
        else
            note "\"${app}\" is preinstalled but missing from system-flatpaks.list.
       That list is the definition of the approved desktop; preinstalling only
       changes when an app arrives, not whether it is approved."
        fi
    done
else
    note "config/desktop/preinstalled-flatpaks.list is missing"
fi

declare -A RUNTIME_COUNT
total_installed=0

for app in "${APPS[@]}"; do
    # Flathub ids are reverse-DNS. Catching the shape first turns "pasted a full
    # ref" (app/org.gnome.Loupe/x86_64/stable) into a clear message rather than
    # a 404 that reads like the app was removed from Flathub.
    if [[ ! "$app" =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$ ]]; then
        note "\"${app}\" is not a Flatpak application id — expected reverse-DNS
       like org.gnome.Loupe, not a ref or a package name"
        continue
    fi

    body=$(mktemp)
    code=$(curl -sSL -o "$body" -w '%{http_code}' "${API}/appstream/${app}" 2>/dev/null || echo 000)
    case "$code" in
        200) ;;
        404) rm -f "$body"
             note "\"${app}\" is not on Flathub.
       Flathub is the only remote the image defines (build/scripts/75-flatpak.sh),
       so first boot would log a failed install and ship without this app.
       Check the id at https://flathub.org/apps/${app}"
             continue ;;
        *)   rm -f "$body"
             note "cannot verify ${app} (HTTP ${code}) — Flathub unreachable"
             continue ;;
    esac

    # An end-of-life app still installs, and still launches. It just never gets
    # another update, including for security — so shipping one by default is a
    # decision, not a detail, and it must not happen by accident.
    eol=no
    if grep -q '"is_eol": *true' "$body"; then
        eol=yes
        note "\"${app}\" is marked end-of-life on Flathub — it will install but
       never receive another update. Remove it or replace it deliberately."
    fi

    # Flathub's JSON escapes forward slashes ("org.gnome.Platform\/x86_64\/50"),
    # inconsistently between responses — left in, the same runtime counts twice.
    runtime=$(sed -nE 's/.*"runtime": *"([^"]+)".*/\1/p' "$body" | head -1 | tr -d '\\')
    rm -f "$body"

    sum=$(mktemp)
    if [[ "$(curl -sSL -o "$sum" -w '%{http_code}' "${API}/summary/${app}" 2>/dev/null || echo 000)" == 200 ]]; then
        # These laptops are x86_64. An aarch64-only app resolves on Flathub and
        # then installs nothing at all on the target hardware.
        if ! grep -q '"x86_64"' "$sum"; then
            note "\"${app}\" has no x86_64 build on Flathub"
        fi
        # "installed_size" appears both at the top level and inside the per-branch
        # object; they agree for the stable branch, so the largest is the right one.
        size=$(sed -nE 's/.*"installed_size": *([0-9]+).*/\1/p' "$sum" \
               | tr ',' '\n' | sort -n | tail -1)
        total_installed=$(( total_installed + ${size:-0} ))
    fi
    rm -f "$sum"

    # Still counted towards the footprint — it does get installed — but not
    # reported with a tick it has not earned.
    [[ -n "$runtime" ]] && RUNTIME_COUNT["$runtime"]=$(( ${RUNTIME_COUNT["$runtime"]:-0} + 1 ))
    [[ "$eol" == yes ]] || echo "  ✓ ${app}${runtime:+  ($runtime)}"
done

# Not a pass/fail condition — a footprint report. Every distinct runtime is a
# separate ~1 GB download at first boot, so one straggler app pinned to an old
# branch costs as much as a dozen apps sharing the current one. Printed so that
# cost is visible in the validation log instead of only in a support ticket.
echo "-- runtimes --"
for rt in "${!RUNTIME_COUNT[@]}"; do
    printf '  %3d app(s)  %s\n' "${RUNTIME_COUNT[$rt]}" "$rt"
done | sort -rn
printf '  applications: %d MiB installed, %d distinct runtime(s)\n' \
    "$(( total_installed / 1024 / 1024 ))" "${#RUNTIME_COUNT[@]}"

(( fail == 0 )) || { echo "Flatpak list validation failed"; exit 1; }
echo "Flatpak list validation passed"
