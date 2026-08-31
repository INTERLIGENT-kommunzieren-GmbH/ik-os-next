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
# A warning is printed and counted, but does not fail the run. Reserved for the
# end-of-life allowlist, so an accepted risk stays visible in every log rather
# than disappearing the moment it is accepted.
warns=0
warn() { echo "  ⚠ $*"; warns=$(( warns + 1 )); }

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

# End-of-life applications kept on purpose (SDD Rule 15). The key is the app id,
# the value is the reason it stays — an entry here turns the end-of-life failure
# below into a warning and nothing else: a 404, a missing x86_64 build or an
# unreachable Flathub still fail for an allowlisted app.
#
# Two properties matter more than the exemption itself. The reason is required,
# so an exception cannot be added without saying why in the file that grants it.
# And a stale exception fails: if the app stops being end-of-life, or leaves the
# list, the entry has to go. An allowlist that silently outlives its subject is
# how a check stops meaning anything.
# Intentionally empty. draw.io was the one candidate and it left the list
# entirely (ADR 0016), so nothing is exempt today; the machinery stays because
# the next end-of-life app is a matter of time, and the stale-entry check below
# means an exemption cannot be forgotten once granted.
declare -A EOL_ACCEPTED=()

declare -A RUNTIME_COUNT
declare -A EOL_SEEN
declare -A RESOLVED
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

    RESOLVED["$app"]=1

    # An end-of-life app still installs, and still launches. It just never gets
    # another update, including for security — so shipping one by default is a
    # decision, not a detail, and it must not happen by accident.
    eol=no
    if grep -q '"is_eol": *true' "$body"; then
        eol=yes
        EOL_SEEN["$app"]=1
        if [[ -v EOL_ACCEPTED["$app"] ]]; then
            warn "\"${app}\" is end-of-life on Flathub, kept deliberately:
       ${EOL_ACCEPTED[$app]}"
        else
            note "\"${app}\" is marked end-of-life on Flathub — it will install but
       never receive another update. Remove it or replace it deliberately."
        fi
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

# The allowlist is checked against reality, in both directions. Without this an
# exception granted once stays granted: the app gets un-deprecated, or dropped
# from the list entirely, and the entry survives to quietly exempt whatever later
# takes that id.
for app in "${!EOL_ACCEPTED[@]}"; do
    if ! printf '%s\n' "${APPS[@]}" | grep -qxF "$app"; then
        note "the end-of-life exception for \"${app}\" is stale — it is not in
       system-flatpaks.list any more. Remove the EOL_ACCEPTED entry."
    elif [[ ! -v RESOLVED["$app"] ]]; then
        : # already failed above with a more specific message
    elif [[ ! -v EOL_SEEN["$app"] ]]; then
        note "\"${app}\" is no longer end-of-life on Flathub. Remove the
       EOL_ACCEPTED entry so the next one is noticed."
    fi
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
if (( warns > 0 )); then
    echo "Flatpak list validation passed with ${warns} accepted end-of-life app(s)"
else
    echo "Flatpak list validation passed"
fi
