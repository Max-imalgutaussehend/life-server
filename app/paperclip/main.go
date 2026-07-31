// Paperclip — the web UI for the ticket queue. (M9, step 5)
//
// WHY GO AND NOT A FRAMEWORK
//	The host has 3.7 GB of RAM shared by Postgres, n8n, Redis and the rest. A
//	Node or Python service costs 100-200 MB resident and drags in a dependency
//	tree that has to be patched forever. This is one table rendered as HTML: a
//	static Go binary does it in ~15 MB with the standard library and one
//	Postgres driver.
//
// WHY IT NEEDS NO CLAUDE CREDENTIAL
//	Per ADR-0017 the agents run on the operator's Mac, because Claude Code's
//	OAuth token is Keychain-bound. This UI only reads and writes tickets, so it
//	belongs on the server with the data — and a compromise here yields tickets,
//	not an account.
//
// AUTHENTICATION IS AT THE EDGE
//	`access: private` in services.yml means Cloudflare Access gates this
//	hostname before a request reaches the tunnel. There is deliberately no login
//	here: a second, weaker auth system would be a liability, not a defence.
package main

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

//go:embed templates/*.html
var templateFS embed.FS

type Ticket struct {
	ID        int64
	Key       sql.NullString
	Title     string
	Body      string
	Status    string
	Priority  string
	Domain    sql.NullString
	Role      string
	ParentID  sql.NullInt64
	ClaimedBy sql.NullString
	Result    sql.NullString
	LastError sql.NullString
	Attempts  int
	CreatedAt time.Time
	UpdatedAt time.Time
	ClosedAt  sql.NullTime
}

// Age renders "3m" / "2h" / "5d" rather than a timestamp. When scanning a
// queue, how long something has been sitting is the question being asked.
func (t Ticket) Age() string {
	d := time.Since(t.CreatedAt)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
}

func (t Ticket) IsOpen() bool  { return t.Status == "open" }
func (t Ticket) NeedsMe() bool { return t.Status == "review" }
func (t Ticket) Failed() bool  { return t.Status == "failed" }

type Event struct {
	EventType string
	Actor     string
	Payload   string
	CreatedAt time.Time
}

type server struct {
	db  *sql.DB
	tpl *template.Template

	// Shared secret for /api/*. Empty disables those endpoints entirely, so a
	// misconfigured deployment fails closed rather than serving an open API.
	agentToken string
}

func main() {
	// A scratch image has no curl, no wget, no shell — so the binary is its own
	// health probe. `paperclip -healthcheck` asks the running server whether it
	// can still reach the database and exits 0 or 1 accordingly.
	if len(os.Args) > 1 && os.Args[1] == "-healthcheck" {
		os.Exit(selfCheck())
	}

	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		log.Fatal("DATABASE_URL is not set")
	}

	db, err := sql.Open("pgx", dsn)
	if err != nil {
		log.Fatalf("open database: %v", err)
	}
	defer db.Close()

	// Small pool on purpose. Each service role has CONNECTION LIMIT 20
	// (ADR-0005); a UI that opens more than a handful is starving the agents of
	// connections to serve page views nobody is looking at.
	db.SetMaxOpenConns(5)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(time.Hour)

	// Fail fast and loudly. A UI that starts without a database and then 500s
	// on every request looks like a UI bug; this looks like what it is.
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		log.Fatalf("cannot reach the database: %v", err)
	}

	tpl, err := template.ParseFS(templateFS, "templates/*.html")
	if err != nil {
		log.Fatalf("parse templates: %v", err)
	}

	// Empty is allowed and disables /api/* — the UI still works. That is the
	// right default: an agent API served without a token would be reachable by
	// anything on the apps network.
	agentToken := os.Getenv("AGENT_API_TOKEN")
	if agentToken == "" {
		log.Print("AGENT_API_TOKEN not set — the agent API is disabled")
	}

	s := &server{db: db, tpl: tpl, agentToken: agentToken}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /{$}", s.handleIndex)
	mux.HandleFunc("GET /ticket/{id}", s.handleTicket)
	mux.HandleFunc("POST /ticket/{id}/status", s.handleStatus)
	mux.HandleFunc("POST /goal", s.handleNewGoal)

	// ── The agent API (M10, ADR-0019) ────────────────────────────────────
	// The agent runner reaches tickets through THIS, never through a database
	// connection string. That is the sandbox rule from M9: a session gets an
	// interface, not credentials. If an agent is prompt-injected, the worst it
	// can do here is claim and complete tickets — it cannot read another
	// service's data, because it never holds a Postgres password.
	//
	// Guarded by a shared token rather than Access: the runner is a machine on
	// the internal network and cannot complete a browser login. The endpoints
	// are unreachable from the internet regardless, since Caddy only exposes
	// this host and the agent network cannot route to it.
	mux.HandleFunc("POST /api/claim", s.requireToken(s.handleAPIClaim))
	mux.HandleFunc("POST /api/finish", s.requireToken(s.handleAPIFinish))
	mux.HandleFunc("POST /api/children", s.requireToken(s.handleAPIChildren))
	mux.HandleFunc("POST /api/event", s.requireToken(s.handleAPIEvent))

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Graceful shutdown so `docker compose restart` does not cut a request in
	// half and leave a ticket half-updated.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}()

	log.Printf("paperclip listening on %s", srv.Addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server: %v", err)
	}
}

// selfCheck runs in a SEPARATE, short-lived process that Docker starts for the
// healthcheck. It talks to the already-running server over localhost rather
// than opening its own database connection — otherwise every probe would burn
// one of the role's 20 allowed connections (ADR-0005) just to ask a question
// the server can already answer.
func selfCheck() int {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	client := &http.Client{Timeout: 4 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: %v\n", err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "healthcheck: status %d\n", resp.StatusCode)
		return 1
	}
	return 0
}

// Checks the DATABASE, not just that the process is alive. A health check that
// passes while the thing the service exists for is broken is worse than none:
// it turns an outage into a mystery.
func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := s.db.PingContext(ctx); err != nil {
		http.Error(w, "database unreachable", http.StatusServiceUnavailable)
		return
	}
	fmt.Fprintln(w, "ok")
}

const ticketColumns = `id, key, title, body, status, priority, domain, role,
	parent_id, claimed_by, result, last_error, attempts,
	created_at, updated_at, closed_at`

type scanner interface{ Scan(...any) error }

func scanTicket(row scanner) (Ticket, error) {
	var t Ticket
	err := row.Scan(&t.ID, &t.Key, &t.Title, &t.Body, &t.Status, &t.Priority,
		&t.Domain, &t.Role, &t.ParentID, &t.ClaimedBy, &t.Result, &t.LastError,
		&t.Attempts, &t.CreatedAt, &t.UpdatedAt, &t.ClosedAt)
	return t, err
}

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	// Ordered so the things wanting attention come first: review (a human is
	// the blocker), then failed, then the live queue, then history.
	rows, err := s.db.QueryContext(r.Context(), `
		SELECT `+ticketColumns+` FROM tickets
		ORDER BY
			CASE status
				WHEN 'review'  THEN 0
				WHEN 'failed'  THEN 1
				WHEN 'open'    THEN 2
				WHEN 'claimed' THEN 3
				WHEN 'blocked' THEN 4
				ELSE 5
			END,
			priority DESC, created_at DESC
		LIMIT 200`)
	if err != nil {
		s.fail(w, "load tickets", err)
		return
	}
	defer rows.Close()

	var tickets []Ticket
	counts := map[string]int{}
	for rows.Next() {
		t, err := scanTicket(rows)
		if err != nil {
			s.fail(w, "read ticket", err)
			return
		}
		tickets = append(tickets, t)
		counts[t.Status]++
	}
	if err := rows.Err(); err != nil {
		s.fail(w, "read tickets", err)
		return
	}

	s.render(w, "index.html", map[string]any{
		"Tickets": tickets,
		"Counts":  counts,
		"Total":   len(tickets),
	})
}

func (s *server) handleTicket(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		http.Error(w, "bad ticket id", http.StatusBadRequest)
		return
	}

	row := s.db.QueryRowContext(r.Context(),
		`SELECT `+ticketColumns+` FROM tickets WHERE id = $1`, id)
	t, err := scanTicket(row)
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "no such ticket", http.StatusNotFound)
		return
	} else if err != nil {
		s.fail(w, "load ticket", err)
		return
	}

	// The event log is the only record of what an agent actually did, so the
	// detail page shows it in full rather than summarising.
	evRows, err := s.db.QueryContext(r.Context(), `
		SELECT event_type, actor, payload::text, created_at
		FROM ticket_events WHERE ticket_id = $1 ORDER BY id`, id)
	if err != nil {
		s.fail(w, "load events", err)
		return
	}
	defer evRows.Close()

	var events []Event
	for evRows.Next() {
		var e Event
		if err := evRows.Scan(&e.EventType, &e.Actor, &e.Payload, &e.CreatedAt); err != nil {
			s.fail(w, "read event", err)
			return
		}
		events = append(events, e)
	}
	if err := evRows.Err(); err != nil {
		s.fail(w, "read events", err)
		return
	}

	children, err := s.childrenOf(r.Context(), id)
	if err != nil {
		s.fail(w, "load children", err)
		return
	}

	s.render(w, "ticket.html", map[string]any{
		"T": t, "Events": events, "Children": children,
	})
}

func (s *server) childrenOf(ctx context.Context, id int64) ([]Ticket, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT `+ticketColumns+` FROM tickets WHERE parent_id = $1 ORDER BY id`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Ticket
	for rows.Next() {
		t, err := scanTicket(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// The review gate: an agent finishes into 'review' and a human decides whether
// it is actually done. Deliberately not automatic — an agent should not certify
// its own work.
func (s *server) handleStatus(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		http.Error(w, "bad ticket id", http.StatusBadRequest)
		return
	}

	status := r.FormValue("status")
	// Whitelist, not passthrough. The enum would reject anything else anyway,
	// but a 400 here beats a 500 out of the database.
	switch status {
	case "done", "cancelled", "open":
	default:
		http.Error(w, "status not allowed from the UI", http.StatusBadRequest)
		return
	}

	// closed_at is set exactly for terminal states — the schema enforces this,
	// and getting it wrong is what silently stuck every early worker ticket.
	closed := "NULL"
	if status == "done" || status == "cancelled" {
		closed = "now()"
	}

	_, err = s.db.ExecContext(r.Context(), fmt.Sprintf(`
		UPDATE tickets
		SET status = $1::ticket_status, claimed_by = NULL, closed_at = %s
		WHERE id = $2`, closed), status, id)
	if err != nil {
		s.fail(w, "update status", err)
		return
	}

	if _, err := s.db.ExecContext(r.Context(), `
		INSERT INTO ticket_events (ticket_id, event_type, actor, payload)
		VALUES ($1, 'status_changed', 'operator', jsonb_build_object('to', $2::text))`,
		id, status); err != nil {
		// Not fatal: the status change succeeded and that is what the operator
		// asked for. But a missing audit entry is worth a log line.
		log.Printf("status_changed event not recorded for #%d: %v", id, err)
	}

	http.Redirect(w, r, "/ticket/"+strconv.FormatInt(id, 10), http.StatusSeeOther)
}

func (s *server) handleNewGoal(w http.ResponseWriter, r *http.Request) {
	goal := strings.TrimSpace(r.FormValue("goal"))
	if goal == "" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}

	title := goal
	if len(title) > 200 {
		title = title[:200]
	}

	// role 'ceo': the runner picks this up and decomposes it into workers.
	if _, err := s.db.ExecContext(r.Context(), `
		INSERT INTO tickets (title, body, role, priority)
		VALUES ($1, $2, 'ceo', 'normal')`, title, goal); err != nil {
		s.fail(w, "create goal", err)
		return
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// ── The agent API ───────────────────────────────────────────────────────────

// requireToken gates the /api/* endpoints. A constant-time comparison, because
// a naive == leaks the token one byte at a time to anyone who can measure.
func (s *server) requireToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.agentToken == "" {
			http.Error(w, "agent API disabled", http.StatusNotFound)
			return
		}
		got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if subtle.ConstantTimeCompare([]byte(got), []byte(s.agentToken)) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("write json: %v", err)
	}
}

// handleAPIClaim hands out exactly one ticket, atomically.
//
// FOR UPDATE SKIP LOCKED is what makes concurrent runners safe: two agents
// polling in the same instant cannot claim the same ticket, and neither blocks
// waiting for the other.
func (s *server) handleAPIClaim(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Role   string `json:"role"`
		Runner string `json:"runner"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if req.Role != "ceo" && req.Role != "worker" {
		http.Error(w, "role must be ceo or worker", http.StatusBadRequest)
		return
	}

	var t Ticket
	err := s.db.QueryRowContext(r.Context(), `
		UPDATE tickets SET
			status = 'claimed', claimed_by = $1, claimed_at = now(),
			attempts = attempts + 1
		WHERE id = (
			SELECT id FROM tickets
			WHERE status = 'open' AND role = $2
			ORDER BY priority DESC, created_at
			FOR UPDATE SKIP LOCKED
			LIMIT 1
		)
		RETURNING `+ticketColumns, req.Runner, req.Role).Scan(
		&t.ID, &t.Key, &t.Title, &t.Body, &t.Status, &t.Priority,
		&t.Domain, &t.Role, &t.ParentID, &t.ClaimedBy, &t.Result, &t.LastError,
		&t.Attempts, &t.CreatedAt, &t.UpdatedAt, &t.ClosedAt)

	if errors.Is(err, sql.ErrNoRows) {
		// An empty queue is the normal case, not an error.
		writeJSON(w, map[string]any{"ticket": nil})
		return
	} else if err != nil {
		s.failJSON(w, "claim", err)
		return
	}

	writeJSON(w, map[string]any{"ticket": map[string]any{
		"id": t.ID, "title": t.Title, "body": t.Body,
		"role": t.Role, "attempts": t.Attempts,
	}})
}

func (s *server) handleAPIFinish(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID     int64  `json:"id"`
		Status string `json:"status"`
		Result string `json:"result"`
		Error  string `json:"error"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	// Whitelist. 'done' and 'cancelled' are not here on purpose: an agent does
	// not close its own work, a human does that through the review gate.
	switch req.Status {
	case "review", "failed", "open":
	default:
		http.Error(w, "status not allowed from an agent", http.StatusBadRequest)
		return
	}

	// closed_at exactly for terminal states — the schema enforces this, and
	// getting it wrong is what silently stuck every early worker ticket.
	closed := "NULL"
	if req.Status == "failed" {
		closed = "now()"
	}

	if _, err := s.db.ExecContext(r.Context(), fmt.Sprintf(`
		UPDATE tickets SET status = $1::ticket_status, claimed_by = NULL,
			result = NULLIF($2, ''), last_error = NULLIF($3, ''), closed_at = %s
		WHERE id = $4`, closed),
		req.Status, req.Result, req.Error, req.ID); err != nil {
		s.failJSON(w, "finish", err)
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

// handleAPIChildren turns a CEO's plan into worker tickets. Validation lives
// here rather than in the agent: the runner is the untrusted party, and a
// domain or priority the enum rejects would fail the whole insert.
func (s *server) handleAPIChildren(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ParentID int64 `json:"parent_id"`
		Children []struct {
			Title    string `json:"title"`
			Body     string `json:"body"`
			Domain   string `json:"domain"`
			Priority string `json:"priority"`
		} `json:"children"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if len(req.Children) == 0 {
		http.Error(w, "no children", http.StatusBadRequest)
		return
	}
	if len(req.Children) > 20 {
		// A CEO asked for at most 6. Twenty is already a runaway.
		http.Error(w, "too many children", http.StatusBadRequest)
		return
	}

	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		s.failJSON(w, "begin", err)
		return
	}
	defer func() { _ = tx.Rollback() }()

	for _, c := range req.Children {
		title := strings.TrimSpace(c.Title)
		if title == "" {
			title = "untitled"
		}
		if len(title) > 500 {
			title = title[:500]
		}
		if _, err := tx.ExecContext(r.Context(), `
			INSERT INTO tickets (title, body, domain, priority, parent_id, role)
			VALUES ($1, $2, $3, $4::ticket_priority, $5, 'worker')`,
			title, c.Body, normaliseDomain(c.Domain), normalisePriority(c.Priority),
			req.ParentID); err != nil {
			s.failJSON(w, "insert child", err)
			return
		}
	}

	if err := tx.Commit(); err != nil {
		s.failJSON(w, "commit", err)
		return
	}
	writeJSON(w, map[string]any{"created": len(req.Children)})
}

func (s *server) handleAPIEvent(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TicketID int64  `json:"ticket_id"`
		Type     string `json:"type"`
		Actor    string `json:"actor"`
		Payload  string `json:"payload"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if req.Payload == "" {
		req.Payload = "{}"
	}
	if _, err := s.db.ExecContext(r.Context(), `
		INSERT INTO ticket_events (ticket_id, event_type, actor, payload)
		VALUES ($1, $2, $3, $4::jsonb)`,
		req.TicketID, req.Type, req.Actor, req.Payload); err != nil {
		s.failJSON(w, "event", err)
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

// Fall back rather than reject: one odd value should not lose a CEO's entire
// plan, and the enum would refuse the insert outright.
func normaliseDomain(d string) string {
	switch d {
	case "uni", "work", "jobsearch", "personal", "projects":
		return d
	default:
		return "personal"
	}
}

func normalisePriority(p string) string {
	switch p {
	case "low", "normal", "high", "urgent":
		return p
	default:
		return "normal"
	}
}

func (s *server) failJSON(w http.ResponseWriter, what string, err error) {
	log.Printf("api %s: %v", what, err)
	http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
}

func (s *server) render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.tpl.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("render %s: %v", name, err)
	}
}

// The browser gets a generic message; the log gets the detail. A database error
// echoed into a page is an information leak, and being behind Access is not a
// reason to be careless about it.
func (s *server) fail(w http.ResponseWriter, what string, err error) {
	log.Printf("%s: %v", what, err)
	http.Error(w, "internal error — see the container log", http.StatusInternalServerError)
}
