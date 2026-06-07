package auth

import (
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/AzureAD/microsoft-authentication-library-for-go/apps/public"
)

// LoginSessionTTL is the maximum time a session may sit unclaimed in the
// store. After this deadline the session is considered abandoned and will
// be removed by the next call to [LoginSessionStore.Register]. MSAL's own
// interactive-flow timeout is ~5 minutes; we allow a little more headroom
// so a slow user is not evicted before MSAL gives up.
const LoginSessionTTL = 10 * time.Minute

// ErrSessionNotFound is returned by [LoginSessionStore.Claim] when no
// session with the given ID exists (already claimed, never started, or
// the daemon was restarted).
var ErrSessionNotFound = errors.New("auth: login session not found")

// LoginSessionResult is the outcome of one completed MSAL interactive
// login, delivered through [LoginSession.ResultCh].
type LoginSessionResult struct {
	Account    Account
	MSALAcct   public.Account
	CacheBytes []byte
	Err        error
}

// LoginSession is an in-flight two-phase interactive login. The host
// app receives an AuthURL from the daemon via auth.login.start, opens
// the browser, and then calls auth.login.complete to wait for the OAuth
// redirect to arrive at MSAL's localhost listener.
//
// The lifecycle is single-use: once ResultCh delivers a value the session
// is done and must not be reused.
type LoginSession struct {
	// ID is the opaque session token the client passes back in
	// auth.login.complete to identify this particular login attempt.
	ID string

	// AuthURL is the Microsoft Entra authorization URL that the host
	// app must open in the system browser.
	AuthURL string

	// ResultCh receives exactly one value when MSAL completes or fails
	// the OAuth exchange. The channel has a buffer of 1 so the MSAL
	// goroutine never blocks if the client disconnects before calling
	// auth.login.complete.
	ResultCh chan LoginSessionResult

	// createdAt is used by [LoginSessionStore.Register] to evict sessions
	// that have exceeded [LoginSessionTTL] without being claimed.
	createdAt time.Time
}

// LoginSessionStore is a concurrency-safe map of pending login sessions
// keyed by session ID. It is owned by [Handlers] and lives for the
// daemon's lifetime.
//
// The zero value is not usable; construct with [NewLoginSessionStore].
type LoginSessionStore struct {
	mu       sync.Mutex
	sessions map[string]*LoginSession
}

// NewLoginSessionStore returns an empty, ready-to-use store.
func NewLoginSessionStore() *LoginSessionStore {
	return &LoginSessionStore{
		sessions: make(map[string]*LoginSession),
	}
}

// Register inserts sess into the store keyed by sess.ID. It panics if
// sess or sess.ID is zero — both are programming errors.
//
// As a side effect, Register sweeps and removes any sessions that have
// exceeded [LoginSessionTTL] without being claimed. This keeps the map
// bounded for long-running daemons even if many logins are abandoned.
func (s *LoginSessionStore) Register(sess *LoginSession) {
	if sess == nil || sess.ID == "" {
		panic("auth: LoginSessionStore.Register: nil or empty session")
	}
	now := time.Now()
	sess.createdAt = now
	s.mu.Lock()
	defer s.mu.Unlock()
	// Evict abandoned sessions before inserting the new one.
	for id, existing := range s.sessions {
		if now.Sub(existing.createdAt) > LoginSessionTTL {
			delete(s.sessions, id)
		}
	}
	s.sessions[sess.ID] = sess
}

// Claim removes the session with the given id from the store and returns
// it. If no session with that id exists, [ErrSessionNotFound] is
// returned. Claim is the only way to obtain a session for consumption;
// calling it twice for the same id always returns an error on the second
// call, preventing replay.
func (s *LoginSessionStore) Claim(id string) (*LoginSession, error) {
	if id == "" {
		return nil, fmt.Errorf("auth: session id is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.sessions[id]
	if !ok {
		return nil, fmt.Errorf("%w: %q", ErrSessionNotFound, id)
	}
	delete(s.sessions, id)
	return sess, nil
}
