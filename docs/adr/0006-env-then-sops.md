# ADR-0006: Plain .env now, SOPS from M7

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0 (decision), M7 (SOPS migration)
- **Supersedes discussion:** an earlier proposal to adopt SOPS+age immediately

## Context

"Everything reproducible from Git" and "secrets never in Git" are in direct
tension. SOPS+age resolves it by committing encrypted secrets. The question was
whether to adopt it on day one.

The argument for waiting, which was accepted: SOPS solves *distribution* of
secrets among multiple parties. With one server and one operator, there is no
distribution problem to solve. The second party arrives in M7, when GitHub
Actions needs to deploy.

## Decision

**Phase 1 (M1–M6): a plain `.env` file, chmod 600, gitignored.**
**Phase 2 (from M7): SOPS+age, encrypted secrets committed to Git.**

Three rules make the later migration cheap:

1. **`.env` is never edited by hand.** `scripts/setup-env.sh` writes it.
2. **`env.example` is the committed contract.** Every variable is declared there
   with a placeholder, so Git always records what the system needs.
3. **`make check-env` proves they agree** — it fails on a key present in one and
   missing from the other, in either direction.

Without these, migrating to SOPS means reconstructing which forty variables
accumulated by hand over two years. With them, it is "encrypt the file that
already exists".

## Alternatives considered

**SOPS+age from M0.** Fully reproducible immediately. Rejected as premature for
a single operator; the accepted counter-argument is above. Roughly 10 minutes of
setup deferred, not avoided.

**Infisical / HashiCorp Vault.** Proper secret management with rotation and
audit. Rejected: a service that must be running before anything else can start,
with its own bootstrap secret, its own backup, and its own failure mode. Far
too much machinery for one host.

**Docker secrets.** Native, no extra tooling. Rejected: designed for Swarm; in
plain Compose it is file-mounting with extra steps, and does not solve the
Git-reproducibility question at all.

## Trade-offs

**Gained:** no encryption tooling in the loop while the system is being built.
Debugging is `cat .env`.

**Given up — and this is the real cost:** the server is **not** fully
reproducible from Git during M1–M6. A total loss requires the repo *and* a copy
of `.env`. This is a deliberate, bounded gap, not an oversight.

**Consequence that must not be forgotten:** `.env` therefore **must** be in the
backup scope from M5. It is the one file that Git does not protect.

## Consequences

- `.gitignore` blocks `.env` and `.env.*` but allows `env.example`.
- A pre-commit hook (gitleaks) blocks accidental secret commits.
- `N8N_ENCRYPTION_KEY` and `RESTIC_PASSWORD` must be copied to a password
  manager the moment they are generated: losing the first makes every n8n
  credential unreadable, losing the second makes every backup unreadable.
- M5's backup scope explicitly includes `/opt/life-server/.env`.

## Follow-up

- [x] M5: verify `.env` is included in the restic backup set — asserted every run
- [x] M7: install SOPS+age, encrypt `.env` to `secrets.enc.env`, commit it
      — `.sops.yaml` declares the recipient; `make secrets-verify` proves the
      encrypted file round-trips to the live `.env`
- [x] M7: give GitHub Actions its own age key, not a copy of the operator's
      — done 2026-07-30. CI's recipient is
      `age1pzrzrjcmgg0srhu3q4g4553fxsm0yumlyg8tdh57tjvy28k3yy7qmavlsr`,
      generated separately at `~/.config/sops/age/ci-key.txt`; both recipients
      were verified to decrypt independently. Revoking CI is now a one-line
      edit to `.sops.yaml` plus `sops updatekeys` — the operator's key is
      untouched, which was the entire point of not sharing one.
- [x] M7: Phase 2 is active for both recipients

**The failure this guards against.** `.github/workflows/validate.yml` decrypts
`secrets.enc.env` with CI's key on every push. Not because CI needs the values —
it counts variables and discards them — but because the way this setup breaks is
silent: someone re-encrypts without `sops updatekeys`, CI quietly stops being a
recipient, and nobody finds out until a restore. A check that runs on every push
turns a disaster-time discovery into a red build.

**Phase 2 notes (2026-07-30).** Key names stay in plaintext inside
`secrets.enc.env` and only values are encrypted, so a diff shows *which* secret
changed without revealing any value — rotation stays auditable. `.env` remains
the file every tool reads; `secrets.enc.env` is the committed, recoverable copy.
`make secrets-verify` fails loudly when the two drift, which is the failure mode
that would otherwise surface during a restore.

The age **private** key lives at `~/.config/sops/age/keys.txt`, outside the
repository, and `.gitignore` now blocks `keys.txt` / `*.agekey` as a safety net.
Losing it makes `secrets.enc.env` permanently undecryptable — it belongs in a
password manager alongside `RESTIC_PASSWORD`.
