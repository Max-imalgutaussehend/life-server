# Operator tasks — what only you can do

Everything buildable has been built. What remains needs either the Cloudflare
dashboard, a GitHub account, or a decision that is yours to make.

Ordered by urgency. **Task 1 is a live security gap** — the rest can wait.

---

## 1. 🔴 Access policies for three hostnames — do this first

**Why it matters:** `n8n`, `status` and `ntfy` are reachable from the internet
right now. Each sits behind its own login, and each of those logins is
rate-limited with a long generated password — so this is not an open door. But it
is a *single* layer, and a single layer means any future CVE in any of those three
products is directly exploitable.

Cloudflare Access puts authentication in front of all three, so an attacker never
reaches the application at all.

### Steps (one application per hostname)

Cloudflare Zero Trust → **Access** → **Applications** → *Add an application* →
**Self-hosted**, then for each:

| Application name | Domain | Session |
|---|---|---|
| n8n | `n8n.maxrommel.de` | 24 hours |
| status | `status.maxrommel.de` | 24 hours |
| ntfy | `ntfy.maxrommel.de` | 30 days |

Policy for each — identical:

- Action: **Allow**
- Rule: *Emails* → `max.rml@web.de`

### ⚠️ One exception: ntfy needs a bypass path

The ntfy **phone app is not a browser** and cannot complete an Access login. If
you gate `ntfy.maxrommel.de` entirely, push notifications stop arriving.

In the ntfy application, add a **second policy, ordered above the Allow policy**:

- Action: **Bypass**
- Rule: *Everyone*
- Path: `/<your topic>` — the value of `NTFY_TOPIC` in `.env`
  (get it with `grep NTFY_TOPIC .env`)

The topic itself stays protected by ntfy's own `deny-all` plus your token, so a
bypass on that single path is not an open endpoint. The web UI stays gated.

### Verify — do not skip

```bash
# All three must return 302 (redirect to the Cloudflare login):
for h in n8n status ntfy; do
  printf '%-8s ' "$h"
  curl -s -o /dev/null -w '%{http_code}\n' "https://$h.maxrommel.de/"
done
```

A `200` means the policy did not attach — check the hostname spelling in the
dashboard. Then confirm your phone still receives alerts: `make alert-test`.

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

## 5. 🟡 M7: one command to finish CI

The repository is pushed, `.github/workflows/validate.yml` exists, and CI has its
**own** age key — not a copy of yours (ADR-0006), so a leaked CI key is revoked by
editing `.sops.yaml` without rotating anything of yours.

One thing is missing: GitHub does not hold that key yet. Until you run this, the
`secrets` job fails on every push.

```bash
gh secret set SOPS_AGE_KEY < ~/.config/sops/age/ci-key.txt
```

No dashboard needed. Check the result with `gh run list --limit 3`.

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
