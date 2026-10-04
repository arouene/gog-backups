"""Local stand-in for the GOG endpoints used by gog-backups tests.

Prints the listening port on stdout, then serves until killed.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

INSTALLER = b"MZ" + bytes(range(256)) * 64
DETAILS = {
    "1": {
        "downloads": [["English", {"windows": [{
            "manualUrl": "/downloads/game_a/en1installer0",
            "name": "Game A", "version": "1.0", "size": "1 MB"}]}]],
        "extras": [],
        "dlcs": [],
    },
    "2": {
        "downloads": [["English", {"linux": [{
            "manualUrl": "/downloads/game_b/en3installer0",
            "name": "Game B", "version": "2.0", "size": "2 MB"}]}]],
        "extras": [],
        "dlcs": [],
    },
}
seen = set()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body=b"", headers=()):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def json(self, data):
        self.reply(200, json.dumps(data), [("Content-Type", "application/json")])

    def redirect(self, location):
        self.reply(302, headers=[("Location", location)])

    def authorized(self):
        if self.headers.get("Authorization", "").startswith("Bearer AT"):
            return True
        self.reply(401)
        return False

    def do_GET(self):
        url = urlsplit(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path == "/token":
            grant = (query.get("grant_type"), query.get("code") or query.get("refresh_token"))
            tokens = {("authorization_code", "CODE1"): "1",
                      ("authorization_code", "CODE2"): "2",
                      ("refresh_token", "RT1"): "3"}
            if query.get("client_secret") and grant in tokens:
                n = tokens[grant]
                self.json({"access_token": "AT" + n, "refresh_token": "RT" + n,
                           "expires_in": 3600})
            else:
                self.reply(400, '{"error":"invalid_grant"}')
        elif url.path == "/account/getFilteredProducts":
            if self.authorized():
                page = int(query.get("page", "1"))
                self.json({"totalPages": 2, "products": [
                    {"id": page, "title": "Game " + "AB"[page - 1],
                     "slug": "game_" + "ab"[page - 1]}]})
        elif url.path.startswith("/account/gameDetails/"):
            game = url.path.split("/")[-1].split(".")[0]
            if not self.authorized():
                pass
            elif game == "2" and game not in seen:
                seen.add(game)
                self.reply(503, headers=[("Retry-After", "0")])
            else:
                self.json(DETAILS[game])
        elif url.path == "/downloads/game_a/en1installer0":
            if self.authorized():
                self.redirect("/cdn/token/setup_game_a_1.0_(123).exe?sig=x")
        elif url.path.startswith("/cdn/"):
            self.reply(200, INSTALLER,
                       [("Content-Type", "application/octet-stream"),
                        ("Content-Disposition",
                         'attachment; filename="setup_game_a_1.0_(123).exe"')])
        else:
            self.reply(404)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    sys.exit(0)
