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

- [ ] M5: verify `.env` is included in the restic backup set
- [ ] M7: install SOPS+age, encrypt `.env` to `secrets.enc.env`, commit it
- [ ] M7: give GitHub Actions its own age key, not a copy of the operator's
- [ ] M7: update this ADR's status to note Phase 2 is active
