# Operator tasks — what only you can do

Everything buildable has been built. What remains needs either the Cloudflare
dashboard, a GitHub account, or a decision that is yours to make.

Ordered by urgency. **Task 1 is a live security gap** — the rest can wait.

---

## 1. ✅ Access policies — done 2026-07-31

All three hostnames are gated; the ntfy topic path is deliberately not.
Verified by redirect target, and a test alert was delivered to the phone.
Kept here as the record of what was built and why.

**Why it mattered:** `n8n`, `status` and `ntfy` were reachable from the internet
right now. Each sits behind its own login, and each of those logins is
rate-limited with a long generated password — so this is not an open door. But it
is a *single* layer, and a single layer means any future CVE in any of those three
products is directly exploitable.

Cloudflare Access puts authentication in front of all three, so an attacker never
reaches the application at all.

### Steps (one application per hostname)

Cloudflare Zero Trust → **Access** → **Applications** → *Add an application* →
**Self-hosted**, then for each:

| Application name | Destination | Session |
|---|---|---|
| n8n | `n8n.maxrommel.de` | 24 hours |
| status | `status.maxrommel.de` | 24 hours |
| ntfy-push | `ntfy.maxrommel.de/<NTFY_TOPIC>` | 24 hours (Bypass — irrelevant) |
| ntfy-web | `ntfy.maxrommel.de` | 30 days |

Four applications, not three — see the ntfy exception below.

Policy for each — identical:

- Action: **Allow**
- Rule: *Emails* → `max.rml@web.de`

### ⚠️ One exception: ntfy needs TWO applications

The ntfy **phone app is not a browser** and cannot complete an Access login. If
you gate `ntfy.maxrommel.de` entirely, push notifications stop arriving.

The path lives on the **destination**, not on the policy, so a single
application cannot express "bypass this one path, gate everything else". It
takes two applications. Cloudflare matches the more specific path first:

| Application | Destination | Policy |
|---|---|---|
| `ntfy-push` | `ntfy.maxrommel.de/<NTFY_TOPIC>` | Bypass → Everyone |
| `ntfy-web` | `ntfy.maxrommel.de` (path empty) | Allow → Emails → your address |

Get the topic with `grep NTFY_TOPIC .env`.

**Do not put an Allow policy on `ntfy-push`** — the Bypass above it already
matches everything that app covers, so the Allow is dead weight that suggests a
protection which is not there.

**Do not save a Bypass whose destination has no path.** That bypasses the entire
hostname, which is worse than having no application at all: the dashboard shows
a protected app while nothing is protected.

The topic stays protected by ntfy's own `deny-all` plus your token, and the topic
string is 40 random characters, so an open path is not an open endpoint.

### Verify — do not skip

**A 302 alone proves nothing.** Uptime Kuma redirects `/` to `/dashboard` on its
own, so an unprotected `status` returns 302 exactly like a protected one does.
This was observed on 2026-07-31 while only the n8n policy existed. Check the
redirect *target*, not the status code:

```bash
TOPIC=$(grep NTFY_TOPIC .env | cut -d= -f2)
check() {
  loc=$(curl -s -o /dev/null -D - --max-time 15 "$1" | grep -i '^location:')
  case "$loc" in
    *cloudflareaccess.com*) echo "GATED    $2" ;;
    *)                      echo "NOT GATED  $2" ;;
  esac
}
check "https://n8n.maxrommel.de/"        "n8n"
check "https://status.maxrommel.de/"     "status"
check "https://ntfy.maxrommel.de/"       "ntfy web UI"
check "https://ntfy.maxrommel.de/$TOPIC" "ntfy topic — MUST be NOT GATED"
```

The first three must be `GATED`. The fourth must **not** be — that is the phone's
push path, and gating it silently stops all alerts.

Then prove delivery end to end: `make alert-test`, and confirm the notification
actually arrives on the phone. The server returning a message id only proves ntfy
accepted it, not that it was delivered.

---

## 2. 🟡 Store three things in your password manager

None of these can be recovered if lost:

| What | Where to get it | Consequence of losing it |
|---|---|---|
| `RESTIC_PASSWORD` | `grep RESTIC_PASSWORD .env` | **every backup becomes unreadable** |
| age private key | `~/.config/sops/age/keys.txt` | `secrets.enc.env` becomes undecryptable |
| Hetzner root password | Hetzner console | the console is your last-resort access (ADR-0013) |

Also worth saving for convenience: `N8N_OWNER_PASSWORD`, `KUMA_ADMIN_PASSWORD`,
`NTFY_ADMIN_PASSWORD`, `NTFY_PHONE_TOKEN` — all in `.env`, all recoverable from
backup, so these are lower stakes.

---

## 3. 🟡 Subscribe your phone to alerts

Install the **ntfy** app (iOS/Android), then:

1. Settings → *Add server* → `https://ntfy.maxrommel.de`
2. Authentication: **Access token** → the value of `NTFY_PHONE_TOKEN` in `.env`
3. Subscribe to the topic in `NTFY_TOPIC`

Test with `make alert-test`. If nothing arrives, check task 1's bypass rule.

---

## 4. 🟢 Decide: automate the off-host backup?

Today backups are two tiers: automatic daily on the server, and `make backup-pull`
to this laptop **when you run it**. The laptop tier is what survives losing the
server, so its value decays with time since the last pull —
`make backup-pull-status` warns past 7 days.

To make it automatic, give me a Backblaze B2 bucket + application key (~1 cent a
month at this size, and off-provider from Hetzner). One variable changes;
every script stays the same.

Otherwise: run `make backup-pull` weekly, and after anything you would hate to
redo.

---

## 5. ✅ M7: done — nothing left to do

`SOPS_AGE_KEY` was set on 2026-07-31 and all three jobs are green
(`decrypted 24 variables with CI's key`, matching what your own key decrypts).

CI has its **own** age key, not a copy of yours (ADR-0006). If it ever leaks:
delete its recipient line from `.sops.yaml`, run `sops updatekeys secrets.enc.env`,
commit. Your key is untouched and nothing you hold needs re-encrypting.

**There is no GHCR build job, deliberately.** All eight images are pinned
third-party images (ADR-0011) and the repository contains no Dockerfile — a build
job would have nothing to build. What CI does instead is enforce the invariants:
generated files match `services.yml`, no `:latest`, no secret tracked,
`secrets.enc.env` still decryptable by CI, plus the linters that `make lint`
skips when they are not installed locally.

Per ADR-0007 the server pulls; CI holds no SSH key and cannot reach the host.

---

## 6. 🟢 M8.5: close port 22

**Tailscale is ruled out** (your work laptop prohibits it), so ADR-0013's
mechanism needs replacing. Recommended: **Cloudflare Access SSH** — browser-based,
no client software, works from the work laptop, and reaches the same end state of
zero public inbound ports.

Port 22 currently absorbs ~1000 automated attempts a day (key-only, rate-limited,
fail2ban has banned 95 IPs). Not urgent, but it is the last public port.

Say the word and I will write the superseding ADR and implement it.

---

## 7. 🟢 M9: Paperclip and Hermes

**Blocked on:** these do not exist yet. `services.yml` reserves their hostnames,
and M4 already provisioned their databases, roles and credentials — but there is
no application code, and I should not invent what they do.

Tell me what either service should be and it becomes a normal build.

---

## Optional hardening, worth doing eventually

- **MFA in n8n** (currently off) — Settings → *Two-factor authentication*.
  Worth it while n8n is publicly reachable.
- **External monitor** — Kuma cannot report its own death (it dies with the
  host). A free Uptime Robot or Healthchecks.io check on
  `https://status.maxrommel.de` closes that gap, and pointing Healthchecks.io at
  the backup timer closes ADR-0009's last follow-up.
- **`brew install pre-commit && pre-commit install`** — the hooks are configured
  but not installed locally; I have been running their equivalents by hand.
