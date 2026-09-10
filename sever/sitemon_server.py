#!/usr/bin/env python3
"""sitemon server: prinimaet otchety ot routerov i pokazyvaet status."""
import html
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

PORT = int(os.environ.get("PORT", "8080"))
TOKEN = os.environ.get("TOKEN", "changeme")
STATE_FILE = os.environ.get("STATE_FILE", "/var/lib/sitemon/state.json")
STALE_SEC = int(os.environ.get("STALE_SEC", "9000"))
HISTORY = 100

lock = threading.Lock()


def load():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def save(state):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, ensure_ascii=False)
    os.replace(tmp, STATE_FILE)


state = load()


def parse_data(data):
    out = []
    for item in data.split(";"):
        parts = item.split("|")
        if len(parts) != 4:
            continue
        url, status, t_open, t_full = parts
        out.append({"url": url, "status": status,
                    "open": int(t_open or 0), "full": int(t_full or 0)})
    return out


def fmt_time(ts):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))


def render_page():
    now = time.time()
    rows = []
    with lock:
        routers = sorted(state.items())
    for name, info in routers:
        last = info.get("last", {})
        ts = last.get("ts", 0)
        stale = now - ts > STALE_SEC
        sites = last.get("sites", [])
        for i, s in enumerate(sites or [{"url": "-", "status": "-", "open": 0, "full": 0}]):
            if stale:
                cls, status = "stale", "NET DANNYH"
            elif s["status"] == "OK":
                cls, status = "ok", "OK"
            else:
                cls, status = "fail", "FAIL"
            rows.append(
                "<tr class='{cls}'><td>{name}</td><td>{url}</td><td class='st'>{status}</td>"
                "<td>{o}</td><td>{f}</td><td>{a}</td><td>{t}</td></tr>".format(
                    cls=cls,
                    name=html.escape(name) if i == 0 else "",
                    url=html.escape(s["url"]),
                    status=status,
                    o=s["open"] if s["status"] == "OK" else "-",
                    f=s["full"] if s["status"] == "OK" else "-",
                    a=last.get("attempt", "-") if i == 0 else "",
                    t=fmt_time(ts) if ts else "-",
                ))
    return """<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta http-equiv="refresh" content="60"><title>sitemon</title>
<style>
body{font-family:sans-serif;margin:2em;background:#fafafa}
table{border-collapse:collapse;min-width:800px}
th,td{border:1px solid #ccc;padding:6px 12px;text-align:left}
th{background:#eee}
tr.ok .st{color:#080;font-weight:bold}
tr.fail .st{color:#c00;font-weight:bold}
tr.stale{color:#999;background:#f0f0f0}
</style></head><body>
<h2>Monitoring saitov s routerov</h2>
<table><tr><th>Router</th><th>Sait</th><th>Status</th><th>Otkrytie, ms</th>
<th>Polnaya zagruzka, ms</th><th>Popytka</th><th>Obnovleno</th></tr>
%s</table>
<p style="color:#666">Obnovleno: %s. Stranica obnovlyaetsya avtomaticheski raz v minutu.</p>
</body></html>""" % ("\n".join(rows) or "<tr><td colspan=7>Otchetov poka net</td></tr>",
                      fmt_time(now))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, render_page())
        elif self.path == "/api":
            with lock:
                body = json.dumps(state, ensure_ascii=False, indent=1)
            self._send(200, body, "application/json; charset=utf-8")
        else:
            self._send(404, "not found", "text/plain")

    def do_POST(self):
        if self.path != "/report":
            return self._send(404, "not found", "text/plain")
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length).decode("utf-8", "replace")
        q = parse_qs(raw, keep_blank_values=True)
        get = lambda k: q.get(k, [""])[0]

        if get("token") != TOKEN:
            return self._send(403, "bad token", "text/plain")
        name = get("name").strip()[:64]
        if not name:
            return self._send(400, "no name", "text/plain")
        sites = parse_data(get("data"))
        try:
            attempt = int(get("attempt") or 1)
        except ValueError:
            attempt = 1

        report = {"ts": time.time(), "attempt": attempt, "sites": sites}
        with lock:
            r = state.setdefault(name, {"last": {}, "history": []})
            r["last"] = report
            r["history"] = (r.get("history", []) + [report])[-HISTORY:]
            save(state)
        print(f"{fmt_time(report['ts'])} {name}: {get('data')} (attempt {attempt})", flush=True)
        self._send(200, "ok", "text/plain")


if __name__ == "__main__":
    print(f"sitemon server on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
