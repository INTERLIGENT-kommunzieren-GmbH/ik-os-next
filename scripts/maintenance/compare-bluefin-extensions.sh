#!/bin/bash
# SDD §12 — the Bluefin extension set MUST be verified against a real Bluefin
# system, not inferred. Run this ON A BLUEFIN MACHINE and reconcile the output
# with desktop/gnome/extensions/versions.lock.
set -euo pipefail

LOCK="${1:-desktop/gnome/extensions/versions.lock}"

echo "== extensions enabled on this system =="
gsettings get org.gnome.shell enabled-extensions \
    | tr -d "[]' " | tr ',' '\n' | grep -v '^$' | sort > /tmp/bluefin-enabled.txt
cat /tmp/bluefin-enabled.txt

echo
echo "== installed extension versions =="
for d in /usr/share/gnome-shell/extensions/*/ ~/.local/share/gnome-shell/extensions/*/; do
    [[ -f "${d}metadata.json" ]] || continue
    jq -r '"\(.uuid)\t\(.version // "-")\t\(.name)"' "${d}metadata.json"
done | sort

if [[ -r "$LOCK" ]]; then
    echo
    echo "== not yet classified in ${LOCK} (SDD §12) =="
    comm -23 /tmp/bluefin-enabled.txt \
        <(sed -e 's/#.*//' "$LOCK" | awk 'NF{print $1}' | sort) \
        || true
    echo
    echo "Classify each as: required | optional | unsupported | replaced-by-ik-os"
    echo "and record where the Debian equivalent comes from, or vendor it with a"
    echo "pinned revision."
fi
