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
  { name: "whoami", url: "http://" + process.env.PREFIX + "whoami:8000/" },
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
          sock.emit("add", {
            type: "http",
            name: m.name,
            url: m.url,
            method: "GET",
            interval: 60,
            retryInterval: 60,
            maxretries: 2,
            accepted_statuscodes: ["200-299"],
            notificationIDList: notifId ? { [notifId]: true } : {},
            active: true,
            // Kuma 2.x added monitor.conditions as NOT NULL. Omitting it (or
            // sending null) fails the insert with SQLITE_CONSTRAINT, and the
            // error only surfaces in the callback — the socket itself looks
            // fine, which is why the first attempt appeared to "time out".
            conditions: [],
          }, (ares) => {
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
