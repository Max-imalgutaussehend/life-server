# Operator tasks — what only you can do

Everything buildable has been built. What remains needs either the Cloudflare
dashboard or a decision that is yours to make.

**Updated 2026-07-31 — there is no longer a live security gap.** Tasks 1–3 and 5
are done: all private hostnames are behind Cloudflare Access, secrets are in
Bitwarden and the plaintext Desktop copy is destroyed, phone alerts are
confirmed delivered end to end, and CI is green.

What is left, in order:

| | Task | Needs |
|---|---|---|
| 6 | Close port 22 | ~10 min, dashboard + a cold reconnect test |
| 7 | M9 questions | two answers, no work |
| 4 | Automate off-host backups | a decision (B2 credentials) |

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

## 2. ✅ Password manager — done 2026-07-31

Entered in Bitwarden by the operator. The plaintext copy on the Desktop
(`life-server-secrets-BITWARDEN-DANN-LOESCHEN.txt`) was overwritten and deleted
the same day, after verifying that both irreplaceable secrets are still
recoverable: the age key decrypts `secrets.enc.env` from
`~/.config/sops/age/keys.txt`, and `RESTIC_PASSWORD` is present in `.env` and in
the committed encrypted file.

Kept below as the reference for what must never be lost.

### The three that cannot be recovered

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

## 3. ✅ Phone alerts — done 2026-07-31, delivery confirmed

The operator received two test notifications on the phone. **The monitoring
chain is now proven end to end**: Kuma detects → ntfy publishes → the Cloudflare
bypass passes it → the phone receives it. That was the last unverified hop, and
the one that would otherwise have failed silently during a real outage.

Kept below as the setup reference for a new device.

Install the **ntfy** app (iOS/Android), then:

1. Add server → `https://ntfy.maxrommel.de`
2. **Settings → Users → Add user**, and enter **username + password**:

   | Field | Value |
   |---|---|
   | Server | `https://ntfy.maxrommel.de` |
   | Username | `phone` |
   | Password | `grep NTFY_PHONE_PASSWORD .env` |

3. Subscribe to the topic in `NTFY_TOPIC` (`grep NTFY_TOPIC .env`)

**Why a password and not the token:** the mobile app's "Add user" screen accepts
only username/password in some versions — observed 2026-07-31. So a dedicated
`phone` account exists alongside `NTFY_PHONE_TOKEN`; either works, use whichever
the app offers.

**Credentials are not optional.** Verified: an anonymous poll returns **403**,
the same request authenticated returns **200**. The Cloudflare bypass opens the
network path; ntfy's own `deny-all` still demands credentials. That is the
layering working as designed.

**Do not use the `max` admin account on the phone.** `phone` is granted
`read-only` on the topic (verified: read 200, publish 403). The admin account is
read-write, so a stolen phone could publish a forged "all clear" — the one
message that has to be trustworthy.

Test with `make alert-test`. Messages are retained until they expire, so
anything sent before you subscribe should appear once you do.

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

## 6. 🟡 M8.5: close port 22 — decided, needs you to activate

[ADR-0016](adr/0016-ssh-via-cloudflare-access.md) is written and supersedes
ADR-0013: **Cloudflare Access SSH** instead of Tailscale, since your work laptop
prohibits it. Same end state, no new inbound port, no new third party — the
tunnel already carries everything else.

**Full steps are in [`docs/milestones/M8.5.md`](milestones/M8.5.md).** Two
dashboard changes (~4 min), an `~/.ssh/config` stanza, then verify and close.

**Why I did not do it for you:** closing the only working access path requires
the console fallback to be real, and the console needs the Hetzner root
password — which is not in `.env`, not in the repo, and not something I can
confirm is in Bitwarden. Closing on an unverified fallback is the exact failure
ADR-0013 was written to prevent.

Port 22 stays `ufw limit`, key-only, fail2ban-guarded — the posture that has
held since M1 against ~1000 attempts a day. Not urgent, but it is the last
public port.

---

## 7. 🟢 M9: Paperclip — steps 1–2 built, 2 questions left

Unblocked by your answers on 2026-07-31. Because you have a Claude subscription
and no API key, **Claude Code itself is the agent runtime** — a subscription
authenticates interactively and is not a credential a server daemon can present
to the API. Hermes as a long-running API client is therefore not buildable;
Paperclip owns the tickets and invokes Claude Code sessions.

Done and verified: the ticket schema, and the agent sandbox (15/15, plus a
negative control proving the test can actually fail). See
[`docs/milestones/M9.md`](milestones/M9.md).

**Two answers would unblock the rest:**

1. **The "work agent"** — what is it, and how should it connect? Inbound
   webhook, outbound polling, or a shared queue? This decides whether anything
   new has to be publicly reachable, so I will not guess it.
2. **Concurrency** — how many agent sessions may run at once? A subscription has
   rate limits and an unbounded delegation tree will find them.

**One design problem I cannot solve alone:** Claude Code's OAuth session lives
on the machine where the login happened. Running sessions in throwaway
containers means either mounting that credential in — which contradicts the
sandbox that makes code execution safe — or logging in per session, which is
interactive and defeats automation. This needs a decision before step 3.

---

## 8. 🔴 Publish the Paperclip UI — one Access application

**The UI is built, deployed and healthy, but its public route is deliberately
switched off.**

`services.yml` has `paperclip` at `enabled: false` with a comment explaining
why: when it was briefly enabled without an Access policy,
`paperclip.maxrommel.de` answered **200 to an unauthenticated request** — a
public ticket queue containing whatever the agents know about work, uni and job
search. Reverted within minutes.

Create the application exactly like the others:

| Field | Value |
|---|---|
| Application name | `paperclip` |
| Destination | Public hostname `paperclip` . `maxrommel.de`, path empty |
| Session Duration | `24 hours` |
| Policy | Allow → Include → **Emails** → `max.rml@web.de` |

Then publish it:

```bash
# in services.yml set: enabled: true
make generate && make deploy-stack
curl -s -o /dev/null -D - https://paperclip.maxrommel.de/ | grep -i location
# must point at cloudflareaccess.com
```

Until then the UI still works — it is simply only reachable from inside the
server's `apps` network.

---

## 9. 🟡 Decide: how WhatsApp connects

[ADR-0018](adr/0018-whatsapp-assistant.md) has the full reasoning. One choice:

- **Meta WhatsApp Business Cloud API** (recommended) — official, free tier far
  beyond personal use, ~15 minutes of dashboard setup, no risk to your account.
- **An unofficial library** driving WhatsApp Web — no setup, but against
  WhatsApp's terms, and your personal number can be banned.

**No second LLM is needed.** The CEO agent already turns a sentence into
tickets, and a WhatsApp message is a sentence — the bridge is transport, not
intelligence. Routing over free providers would send your job-search and work
messages through whichever vendor had quota that hour, which is the one thing
this system is built to avoid.

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
