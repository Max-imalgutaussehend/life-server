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
	"database/sql"
	"embed"
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

	s := &server{db: db, tpl: tpl}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /{$}", s.handleIndex)
	mux.HandleFunc("GET /ticket/{id}", s.handleTicket)
	mux.HandleFunc("POST /ticket/{id}/status", s.handleStatus)
	mux.HandleFunc("POST /goal", s.handleNewGoal)

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
