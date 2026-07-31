-- =============================================================================
-- 002-agent-runtime.sql — what the runner needs to actually execute tickets.
-- =============================================================================
--
-- 001 modelled a ticket. This adds the columns the execution loop needs, kept
-- as a separate migration because 001 is already applied and applied
-- migrations are never edited (scripts/migrate.sh enforces that with a
-- checksum).
--
-- ADDITIVE ONLY. Every column is nullable or defaulted, so the rows created
-- under 001 remain valid and no backfill is required.
-- =============================================================================

BEGIN;

-- ── Who works this ticket ───────────────────────────────────────────────────
-- 'ceo'    — decomposes a goal into child tickets. Plans, does not implement.
-- 'worker' — does one concrete piece of work.
-- The distinction is a prompt and a tool policy, not a separate service
-- (ADR-0017): both are `claude -p` sessions.
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'worker';

DO $$
BEGIN
	IF NOT EXISTS (
		SELECT FROM pg_constraint WHERE conname = 'ticket_role_known'
	) THEN
		ALTER TABLE tickets ADD CONSTRAINT ticket_role_known
			CHECK (role IN ('ceo', 'worker'));
	END IF;
END
$$;

-- ── Outcome ─────────────────────────────────────────────────────────────────
-- What the session produced. Free text: it is a summary for a human, not
-- something queried structurally.
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS result text;

-- Claude Code's own session id, so a ticket can be traced back to its
-- transcript. Without this, "why did the agent do that" is unanswerable.
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS session_id text;

-- ── Retry accounting ────────────────────────────────────────────────────────
-- A ticket that fails is retried, but not forever. Without a counter, a ticket
-- that always fails is picked up on every poll and burns the whole rate limit
-- on one broken task — the classic poison-message failure.
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS attempts int NOT NULL DEFAULT 0;
ALTER TABLE tickets ADD COLUMN IF NOT EXISTS last_error text;

-- ── A 'failed' terminal state ───────────────────────────────────────────────
-- 001 had 'cancelled' (a decision) but nothing for "tried and could not".
-- Conflating the two loses the distinction between "we chose not to" and
-- "this is broken", which is exactly what you want to know later.
DO $$
BEGIN
	IF NOT EXISTS (
		SELECT FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
		WHERE t.typname = 'ticket_status' AND e.enumlabel = 'failed'
	) THEN
		ALTER TYPE ticket_status ADD VALUE 'failed';
	END IF;
END
$$;

COMMIT;

-- ALTER TYPE ... ADD VALUE cannot be used in the same transaction that added
-- it, so everything referencing 'failed' goes in a second transaction.
BEGIN;

-- 001's constraint required closed_at for done/cancelled. 'failed' is equally
-- terminal and must record when it stopped, or "how long has this been stuck"
-- has no answer.
ALTER TABLE tickets DROP CONSTRAINT IF EXISTS ticket_closed_has_timestamp;
ALTER TABLE tickets ADD CONSTRAINT ticket_closed_has_timestamp
	CHECK ((status IN ('done', 'cancelled', 'failed')) = (closed_at IS NOT NULL));

-- The runner's claim query orders by priority then age within a role, and
-- 001's partial index does not carry role. Same predicate, plus role, so a CEO
-- poll and a worker poll each hit an index rather than scanning.
CREATE INDEX IF NOT EXISTS tickets_claim_idx
	ON tickets (role, priority DESC, created_at)
	WHERE status = 'open';

COMMIT;
