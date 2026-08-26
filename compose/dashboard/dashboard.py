#!/usr/bin/env python3
"""
dashboard.py — one page showing the whole system. (M17)

WHY IT COLLECTS ON REQUEST INSTEAD OF ON A TIMER
    The operator said they will not open this often. A cron job scraping every
    minute would burn CPU around the clock to produce numbers that are stale
    anyway by the time anyone looks. Collecting when the page is requested
    costs nothing while nobody is watching and is never out of date.

    The trade: a page load takes a second or two, and a hanging data source
    delays it. Each section is therefore rendered independently — one broken
    source shows an error in its own box instead of an empty page.

WHY NO DOCKER SOCKET
    Per-container CPU and memory would need it, and that means host root
    (ADR-0023). Three containers already have it; a fourth for a convenience
    readout is not a trade worth making. Host-level figures come from /proc
    read-only, and per-service up/down comes from Uptime Kuma, which is
    already watching every service anyway.

DATA SOURCES, all read-only
    /proc, /sys        host CPU, memory, load, uptime
    kuma.db  (SQLite)  service up/down, outages, response times
    paperclip (PG)     agents, issues, runs
"""

import html
import os
import shutil
import sqlite3
import subprocess
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

KUMA_DB = os.environ.get("KUMA_DB", "/data/kuma/kuma.db")
PG_DSN = os.environ.get("PAPERCLIP_DSN", "")
PORT = int(os.environ.get("PORT", "8080"))


# ── helpers ─────────────────────────────────────────────────────────────────

def esc(v):
    return html.escape(str(v))


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default


def human_bytes(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def human_secs(s):
    s = int(s)
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        return f"{s // 3600}h {(s % 3600) // 60}m"
    return f"{s // 86400}d {(s % 86400) // 3600}h"


# ── i) host resources ───────────────────────────────────────────────────────

def host_metrics():
    m = {}

    load = read("/proc/loadavg").split()
    if load:
        m["load"] = f"{load[0]} · {load[1]} · {load[2]}"

    mem = {}
    for line in read("/proc/meminfo").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            mem[parts[0].rstrip(":")] = int(parts[1]) * 1024
    if mem:
        total = mem.get("MemTotal", 0)
        avail = mem.get("MemAvailable", 0)
        m["mem_total"] = total
        m["mem_used"] = total - avail
        m["mem_pct"] = round((total - avail) / total * 100) if total else 0

    up = read("/proc/uptime").split()
    if up:
        m["uptime"] = human_secs(float(up[0]))

    # CPU percentage needs two samples: a single /proc/stat read gives totals
    # since boot, which is not what anyone means by "current load".
    def cpu_sample():
        for line in read("/proc/stat").splitlines():
            if line.startswith("cpu "):
                v = [int(x) for x in line.split()[1:]]
                return sum(v), v[3]  # total, idle
        return None

    a = cpu_sample()
    if a:
        time.sleep(0.25)
        b = cpu_sample()
        if b and b[0] != a[0]:
            busy = (b[0] - a[0]) - (b[1] - a[1])
            m["cpu_pct"] = round(busy / (b[0] - a[0]) * 100)

    try:
        du = shutil.disk_usage("/host-root")
        m["disk_total"] = du.total
        m["disk_used"] = du.used
        m["disk_pct"] = round(du.used / du.total * 100)
    except OSError:
        pass

    return m


# ── ii/iii) services, outages, anomalies ────────────────────────────────────

def kuma_data():
    if not os.path.exists(KUMA_DB):
        raise FileNotFoundError(f"{KUMA_DB} nicht gefunden")

    # Read-only URI: this file belongs to a running Uptime Kuma. Opening it
    # writable risks a lock fight with the process that owns it.
    con = sqlite3.connect(f"file:{KUMA_DB}?mode=ro", uri=True, timeout=5)
    con.row_factory = sqlite3.Row
    try:
        monitors = []
        for r in con.execute("select id, name, active from monitor order by name"):
            last = con.execute(
                "select status, time, ping, msg from heartbeat "
                "where monitor_id = ? order by time desc limit 1", (r["id"],)
            ).fetchone()

            day = con.execute(
                "select count(*) total, sum(case when status = 1 then 1 else 0 end) up, "
                "avg(ping) avg_ping from heartbeat "
                "where monitor_id = ? and time > datetime('now', '-24 hours')",
                (r["id"],)
            ).fetchone()

            total = day["total"] or 0
            up = day["up"] or 0
            monitors.append({
                "name": r["name"],
                "active": bool(r["active"]),
                "status": last["status"] if last else None,
                "msg": (last["msg"] or "") if last else "",
                "uptime_24h": round(up / total * 100, 1) if total else None,
                "outages_24h": total - up,
                "avg_ping": round(day["avg_ping"]) if day["avg_ping"] else None,
            })

        # An anomaly here is a state CHANGE, not a state. A service that has
        # been down for a week is a known problem, not news; one that flipped
        # an hour ago is what someone opening this page needs to see.
        events = con.execute(
            "select h.time, h.status, h.msg, m.name from heartbeat h "
            "join monitor m on m.id = h.monitor_id "
            "where h.important = 1 and h.time > datetime('now', '-7 days') "
            "order by h.time desc limit 15"
        ).fetchall()

        return monitors, [dict(e) for e in events]
    finally:
        con.close()


# ── iv/v) agents, tasks, KPIs ───────────────────────────────────────────────

def paperclip_data():
    if not PG_DSN:
        raise RuntimeError("PAPERCLIP_DSN ist nicht gesetzt")

    def q(sql):
        # psql over the wire rather than a driver: this image would otherwise
        # need psycopg, and the service is meant to stay dependency-free.
        # \x1f as the separator because it cannot occur in the data.
        out = subprocess.run(
            ["psql", PG_DSN, "-tAF", "\x1f", "-c", sql],
            capture_output=True, text=True, timeout=15,
        )
        if out.returncode != 0:
            raise RuntimeError(out.stderr.strip()[:200])
        return [ln.split("\x1f") for ln in out.stdout.strip().splitlines() if ln]

    return {
        "agents": q("""
            select a.name, a.role, a.status, a.adapter_type,
                   (select count(*) from agents c where c.reports_to = a.id)
              from agents a
             where a.status <> 'terminated'
             order by (select count(*) from agents c where c.reports_to = a.id) desc, a.name
        """),
        "issues": q("select status, count(*) from issues group by status order by count(*) desc"),
        "runs": q("""
            select status, count(*) from heartbeat_runs
             where created_at > now() - interval '7 days'
             group by status order by count(*) desc
        """),
        "recent": q("""
            select left(coalesce(a.name, '?'), 20), r.status,
                   to_char(r.created_at, 'DD.MM HH24:MI'),
                   left(coalesce(r.error, ''), 70)
              from heartbeat_runs r
              left join agents a on a.id = r.agent_id
             order by r.created_at desc limit 8
        """),
    }


# ── rendering ───────────────────────────────────────────────────────────────

def bar(pct, warn=75, crit=90):
    cls = "ok" if pct < warn else ("warn" if pct < crit else "crit")
    return (f'<div class="bar"><span class="{cls}" style="width:{min(pct, 100)}%"></span></div>'
            f'<span class="pct {cls}">{pct}%</span>')


def section(title, body):
    return f"<section><h2>{esc(title)}</h2>{body}</section>"


def failed(title, err):
    return section(title, f'<p class="err">Nicht verfügbar: {esc(err)}</p>')


def render_host():
    m = host_metrics()
    if not m:
        return failed("System", "/proc nicht lesbar")
    rows = []
    if "cpu_pct" in m:
        rows.append(("CPU", bar(m["cpu_pct"])))
    if "mem_pct" in m:
        rows.append(("Speicher", bar(m["mem_pct"])
                     + f'<span class="sub">{human_bytes(m["mem_used"])} / {human_bytes(m["mem_total"])}</span>'))
    if "disk_pct" in m:
        rows.append(("Festplatte", bar(m["disk_pct"])
                     + f'<span class="sub">{human_bytes(m["disk_used"])} / {human_bytes(m["disk_total"])}</span>'))
    if "load" in m:
        rows.append(("Last (1·5·15m)", f'<span class="mono">{esc(m["load"])}</span>'))
    if "uptime" in m:
        rows.append(("Uptime", f'<span class="mono">{esc(m["uptime"])}</span>'))

    body = '<table class="kv">' + "".join(
        f"<tr><th>{esc(k)}</th><td>{v}</td></tr>" for k, v in rows) + "</table>"
    return section("System", body)


def render_services():
    try:
        monitors, events = kuma_data()
    except Exception as e:
        return failed("Dienste", str(e)), failed("Auffälligkeiten", str(e))

    if not monitors:
        svc = '<p class="err">Uptime Kuma überwacht noch keine Dienste.</p>'
    else:
        rows = []
        for m in monitors:
            dot = "up" if m["status"] == 1 else ("down" if m["status"] == 0 else "unknown")
            label = {"up": "läuft", "down": "aus", "unknown": "?"}[dot]
            up24 = f'{m["uptime_24h"]}%' if m["uptime_24h"] is not None else "—"
            ping = f'{m["avg_ping"]} ms' if m["avg_ping"] else "—"
            note = (f'<span class="sub">{esc(m["msg"][:60])}</span>'
                    if m["status"] == 0 and m["msg"] else "")
            rows.append(
                f'<tr><td><span class="dot {dot}"></span>{esc(m["name"])}{note}</td>'
                f'<td class="mono">{label}</td><td class="mono">{up24}</td>'
                f'<td class="mono">{ping}</td>'
                f'<td class="mono">{m["outages_24h"] or "—"}</td></tr>')
        svc = ('<table><thead><tr><th>Dienst</th><th>Status</th><th>24h</th>'
               '<th>Ø Antwort</th><th>Ausfälle</th></tr></thead><tbody>'
               + "".join(rows) + "</tbody></table>")

    # The stack runs more services than Kuma watches. Saying so is the
    # difference between "everything is fine" and "everything I look at is
    # fine", and only one of those is true.
    svc += ('<p class="note">Nur überwachte Dienste. Was hier fehlt, wird von '
            'Uptime Kuma nicht geprüft — das ist kein Urteil über seinen Zustand.</p>')

    if not events:
        anom = '<p class="quiet">Keine Zustandswechsel in den letzten 7 Tagen.</p>'
    else:
        items = []
        for e in events:
            kind = "up" if e["status"] == 1 else "down"
            verb = "wieder da" if e["status"] == 1 else "ausgefallen"
            items.append(
                f'<li><span class="dot {kind}"></span>'
                f'<span class="mono when">{esc(str(e["time"])[:16])}</span> '
                f'<strong>{esc(e["name"])}</strong> {verb}'
                + (f'<span class="sub">{esc((e["msg"] or "")[:70])}</span>' if e["msg"] else "")
                + "</li>")
        anom = f'<ul class="events">{"".join(items)}</ul>'

    return section("Dienste", svc), section("Auffälligkeiten (7 Tage)", anom)


def render_paperclip():
    try:
        d = paperclip_data()
    except Exception as e:
        return failed("Agenten", str(e)), failed("Kennzahlen", str(e))

    rows = []
    for name, role, status, adapter, subs in d["agents"]:
        cls = {"idle": "up", "running": "up", "error": "down",
               "paused": "unknown"}.get(status, "unknown")
        kind = "Manager" if int(subs or 0) > 0 else "Arbeiter"
        rows.append(f'<tr><td><span class="dot {cls}"></span>{esc(name)}</td>'
                    f'<td class="mono">{esc(status)}</td><td class="mono">{kind}</td>'
                    f'<td class="mono sub">{esc(adapter)}</td></tr>')
    agents = ('<table><thead><tr><th>Agent</th><th>Status</th><th>Rolle</th>'
              '<th>Adapter</th></tr></thead><tbody>' + "".join(rows) + "</tbody></table>")

    def chips(pairs, empty):
        if not pairs:
            return f'<p class="quiet">{empty}</p>'
        return '<div class="chips">' + "".join(
            f'<span class="chip"><b>{esc(c)}</b> {esc(s)}</span>' for s, c in pairs) + "</div>"

    total_runs = sum(int(c) for _, c in d["runs"]) if d["runs"] else 0
    ok_runs = sum(int(c) for s, c in d["runs"] if s in ("succeeded", "success", "completed"))
    rate = f"{round(ok_runs / total_runs * 100)}%" if total_runs else "—"

    recent = ""
    if d["recent"]:
        items = []
        for agent, status, when, err in d["recent"]:
            cls = "up" if status in ("succeeded", "success", "completed") else "down"
            items.append(f'<li><span class="dot {cls}"></span>'
                         f'<span class="mono when">{esc(when)}</span> '
                         f'<strong>{esc(agent)}</strong> <span class="mono">{esc(status)}</span>'
                         + (f'<span class="sub">{esc(err)}</span>' if err else "") + "</li>")
        recent = f'<h3>Letzte Läufe</h3><ul class="events">{"".join(items)}</ul>'

    kpi = (f'<div class="kpis">'
           f'<div class="kpi"><b>{rate}</b><span>Erfolgsquote (7 T)</span></div>'
           f'<div class="kpi"><b>{total_runs}</b><span>Läufe (7 T)</span></div>'
           f'<div class="kpi"><b>{len(d["agents"])}</b><span>Agenten aktiv</span></div>'
           f'</div><h3>Tickets</h3>{chips(d["issues"], "Keine Tickets.")}'
           f'<h3>Läufe nach Status (7 Tage)</h3>'
           f'{chips(d["runs"], "Keine Läufe in den letzten 7 Tagen.")}{recent}')

    return section("Agenten", agents), section("Kennzahlen", kpi)


CSS = """
:root{--ink:#1a1a1a;--soft:#52525b;--quiet:#71717a;--paper:#fdfdfc;--rule:#e4e4e7;
--ok:#16a34a;--warn:#ca8a04;--crit:#dc2626}
@media(prefers-color-scheme:dark){:root{--ink:#e8e8e6;--soft:#a1a1aa;--quiet:#8b8b93;
--paper:#141414;--rule:#2a2a2a;--ok:#4ade80;--warn:#facc15;--crit:#f87171}}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);font-size:15px;line-height:1.5;
font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;-webkit-font-smoothing:antialiased}
main{max-width:60rem;margin:0 auto;padding:2.5rem 1.5rem 4rem}
header{display:flex;justify-content:space-between;align-items:baseline;flex-wrap:wrap;gap:.5rem;margin-bottom:2rem}
h1{font-size:1.5rem;font-weight:600;margin:0}
.stamp{font-size:.8rem;color:var(--quiet)}
section{margin-bottom:2.5rem}
h2{font-size:.75rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;
color:var(--quiet);margin:0 0 .9rem;padding-bottom:.35rem;border-bottom:1px solid var(--rule)}
h3{font-size:.8rem;font-weight:600;color:var(--soft);margin:1.4rem 0 .5rem}
table{width:100%;border-collapse:collapse;font-size:.9rem}
th{text-align:left;font-weight:500;color:var(--quiet);font-size:.78rem;
text-transform:uppercase;letter-spacing:.05em;padding:.3rem .6rem .3rem 0}
td{padding:.45rem .6rem .45rem 0;border-top:1px solid var(--rule);vertical-align:top}
table.kv th{width:11rem;vertical-align:middle;text-transform:none;font-size:.9rem;letter-spacing:0;color:var(--soft)}
table.kv td{border-top:1px solid var(--rule);display:flex;align-items:center;gap:.6rem;flex-wrap:wrap}
.mono{font-variant-numeric:tabular-nums;font-size:.88rem}
.sub{display:block;color:var(--quiet);font-size:.8rem}
.quiet,.note{color:var(--quiet);font-size:.82rem}
.note{margin:.8rem 0 0}
.err{color:var(--crit);font-size:.88rem}
.bar{flex:1;min-width:8rem;height:7px;background:var(--rule);border-radius:4px;overflow:hidden}
.bar span{display:block;height:100%}
.bar .ok{background:var(--ok)}.bar .warn{background:var(--warn)}.bar .crit{background:var(--crit)}
.pct{font-variant-numeric:tabular-nums;font-size:.85rem;min-width:2.6rem}
.pct.ok{color:var(--ok)}.pct.warn{color:var(--warn)}.pct.crit{color:var(--crit)}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:.5rem;
background:var(--quiet);vertical-align:middle}
.dot.up{background:var(--ok)}.dot.down{background:var(--crit)}.dot.unknown{background:var(--quiet)}
.events{list-style:none;margin:0;padding:0;font-size:.88rem}
.events li{padding:.4rem 0;border-top:1px solid var(--rule)}
.when{color:var(--quiet);margin-right:.4rem}
.chips{display:flex;gap:.5rem;flex-wrap:wrap}
.chip{border:1px solid var(--rule);border-radius:4px;padding:.25rem .6rem;font-size:.82rem;color:var(--soft)}
.chip b{color:var(--ink);font-variant-numeric:tabular-nums}
.kpis{display:flex;gap:1rem;flex-wrap:wrap;margin-bottom:.5rem}
.kpi{border:1px solid var(--rule);border-radius:6px;padding:.8rem 1.2rem;min-width:8rem}
.kpi b{display:block;font-size:1.6rem;font-weight:600;font-variant-numeric:tabular-nums}
.kpi span{font-size:.78rem;color:var(--quiet)}
@media(max-width:560px){table.kv th{width:auto;display:block;border:0;padding-bottom:0}
table.kv td{border-top:0}table.kv tr{display:block;border-top:1px solid var(--rule);padding:.5rem 0}}
"""


def render_page():
    started = time.time()
    parts = [render_host()]
    svc, anom = render_services()
    agents, kpi = render_paperclip()
    parts += [svc, anom, agents, kpi]
    took = time.time() - started
    now = datetime.now(timezone.utc).astimezone().strftime("%d.%m.%Y %H:%M:%S")

    return f"""<!doctype html>
<html lang="de"><meta charset="utf-8">
<title>Dashboard</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<style>{CSS}</style>
<main>
<header><h1>Dashboard</h1>
<span class="stamp">{esc(now)} · in {took:.1f}s erhoben</span></header>
{"".join(parts)}
<p class="note">Werte werden beim Aufruf erhoben, nicht zwischengespeichert.
Neu laden = neu messen.</p>
</main></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            body, ctype = b'{"ok":true}', "application/json"
        elif self.path in ("/", "/index.html"):
            try:
                body = render_page().encode()
            except Exception as e:  # never serve a blank page
                body = ("<!doctype html><meta charset=utf-8><title>Dashboard</title>"
                        f"<p style='font-family:sans-serif'>Dashboard-Fehler: "
                        f"{esc(e)}</p>").encode()
            ctype = "text/html; charset=utf-8"
        else:
            self.send_response(404)
            self.end_headers()
            return

        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
