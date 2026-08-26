#!/bin/bash
# Provisioning that cannot be ordered by boot targets (SDD §16, §17, §23, §37).
#
# gnome-initial-setup creates the first account from inside the GDM session,
# long after multi-user.target. Anything needing a user must therefore be
# triggered by the account appearing, not by boot ordering. Every check here
# exists because that went wrong once — see docs/development.md.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
echo "== provisioning =="

USER_NAME=${SUDO_USER:-${USER:-$(id -un)}}

echo "-- hostname --"
# The image ships the placeholder "ik-os"; ik-os-hostname.service replaces it
# before the login prompt, so seeing the placeholder means it never ran.
check "hostname is not the image placeholder" \
    bash -c '[ "$(hostnamectl --static)" != "ik-os" ]'
check "hostname was derived by ik-os"        bash -c 'hostnamectl --static | grep -q "^ik-"'
# libnss-myhostname is what stops sudo printing "unable to resolve host <name>"
# and pausing on every invocation.
check "the machine can resolve its own name" \
    bash -c 'getent hosts "$(hostnamectl --static)"'
check "sudo does not warn about the host" \
    bash -c '! sudo -n true 2>&1 | grep -q "unable to resolve host"'

echo "-- group membership (SDD §17, §23) --"
check "user is in the docker group"          bash -c "id -nG '$USER_NAME' | tr ' ' '\n' | grep -qx docker"
check "user is in the lpadmin group"         bash -c "id -nG '$USER_NAME' | tr ' ' '\n' | grep -qx lpadmin"
check "docker works without sudo"            bash -c 'docker version >/dev/null'

echo "-- Homebrew (SDD §16) --"
check "brew is installed"                    test -x /home/linuxbrew/.linuxbrew/bin/brew
# Debian comments out the profile.d loop in /etc/bash.bashrc, so a login-shell
# snippet alone leaves brew missing in every GNOME Terminal.
check "brew is on PATH in a non-login shell" \
    bash -ic 'command -v brew >/dev/null'
if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    check "the company Brewfile is satisfied" \
        bash -c '/home/linuxbrew/.linuxbrew/bin/brew bundle check --file=/usr/share/ik-os/Brewfile'
else
    skip "Brewfile applied" "brew is not installed"
fi

echo "-- Flatpak (SDD §15) --"
check "flathub remote configured"            bash -c 'flatpak remotes --system | grep -q flathub'
check "flathub is reachable"                 bash -c 'timeout 60 flatpak remote-ls --system flathub >/dev/null'
# The approved list must actually be installed, not merely attempted. First boot
# used to swallow install failures and stamp itself done, leaving an empty app
# store that never retried.
flatpaks_installed() {
    local list=/usr/share/ik-os/system-flatpaks.list ref
    [[ -r "$list" ]] || return 0
    while IFS= read -r ref; do
        flatpak info --system "$ref" >/dev/null 2>&1 || return 1
    done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$list" | grep -v '^$')
    return 0
}
check "every approved Flatpak is installed"  flatpaks_installed
# Apps can all be installed and the app store still show nothing: searching
# needs appstream metadata, which installing apps does not fetch.
check "appstream metadata is present" \
    bash -c "compgen -G '/var/lib/flatpak/appstream/flathub/*/*' >/dev/null"
check "flatpak search returns results"       bash -c 'timeout 60 flatpak search drawio | grep -q drawio'

echo "-- units must stay re-runnable --"
# RemainAfterExit on a .path-triggered oneshot leaves it active after the
# boot-time no-op run, and systemd then ignores every later trigger. That is
# how Homebrew came to never install.
for u in ik-os-user-groups ik-os-homebrew; do
    check "${u} is not stuck active" \
        bash -c "[ \"\$(systemctl show -p RemainAfterExit --value ${u}.service)\" != yes ]"
    check "${u} did not fail"        bash -c "! systemctl is-failed --quiet ${u}.service"
done
check "ik-os-hostname did not fail"          bash -c '! systemctl is-failed --quiet ik-os-hostname.service'

echo "-- user-visible progress --"
# Post-login provisioning is invisible without this: the desktop looks idle
# while hundreds of megabytes download.
check "notify helper present"                test -x /usr/libexec/ik-os/ik-os-notify
check "notify-send installed"                command -v notify-send
check "progress renderer present"            test -x /usr/libexec/ik-os/ik-os-provisioning-monitor
check "zenity present"                       command -v zenity
# A user unit, because the system services doing this work are triggered by the
# account being created -- before that account has a session to draw in.
check "progress unit enabled for the session" \
    test -L /usr/lib/systemd/user/graphical-session.target.wants/ik-os-provisioning.service
# The status file the renderer reads. state=done is the resting state of a
# machine whose Brewfile is satisfied; anything else means work or a failure.
STATUS=/run/ik-os/provisioning.status
check "provisioning state was published"     test -s "$STATUS"
provisioning_settled() {
    [[ -r "$STATUS" ]] || return 1
    grep -qx 'state=done' "$STATUS"
}
check "provisioning reached a done state"    provisioning_settled
# The gate that answers "does a release that adds a package install it?": the
# bundle is only run when this check says it is unsatisfied, so on a settled
# machine it must pass.
brewfile_gate_is_satisfied() {
    local brew=/home/linuxbrew/.linuxbrew/bin/brew
    [[ -x "$brew" ]] || return 1
    sudo -H -u "$USER_NAME" HOMEBREW_NO_AUTO_UPDATE=1 \
        "$brew" bundle check --file=/usr/share/ik-os/Brewfile >/dev/null 2>&1
}
check "the Brewfile gate reports satisfied"  brewfile_gate_is_satisfied
# An unchanged Brewfile that failed before retries silently. Its presence on a
# healthy machine means the toolset is incomplete and nobody is being told.
check "no Brewfile is stuck failing"         test ! -e /var/lib/ik-os/homebrew/failed-for

echo "-- no failed units --"
# systemd-networkd-wait-online failing after a 2-minute timeout was invisible
# except as "degraded" — and it was silently adding those 2 minutes to boot.
check "system is not degraded"               bash -c '[ "$(systemctl is-system-running)" != degraded ]'
no_failed_units() { [[ -z "$(systemctl --failed --no-legend --no-pager)" ]]; }
check "no failed system units"               no_failed_units

echo "-- first boot --"
firstboot_clean() { ! compgen -G '/var/lib/ik-os/firstboot/*.failed' >/dev/null; }
check "no first-boot step failed"            firstboot_clean

echo "-- provisioning re-runs per image, not per boot --"
STATE=/var/lib/ik-os/firstboot
# The stamp that decides whether the setup splash is shown. Absent means the
# first-boot run never reached its end.
check "the run recorded its image"           test -s "${STATE}/.last-run-image"

booted_image() {
    bootc status --json 2>/dev/null \
        | jq -r '.status.booted.image.imageDigest // empty' 2>/dev/null
}
last_run_is_current() {
    local booted; booted=$(booted_image)
    [[ -n "$booted" ]] || return 0   # not a bootc deployment; nothing to compare
    [[ "$(cat "${STATE}/.last-run-image")" == "$booted" ]]
}
check "the recorded image is the booted one"  last_run_is_current

# An empty stamp is the bug this replaced: /var survives a bootc update, so a
# stamp that names no image can never expire and the machine keeps the Flatpak
# list it first booted with forever.
image_stamps_are_stamped() {
    local f n
    for n in enrollment vpn flatpak verify-docker verify-cups; do
        f="${STATE}/${n}.done"
        [[ -e "$f" ]] || continue
        [[ -s "$f" ]] || return 1
    done
}
check "image-scoped stamps name an image"    image_stamps_are_stamped

# The symptom being fixed: "Setting up this machine" on every single boot. A
# settled machine must do nothing and touch plymouth not at all. Run it with a
# plymouth shim ahead on PATH so a call would be recorded rather than drawn.
rerun_is_a_noop() {
    local d out run_rc verdict
    d=$(mktemp -d) || return 1
    printf '#!/bin/sh\necho called >> %s/hit\nexit 0\n' "$d" > "$d/plymouth"
    chmod +x "$d/plymouth"
    out=$(PATH="$d:$PATH" timeout 60 /usr/libexec/ik-os/ik-os-firstboot 2>&1)
    run_rc=$?
    verdict=1
    if (( run_rc == 0 )) && [[ ! -e "$d/hit" ]] \
       && grep -q "nothing to do for image" <<<"$out"; then
        verdict=0
    fi
    rm -rf "$d"
    return "$verdict"
}
check "a re-run does nothing and shows nothing" rerun_is_a_noop

summary
