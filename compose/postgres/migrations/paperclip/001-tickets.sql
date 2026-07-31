-- =============================================================================
-- 001-tickets.sql — the ticket substrate for Paperclip. (M9, step 1)
-- =============================================================================
--
-- WHY TICKETS AND NOT A CHAT LOG
--   Agents that talk to each other freely produce work that cannot be resumed,
--   audited, or handed to a second agent. A ticket is a row: it has an owner, a
--   state, a parent, and a history. That is what makes multi-agent work
--   recoverable after a crash and reviewable afterwards.
--
-- WHY THIS RUNS BEFORE ANY AGENT EXISTS
--   The schema is testable with psql alone. Proving it works costs nothing and
--   proves it before an agent layer hides the failure modes.
--
-- IDEMPOTENT ON PURPOSE
--   Every statement tolerates being re-run. compose/postgres/initdb only fires
--   on an empty volume, so it cannot deliver schema to a database that already
--   exists — migrations must be safe to apply repeatedly instead.
--
-- OWNERSHIP
--   Applied as the `paperclip` role, so every object belongs to it. ADR-0005
--   gives that role rights to its own database and nothing else; running this
--   as the superuser would create objects the service cannot alter later.
-- =============================================================================

BEGIN;

-- ── Status and priority as enums, not free text ─────────────────────────────
-- A typo in a status string is a ticket that no query will ever find again.
-- The database refuses the typo instead.
DO $$
BEGIN
	IF NOT EXISTS (SELECT FROM pg_type WHERE typname = 'ticket_status') THEN
		CREATE TYPE ticket_status AS ENUM (
			'open',        -- created, nobody working on it
			'claimed',     -- an agent has taken it; see claimed_by
			'blocked',     -- waiting on something external, see blocked_reason
			'review',      -- work done, awaiting a human or the parent agent
			'done',
			'cancelled'
		);
	END IF;

	IF NOT EXISTS (SELECT FROM pg_type WHERE typname = 'ticket_priority') THEN
		CREATE TYPE ticket_priority AS ENUM ('low', 'normal', 'high', 'urgent');
	END IF;
END
$$;

-- ── Tickets ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tickets (
	id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

	-- Human-facing handle ("UNI-14"). Separate from id so it can be spoken,
	-- typed and pasted without exposing a row count.
	key          text UNIQUE,

	title        text        NOT NULL CHECK (length(trim(title)) > 0),
	body         text        NOT NULL DEFAULT '',

	status       ticket_status   NOT NULL DEFAULT 'open',
	priority     ticket_priority NOT NULL DEFAULT 'normal',

	-- Life domains from the operator's brief: uni, work, jobsearch, personal,
	-- projects. Deliberately text, not an enum — domains are the thing most
	-- likely to change, and adding "health" should not need a migration.
	domain       text,

	-- Delegation. ON DELETE CASCADE: deleting a parent removes the subtree,
	-- because an orphaned subtask has no meaning and would be worked forever.
	parent_id    bigint REFERENCES tickets(id) ON DELETE CASCADE,

	-- Which agent session holds this. Null unless status = 'claimed'; the
	-- constraint below enforces that rather than trusting callers.
	claimed_by   text,
	claimed_at   timestamptz,

	blocked_reason text,

	created_at   timestamptz NOT NULL DEFAULT now(),
	updated_at   timestamptz NOT NULL DEFAULT now(),
	closed_at    timestamptz,

	-- A ticket cannot be its own parent. Deeper cycles are not expressible in
	-- a CHECK; the application must not build them.
	CONSTRAINT ticket_not_own_parent CHECK (parent_id IS DISTINCT FROM id),

	-- 'claimed' without a claimant is a ticket nobody is working on that looks
	-- like one somebody is. That is the state that stalls a queue silently.
	CONSTRAINT ticket_claimed_has_owner
		CHECK ((status = 'claimed') = (claimed_by IS NOT NULL)),

	-- Likewise a terminal ticket must record when it ended.
	CONSTRAINT ticket_closed_has_timestamp
		CHECK ((status IN ('done', 'cancelled')) = (closed_at IS NOT NULL))
);

-- The queue query — "next open ticket, best priority, oldest first" — is the
-- one every agent runs constantly. A partial index keeps it off the closed
-- tickets, which will eventually outnumber the open ones by orders of
-- magnitude.
CREATE INDEX IF NOT EXISTS tickets_queue_idx
	ON tickets (priority DESC, created_at)
	WHERE status = 'open';

CREATE INDEX IF NOT EXISTS tickets_parent_idx ON tickets (parent_id)
	WHERE parent_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS tickets_domain_idx ON tickets (domain, status);

-- ── Event log ───────────────────────────────────────────────────────────────
-- Append-only. The tickets table holds current state; this holds how it got
-- there. When an agent does something surprising, this is the only record of
-- what it saw and decided — ADR-0012 wants an audit log, and this is its
-- ticket-shaped half.
CREATE TABLE IF NOT EXISTS ticket_events (
	id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	ticket_id  bigint NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,

	-- 'created', 'claimed', 'status_changed', 'commented', 'delegated', ...
	-- Free text: the vocabulary will grow, and an unknown event type must be
	-- storable rather than rejected — losing the record of a surprise is worse
	-- than storing an unexpected string.
	event_type text NOT NULL,

	-- Who: an agent session id, or the operator.
	actor      text NOT NULL,

	-- Anything structured the event carries. jsonb, not json: it is queryable.
	payload    jsonb NOT NULL DEFAULT '{}'::jsonb,

	created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ticket_events_ticket_idx
	ON ticket_events (ticket_id, created_at);

-- ── updated_at maintenance ──────────────────────────────────────────────────
-- In a trigger rather than in application code, because there will be more
-- than one writer (Paperclip, agent sessions, and psql by hand) and only the
-- database sees all of them.
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
	NEW.updated_at := now();
	RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tickets_set_updated_at ON tickets;
CREATE TRIGGER tickets_set_updated_at
	BEFORE UPDATE ON tickets
	FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;
