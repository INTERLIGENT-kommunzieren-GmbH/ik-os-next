#!/usr/bin/python3
"""Serve the company video backgrounds to teams-for-linux (ADR 0020).

Teams owns the background picker and offers no way to add to it. What
teams-for-linux can do is redirect the image requests the picker makes: every
URL under statics.teams.cdn.office.net/evergreen-assets/backgroundimages/ is
rewritten to customBGServiceBaseUrl, which is this service. A company
background therefore reaches the picker by being served *in place of* one of
Microsoft's own assets -- the names listed in slots.txt, paired with the images
in sorted order.

Everything this service does not claim is proxied straight back to Microsoft.
Without that, the redirect turns every unclaimed tile into an empty box, and
the picker looks broken rather than extended.

Three behaviours of the client are load-bearing here, each established against
a running Teams and each the reason for a specific line below:

  * Every response must carry Access-Control-Allow-Origin. The picker draws the
    chosen image into a canvas, so without the header Teams fetches the image
    and then silently refuses to apply it -- the background never changes and
    nothing is logged.
  * config.json must be a bare JSON array. The documented
    {"videoBackgroundImages": [...]} object makes the app throw "configJSON is
    not iterable". Nothing has consumed that list since 2.x, so the manifest
    exists only to keep a warning out of the app log.
  * The custom-background list no longer reaches the picker at all, which is
    why replacing Microsoft's assets is the only mechanism left.

Run by ik-os-teams-backgrounds.service on 127.0.0.1:8421.
"""

import os
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = "/usr/share/ik-os/teams-backgrounds"
UPSTREAM = "https://statics.teams.cdn.office.net/evergreen-assets/backgroundimages/"
ADDRESS = ("127.0.0.1", 8421)
TIMEOUT = 10


def build_map():
    """Microsoft asset name -> our image basename, paired in sorted order."""
    images = sorted(
        f[: -len(".jpg")]
        for f in os.listdir(ROOT)
        if f.endswith(".jpg") and not f.endswith("-thumb.jpg")
    )
    with open(os.path.join(ROOT, "slots.txt"), encoding="utf-8") as fh:
        slots = [l.strip() for l in fh if l.strip() and not l.startswith("#")]
    # The build asserts this too; repeated here because a mismatch means an
    # image nobody can see, which is worth failing loudly rather than serving
    # a partial set.
    if len(slots) < len(images):
        sys.exit(f"only {len(slots)} slots for {len(images)} images")
    return dict(zip(slots, images))


MAP = build_map()


class Handler(BaseHTTPRequestHandler):
    server_version = "ik-os-teams-backgrounds"

    def do_GET(self):
        self.respond(body=True)

    def do_HEAD(self):
        self.respond(body=False)

    def respond(self, body):
        # Only the basename is ever used, so no request can escape ROOT.
        name = os.path.basename(self.path.split("?")[0])
        try:
            payload, ctype, origin = self.resolve(name)
        except Exception as err:
            self.log_message("miss %s (%s)", name, err)
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        # Required: the picker draws the image into a canvas.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        if body:
            self.wfile.write(payload)
        self.log_message("%s %s", origin, name)

    def resolve(self, name):
        if name == "config.json":
            with open(f"{ROOT}/config.json", "rb") as fh:
                return fh.read(), "application/json", "ik"
        stem, _, ext = name.rpartition(".")
        thumb = stem.endswith("_thumb")
        if thumb:
            stem = stem[: -len("_thumb")]
        image = MAP.get(stem)
        if image:
            suffix = "-thumb" if thumb else ""
            with open(f"{ROOT}/{image}{suffix}.jpg", "rb") as fh:
                return fh.read(), "image/jpeg", "ik"
        # Not ours: hand Microsoft's own asset back. Offline this fails and the
        # tile stays empty -- the company images keep working either way.
        with urllib.request.urlopen(UPSTREAM + name, timeout=TIMEOUT) as resp:
            return resp.read(), resp.headers.get("Content-Type", "image/jpeg"), "ms"

    def log_message(self, fmt, *args):
        # stderr, so journalctl -u ik-os-teams-backgrounds shows every asset the
        # client asks for, marked "ik" (served from the image) or "ms"
        # (proxied). That log is how a retired Microsoft asset name is found
        # when a background stops appearing.
        sys.stderr.write((fmt % args) + "\n")


if __name__ == "__main__":
    print(f"serving {len(MAP)} company backgrounds on {ADDRESS[0]}:{ADDRESS[1]}")
    ThreadingHTTPServer(ADDRESS, Handler).serve_forever()
