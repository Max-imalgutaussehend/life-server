#!/usr/bin/env bash
# =============================================================================
# seed-monitors.sh — create Uptime Kuma monitors from the service registry
# =============================================================================
#
# WHY THIS EXISTS
#   Uptime Kuma is configured by clicking, and clicking is configuration drift
#   (the same objection ADR-0008 raises against Portainer). A service added to
#   services.yml would silently go unmonitored until somebody remembered to add
#   it in the UI — and "we thought it was monitored" is worse than knowing it
#   is not.
#
# WHAT IT MONITORS, AND WHY INTERNALLY
#   Each service is checked through the apps network by CONTAINER NAME, not by
#   public hostname. A public check would be intercepted by Cloudflare Access,
#   and a 302 to a login page is not a health signal — it measures the gate
#   rather than the service behind it.
#
# IDEMPOTENT
#   Monitors are matched by name; re-running adds what is missing and leaves
#   existing monitors alone. Safe to run after adding a service.
#
# USAGE
#   make seed-monitors
# =============================================================================
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/life-server}"
cd "$REPO_DIR"

set -a
# shellcheck disable=SC1091  # server-side path, not resolvable at lint time
. ./.env
set +a

ENV_PREFIX_NAME="${ENV_PREFIX_NAME:-prod-}"
KUMA="${ENV_PREFIX_NAME}status"

: "${KUMA_ADMIN_USER:?KUMA_ADMIN_USER is not set in .env}"
: "${KUMA_ADMIN_PASSWORD:?KUMA_ADMIN_PASSWORD is not set in .env}"
: "${NTFY_TOPIC:?NTFY_TOPIC is not set in .env}"

# Wait for Kuma to actually answer before opening a socket. Without this, a run
# shortly after `docker restart` fails with a bare "timed out" that looks like a
# script bug rather than a service that was still booting.
printf 'waiting for %s' "$KUMA"
for _ in $(seq 1 40); do
	if docker exec "$KUMA" curl -fsS http://localhost:3001/ >/dev/null 2>&1; then
		printf ' ready\n'
		break
	fi
	printf '.'
	sleep 3
done

# Kuma's API is Socket.IO, not REST, so a client has to speak it. socket.io-client
# ships inside the image, so this runs there rather than needing anything on the
# host.
docker exec \
	-e KU="$KUMA_ADMIN_USER" \
	-e KP="$KUMA_ADMIN_PASSWORD" \
	-e TOPIC="$NTFY_TOPIC" \
	-e PREFIX="$ENV_PREFIX_NAME" \
	-e NTFY_PASS="$KUMA_ADMIN_PASSWORD" \
	"$KUMA" node -e '
const io = require("socket.io-client");
const sock = io("http://localhost:3001", { transports: ["websocket"] });

const monitors = [
  { name: "caddy",  url: "http://" + process.env.PREFIX + "caddy:80/healthz" },
  { name: "n8n",    url: "http://" + process.env.PREFIX + "n8n:5678/healthz" },
  { name: "ntfy",   url: "http://" + process.env.PREFIX + "ntfy:80/v1/health" },

  // The whoami monitor went with the service in M11. A monitor pointing at a
  // container that no longer exists is not a harmless leftover: it alerts
  // forever, and an alert you learn to ignore is worse than no alert.
  //
  // NOTE: no apostrophes anywhere in this block. The whole script body is one
  // single-quoted node -e argument, so a stray apostrophe silently ends the
  // string and the rest gets parsed as shell (shellcheck SC1011).

  // M11. Reachable because Paperclip is on `apps` as well as `agent`.
  { name: "paperclip", url: "http://" + process.env.PREFIX + "paperclip:3100/api/health" },

  // ── THE MOST IMPORTANT MONITOR HERE (M11, ADR-0020) ──────────────────────
  //
  // A PUSH monitor, not an HTTP one, and that is the whole point.
  //
  // cliproxy lives on `agent`; Kuma lives on `apps`. Kuma could poll it only
  // by joining `agent` — which would also let every code-executing agent
  // session reach Kuma, and Kuma holds the ntfy PUBLISH token, i.e. the
  // ability to send a forged all-clear. M8 established that the all-clear is
  // the one message that must stay trustworthy. So the connection direction is
  // inverted instead: the agent side reports OUT, and no network is widened.
  //
  // WHAT IT CATCHES: the Claude OAuth credential expires in ~7 days, and when
  // it does every agent stops SILENTLY — indistinguishable from an empty
  // queue. That is the M10 failure exactly, and it is the failure this system
  // is most likely to actually hit.
  //
  // Unlike an HTTP check, the heartbeat is sent only after a REAL completion
  // succeeds (see compose/cliproxy/heartbeat.sh), so it proves the credential
  // still works — not merely that the process is up.
  //
  // 3900s ≈ 65 min against an hourly heartbeat: one missed report is tolerated
  // (a restart), two is an alert.
  { name: "cliproxy", type: "push", interval: 3900 },

  // ── M17: the services that were running unwatched ────────────────────────
  // The dashboard made the gap obvious — six monitors against fifteen
  // containers, and the ones missing were not the unimportant ones.
  //
  // omniroute is the clearest case: every agent turn in the system goes
  // through it since M13. It had no monitor at all, so an outage there would
  // have looked like "the agents have gone quiet" with no way to tell why.
  //
  // Reachable because Kuma is on `apps` and these expose HTTP there. openclaw
  // and hermes are deliberately NOT here: they sit on `agent` only, and
  // widening Kuma into that segment is exactly what the cliproxy push monitor
  // above exists to avoid. Their health is visible through the runs they
  // produce, on the dashboard.
  { name: "omniroute", url: "http://" + process.env.PREFIX + "omniroute:20128/v1/models" },
  { name: "portfolio", url: "http://" + process.env.PREFIX + "portfolio:8080/healthz" },
  { name: "dashboard", url: "http://" + process.env.PREFIX + "dashboard:8090/healthz" },
  // postgres and redis are NOT here on purpose. They sit on `data`
  // (internal: true) and Kuma sits on `apps`, so it cannot reach them at all
  // — a monitor would report a permanent outage for two healthy databases.
  // Joining Kuma to `data` to fix that would hand the container that holds
  // the ntfy publish token a route to the databases, which is a worse trade
  // than not graphing them. Their health shows up through the services that
  // depend on them.
];

const fail = (m) => { console.error("  ERROR: " + m); process.exit(1); };
const timer = setTimeout(() => fail("timed out talking to Kuma"), 60000);

sock.on("connect_error", (e) => fail("connect: " + e.message));

// Captured from the pushed event, not from a callback — see the note below.
let currentList = {};
sock.on("monitorList", (list) => { currentList = list || {}; });

// Same pattern for notifications: pushed as an event, not returned by a call.
// Without this, every run added another identical "ntfy" channel.
let currentNotifs = [];
sock.on("notificationList", (list) => { currentNotifs = list || []; });

sock.on("connect", () => {
  sock.emit("login", { username: process.env.KU, password: process.env.KP, token: "" }, (res) => {
    if (!res || !res.ok) fail("login rejected: " + JSON.stringify(res));
    console.log("  logged in");

    // The notification channel must exist before monitors can reference it.
    // isDefault/applyExisting so later monitors inherit it automatically.
    const notif = {
      name: "ntfy",
      type: "ntfy",
      isDefault: true,
      applyExisting: true,
      ntfyserverurl: "http://" + process.env.PREFIX + "ntfy:80",
      ntfytopic: process.env.TOPIC,
      ntfyPriority: 4,
      ntfyAuthenticationMethod: "usernamePassword",
      ntfyusername: "kuma",
      ntfypassword: process.env.NTFY_PASS,
    };

    // Reuse the existing channel if present, so re-runs do not pile up
    // duplicate identical notification targets.
    const withNotif = (notifId, label) => {
      console.log("  notification " + label + " (id " + notifId + ")");

      // Kuma pushes the monitor list as an EVENT; getMonitorList takes no
      // callback. Reading it from a callback returned undefined, so every
      // monitor looked absent and a second run duplicated all of them. The
      // list arrives unprompted right after login, so it is captured there.
      const seed = () => {
        const existing = new Set(
          Object.values(currentList || {}).map((m) => m.name)
        );

        const todo = monitors.filter((m) => !existing.has(m.name));
        if (todo.length === 0) {
          console.log("  all monitors already present, nothing to add");
          clearTimeout(timer);
          sock.close();
          process.exit(0);
        }

        let done = 0;
        let failures = 0;
        for (const m of todo) {
          // A push monitor inverts the direction: Kuma waits to be told, and
          // alerts when nobody tells it. That is what lets the proxy be
          // watched from `agent` without Kuma joining that network.
          //
          // heartbeatInterval is deliberately long for the proxy — it reports
          // hourly, and Kuma alerts if two reports are missed. Anything
          // shorter would page on a restart.
          const isPush = m.type === "push";
          sock.emit("add", Object.assign({
            type: isPush ? "push" : "http",
            name: m.name,
            interval: m.interval || 60,
            retryInterval: m.interval || 60,
            maxretries: isPush ? 1 : 2,
            notificationIDList: notifId ? { [notifId]: true } : {},
            active: true,
            // Kuma 2.x added monitor.conditions as NOT NULL. Omitting it (or
            // sending null) fails the insert with SQLITE_CONSTRAINT, and the
            // error only surfaces in the callback — the socket itself looks
            // fine, which is why the first attempt appeared to "time out".
            conditions: [],
          },
          // url/method/accepted_statuscodes are meaningless for a push monitor
          // and pushToken is meaningless for an HTTP one. Kuma mints the token
          // itself when one is not supplied, which is what `make proxy-token`
          // then reads back.
          // accepted_statuscodes is sent for BOTH types. It is meaningless for
          // a push monitor, but Kuma calls .every() on it unconditionally
          // while saving — omitting it fails with "Cannot read properties of
          // undefined (reading every)", which names no field and is therefore
          // very hard to place.
          isPush
            ? { accepted_statuscodes: ["200-299"] }
            : { url: m.url, method: "GET", accepted_statuscodes: ["200-299"] }
          ), (ares) => {
            if (!ares || !ares.ok) {
              // Report and keep going: one bad monitor should not silently
              // abort seeding the rest.
              console.error("  " + m.name + ": FAILED " + JSON.stringify(ares));
              failures++;
            } else {
              console.log("  " + m.name + ": added");
            }
            if (++done >= todo.length) {
              clearTimeout(timer);
              sock.close();
              if (failures > 0) {
                console.error("  seeding finished with " + failures + " failure(s)");
                process.exit(1);
              }
              console.log("  seeding complete");
              process.exit(0);
            }
          });
        }
      };

      // Give the pushed monitorList a moment to arrive before comparing.
      setTimeout(seed, 2000);
    };

    // Wait for the pushed notificationList, then create or reuse.
    setTimeout(() => {
      const found = currentNotifs.find((n) => n.name === "ntfy");
      if (found) {
        withNotif(found.id, "reused");
      } else {
        sock.emit("addNotification", notif, null, (nres) => {
          if (!nres || !nres.ok) fail("addNotification: " + JSON.stringify(nres));
          withNotif(nres.id, "created");
        });
      }
    }, 2000);
  });
});
'
